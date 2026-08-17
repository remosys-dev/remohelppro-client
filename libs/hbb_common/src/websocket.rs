use crate::{
    config::{
        keys::OPTION_RELAY_SERVER, use_ws, Config, Socks5Server, RELAY_PORT, RENDEZVOUS_PORT,
    },
    protobuf::Message,
    socket_client::split_host_port,
    sodiumoxide::crypto::secretbox::Key,
    tcp::{DynTcpStream, Encrypt},
    tls::{get_cached_tls_accept_invalid_cert, get_cached_tls_type, upsert_tls_cache, TlsType},
    ResultType,
};
use anyhow::bail;
use async_recursion::async_recursion;
use bytes::{Bytes, BytesMut};
use futures::{SinkExt, StreamExt};
use std::{
    io::{Error, ErrorKind},
    net::SocketAddr,
    sync::Arc,
    time::Duration,
};
use tokio::{net::TcpStream, time::timeout};
use tokio_native_tls::native_tls::TlsConnector;
use tokio_tungstenite::{
    client_async_tls_with_config, tungstenite::protocol::Message as WsMessage, Connector,
    MaybeTlsStream, WebSocketStream,
};
use tungstenite::client::IntoClientRequest;
use tungstenite::protocol::Role;

/// 443 の道が通る「土管」。直につないだ TCP でも、プロキシ越しでも同じ形にする。
///
/// 🔴🔴 なぜ型を変えたか（2026-08-17）。
///   元は `MaybeTlsStream<TcpStream>` に固定されていた。
///   ⚠ プロキシを通すと中身は TcpStream ではなくなる（CONNECT 後の緩衝つきの流れ、
///     あるいは socks5 の流れ）ので、この型のままでは**入れられなかった**。
///   ＝ だから上流は `// to-do: websocket proxy.` のまま放置されていた。
///   `DynTcpStream` は中身を箱に入れて隠すので、どちらも同じ形で扱える。
type WsTransport = MaybeTlsStream<DynTcpStream>;

pub struct WsFramedStream {
    stream: WebSocketStream<WsTransport>,
    addr: SocketAddr,
    encrypt: Option<Encrypt>,
    send_timeout: u64,
}

/// 443 の宛先を「ホスト名」と「ポート」に分ける。
///
/// ⚠ `wss` と `ws` は `url` が既定のポートを知らないので、自分で決める。
///   知らないまま 0 番を使うと、**プロキシに CONNECT 先 0 番を頼む**ことになり
///   必ず断られる。
fn ws_host_port(url: &str) -> ResultType<(String, u16)> {
    let u = url::Url::parse(url)?;
    let host = match u.host_str() {
        Some(h) => h.to_string(),
        None => bail!("no host in websocket url: {}", url),
    };
    let default_port = match u.scheme() {
        "wss" | "https" => 443u16,
        _ => 80u16,
    };
    Ok((host, u.port().unwrap_or(default_port)))
}

/// 443 の土管を1本開ける。プロキシが設定されていれば、必ずそこを通す。
///
/// ⚠ 直つなぎのときは、これまでどおり local_addr を使わない。
///   使うと、ポートの再利用の都合で IPv6/IPv4 の食い違いが出て、
///   **今まで繋がっていた環境が繋がらなくなる**（穴を塞ぐつもりで穴を開ける）。
async fn open_ws_transport(
    url: &str,
    proxy_conf: Option<&Socks5Server>,
    ms_timeout: u64,
) -> ResultType<(DynTcpStream, SocketAddr)> {
    let (host, port) = ws_host_port(url)?;

    if let Some(conf) = proxy_conf {
        log::info!(
            "RL: 443の道もプロキシを通します（宛先 {}:{}）",
            host,
            port
        );
        let proxy = crate::proxy::Proxy::from_conf(conf, Some(ms_timeout))?;
        return proxy.connect_raw((host.as_str(), port), None).await;
    }

    let mut last_err: Option<anyhow::Error> = None;
    match tokio::net::lookup_host((host.as_str(), port)).await {
        Ok(addrs) => {
            for addr in addrs {
                match timeout(Duration::from_millis(ms_timeout), TcpStream::connect(addr)).await {
                    Ok(Ok(s)) => {
                        s.set_nodelay(true).ok();
                        return Ok((DynTcpStream(Box::new(s)), addr));
                    }
                    Ok(Err(e)) => last_err = Some(e.into()),
                    Err(e) => last_err = Some(e.into()),
                }
            }
        }
        // ⚠ 名前を引けないのも「直接は出られない」の一つの形。
        //   ここで諦めずに、下のプロキシの逃げ道まで進む。
        Err(e) => last_err = Some(e.into()),
    }

    // 🔴 最後の逃げ道: パソコンに元から入っているプロキシの設定を使う。
    //
    //   ⚠ お客様は自分の会社のプロキシの場所を知らない。常駐には画面が無い。
    //     手で入れてもらう道だけでは、実際には届かない。
    //   ★直につないで駄目だったときにだけ使う。
    //     普段（家庭・直接出られる会社）はここまで来ないので、
    //     **今まで繋がっていた環境の動きは何も変わらない**。
    if let Some(conf) = crate::system_proxy::detect() {
        log::info!("RL: 直接つなげなかったので、パソコンのプロキシ設定で試します");
        match crate::proxy::Proxy::from_conf(&conf, Some(ms_timeout)) {
            Ok(proxy) => match proxy.connect_raw((host.as_str(), port), None).await {
                Ok(v) => {
                    log::info!("RL: パソコンのプロキシ設定で 443 の道が通りました");
                    return Ok(v);
                }
                Err(e) => log::warn!("RL: パソコンのプロキシ設定でも通りませんでした: {}", e),
            },
            Err(e) => log::warn!("RL: パソコンのプロキシ設定を読めましたが、使えません: {}", e),
        }
    }

    match last_err {
        Some(e) => bail!(e),
        None => bail!("no address resolved for {}:{}", host, port),
    }
}

