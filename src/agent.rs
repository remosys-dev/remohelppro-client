// REMOHELP PRO 常駐エージェント
//   管理サーバー(svr.remohelppro.jp)の /api/agent/* と連携し、
//   ①無人アクセス用の永続PW設定＆自己登録 ②電源コマンド(起動WoL/再起動/シャットダウン)の実行
//   を行う。常駐(サービス)の server プロセス内から起動する。非常駐ビルドでは何もしない。
//
//   関連（サーバー側）: svr-fork の src/app/api/agent/{register,poll,report,heartbeat}
//   実行の配送: 再起動/シャットダウン=対象端末自身 / 起動(WoL)=同一LANの起こし役が本端末。

#[cfg(target_os = "windows")]
pub use imp::{is_resident, run};

#[cfg(not(target_os = "windows"))]
pub fn is_resident() -> bool {
    false
}

#[cfg(not(target_os = "windows"))]
pub async fn run() {}

#[cfg(target_os = "windows")]
mod imp {
    use hbb_common::{
        config::{self, Config},
        log, tokio,
    };
    use serde_json::{json, Value};
    use std::time::Duration;

    const POLL_INTERVAL_SECS: u64 = 7;

    /// 常駐(無人アクセス＋電源エージェント)ビルドか。CIがbakedフラグを立てる。
    /// 検証用に option "resident"=="Y" でも有効化できる。
    pub fn is_resident() -> bool {
        config::IS_RESIDENT_BUILD || Config::get_option("resident") == "Y"
    }

    fn url(path: &str) -> String {
        format!("{}{}", config::AGENT_API_BASE, path)
    }

    async fn http() -> reqwest::Client {
        crate::hbbs_http::create_http_client_async_with_url(config::AGENT_API_BASE).await
    }

    async fn post(path: &str, token: Option<&str>, body: Value) -> Option<Value> {
        let client = http().await;
        let mut req = client.post(url(path)).json(&body);
        if let Some(t) = token {
            req = req.header("x-agent-token", t);
        }
        match req.send().await {
            Ok(resp) => resp.json::<Value>().await.ok(),
            Err(e) => {
                log::debug!("agent post {} failed: {}", path, e);
                None
            }
        }
    }

    fn agent_token() -> Option<String> {
        let t = Config::get_option("agent-token");
        if t.is_empty() {
            None
        } else {
            Some(t)
        }
    }

    /// 本端末の代表 MAC（登録時にサーバーへ送る＝他端末から本端末を WoL 可能にする）。
    fn primary_mac() -> Option<String> {
        for itf in default_net::get_interfaces() {
            if let Some(mac) = itf.mac_addr {
                let s = mac.to_string();
                if s != "00:00:00:00:00:00" {
                    return Some(s);
                }
            }
        }
        None
    }

    /// 起こし役として、対象 MAC へマジックパケットを送出（全インターフェースのブロードキャストへ）。
    fn send_wol_to_mac(mac: &str) {
        let interfaces = default_net::get_interfaces();
        if let Ok(mac_addr) = mac.parse() {
            for interface in &interfaces {
                for ipv4 in &interface.ipv4 {
                    let _ = wol::send_wol(mac_addr, None, Some(std::net::IpAddr::V4(ipv4.addr)));
                }
            }
        }
    }

