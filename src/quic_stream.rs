// RemoSys 自作エンジン I-1: QUIC トランスポート（KCP→QUIC で HoL ブロッキング解消）
//
// 設計: docs/engine_integration_remohelppro.md（RemoSys リポジトリ）。
// 継ぎ目の核は engine-poc の I-1a/I-1b で実証済み：
//   - I-1a: quinn の (SendStream,RecvStream)→tokio::io::join→Framed でメッセージ往復（300/300）。
//   - I-1b: quinn を「外から渡した既存UDPソケット」で稼働（穴あけ済みソケット相当・200/200）。
// 本ファイルは KCP(`kcp_stream.rs`)と同形で、quinn を `Stream::Tcp` に化けさせる。
//   方式: quinn の join 済みストリームを QuicIo(newtype) で TcpStreamTrait に適合させ（orphanルール回避）、
//         既存の FramedStream + BytesCodec + DynTcpStream に載せる＝上位(映像/入力/ファイル)は無改変で使える。
//
// ⚠ 初版。ビルド確認はユーザー環境。既知の要調整点：
//   (1) 自己署名TLS+検証無効＝RustDesk既存暗号(curve25519/secretbox)と二重になる。片方に寄せる設計が要る(§6-E)。
//   (2) accept 側：RustDesk は rendezvous で handshake 初弾(init_packet)を先読みしKCPに渡す。QUIC はその初弾を
//       quinn に届ける必要がある（現状は quinn がソケットから直接受ける前提）。
//   (3) 本命の HoL 解消は I-1.5（映像だけ QUIC DATAGRAM に回す）で出る。本ファイルは信頼stream＝I-1(疎通)段階。

use hbb_common::{
    anyhow,
    bytes_codec::BytesCodec,
    config,
    tcp::{DynTcpStream, FramedStream},
    tokio::{
        self,
        io::{AsyncRead, AsyncWrite, ReadBuf},
    },
    tokio_util, ResultType, Stream,
};
use std::{
    net::SocketAddr,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};

type QuicJoin = tokio::io::Join<quinn::RecvStream, quinn::SendStream>;

/// quinn の join 済みストリームを RustDesk の TcpStreamTrait に適合させる newtype。
/// (Join は外部型ゆえ直接 impl できない＝orphanルール回避のため包む)
struct QuicIo(QuicJoin);

impl AsyncRead for QuicIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}
impl AsyncWrite for QuicIo {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}
// ⚠ TcpStreamTrait は hbb_common に blanket impl があり QuicIo に自動付与される(明示実装は E0119 衝突)。

/// QUIC 接続のハンドル。endpoint/connection を生かし続けるため呼び出し側が保持する（KcpStream と同じ役割）。
#[allow(dead_code)]
pub struct QuicStream {
    endpoint: quinn::Endpoint,
    connection: quinn::Connection,
}

#[allow(dead_code)]
impl QuicStream {
    fn framed(join: QuicJoin, local_addr: SocketAddr, conn: quinn::Connection) -> Stream {
        // 制御/ファイル＝信頼 bi-stream(FramedStream)。映像DATAGRAM用に conn も QuicFramedStream に渡す(1.5-b)。
        let control = FramedStream(
            tokio_util::codec::Framed::new(
                DynTcpStream(Box::new(QuicIo(join))),
                BytesCodec::new(),
            ),
            local_addr,
            None,
            0,
        );
        Stream::Quic(hbb_common::quic::QuicFramedStream::new(control, conn))
    }

    /// connect: 穴あけ済みの std UDP ソケットを quinn に委譲し、bi-stream を開いて Stream を返す。
    /// `remote` は相手の観測アドレス（穴あけで確定したピア）。
    pub async fn connect(
        socket: std::net::UdpSocket,
        remote: SocketAddr,
        timeout: Duration,
    ) -> ResultType<(Self, Stream)> {
        let local_addr = socket
            .local_addr()
            .unwrap_or_else(|_| config::Config::get_any_listen_addr(true));
        let endpoint = make_client_endpoint(socket)?;
        let connecting = endpoint.connect(remote, "rustdesk")?;
        let connection = tokio::time::timeout(timeout, connecting).await??;
        let (send, recv) = tokio::time::timeout(timeout, connection.open_bi()).await??;
        let join = tokio::io::join(recv, send);
        let stream = Self::framed(join, local_addr, connection.clone());
        Ok((
            Self {
                endpoint,
                connection,
            },
            stream,
        ))
    }