impl WsFramedStream {
    #[inline]
    fn get_connector(
        tls_type: &TlsType,
        danger_accept_invalid_certs: bool,
    ) -> ResultType<Option<Connector>> {
        match tls_type {
            TlsType::Plain => Ok(Some(Connector::Plain)),
            TlsType::NativeTls => {
                let connector = TlsConnector::builder()
                    .danger_accept_invalid_certs(danger_accept_invalid_certs)
                    .build()?;
                Ok(Some(Connector::NativeTls(connector)))
            }
            TlsType::Rustls => {
                let connector = match crate::verifier::client_config(danger_accept_invalid_certs) {
                    Ok(client_config) => Some(Connector::Rustls(Arc::new(client_config))),
                    Err(e) => {
                        log::warn!(
                            "Failed to get client config: {:?}, fallback to default connector",
                            e
                        );
                        None
                    }
                };
                Ok(connector)
            }
        }
    }

    async fn connect(
        url: &str,
        proxy_conf: Option<&Socks5Server>,
        ms_timeout: u64,
    ) -> ResultType<(WebSocketStream<WsTransport>, SocketAddr)> {
        let tls_type = get_cached_tls_type(url);
        let is_tls_type_cached = tls_type.is_some();
        let tls_type = tls_type.unwrap_or(TlsType::Rustls);
        let danger_accept_invalid_cert = get_cached_tls_accept_invalid_cert(&url);
        Self::try_connect(
            url,
            proxy_conf,
            ms_timeout,
            tls_type,
            is_tls_type_cached,
            danger_accept_invalid_cert,
            danger_accept_invalid_cert,
        )
        .await
    }

    #[async_recursion]
    async fn try_connect(
        url: &str,
        proxy_conf: Option<&'async_recursion Socks5Server>,
        ms_timeout: u64,
        tls_type: TlsType,
        is_tls_type_cached: bool,
        danger_accept_invalid_cert: Option<bool>,
        original_danger_accept_invalid_certs: Option<bool>,
    ) -> ResultType<(WebSocketStream<WsTransport>, SocketAddr)> {
        let ws_config = None;
        let request = url
            .into_client_request()
            .map_err(|e| Error::new(ErrorKind::Other, e))?;
        let connector =
            Self::get_connector(&tls_type, danger_accept_invalid_cert.unwrap_or(false))?;
        // ⚠ 土管は**やり直すたびに開け直す**こと。
        //   TLS の種類を変えて試し直す作りなので、使い終わった流れは再利用できない。
        let (transport, addr) = open_ws_transport(url, proxy_conf, ms_timeout).await?;
        match timeout(
            Duration::from_millis(ms_timeout),
            client_async_tls_with_config(request, transport, ws_config, connector),
        )
        .await?
        {
            Ok((ws_stream, _)) => {
                upsert_tls_cache(url, tls_type, danger_accept_invalid_cert.unwrap_or(false));
                Ok((ws_stream, addr))
            }
            Err(e) => match (tls_type, is_tls_type_cached, danger_accept_invalid_cert) {
                (TlsType::Rustls, _, None) => {
                    log::warn!(
                            "WebSocket connection with rustls-tls failed, try accept invalid certs: {}, {:?}",
                            url,
                            e
                        );
                    Self::try_connect(
                        url,
                        proxy_conf,
                        ms_timeout,
                        tls_type,
                        is_tls_type_cached,
                        Some(true),
                        original_danger_accept_invalid_certs,
                    )
                    .await
                }
                (TlsType::Rustls, false, Some(_)) => {
                    log::warn!(
                        "WebSocket connection with rustls-tls failed, try native-tls: {}, {:?}",
                        url,
                        e
                    );
                    Self::try_connect(
                        url,
                        proxy_conf,
                        ms_timeout,
                        TlsType::NativeTls,
                        is_tls_type_cached,
                        original_danger_accept_invalid_certs,
                        original_danger_accept_invalid_certs,
                    )
                    .await
                }
                (TlsType::NativeTls, _, None) => {
                    log::warn!(
                            "WebSocket connection with native-tls failed, try accept invalid certs: {}, {:?}",
                            url,
                            e
                        );
                    Self::try_connect(
                        url,
                        proxy_conf,
                        ms_timeout,
                        tls_type,
                        is_tls_type_cached,
                        Some(true),
                        original_danger_accept_invalid_certs,
                    )
                    .await
                }
                _ => {
                    log::error!(
                        "WebSocket connection failed with tls_type {:?}: {}, {:?}",
                        tls_type,
                        url,
                        e
                    );
                    bail!(e)
                }
            },
        }
    }