    /// 実行ファイル名に埋め込まれた登録トークンを取り出す。
    ///
    /// 配布サーバーが `remohelppro-resident-setup__t-<token>.exe` という名前で配る。
    /// 顧客がコマンドを打たずに済むようにするための経路（ファイル名なので署名は壊れない）。
    /// ブラウザが重複ダウンロードで付ける ` (1)` などの余計な文字は捨てる。
    fn enroll_token_from_filename() -> String {
        let Ok(exe) = std::env::current_exe() else {
            return String::new();
        };
        let Some(stem) = exe.file_stem().and_then(|s| s.to_str()) else {
            return String::new();
        };
        let Some(pos) = stem.find("__t-") else {
            return String::new();
        };
        let token: String = stem[pos + 4..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
            .collect();
        if token.len() >= 8 && token.len() <= 64 {
            token
        } else {
            String::new()
        }
    }

    /// 初回のみ：永続PWを生成→ローカル設定→無人アクセス有効化→サーバー登録→端末トークン保存。
    async fn ensure_enrolled() {
        if agent_token().is_some() {
            return;
        }
        let mut enroll = Config::get_option("enroll-token");
        if enroll.is_empty() {
            // `--enroll` で渡されていなければ、実行ファイル名から拾う
            enroll = enroll_token_from_filename();
            if !enroll.is_empty() {
                log::info!("REMOHELP PRO agent: enroll token from filename");
                Config::set_option("enroll-token".to_owned(), enroll.clone());
            }
        }
        if enroll.is_empty() {
            return; // 会社の登録トークン未設定なら何もしない
        }
        let id = Config::get_id();
        if id.is_empty() {
            return;
        }

        // 無人アクセス用の永続パスワードを生成し、ローカルに設定して無人アクセスを有効化
        let pw = Config::get_auto_password(12);
        Config::set_permanent_password(&pw);
        Config::set_option(
            "verification-method".to_owned(),
            "use-permanent-password".to_owned(),
        );
        Config::set_option("approve-mode".to_owned(), "password".to_owned());

        let mut body = json!({
            "enrollToken": enroll,
            "rustdeskId": id,
            "fixedPassword": pw,
        });
        if let Some(mac) = primary_mac() {
            body["macAddress"] = json!(mac);
        }

        match post("/api/agent/register", None, body).await {
            Some(v) if v.get("ok").and_then(Value::as_bool).unwrap_or(false) => {
                if let Some(tok) = v.get("deviceToken").and_then(Value::as_str) {
                    Config::set_option("agent-token".to_owned(), tok.to_owned());
                    log::info!("REMOHELP PRO agent enrolled");
                }
            }
            other => log::warn!("agent enroll failed: {:?}", other),
        }
    }

    async fn report(token: &str, command_id: &str, result: &str) {
        let _ = post(
            "/api/agent/report",
            Some(token),
            json!({ "commandId": command_id, "result": result }),
        )
        .await;
    }

    async fn poll_and_execute(token: &str) {
        let v = match post("/api/agent/poll", Some(token), json!({})).await {
            Some(v) => v,
            None => return,
        };
        let commands = match v.get("commands").and_then(Value::as_array) {
            Some(c) => c.clone(),
            None => return,
        };
        for cmd in commands {
            let id = cmd.get("id").and_then(Value::as_str).unwrap_or("");
            let action = cmd.get("action").and_then(Value::as_str).unwrap_or("");
            if id.is_empty() {
                continue;
            }
            match action {
                "power_on" => {
                    if let Some(mac) = cmd.pointer("/target/macAddress").and_then(Value::as_str) {
                        send_wol_to_mac(mac);
                        report(token, id, "done").await;
                    } else {
                        report(token, id, "failed").await;
                    }
                }
                "power_restart" => {
                    // 再起動すると報告を送れなくなるため、先に done を報告してから実行
                    report(token, id, "done").await;
                    let _ = system_shutdown::reboot();
                }
                "power_off" => {
                    report(token, id, "done").await;
                    let _ = system_shutdown::shutdown();
                }
                _ => report(token, id, "failed").await,
            }
        }
    }

    /// 常駐エージェントのメインループ（server プロセス内で spawn される）。
    pub async fn run() {
        log::info!(
            "REMOHELP PRO resident agent started (poll {}s)",
            POLL_INTERVAL_SECS
        );
        loop {
            ensure_enrolled().await;
            if let Some(token) = agent_token() {
                let _ = post("/api/agent/heartbeat", Some(&token), json!({})).await;
                poll_and_execute(&token).await;
            }
            tokio::time::sleep(Duration::from_secs(POLL_INTERVAL_SECS)).await;
        }
    }
}