    /// accept: 穴あけ済みソケットで quinn サーバを立て、着信を受理して Stream を返す。
    /// ⚠ init_packet の扱いは上記 (2) 参照。
    pub async fn accept(
        socket: std::net::UdpSocket,
        timeout: Duration,
    ) -> ResultType<(Self, Stream)> {
        let local_addr = socket
            .local_addr()
            .unwrap_or_else(|_| config::Config::get_any_listen_addr(true));
        let endpoint = make_server_endpoint(socket)?;
        let incoming = tokio::time::timeout(timeout, endpoint.accept())
            .await?
            .ok_or_else(|| anyhow::anyhow!("QUIC accept: no incoming"))?;
        let connection = tokio::time::timeout(timeout, incoming).await??;
        let (send, recv) = tokio::time::timeout(timeout, connection.accept_bi()).await??;
        let join = tokio::io::join(recv, send);
        let stream = Self::framed(join, local_addr, connection.clone());
        Ok((
            Self {
                endpoint,
                connection,
            },
            stream,
        ))
    }
}

/// ★ 実バイナリでの自己テスト：ループバックで connect↔accept し framed メッセージを1往復。
///   `REMOSYS_QUIC_SELFTEST=1` で core_main 冒頭から呼ぶ。rendezvous/2端末なしで quic_stream の
///   実行時動作（ring プロバイダ・ハンドシェイク・bi-stream・FramedStream 送受）を確認する。
pub fn selftest() {
    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            println!("QUIC-SELFTEST: runtime build failed: {e}");
            return;
        }
    };
    let r: ResultType<(bool, bool, bool)> = rt.block_on(async {
        let sa = std::net::UdpSocket::bind("127.0.0.1:0")?;
        let a_addr = sa.local_addr()?;
        let sc = std::net::UdpSocket::bind("127.0.0.1:0")?;
        let timeout = Duration::from_secs(5);
        let accept = tokio::spawn(async move { QuicStream::accept(sa, timeout).await });
        tokio::time::sleep(Duration::from_millis(150)).await;
        let (_qc, mut cstream) = QuicStream::connect(sc, a_addr, timeout).await?;
        // まず送って accept 側の bi-stream を起こす
        cstream
            .send_bytes(hbb_common::bytes::Bytes::from_static(b"ping"))
            .await?;
        let (_qa, mut sstream) = accept
            .await
            .map_err(|e| anyhow::anyhow!("accept join: {e}"))??;
        let got = sstream
            .next_timeout(3000)
            .await
            .ok_or_else(|| anyhow::anyhow!("server received nothing"))??;
        let ping_ok = &got[..] == b"ping";
        sstream
            .send_bytes(hbb_common::bytes::Bytes::from_static(b"pong"))
            .await?;
        let back = cstream
            .next_timeout(3000)
            .await
            .ok_or_else(|| anyhow::anyhow!("client received no reply"))??;
        let pong_ok = &back[..] == b"pong";

        // --- I-1.5-b: 映像 DATAGRAM の往復（5KB＝複数DATAGRAMに分割される）---
        use hbb_common::message_proto::{
            message, EncodedVideoFrame, EncodedVideoFrames, Message as PbMessage, VideoFrame,
        };
        use hbb_common::protobuf::Message as _; // write_to_bytes / parse_from_bytes(トレイトメソッド)
        let mut ef = EncodedVideoFrame::new();
        ef.data = hbb_common::bytes::Bytes::from(vec![0xABu8; 5000]);
        let mut efs = EncodedVideoFrames::new();
        efs.frames.push(ef);
        let mut vf = VideoFrame::new();
        vf.set_h264s(efs);
        let mut vmsg = PbMessage::new();
        vmsg.set_video_frame(vf);
        let sent = vmsg.write_to_bytes()?;
        // 実flowの映像方向(accept=お客様→connect=相談員)に合わせて sstream から送る
        sstream.send_video(&vmsg).await?;
        let vbytes = cstream
            .next_timeout(3000)
            .await
            .ok_or_else(|| anyhow::anyhow!("video not received over DATAGRAM"))??;
        let got = PbMessage::parse_from_bytes(&vbytes)?;
        let is_video = matches!(&got.union, Some(message::Union::VideoFrame(_)));
        let video_ok = is_video && vbytes.len() == sent.len() && &vbytes[..] == &sent[..];

        Ok((ping_ok, pong_ok, video_ok))
    });
    match r {
        Ok((p, q, v)) => println!(
            "QUIC-SELFTEST: SUCCESS (control ping={p} pong={q} / video-DATAGRAM={v}) = quic_stream + I-1.5 video DATAGRAM run at runtime"
        ),
        Err(e) => println!("QUIC-SELFTEST: FAILED: {e:#}"),
    }
}