    pub async fn new<T: AsRef<str>>(
        url: T,
        _local_addr: Option<SocketAddr>,
        proxy_conf: Option<&Socks5Server>,
        ms_timeout: u64,
    ) -> ResultType<Self> {
        // ⚠ 相手の住所は、土管を開けたときに控えておく。
        //   中身を箱に入れて隠したので、後から流れに聞くことはできない
        //   （プロキシ越しだと、そもそも聞いても**プロキシの住所**しか返らない）。
        let (stream, addr) = Self::connect(url.as_ref(), proxy_conf, ms_timeout).await?;

        let ws = Self {
            stream,
            addr,
            encrypt: None,
            send_timeout: ms_timeout,
        };

        Ok(ws)
    }

    #[inline]
    pub fn set_raw(&mut self) {
        self.encrypt = None;
    }

    #[inline]
    pub async fn from_tcp_stream(stream: TcpStream, addr: SocketAddr) -> ResultType<Self> {
        let ws_stream =
            WebSocketStream::from_raw_socket(
                MaybeTlsStream::Plain(DynTcpStream(Box::new(stream))),
                Role::Client,
                None,
            )
                .await;

        Ok(Self {
            stream: ws_stream,
            addr,
            encrypt: None,
            send_timeout: 0,
        })
    }

    #[inline]
    pub fn local_addr(&self) -> SocketAddr {
        self.addr
    }

    #[inline]
    pub fn set_send_timeout(&mut self, ms: u64) {
        self.send_timeout = ms;
    }

    #[inline]
    pub fn set_key(&mut self, key: Key) {
        self.encrypt = Some(Encrypt::new(key));
    }

    #[inline]
    pub fn is_secured(&self) -> bool {
        self.encrypt.is_some()
    }

    #[inline]
    pub async fn send(&mut self, msg: &impl Message) -> ResultType<()> {
        self.send_raw(msg.write_to_bytes()?).await
    }

    #[inline]
    pub async fn send_raw(&mut self, msg: Vec<u8>) -> ResultType<()> {
        let mut msg = msg;
        if let Some(key) = self.encrypt.as_mut() {
            msg = key.enc(&msg);
        }
        self.send_bytes(Bytes::from(msg)).await
    }

    pub async fn send_bytes(&mut self, bytes: Bytes) -> ResultType<()> {
        let msg = WsMessage::Binary(bytes);
        if self.send_timeout > 0 {
            timeout(
                Duration::from_millis(self.send_timeout),
                self.stream.send(msg),
            )
            .await??
        } else {
            self.stream.send(msg).await?
        };
        Ok(())
    }

    #[inline]
    pub async fn next(&mut self) -> Option<Result<BytesMut, Error>> {
        while let Some(msg) = self.stream.next().await {
            let msg = match msg {
                Ok(msg) => msg,
                Err(e) => {
                    log::error!("{}", e);
                    return Some(Err(Error::new(
                        ErrorKind::Other,
                        format!("WebSocket protocol error: {}", e),
                    )));
                }
            };

            match msg {
                WsMessage::Binary(data) => {
                    let mut bytes = BytesMut::from(&data[..]);
                    if let Some(key) = self.encrypt.as_mut() {
                        if let Err(err) = key.dec(&mut bytes) {
                            return Some(Err(err));
                        }
                    }
                    return Some(Ok(bytes));
                }
                WsMessage::Text(text) => {
                    let bytes = BytesMut::from(text.as_bytes());
                    return Some(Ok(bytes));
                }
                WsMessage::Close(_) => {
                    return None;
                }
                _ => {
                    continue;
                }
            }
        }

        None
    }

