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

    /// 管理サーバーとの通信に使う、**使い回しの**HTTPクライアント。
    ///
    /// 🔴🔴 毎回作ってはいけない（2026-08-08 負荷試算で判明）。
    ///
    ///   元は post のたびに新しいクライアントを作っていた。reqwest の
    ///   クライアントは接続の使い回し（コネクションプール）を内側に持つので、
    ///   毎回作ると**接続を使い回せない**。
    ///   ＝ 7秒ごとに TCP 接続も TLS の握手もゼロからやり直していた。
    ///
    ///   ★中身のデータは60バイト程度なのに、証明書のやり取りだけで
    ///     1回 3〜4KB かかる。**通信の 99% が「つなぎ直しの費用」**だった。
    ///     試算で 1台あたり月 3.6GB。据置き回線なら問題にならないが、
    ///     モバイル回線や従量制のお客様では実害になる。
    ///     使い回せば **7分の1（月0.5GB）** になる。
    ///
    /// ⚠ 一度作ったら差し替えない。途中でプロキシ設定を変えた場合は
    ///   サービスを再起動するまで反映されない。常駐は入れっぱなしで使う物なので、
    ///   通信量の削減を優先する。
    /// ⚠ Client の clone は中身を共有するだけで安い（内部が Arc）。
    static HTTP_CLIENT: tokio::sync::OnceCell<reqwest::Client> =
        tokio::sync::OnceCell::const_new();

    async fn http() -> reqwest::Client {
        HTTP_CLIENT
            .get_or_init(|| async {
                crate::hbbs_http::create_http_client_async_with_url(config::AGENT_API_BASE).await
            })
            .await
            .clone()
    }

    /// 応答コードつきで送る。
    ///
    /// 🔴🔴 これまで応答コードを**一度も見ていなかった**（2026-08-07 実機で判明）。
    ///   管理者が管理画面から端末を削除すると、端末が持っている合鍵は無効になる。
    ///   ところがエージェントは 401 を捨てていたため、**7秒ごとに断られ続けながら
    ///   一生気づかない**。本番で heartbeat 1101回・poll 1099回がすべて 401 だった。
    ///   画面にも記録にも何も出ないので、「入れたのに出てこない」にしか見えない。
    async fn post_status(path: &str, token: Option<&str>, body: Value) -> Option<(u16, Value)> {
        let client = http().await;
        let mut req = client.post(url(path)).json(&body);
        if let Some(t) = token {
            req = req.header("x-agent-token", t);
        }
        match req.send().await {
            Ok(resp) => {
                let status = resp.status().as_u16();
                let v = resp.json::<Value>().await.unwrap_or(Value::Null);
                Some((status, v))
            }
            Err(e) => {
                log::debug!("agent post {} failed: {}", path, e);
                None
            }
        }
    }

    async fn post(path: &str, token: Option<&str>, body: Value) -> Option<Value> {
        post_status(path, token, body).await.map(|(_, v)| v)
    }

    /// 合鍵が通らなくなったときに、捨てて登録からやり直す。
    ///
    /// ⚠ 「通信できない」と「断られた」は別物。ここで消してよいのは**断られた**ときだけ。
    ///   回線が切れているだけで消すと、繋がるたびに登録し直す端末になってしまう。
    fn forget_agent_token(reason: &str) {
        log::warn!(
            "REMOHELP PRO agent: 端末の合鍵が通らなくなりました（{}）。登録からやり直します",
            reason
        );
        Config::set_option("agent-token".to_owned(), String::new());
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

    /// 電源を落とす／再起動する前に、お客様に見せる猶予（秒）。
    ///
    /// 🔴 0 にしない。常駐PCの前に人が座っていることがある（サーバーとは限らない）。
    ///   何の予告も無く落ちると、書きかけの書類が消えたと受け取られる。
    /// 🔴 長くもしない。相談員は「落ちたか」を見届ける必要がある。
    ///   30秒なら、保存する時間はあり、待つのも苦にならない。
    const POWER_GRACE_SECS: u32 = 30;

    /// 電源操作を Windows に**予約**する。受理されれば Ok（実際に落ちるのは猶予のあと）。
    ///
    /// 🔴🔴 `system_shutdown::shutdown()` を使ってはいけない（2026-08-09 実機で判明）。
    ///   あれは `ExitWindowsEx(EWX_SHUTDOWN | EWX_FORCEIFHUNG)` で、**強制ではない**。
    ///   終了を拒むアプリが1つでもあると止まる。Win11 で落ちず、Win10 で落ちたのは
    ///   単に塞ぐものが有ったか無かったかの違いだった。
    ///
    ///   ★`InitiateSystemShutdownW`（= `*_with_message`）が正しい。
    ///     ・サービス（session 0）から**PC全体**を落とせる
    ///     ・お客様の画面に**理由と残り時間**が出る
    ///     ・受理／拒否がその場で戻るので、**嘘の「成功」を報告せずに済む**
    ///
    /// ⚠ 猶予のあとはアプリを強制終了する（第3引数 true）。
    ///   ここを false にすると、また「頼んだのに落ちない」に戻る。
    ///   30秒の予告を出したうえで落とす、が落としどころ。
    #[cfg(windows)]
    fn request_power(reboot: bool) -> std::io::Result<()> {
        let msg = if reboot {
            "REMOHELP PRO の遠隔サポートにより、まもなく再起動します。作業中のものは保存してください。"
        } else {
            "REMOHELP PRO の遠隔サポートにより、まもなく電源を切ります。作業中のものは保存してください。"
        };
        if reboot {
            system_shutdown::reboot_with_message(msg, POWER_GRACE_SECS, true)
        } else {
            system_shutdown::shutdown_with_message(msg, POWER_GRACE_SECS, true)
        }
    }

    /// Windows 以外は従来どおり（常駐は今のところ Windows 専用）。
    #[cfg(not(windows))]
    fn request_power(reboot: bool) -> std::io::Result<()> {
        if reboot {
            system_shutdown::reboot()
        } else {
            system_shutdown::shutdown()
        }
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
    /// 次に登録を試してよい時刻（UNIX秒）。0 なら即試してよい。
    ///
    /// 🔴 登録できない状態（会社が無効・トークンが違う等）はいくらでもある。
    ///   7秒ごとに叩き続けると、当社サーバーの記録が失敗で埋まり、
    ///   本当に見たいものが見えなくなる。実際、上流APIを呼び続けて
    ///   記録を埋めた前科がある（2026-08-05）。
    static NEXT_ENROLL_AT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    /// 登録に失敗したあと、次に試すまで空ける時間（秒）。
    const ENROLL_RETRY_SECS: u64 = 60;

    /// 端末に設定したが、まだサーバーへ届いていない固定パスワード。
    ///
    /// 🔴🔴 **平文は読み戻せない**（2026-08-07 に config.rs を読んで判明）。
    ///   固定パスワードは保存時にハッシュ化される
    ///   （config.rs:724 `encode_permanent_password_storage_from_h1`）。
    ///   ＝「いま端末に入っている合言葉を読んで名乗り直す」はできない。
    ///   ★**こちらから作り直して、その平文を預ける**しかない。
    ///     作った本人なら平文を持っているので、必ず一致させられる。
    ///
    /// 🔴 届いたことを確かめるまで、**端末には書き込まない**（2026-08-14 に順番を逆転）。
    ///   ここに入っているのは「これから使う予定の合言葉」で、まだ端末は古い値で
    ///   動いている。200 が返ってはじめて apply_pending_password() で書き込み、
    ///   同時にここを空にする。
    ///   ⚠ 以前は先に端末へ書いてから預けていた。その間サーバーは古いままで、
    ///     相談員が繋ぐと「パスワードが違います」になった。順番を戻さないこと。
    static PENDING_PW: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

    /// 固定パスワードを揃え直す間隔（秒）。
    ///
    /// 🔴 起動時に1回だけでは足りない（2026-08-08）。
    ///   「起動時に揃えたのだから、あとは壊れない」という前提で作ったが、
    ///   実際には**別の処理が上書きしていた**（常駐版の判定が効いておらず、
    ///   窓が開くたびに壊されていた）。一度きりの修正は、前提が崩れた瞬間に
    ///   **黙って壊れたまま**になる。
    ///   ★見立てを当てにせず、**定期的に揃え直す**。
    ///     何が壊しても、最長でこの間隔で自分で治る。
    ///   ⚠ 相談員は繋ぐ直前にサーバーから受け取るので、値が変わっても困らない。
    ///   ⚠ 接続中に変えても、その接続は切れない（照合は入るときの1回だけ）。
    const PW_ROTATE_INTERVAL_SECS: u64 = 30 * 60;
    static NEXT_ROTATE_AT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    /// 中継サーバーに受け入れられていない状態が、これだけ続いたらやり直す（秒）。
    ///
    /// 🔴 なぜ 30秒にできないか（2026-08-08 ご質問・実際の定数を確かめた）。
    ///   ① **立ち上がりに時間がかかる**。ソケットを開くだけで最大 18 秒
    ///     （CONNECT_TIMEOUT）、その前に NAT 判定や後始末も走る。
    ///     短くすると**立ち上がっている最中にやり直しをかけ、永久に立ち上がれない**。
    ///   ② **RustDesk 自身の自己修復を邪魔する**。4回失敗するとソケットを
    ///     開き直すが、それは 60 秒に1回まで（DNS_INTERVAL）。
    ///     30秒で割り込むと、直りかけたところを毎回潰す。
    ///   ＝ 下限は「60秒 ＋ 立ち上がり分」。90 秒にしてある。
    ///
    /// ⚠ 健全なら 15 秒ごと（REG_INTERVAL）に受け入れられるので、
    ///   90 秒は「6回続けて音沙汰が無い」に相当する。誤って割り込む心配は無い。
    /// ⚠ 元は 150 秒だった（build-36）。安全側に振りすぎていたので詰めた。
    const RENDEZVOUS_STALE_SECS: u64 = 90;
    /// やり直しの間隔（秒）。連打しない。
    const RENDEZVOUS_RETRY_SECS: u64 = 180;
    static NEXT_RZ_RESTART_AT: std::sync::atomic::AtomicU64 =
        std::sync::atomic::AtomicU64::new(0);

    /// 中継サーバーへ登録できていなければ、自分でやり直す。
    ///
    /// 🔴🔴 パソコンを再起動すると、サービスは起動して当社の管理サーバーへ
    ///   ハートビートも送るのに、**中継サーバーへの登録だけが成立しない**
    ///   （2026-08-08 実機で3回再現・Win10/Win11 とも）。
    ///   相談員のビュアーには「リモートデスクトップはオフラインです」と出る。
    ///   ところが**サービスを手で再起動すると必ず繋がる**。
    ///   ＝ サービスが「起動している」ことと「正しく動いている」ことは別。
    ///
    ///   原因はまだ特定できていない。だが**やり直せば直る**ことは分かっている。
    ///   お客様に毎回サービスの再起動をお願いするわけにはいかないので、
    ///   気づいて自分でやり直す。やることは手での再起動と同じ
    ///   （`RendezvousMediator::restart()`）。
    ///
    /// ⚠ 起動直後は猶予を置く。立ち上がりに時間がかかるのは普通で、
    ///   そこでやり直すと立ち上がれない。
    /// ⚠ 原因究明をやめない。これは「繋がらないまま放置しない」ための歯止めであって、
    ///   直したことにはならない。
    fn watch_rendezvous(started_at: u64) {
        let now = now_secs();
        // 一度も受け入れられていなければ、起動からの時間で測る。
        let stale = match crate::secs_since_rendezvous_accepted() {
            Some(secs) => secs,
            None => now.saturating_sub(started_at),
        };
        if stale < RENDEZVOUS_STALE_SECS {
            return;
        }
        if now < NEXT_RZ_RESTART_AT.load(std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        NEXT_RZ_RESTART_AT.store(
            now + RENDEZVOUS_RETRY_SECS,
            std::sync::atomic::Ordering::Relaxed,
        );
        log::warn!(
            "REMOHELP PRO agent: 中継サーバーに{}秒受け入れられていないので、登録をやり直します",
            stale
        );
        crate::RendezvousMediator::restart();
    }

    /// サービスが立ち上がるたびに固定パスワードを作り直し、預ける準備をする。
    ///
    /// 🔴 これが「パスワードが間違っています」の直し（2026-08-07）。
    ///   常駐は登録のときに固定パスワードを作ってサーバーへ預けるが、
    ///   作り直すのは**登録の1回だけ**（登録済みなら ensure_enrolled は先頭で戻る）。
    ///   端末側で書き換わる道があると、預かっている物と中身が**永久に食い違い**、
    ///   端末を消して入れ直す以外に直す道が無かった。
    ///   ★立ち上がるたびに揃え直せば、何が壊しても再起動で自分で治る。
    /// ⚠ 毎回変わるが困らない。相談員は繋ぐ直前にサーバーから受け取る。
    ///   むしろ、つけっぱなしの端末で同じ合言葉が残り続けない分だけ良い。
    /// 新しい合言葉を用意する。**この時点ではまだ端末に書き込まない。**
    ///
    /// 🔴🔴 順番を逆にした（2026-08-14・「常駐がパスワードを要求する」の直し）。
    ///
    ///   これまでは「端末に書く → サーバーへ預ける」の順だった。その間は
    ///   **端末だけが新しく、サーバーは古いまま**になる。相談員はサーバーから
    ///   受け取った古い値で繋ぐので、その窓の間は必ず
    ///   「パスワードが違います」になる。
    ///   窓は短い（報告は7秒ごと）が、開くのは
    ///     ・サービスが立ち上がるたび（＝入れた直後・更新の直後・再起動の直後）
    ///     ・30分ごと
    ///   で、**相談員がいちばん繋ぐ瞬間**と重なる。
    ///
    ///   ★預けてから書く。サーバーが受け取るまで端末は古い値のまま動き、
    ///     受け取った瞬間に両方が新しくなる。
    ///     ＝「サーバーが遅れている」状態が構造的に起こらない。
    ///
    ///   ⚠ 逆向き（サーバーだけが新しい）は、200 を受け取ってから書き込むまでの
    ///     一瞬だけ残る。次の行で書くので、実質は通信の往復1回ぶん。
    ///     完全にゼロにはできない（端末側に「古い方も受け付ける」仕組みが無い）。
    ///
    ///   ⚠ 端末に入っている合言葉は**読み戻せない**（保存形が不可逆）。
    ///     だから「無ければ作る」はできず、揃えるには作り直すしかない。
    ///     PENDING_PW の説明も参照。
    fn rotate_fixed_password() {
        let pw = Config::get_auto_password(12);
        // 照合の仕方だけは先に決めておく。これは合言葉の値とは無関係で、
        // いつ書いても食い違いを生まない。
        Config::set_option(
            "verification-method".to_owned(),
            "use-permanent-password".to_owned(),
        );
        Config::set_option("approve-mode".to_owned(), "password".to_owned());
        if let Ok(mut p) = PENDING_PW.lock() {
            *p = Some(pw);
        }
        NEXT_ROTATE_AT.store(
            now_secs() + PW_ROTATE_INTERVAL_SECS,
            std::sync::atomic::Ordering::Relaxed,
        );
        log::info!("REMOHELP PRO agent: 新しい固定パスワードを用意しました（先にサーバーへ預けます）");
    }

    /// 預けきった合言葉を、はじめて端末に書き込む。
    ///
    /// ⚠ サーバーが 200 を返したときにだけ呼ぶこと。
    ///   届いていないのに書くと、**端末だけが新しくなって繋がらなくなる**。
    ///   それが今回直した不具合そのもの。
    fn apply_pending_password() {
        let pw = match PENDING_PW.lock() {
            Ok(mut p) => p.take(),
            Err(_) => None,
        };
        if let Some(pw) = pw {
            Config::set_permanent_password(&pw);
            log::info!("REMOHELP PRO agent: 固定パスワードを預けてから端末へ書き込みました");
        }
    }

    fn now_secs() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }

    async fn ensure_enrolled() {
        if agent_token().is_some() {
            return;
        }
        // 前回の登録が失敗していたら、少し待ってから試す
        let now = now_secs();
        if now < NEXT_ENROLL_AT.load(std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        // 先に「次は60秒後」を置く。この先どこで抜けても叩き続けない。
        // 成功したらこの関数の最後で 0 に戻す。
        NEXT_ENROLL_AT.store(
            now + ENROLL_RETRY_SECS,
            std::sync::atomic::Ordering::Relaxed,
        );
        let mut enroll = Config::get_option("enroll-token");
        if enroll.is_empty() {
            // 🔴 自己展開のランナーが渡してくる値を最優先で見る（2026-07-31 追加）。
            //
            //   常駐版は「remohelppro-resident-setup__t-<トークン>.exe」という名前で
            //   配るが、**実際に動くのは展開先の remohelppro.exe** なので、
            //   自分の名前からは絶対に取れない。下の
            //   enroll_token_from_filename() は常に空を返していた。
            //   ＝ **端末が1台も登録されない**。落とせるのに何も起きない、
            //   という一番分かりにくい壊れ方をしていた（実機で判明）。
            enroll = std::env::var("RL_ENROLL_TOKEN").unwrap_or_default();
            if !enroll.is_empty() {
                log::info!("REMOHELP PRO agent: enroll token from runner");
                Config::set_option("enroll-token".to_owned(), enroll.clone());
            }
        }
        if enroll.is_empty() {
            // 🔴 インストール先の登録簿を見る（2026-08-05 追加）。
            //   サービスは、インストールのときに動いていたプロセスとは別物で、
            //   環境変数も一時フォルダの設定も引き継がない。
            //   **消えない場所に置いたものだけ**が、ここまで届く。
            enroll = crate::platform::windows::get_enroll_token_reg();
            if !enroll.is_empty() {
                log::info!("REMOHELP PRO agent: enroll token from registry");
                Config::set_option("enroll-token".to_owned(), enroll.clone());
            }
        }
        if enroll.is_empty() {
            // ランナーを経由しない配り方（展開済みを直接置く等）への保険。
            enroll = enroll_token_from_filename();
            if !enroll.is_empty() {
                log::info!("REMOHELP PRO agent: enroll token from filename");
                Config::set_option("enroll-token".to_owned(), enroll.clone());
            }
        }
        if enroll.is_empty() {
            // 🔴 ここで黙って帰らない（2026-08-04 実機調査）。
            //
            //   本番の記録を見たところ、**端末は1台も登録されたことが無かった**
            //   （devices 0件／/api/agent/register への通信は手動テストのみ）。
            //   ところが入れた側には**何のしるしも出ない**。
            //   「入れて、管理者の確認まで押したのに何も起こらない」という、
            //   いちばん分かりにくい壊れ方をする。
            //
            //   登録トークンは次のどれかで届く。全部空なら、この端末は
            //   **永久に登録されない**ので、その事実だけは必ず残す。
            //     ① 自己展開のランナーが渡す RL_ENROLL_TOKEN（正規の道）
            //     ② 実行ファイル名の __t-<トークン>
            //     ③ 設定の enroll-token ④ インストール先の登録簿
            //   ⚠ トークンそのものは書かない（記録から接続の手掛かりを与えない）。
            log::warn!(
                "REMOHELP PRO agent: 登録トークンが無いので登録できません。\
                 会社の登録トークン付きの入手先から入れ直してください \
                 (env={} name={} option={} reg={})",
                if std::env::var("RL_ENROLL_TOKEN").unwrap_or_default().is_empty() { "無" } else { "有" },
                if enroll_token_from_filename().is_empty() { "無" } else { "有" },
                if Config::get_option("enroll-token").is_empty() { "無" } else { "有" },
                if crate::platform::windows::get_enroll_token_reg().is_empty() { "無" } else { "有" },
            );
            return;
        }
        let id = Config::get_id();
        if id.is_empty() {
            log::warn!("REMOHELP PRO agent: 端末IDがまだ決まっていないので登録を見送ります");
            return;
        }

        // 無人アクセス用の永続パスワードを用意し、無人アクセスを有効にする。
        //
        // 🔴 ここで作り直さない（2026-08-07 に作り直し）。
        //   元はこの場で新しい合言葉を作っていたが、サービス起動時にも
        //   rotate_fixed_password() が作るので、**2つの値が競合していた**。
        //   登録では新しい方を預け、次の報告では古い方を預ける、という
        //   食い違いが起きる（そして「パスワードが間違っています」に戻る）。
        //   ★預ける値は1本にする。用意されていなければここで作る。
        let pw = match PENDING_PW.lock().ok().and_then(|p| p.clone()) {
            Some(p) => p,
            None => {
                rotate_fixed_password();
                match PENDING_PW.lock().ok().and_then(|p| p.clone()) {
                    Some(p) => p,
                    None => {
                        log::warn!("REMOHELP PRO agent: 固定パスワードを用意できませんでした");
                        return;
                    }
                }
            }
        };

        // 🔴 自分の版を名乗る（2026-08-06 追加）。
        //
        //   「何が入っているのか誰にも分からない」が、常駐の追跡を2日半止めた。
        //   Windows の「アプリと機能」の表示は当てにならず
        //   （何をビルドしても 1.4.6 と出ていた）、
        //   実機を見ても入っている物が特定できなかった。
        //   ★端末自身に名乗らせるのがいちばん確か。
        //   これで当社の画面から「どの版が入っているか」が分かる。
        // 🔴 このPCの名前を名乗る（2026-08-08）。
        //
        //   名乗らないと、サーバーは接続番号の末尾から `PC-8689` のような
        //   仮の名前を作る（register/route.ts:115）。
        //   ★管理者から見て**どこのPCなのか全く分からない**。
        //   実際「pc-7777 ではどこのPCなのか分からない」というご指摘を受けた。
        //   ⚠ 人が付け直せる仕組み（名前の変更）とは別に、まずこれを送る。
        //     最初から意味のある名前が付いていれば、直す手間そのものが減る。
        //   ⚠ 取れなければ送らない。空を送るとサーバー側の既定を上書きしてしまう。
        let host = crate::common::hostname();
        let mut body = json!({
            "enrollToken": enroll,
            "rustdeskId": id,
            "fixedPassword": pw,
            "appVersion": crate::VERSION,
        });
        if !host.is_empty() && host != "localhost" {
            body["name"] = json!(host);
        }
        if let Some(mac) = primary_mac() {
            body["macAddress"] = json!(mac);
        }

        match post("/api/agent/register", None, body).await {
            Some(v) if v.get("ok").and_then(Value::as_bool).unwrap_or(false) => {
                if let Some(tok) = v.get("deviceToken").and_then(Value::as_str) {
                    Config::set_option("agent-token".to_owned(), tok.to_owned());
                    // 成功したので待ち時間を解除する
                    NEXT_ENROLL_AT.store(0, std::sync::atomic::Ordering::Relaxed);
                    // 🔴 登録が通ってはじめて、端末に書き込む（2026-08-14）。
                    //   預ける前に書くと、サーバーが受け取るまでの間だけ
                    //   端末が新しくなり、その窓で繋ぐと必ず失敗する。
                    apply_pending_password();
                    log::info!("REMOHELP PRO agent enrolled");
                }
            }
            other => log::warn!(
                "agent enroll failed: {:?}（{}秒後にもう一度試します）",
                other,
                ENROLL_RETRY_SECS
            ),
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

    /// 新しい版を落として、自分を入れ替える。
    ///
    /// 🔴 入手先は当社のドメインだけ受け付ける。ここを緩めると、
    ///   記録を書き換えられたときに任意のプログラムを全台へ配れることになる。
    ///   無人アクセスの端末なので、破られたときの被害が最大になる。
    ///   （サーバー側でも同じ確認をしている。**両方で見る**。）
    ///
    /// ⚠ 名前は `.install.exe` で終わらせる。自己展開のランナーは名前も見るため。
    ///   （1.4.32 以降は焼き印でも判定するので二重の備え）
    /// ⚠ `--silent-install` で起動する。画面を出さずに入れ替える。
    /// ⚠ 落とし終わるまで何もしない。中途半端なファイルを実行すると、
    ///   **入れ替えに失敗したうえに元も壊れる**。
    /// 自分（常駐）を端末から取り除く（2026-08-23 ご指示）。
    ///
    /// 🔴 `--uninstall` の入口は既にある（core_main.rs）。ここはそれを
    ///   **別プロセスで**呼ぶだけ。自分自身を消しながら動き続けることはできない。
    ///
    /// ⚠ 実体の場所を推測しない。`current_exe()` で自分の位置を取る。
    ///   決め打ちにすると、置き場所が変わった版で静かに失敗する。
    #[cfg(windows)]
    fn uninstall_self() -> Result<(), String> {
        let exe = std::env::current_exe().map_err(|e| format!("自分の場所が分かりません: {e}"))?;
        log::info!("REMOHELP PRO agent: アンインストールを始めます ({})", exe.display());
        // ⚠ 引数は raw_arg で渡す（[[windows-cmd-quoting-trap]]）。
        //   .args だと引用符が壊れ、**静かに何もしない**ことがある。
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        std::process::Command::new(&exe)
            .raw_arg("--uninstall")
            .creation_flags(DETACHED_PROCESS)
            .spawn()
            .map_err(|e| format!("起動できませんでした: {e}"))?;
        Ok(())
    }

    #[cfg(not(windows))]
    fn uninstall_self() -> Result<(), String> {
        // 常駐は Windows のみ。ここへ来ることは無いが、黙って成功にしない。
        Err("この端末では常駐のアンインストールに対応していません".to_owned())
    }

    async fn self_update(url: &str) -> Result<(), String> {
        if !url.starts_with("https://svr.remohelppro.jp/") {
            return Err(format!("入手先が当社のものではありません: {url}"));
        }
        let client = http().await;
        let resp = client
            .get(url)
            .send()
            .await
            .map_err(|e| format!("落とせませんでした: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("落とせませんでした: HTTP {}", resp.status()));
        }
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| format!("落とせませんでした: {e}"))?;
        // 常駐版は 30MB 前後。極端に小さいものは、エラーページ等を掴んでいる。
        if bytes.len() < 5_000_000 {
            return Err(format!("落とした物が小さすぎます: {} バイト", bytes.len()));
        }
        let dir = std::env::temp_dir();
        let path = dir.join("remohelppro-agent-update.install.exe");
        std::fs::write(&path, &bytes).map_err(|e| format!("置けませんでした: {e}"))?;
        log::info!(
            "REMOHELP PRO agent: 新しい版を置きました（{} バイト）。入れ替えます",
            bytes.len()
        );
        std::process::Command::new(&path)
            .arg("--silent-install")
            .spawn()
            .map_err(|e| format!("起動できませんでした: {e}"))?;
        Ok(())
    }

    async fn poll_and_execute(token: &str) {
        let v = match post("/api/agent/poll", Some(token), json!({})).await {
            Some(v) => v,
            None => return,
        };
        // 🔴🔴 会社名と、機能の許可を受け取って残す（2026-09-02 ご判断）。
        //
        //   ⚠ 常駐は自分がどの会社のものか知らず、顧客の窓に
        //     ⚠ **PC名がそのまま出ていた**。お客様には意味のない文字。
        //   ⚠ 許可も同じ道で受け取る。相談員アプリはコンソールを見に行かないので、
        //     ⚠ **お客様の側から繋いだ瞬間に渡す**しかない
        //     （common.rs の rl_allowed_features → platform_additions）。
        //   ⚠ 値が来ていない項目は**触らない**。消しにいくと、通信が一度
        //     失敗しただけで会社名や機能が消える。
        //   ⚠ commands より**前**に置く。commands が無いと下で return するため。
        if let Some(name) = v.get("companyName").and_then(Value::as_str) {
            if !name.trim().is_empty() {
                hbb_common::config::LocalConfig::set_option(
                    "rl-support-company".to_owned(),
                    name.trim().to_owned(),
                );
            }
        }
        if let Some(f) = v.get("features") {
            for (from, to) in [
                ("switchSides", "rl-allow-switch-sides"),
                ("rebootResume", "rl-allow-reboot-resume"),
                ("privacyMode", "rl-allow-privacy-mode"),
                ("voiceCall", "rl-allow-voice-call"),
                ("ctrlAltDel", "rl-allow-ctrl-alt-del"),
                ("blockInput", "rl-allow-block-input"),
            ] {
                if let Some(b) = f.get(from).and_then(Value::as_bool) {
                    hbb_common::config::LocalConfig::set_option(
                        to.to_owned(),
                        if b { "".to_owned() } else { "N".to_owned() },
                    );
                }
            }
        }
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
                // 🔴🔴 電源操作は「頼んだ結果」を見てから報告する（2026-08-09 実機で判明）。
                //
                //   元は **実行する前に done を報告し、実行結果を `let _ =` で捨てて**いた。
                //   ＝ コンソールには必ず「成功」と出る。落ちたかどうかとは無関係。
                //   実機で林メインノート(Win11)に power_off を**4回**送り、
                //   **4回とも「成功」なのに一度も落ちなかった**。
                //   運用で最も危ない種類の嘘（画面が「できた」と言うのに、できていない）。
                //
                //   ★報告の順番も直す。`InitiateSystemShutdownW` は
                //     **予約して即座に戻る**ので、戻り値を見てから報告できる。
                //     受理されたら done、断られたら failed。
                "power_restart" => match request_power(true) {
                    Ok(_) => report(token, id, "done").await,
                    Err(e) => {
                        log::error!("REMOHELP PRO agent: 再起動を頼めませんでした: {e}");
                        report(token, id, "failed").await;
                    }
                },
                "power_off" => match request_power(false) {
                    Ok(_) => report(token, id, "done").await,
                    Err(e) => {
                        log::error!("REMOHELP PRO agent: 電源オフを頼めませんでした: {e}");
                        report(token, id, "failed").await;
                    }
                },
                // 🔴 自分を新しい版に入れ替える（2026-08-08）。
                //
                //   直しが続く段階で、そのたびにお客様へ入れ直しをお願いするのは
                //   現実的でない（2日で 1.4.29 → 1.4.38 まで動いた）。
                //   ⚠ 押すのは**相談員**（ユーザー判断・案①）。勝手には更新しない。
                //     人がその場にいるので、戻ってこなければすぐ気づける。
                //   ⚠ 版と入手先は**サーバーが決める**。端末に決めさせない。
                //     悪い版を出しても、配布側を1か所直せば全台が戻る。
                //   ⚠ 入れ替えると自分が止まるので、**先に done を報告する**。
                //     報告できないまま入れ替わると、指示が残り続けて何度も走る。
                "self_update" => {
                    let url = cmd.pointer("/update/url").and_then(Value::as_str);
                    let ver = cmd
                        .pointer("/update/version")
                        .and_then(Value::as_str)
                        .unwrap_or("?");
                    match url {
                        Some(u) => {
                            log::info!("REMOHELP PRO agent: 自己更新を開始します ({ver})");
                            report(token, id, "done").await;
                            if let Err(e) = self_update(u).await {
                                log::error!("REMOHELP PRO agent: 自己更新に失敗しました: {e}");
                            }
                        }
                        None => {
                            log::warn!("REMOHELP PRO agent: 更新の入手先がありません");
                            report(token, id, "failed").await;
                        }
                    }
                }
                // 🔴🔴 自分をアンインストールする（2026-08-23 ご指示）。
                //
                //   会社管理者が管理画面から押す。＝ **お客様ご自身の意思**。
                //   ⚠ 当社が勝手に消しに行く仕組みにはしない。
                //     契約が終わった相手の PC を当社の判断で操作するのは、
                //     「もう接続できません」という説明と矛盾する。
                //
                //   ⚠ 消すと自分が止まるので、**先に done を報告する**。
                //     報告できないまま消えると、指示が残り続けて何度も走る
                //     （self_update と同じ形）。
                //
                //   ⚠ 別プロセスで起動して、自分は抜ける。自分自身を消しながら
                //     動き続けることはできない。
                "uninstall" => {
                    log::info!("REMOHELP PRO agent: アンインストールの指示を受けました");
                    report(token, id, "done").await;
                    if let Err(e) = uninstall_self() {
                        log::error!("REMOHELP PRO agent: アンインストールに失敗しました: {e}");
                    }
                }
                // セーフモードで再起動する。
                //   🔴 設定に成功したときだけ再起動する。失敗したまま再起動すると
                //     通常モードで上がるだけだが、相談員は「セーフモードになった」と
                //     思い込んで待つことになるので、必ず失敗として返す。
                "safemode_reboot" => {
                    let minutes = cmd
                        .pointer("/target/deadlineMinutes")
                        .and_then(Value::as_u64)
                        .unwrap_or(crate::safemode::DEFAULT_DEADLINE_MINUTES);
                    match crate::safemode::arm(minutes) {
                        Ok(_) => {
                            // 再起動も「頼めたか」を見てから報告する（2026-08-09）。
                            match request_power(true) {
                                Ok(_) => report(token, id, "done").await,
                                Err(e) => {
                                    log::error!("safemode reboot failed: {e}");
                                    report(token, id, "failed").await;
                                }
                            }
                        }
                        Err(e) => {
                            log::error!("safemode arm failed: {}", e);
                            report(token, id, "failed").await;
                        }
                    }
                }
                // 通常モードへ戻して再起動する。
                //   ここが失敗すると顧客PCがセーフモードのまま残るので、
                //   失敗しても諦めず、見張り（safemode::watch）が期限で再度戻す。
                "safemode_exit" => match crate::safemode::disarm() {
                    Ok(_) => match request_power(true) {
                        Ok(_) => report(token, id, "done").await,
                        Err(e) => {
                            log::error!("safemode exit reboot failed: {e}");
                            report(token, id, "failed").await;
                        }
                    },
                    Err(e) => {
                        log::error!("safemode disarm failed: {}", e);
                        report(token, id, "failed").await;
                    }
                },
                // 作業が長引いたときに、自動復帰までの猶予を延ばす。
                "safemode_extend" => {
                    let minutes = cmd
                        .pointer("/target/deadlineMinutes")
                        .and_then(Value::as_u64)
                        .unwrap_or(crate::safemode::DEFAULT_DEADLINE_MINUTES);
                    match crate::safemode::extend(minutes) {
                        Ok(_) => report(token, id, "done").await,
                        Err(e) => {
                            log::error!("safemode extend failed: {}", e);
                            report(token, id, "failed").await;
                        }
                    }
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
        // 🔴 起動のたびに必ず呼ぶ。セーフモードの取り残しを片づけ、
        //   セーフモード中なら自動復帰の見張りを立てる。ここを飛ばすと
        //   顧客PCがセーフモードのまま戻らなくなる可能性がある。
        crate::safemode::on_service_start();
        // 🔴 立ち上がるたびに固定パスワードを揃え直す（2026-08-07）。
        //   端末に入っている合言葉は読み戻せないので、揃っているかを
        //   確かめる手段が無い。作り直して預け直すのが唯一の方法。
        //   ⚠ 登録より前に置く。まだ登録していない端末なら、この値がそのまま
        //     登録のときに預けられる（ensure_enrolled が読む場所と同じ）。
        //   ⚠ ここで作るだけで、端末にはまだ書かない（2026-08-14）。
        //     書くのはサーバーが受け取ったあと。詳しくは
        //     rotate_fixed_password() / apply_pending_password() の説明を参照。
        //     以前は先に書いていたため、**立ち上げ直した直後に繋ぐと必ず失敗**した
        //     （＝入れた直後・更新の直後・再起動の直後という、いちばん繋ぐ瞬間）。
        rotate_fixed_password();
        // 中継サーバーへの登録の見張り。詳しくは watch_rendezvous() を参照。
        let started_at = now_secs();
        loop {
            watch_rendezvous(started_at);
            // 決めた間隔で揃え直す。何が壊しても、最長でこの間隔で自分で治る。
            //   ⚠ まだ預けきっていない分があるうちは作り直さない。
            //     作り直すたびに端末側だけ変わり、追いつけなくなる。
            if PENDING_PW.lock().map(|p| p.is_none()).unwrap_or(false)
                && now_secs() >= NEXT_ROTATE_AT.load(std::sync::atomic::Ordering::Relaxed)
            {
                rotate_fixed_password();
            }
            ensure_enrolled().await;
            if let Some(token) = agent_token() {
                // いまセーフモードかを毎回伝える。相談員の画面に出し、
                // 「戻し忘れ」に気づけるようにするため。
                let mut body = json!({
                    "safeMode": crate::safemode::is_safe_mode(),
                    // 🔴 版を毎回名乗る（2026-08-07）。
                    //   これまで版を送るのは登録のときだけだった。登録は端末の
                    //   一生で1回きりなので、**入れ直しても画面の版が変わらない**。
                    //   実機で 1.4.32 を入れても 1.4.29 と表示され続け、
                    //   「新しい版が入ったのか」を誰も確かめられなかった。
                    "appVersion": crate::VERSION,
                });
                // 🔴🔴 合言葉が食い違っていたら、名乗り直す（2026-08-07・自己修復）。
                //
                //   常駐は登録のときに固定パスワードを作ってサーバーへ預ける。
                //   作り直すのは**登録の1回だけ**（登録済みなら ensure_enrolled は
                //   先頭で戻る）。ところが端末側で固定パスワードが書き換わる道があり、
                //   そうなると預かっている物と中身が**永久に食い違う**。
                //   相談員が繋ぐと必ず「パスワードが間違っています」になり、
                //   端末を消して入れ直す以外に直す道が無かった。
                //   ★端末が今の合言葉を名乗り直せるようにする。何が壊しても、
                //     次の報告で自然に揃う。
                //   ⚠ 毎回は送らない。まだ届いていない分があるときだけ。
                //     送る回数を増やすほど、値が流れる機会も増える。
                let pending = PENDING_PW.lock().ok().and_then(|p| p.clone());
                if let Some(ref pw) = pending {
                    body["fixedPassword"] = json!(pw);
                }
                let hb = post_status("/api/agent/heartbeat", Some(&token), body).await;
                // 🔴 受け取ってもらえたときだけ手放す。
                //   届かなかったのに手放すと、端末とサーバーが食い違ったまま残る。
                if pending.is_some() {
                    if let Some((200, _)) = hb {
                        // 🔴 受け取ってもらえた。ここではじめて端末に書き込む。
                        apply_pending_password();
                    }
                }
                // 🔴 断られたら、合鍵を捨てて登録からやり直す（2026-08-07）。
                //   管理者が端末を削除すると、この端末の合鍵は無効になる。
                //   これまでは 401 を捨てていたため、**永久に断られ続けたまま**
                //   一度も登録し直さなかった。実機で 1100 回連続の 401 を確認。
                //   ⚠ 通信できない（None）ときは触らない。回線の問題で
                //     登録し直す端末になってしまう。
                match hb {
                    Some((401, _)) | Some((403, _)) => {
                        forget_agent_token("サーバーに拒否されました");
                    }
                    _ => {
                        poll_and_execute(&token).await;
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(POLL_INTERVAL_SECS)).await;
        }
    }
}