// --- quinn endpoint 構築（engine-poc net.rs の server_on_socket/client_on_socket と同じ） ---
fn make_server_endpoint(socket: std::net::UdpSocket) -> ResultType<quinn::Endpoint> {
    let cert = rcgen::generate_simple_self_signed(vec!["rustdesk".to_string()])?;
    let cert_der = rustls::pki_types::CertificateDer::from(cert.cert.der().to_vec());
    let key_der = rustls::pki_types::PrivateKeyDer::try_from(cert.key_pair.serialize_der())
        .map_err(|e| anyhow::anyhow!("key: {e}"))?;
    // ★ プロバイダを ring 明示（既定プロバイダ依存は aws-lc 同居で実行時 panic）
    let rc = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|e| anyhow::anyhow!("tls versions: {e}"))?
    .with_no_client_auth()
    .with_single_cert(vec![cert_der], key_der)?;
    let qsc = quinn::crypto::rustls::QuicServerConfig::try_from(rc)
        .map_err(|e| anyhow::anyhow!("quic server config: {e}"))?;
    let mut sc = quinn::ServerConfig::with_crypto(Arc::new(qsc));
    if let Some(tc) = Arc::get_mut(&mut sc.transport) {
        tc.datagram_receive_buffer_size(Some(16 * 1024 * 1024));
        tc.datagram_send_buffer_size(16 * 1024 * 1024);
        tc.max_idle_timeout(Some(Duration::from_secs(15).try_into()?));
    }
    Ok(quinn::Endpoint::new(
        quinn::EndpointConfig::default(),
        Some(sc),
        socket,
        Arc::new(quinn::TokioRuntime),
    )?)
}

fn make_client_endpoint(socket: std::net::UdpSocket) -> ResultType<quinn::Endpoint> {
    // ★ プロバイダを ring 明示：workspace に aws-lc も同居するため builder()(既定プロバイダ依存)は
    //   実行時に「複数プロバイダ」panic になる。明示指定で防ぐ。
    let crypto = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|e| anyhow::anyhow!("tls versions: {e}"))?
    .dangerous()
    .with_custom_certificate_verifier(Arc::new(NoVerify))
    .with_no_client_auth();
    let qc = quinn::crypto::rustls::QuicClientConfig::try_from(crypto)?;
    let mut cc = quinn::ClientConfig::new(Arc::new(qc));
    let mut tc = quinn::TransportConfig::default();
    tc.datagram_receive_buffer_size(Some(16 * 1024 * 1024));
    tc.datagram_send_buffer_size(16 * 1024 * 1024);
    tc.max_idle_timeout(Some(Duration::from_secs(15).try_into()?));
    cc.transport_config(Arc::new(tc));
    let mut ep = quinn::Endpoint::new(
        quinn::EndpointConfig::default(),
        None,
        socket,
        Arc::new(quinn::TokioRuntime),
    )?;
    ep.set_default_client_config(cc);
    Ok(ep)
}

// PoC 用の「検証しない」証明書検証器（localhost/自己署名用・本番は §6-E で既存暗号に寄せる）
#[derive(Debug)]
struct NoVerify;
impl rustls::client::danger::ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