    #[inline]
    pub async fn next_timeout(&mut self, ms: u64) -> Option<Result<BytesMut, Error>> {
        match timeout(Duration::from_millis(ms), self.next()).await {
            Ok(res) => res,
            Err(_) => None,
        }
    }
}

pub fn is_ws_endpoint(endpoint: &str) -> bool {
    endpoint.starts_with("ws://") || endpoint.starts_with("wss://")
}

/**
 * Core function to convert an endpoint to WebSocket format
 *
 * Converts between different address formats:
 * 1. IPv4 address with/without port -> ws://ipv4:port
 * 2. IPv6 address with/without port -> ws://[ipv6]:port
 * 3. Domain with/without port -> ws(s)://domain/ws/path
 *
 * @param endpoint The endpoint to convert
 * @return The converted WebSocket endpoint
 */
pub fn check_ws(endpoint: &str) -> String {
    if !use_ws() {
        return endpoint.to_string();
    }

    if endpoint.is_empty() {
        return endpoint.to_string();
    }

    if is_ws_endpoint(endpoint) {
        return endpoint.to_string();
    }

    let Some((endpoint_host, endpoint_port)) = split_host_port(endpoint) else {
        debug_assert!(false, "endpoint doesn't have port");
        return endpoint.to_string();
    };

    let custom_rendezvous_server = Config::get_rendezvous_server();
    let relay_server = Config::get_option(OPTION_RELAY_SERVER);
    let rendezvous_port = split_host_port(&custom_rendezvous_server)
        .map(|(_, p)| p)
        .unwrap_or(RENDEZVOUS_PORT);
    let relay_port = split_host_port(&relay_server)
        .map(|(_, p)| p)
        .unwrap_or(RELAY_PORT);

    let (relay, dst_port) = if endpoint_port == rendezvous_port {
        // rendezvous
        (false, endpoint_port + 2)
    } else if endpoint_port == rendezvous_port - 1 {
        // online
        (false, endpoint_port + 3)
    } else if endpoint_port == relay_port || endpoint_port == rendezvous_port + 1 {
        // relay
        // https://github.com/rustdesk/rustdesk/blob/6ffbcd1375771f2482ec4810680623a269be70f1/src/rendezvous_mediator.rs#L615
        // https://github.com/rustdesk/rustdesk-server/blob/235a3c326ceb665e941edb50ab79faa1208f7507/src/relay_server.rs#L83, based on relay port.
        (true, endpoint_port + 2)
    } else {
        // fallback relay
        // for controlling side, relay server is passed from the controlled side, not related to local config.
        (true, endpoint_port + 2)
    };

    let (address, is_domain) = if crate::is_ip_str(endpoint) {
        (format!("{}:{}", endpoint_host, dst_port), false)
    } else {
        let domain_path = if relay { "/ws/relay" } else { "/ws/id" };
        (format!("{}{}", endpoint_host, domain_path), true)
    };
    let protocol = if is_domain {
        let api_server = Config::get_option("api-server");
        if api_server.starts_with("https") {
            "wss"
        } else {
            "ws"
        }
    } else {
        "ws"
    };
    format!("{}://{}", protocol, address)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{keys, Config};

    #[test]
    fn test_check_ws() {
        // enable websocket
        Config::set_option(keys::OPTION_ALLOW_WEBSOCKET.to_string(), "Y".to_string());

        // not set custom-rendezvous-server
        Config::set_option("custom-rendezvous-server".to_string(), "".to_string());
        Config::set_option("relay-server".to_string(), "".to_string());
        Config::set_option("api-server".to_string(), "".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        assert_eq!(check_ws("rustdesk.com:21115"), "ws://rustdesk.com/ws/id");
        assert_eq!(check_ws("rustdesk.com:21116"), "ws://rustdesk.com/ws/id");
        assert_eq!(check_ws("rustdesk.com:21117"), "ws://rustdesk.com/ws/relay");
        // set relay-server without port
        Config::set_option("relay-server".to_string(), "127.0.0.1".to_string());
        Config::set_option(
            "api-server".to_string(),
            "https://api.rustdesk.com".to_string(),
        );
        assert_eq!(
            check_ws("[0:0:0:0:0:0:0:1]:21115"),
            "ws://[0:0:0:0:0:0:0:1]:21118"
        );
        assert_eq!(
            check_ws("[0:0:0:0:0:0:0:1]:21116"),
            "ws://[0:0:0:0:0:0:0:1]:21118"
        );
        assert_eq!(
            check_ws("[0:0:0:0:0:0:0:1]:21117"),
            "ws://[0:0:0:0:0:0:0:1]:21119"
        );
        assert_eq!(check_ws("rustdesk.com:21115"), "wss://rustdesk.com/ws/id");
        assert_eq!(check_ws("rustdesk.com:21116"), "wss://rustdesk.com/ws/id");
        assert_eq!(
            check_ws("rustdesk.com:21117"),
            "wss://rustdesk.com/ws/relay"
        );
        // set relay-server with default port
        Config::set_option("relay-server".to_string(), "127.0.0.1:21117".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server with custom port
        Config::set_option("relay-server".to_string(), "127.0.0.1:34567".to_string());
        assert_eq!(check_ws("rustdesk.com:21115"), "wss://rustdesk.com/ws/id");
        assert_eq!(check_ws("rustdesk.com:21116"), "wss://rustdesk.com/ws/id");
        assert_eq!(
            check_ws("rustdesk.com:34567"),
            "wss://rustdesk.com/ws/relay"
        );

        // set custom-rendezvous-server without port
        Config::set_option(
            "custom-rendezvous-server".to_string(),
            "127.0.0.1".to_string(),
        );
        Config::set_option("relay-server".to_string(), "".to_string());
        Config::set_option("api-server".to_string(), "".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server without port
        Config::set_option("relay-server".to_string(), "127.0.0.1".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server with default port
        Config::set_option("relay-server".to_string(), "127.0.0.1:21117".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server with custom port
        Config::set_option("relay-server".to_string(), "127.0.0.1:34567".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:34567"), "ws://127.0.0.1:34569");

        // set custom-rendezvous-server without default port
        Config::set_option(
            "custom-rendezvous-server".to_string(),
            "127.0.0.1".to_string(),
        );
        Config::set_option("relay-server".to_string(), "".to_string());
        Config::set_option("api-server".to_string(), "".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server without port
        Config::set_option("relay-server".to_string(), "127.0.0.1".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server with default port
        Config::set_option("relay-server".to_string(), "127.0.0.1:21117".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server with custom port
        Config::set_option("relay-server".to_string(), "127.0.0.1:34567".to_string());
        assert_eq!(check_ws("127.0.0.1:21115"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:21116"), "ws://127.0.0.1:21118");
        assert_eq!(check_ws("127.0.0.1:34567"), "ws://127.0.0.1:34569");

        // set custom-rendezvous-server with custom port
        Config::set_option(
            "custom-rendezvous-server".to_string(),
            "127.0.0.1:23456".to_string(),
        );
        Config::set_option("relay-server".to_string(), "".to_string());
        Config::set_option("api-server".to_string(), "".to_string());
        assert_eq!(check_ws("127.0.0.1:23455"), "ws://127.0.0.1:23458");
        assert_eq!(check_ws("127.0.0.1:23456"), "ws://127.0.0.1:23458");
        assert_eq!(check_ws("127.0.0.1:23457"), "ws://127.0.0.1:23459");
        // set relay-server without port
        Config::set_option("relay-server".to_string(), "127.0.0.1".to_string());
        assert_eq!(check_ws("127.0.0.1:23455"), "ws://127.0.0.1:23458");
        assert_eq!(check_ws("127.0.0.1:23456"), "ws://127.0.0.1:23458");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server with default port
        Config::set_option("relay-server".to_string(), "127.0.0.1:21117".to_string());
        assert_eq!(check_ws("127.0.0.1:23455"), "ws://127.0.0.1:23458");
        assert_eq!(check_ws("127.0.0.1:23456"), "ws://127.0.0.1:23458");
        assert_eq!(check_ws("127.0.0.1:21117"), "ws://127.0.0.1:21119");
        // set relay-server with custom port
        Config::set_option("relay-server".to_string(), "127.0.0.1:34567".to_string());
        assert_eq!(check_ws("127.0.0.1:23455"), "ws://127.0.0.1:23458");
        assert_eq!(check_ws("127.0.0.1:23456"), "ws://127.0.0.1:23458");
        assert_eq!(check_ws("127.0.0.1:34567"), "ws://127.0.0.1:34569");
    }
}
