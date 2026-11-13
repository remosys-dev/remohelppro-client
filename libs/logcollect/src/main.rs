#![cfg_attr(windows, windows_subsystem = "windows")]

//! REMOHELP PRO ログ集めプログラム（2026-10-09 社長のご指示）。
//!
//! お客様と相談員の**両方**が使う、1つの小さな実行ファイル。
//!   ・お客様: 相談員が送った URL のページから落とす。ファイル名
//!            `remohelppro-logs-<札>.exe` の札で「どの依頼へ送るか」を知り、
//!            集める → 確認 → 当社へ送る。
//!   ・相談員: 同じ exe。札が無ければ送らず、ZIP を「ダウンロード」へ置いて
//!            選択状態で開く（画面「ログ分析依頼」へドラッグする）。
//!
//! 手本:
//!   ・送受信/更新の作法  libs/launcher（hbb_common を使わない小さな exe）
//!   ・自分の名前から札    libs/portable（dl_token_from_exe_name）
//!   ・集める場所          src/rl_send_log.rs / public/download/remohelppro-collect-logs.cmd
//!     ⚠ この3か所は**同じ場所**を見ること。片方だけ足すと食い違う。
//!
//! 🔴 管理者の確認（UAC）は1回だけ。断られたら集まる分だけ進める。
//! 🔴 別の人の管理者IDで昇格されると、昇格側の APPDATA が別人の物になる。
//!   ★昇格前に本人のフォルダを覚え、昇格側へ引数で渡す（.cmd と同じ直し）。
//! 🔴 送信先は RL_API_BASE の1か所だけ。⚠ 試験用は dev を焼くこと。

#[cfg(not(windows))]
fn main() {
    eprintln!("このプログラムは Windows 専用です。");
}

#[cfg(windows)]
fn main() {
    windows_impl::run();
}

#[cfg(windows)]
mod windows_impl {
    use std::ffi::OsStr;
    use std::io::Write;
    use std::os::windows::ffi::OsStrExt;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    /// 送信先。⚠ **ここ1か所だけ**（手本=launcher の RL_API_BASE）。
    ///   試験用の版は `RL_LOGCOLLECT_API_BASE=https://dev.remohelppro.jp` を焼く。
    ///   ⚠ option_env! はコンパイル時定数。**値を実際に使う**こと
    ///     （記録: option-env-const-fold-trap。真偽だけ見ると文字列が捨てられる）。
    const RL_API_BASE: &str = match option_env!("RL_LOGCOLLECT_API_BASE") {
        Some(v) => v,
        None => "https://svr.remohelppro.jp",
    };

    const TITLE: &str = "REMOHELP PRO ログ集め";

    pub fn run() {
        // ── 札（お客様モードか）を決める ──
        //   ① ファイル名 remohelppro-logs-<札>.exe
        //   ② 昇格して自分を呼び直したときは引数 --token <札>（名前からも読めるが明示する）
        let token = arg_value("--token").or_else(token_from_exe_name);

        // ── 昇格前に「本人のフォルダ」を覚える ──
        //   ⚠ UAC で別の管理者IDを入れられると、昇格側の APPDATA は別人の物になる。
        let elevated_phase = has_flag("--elevated");
        let user = if elevated_phase {
            UserDirs {
                appdata: arg_value("--appdata").unwrap_or_default(),
                localappdata: arg_value("--localappdata").unwrap_or_default(),
                downloads: arg_value("--downloads").unwrap_or_default(),
                username: arg_value("--user").unwrap_or_default(),
            }
        } else {
            UserDirs::current()
        };

        // ── 管理者の確認（UAC）を1回だけ ──
        //   ⚠ 断られたら集まる分だけ進める（手ぶらで終わらせない）。
        if !is_elevated() && !elevated_phase {
            if relaunch_elevated(&user, token.as_deref()) {
                return; // 昇格側が続ける
            }
            // 断られた → このまま、ふつうの権限で進む
        }

        // ── 集める ──
        let (zip_bytes, note) = build_zip(&user);

        // ── 送る / 置く ──
        match token.as_deref() {
            Some(tok) => send_to_server(tok, &zip_bytes, &note),
            None => save_for_operator(&user, &zip_bytes),
        }
    }

    // ──────────────────────────────── 本人のフォルダ ────────────────

    struct UserDirs {
        appdata: String,
        localappdata: String,
        downloads: String,
        username: String,
    }

    impl UserDirs {
        fn current() -> Self {
            let profile = std::env::var("USERPROFILE").unwrap_or_default();
            let downloads = if profile.is_empty() {
                String::new()
            } else {
                format!("{profile}\\Downloads")
            };
            UserDirs {
                appdata: std::env::var("APPDATA").unwrap_or_default(),
                localappdata: std::env::var("LOCALAPPDATA").unwrap_or_default(),
                downloads,
                username: std::env::var("USERNAME").unwrap_or_default(),
            }
        }
        fn appdata(&self) -> String {
            if self.appdata.is_empty() {
                std::env::var("APPDATA").unwrap_or_default()
            } else {
                self.appdata.clone()
            }
        }
    }

    // ──────────────────────────────── 札 ────────────────

    /// ファイル名 `remohelppro-logs-<札>.exe` から札を取り出す。
    /// ⚠ ブラウザが付ける ` (1)` などは外す（手本=portable）。
    /// ⚠ 札は 32 文字の英数と - _（サーバーと同じ形）。読めなければ None。
    fn token_from_exe_name() -> Option<String> {
        const PREFIX: &str = "remohelppro-logs-";
        let exe = std::env::current_exe().ok()?;
        let stem = exe.file_stem()?.to_string_lossy().to_string();
        let stem = match stem.rfind(" (") {
            Some(i)
                if stem.ends_with(')')
                    && stem[i + 2..stem.len() - 1].chars().all(|c| c.is_ascii_digit()) =>
            {
                stem[..i].to_string()
            }
            _ => stem,
        };
        let tok = stem.strip_prefix(PREFIX)?;
        if tok.len() == 32 && tok.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            Some(tok.to_string())
        } else {
            None
        }
    }

    // ──────────────────────────────── 集める ────────────────

    /// 集める場所（名札, 置き場）。
    /// ⚠ rl_send_log.rs / collect-logs.cmd と**同じ場所**。片方だけ足さない。
    fn log_sources(user: &UserDirs) -> Vec<(String, PathBuf)> {
        let appdata = user.appdata();
        let windir = std::env::var("windir").unwrap_or_else(|_| "C:\\Windows".to_owned());
        let public = std::env::var("PUBLIC").unwrap_or_else(|_| "C:\\Users\\Public".to_owned());
        let mut v: Vec<(String, PathBuf)> = Vec::new();

        let pub_root = Path::new(&public).join("Documents").join("REMOHELP PRO");
        if let Ok(rd) = std::fs::read_dir(&pub_root) {
            for e in rd.flatten() {
                if e.path().is_dir() {
                    let name = e.file_name().to_string_lossy().to_string();
                    v.push((format!("1-お客様用-{name}"), e.path().join("log")));
                }
            }
        }
        for (label, sub) in [
            ("2-相談員のログ", "remohelppro"),
            ("3-常駐のログ", "remohelppro-agent"),
            ("4-ワンタイムのログ", "remohelppro-support"),
        ] {
            v.push((label.to_owned(), Path::new(&appdata).join(sub).join("log")));
        }
        // 🔴 裏方（SYSTEM / サービス）の記録は、3製品とも集める（2026-11-13）。
        //   ⚠ 以前は相談員版（remohelppro）の分しか見ていなかった。
        //     常駐の本体の記録（ServiceProfiles の remohelppro-agent の log）が
        //     まるごと抜けていた（11/06 に判明）。
        let sys = Path::new(&windir).join("System32").join("config").join("systemprofile");
        let svc = Path::new(&windir)
            .join("ServiceProfiles")
            .join("LocalService");
        for (n, app) in [
            ("5-裏方(SYSTEM)", "remohelppro"),
            ("5-裏方(SYSTEM)-常駐", "remohelppro-agent"),
            ("5-裏方(SYSTEM)-ワンタイム", "remohelppro-support"),
        ] {
            v.push((
                n.to_owned(),
                sys.join("AppData").join("Roaming").join(app).join("log"),
            ));
        }
        for (n, app) in [
            ("6-サービス", "remohelppro"),
            ("6-サービス-常駐", "remohelppro-agent"),
            ("6-サービス-ワンタイム", "remohelppro-support"),
        ] {
            v.push((
                n.to_owned(),
                svc.join("AppData").join("Roaming").join(app).join("log"),
            ));
        }
        v
    }

    /// この端末のこと（どのPCから出たログか）。⚠ 合言葉・認証コードは書かない。
    ///   ⚠ 調査に役立つ物だけ: PC名・利用者・OS版・アプリの版・接続先・送信先。
    ///   （.cmd 版 remohelppro-collect-logs.cmd と同じくらいの情報量にそろえる）
    fn machine_note(user: &UserDirs, elevated: bool) -> String {
        let mut s = String::new();
        s.push_str(&format!("採取日時      : {}\r\n", now_string()));
        s.push_str(&format!("PC名          : {}\r\n", env_or("COMPUTERNAME", "?")));
        let uname = if user.username.is_empty() {
            env_or("USERNAME", "?")
        } else {
            user.username.clone()
        };
        s.push_str(&format!("Windows利用者 : {uname}\r\n"));
        s.push_str(&format!(
            "管理者で実行  : {}\r\n",
            if elevated {
                "はい"
            } else {
                "いいえ（裏方の記録は集まりません）"
            }
        ));
        // OS: env の "Windows_NT" は版が分からないので `cmd /c ver` の実際の版を使う。
        let os = run_hidden("cmd", &["/c", "ver"]);
        let os = os.lines().find(|l| !l.trim().is_empty()).unwrap_or("Windows").trim();
        s.push_str(&format!("OS            : {os}\r\n"));
        // 🔴 送信先を**実際に書く**＝ RL_API_BASE が実行ファイルに残り、焼き込みを grep で確かめられる。
        s.push_str(&format!("送信先        : {RL_API_BASE}\r\n"));

        s.push_str("\r\n--- 入っているアプリの版 ---\r\n");
        let mut any = false;
        for (label, app) in [
            ("相談員", "remohelppro"),
            ("常駐", "remohelppro-agent"),
            ("ワンタイム", "remohelppro-support"),
        ] {
            if let Some(v) = app_version(app) {
                s.push_str(&format!("  {label}({app}) : {v}\r\n"));
                any = true;
            }
        }
        if !any {
            s.push_str("  （入っているアプリが見つかりません）\r\n");
        }

        s.push_str("\r\n--- 接続先（秘密は出しません） ---\r\n");
        let cfg = config_servers(user);
        if cfg.is_empty() {
            s.push_str("  （設定が見つかりません）\r\n");
        } else {
            s.push_str(&cfg);
        }
        s
    }

    /// 入っているアプリの版を登録簿(Uninstall)から読む。⚠ 秘密ではない。
    fn app_version(app: &str) -> Option<String> {
        for base in [
            "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
            "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
        ] {
            let out = run_hidden("reg", &["query", &format!("{base}\\{app}"), "/v", "DisplayVersion"]);
            for line in out.lines() {
                if let Some(i) = line.find("REG_SZ") {
                    let v = line[i + 6..].trim();
                    if !v.is_empty() {
                        return Some(v.to_string());
                    }
                }
            }
        }
        None
    }

    /// 接続先だけを設定から拾う（custom-rendezvous-server / relay-server / api-server / host）。
    /// ⚠ 合言葉・登録トークン・鍵の行は**絶対に出さない**。
    fn config_servers(user: &UserDirs) -> String {
        let mut out = String::new();
        let windir = std::env::var("windir").unwrap_or_else(|_| "C:\\Windows".to_owned());
        let dirs = [
            Path::new(&user.appdata()).join("remohelppro").join("config"),
            Path::new(&user.appdata()).join("remohelppro-agent").join("config"),
            Path::new(&windir)
                .join("ServiceProfiles")
                .join("LocalService")
                .join("AppData")
                .join("Roaming")
                .join("remohelppro-agent")
                .join("config"),
        ];
        for dir in dirs {
            let Ok(rd) = std::fs::read_dir(&dir) else { continue };
            for e in rd.flatten() {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) != Some("toml") {
                    continue;
                }
                let Ok(text) = std::fs::read_to_string(&p) else { continue };
                for ln in text.lines() {
                    let t = ln.trim_start();
                    if t.starts_with("custom-rendezvous-server")
                        || t.starts_with("relay-server")
                        || t.starts_with("api-server")
                        || t.starts_with("rendezvous_server")
                        || t.starts_with("host ")
                        || t.starts_with("host=")
                    {
                        let name = p.file_name().unwrap_or_default().to_string_lossy();
                        out.push_str(&format!("  {name} : {}\r\n", ln.trim()));
                    }
                }
            }
        }
        out
    }

    /// 窓を出さずにコマンドを実行して標準出力を返す（CREATE_NO_WINDOW）。
    fn run_hidden(cmd: &str, args: &[&str]) -> String {
        use std::os::windows::process::CommandExt;
        let out = std::process::Command::new(cmd)
            .args(args)
            .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
            .output();
        match out {
            Ok(o) => String::from_utf8_lossy(&o.stdout).to_string(),
            Err(_) => String::new(),
        }
    }

    /// ZIP に入れる中身の合計の上限（圧縮前）。サーバーの上限 50MB より小さくする。
    const MAX_TOTAL_BYTES: u64 = 120 * 1024 * 1024;

    /// フォルダの中の .log / .txt を、下のフォルダ（3段まで）も含めて拾う。
    /// ⚠ ログだけ。設定や鍵を巻き込まない。⚠ 新しい物から先に入れる（上限で切れても新しい分が残る）。
    fn collect_files(dir: &Path, rel: &str, depth: u32, out: &mut Vec<(String, PathBuf)>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        let mut here: Vec<(std::time::SystemTime, String, PathBuf)> = Vec::new();
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            let r = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            if p.is_dir() {
                if depth < 3 {
                    collect_files(&p, &r, depth + 1, out);
                }
                continue;
            }
            // ⚠ 古い記録は自動で .zip に固められている（log\cm にもあった）。それも入れる。
            if !name.ends_with(".log") && !name.ends_with(".txt") && !name.ends_with(".zip") {
                continue;
            }
            let t = e
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            here.push((t, r, p));
        }
        here.sort_by(|a, b| b.0.cmp(&a.0));
        out.extend(here.into_iter().map(|(_, r, p)| (r, p)));
    }

    /// 集めて1つの ZIP（メモリ上）にまとめる。読めない物は飛ばす。
    fn build_zip(user: &UserDirs) -> (Vec<u8>, String) {
        let elevated = is_elevated();
        let note = machine_note(user, elevated);
        let buf = std::io::Cursor::new(Vec::<u8>::new());
        let mut zip = zip::ZipWriter::new(buf);
        let opts = zip::write::FileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);

        let _ = zip.start_file("0-この端末.txt", opts);
        let _ = zip.write_all(note.as_bytes());

        // 🔴🔴 **下のフォルダまで集める**（2026-11-13）。
        //   ⚠ 以前は log の**直下**だけを見ていた。接続の記録は
        //     log\server・log\cm・log\portable-service など**下のフォルダ**にある
        //     （記録: remohelppro-logs-live-in-subfolders）。＝肝心の記録が入っていなかった。
        //   ⚠ 全体の大きさに上限を置く（サーバーは 50MB まで）。超えた分は飛ばして、
        //     飛ばした物は 0-入れられなかった物.txt に書く。
        let mut total: u64 = 0;
        let mut skipped: Vec<String> = Vec::new();
        for (label, dir) in log_sources(user) {
            let mut files: Vec<(String, PathBuf)> = Vec::new();
            collect_files(&dir, "", 0, &mut files);
            for (rel, p) in files {
                let Ok(data) = std::fs::read(&p) else {
                    skipped.push(format!("{label}/{rel}（読めない）"));
                    continue;
                };
                if total + data.len() as u64 > MAX_TOTAL_BYTES {
                    skipped.push(format!("{label}/{rel}（大きさの上限）"));
                    continue;
                }
                if zip.start_file(format!("{label}/{rel}"), opts).is_err() {
                    continue;
                }
                total += data.len() as u64;
                let _ = zip.write_all(&data);
            }
        }
        if !skipped.is_empty() {
            let _ = zip.start_file("0-入れられなかった物.txt", opts);
            let _ = zip.write_all(skipped.join("\r\n").as_bytes());
        }
        let cursor = zip.finish().unwrap_or_else(|_| std::io::Cursor::new(Vec::new()));
        (cursor.into_inner(), note)
    }

    // ──────────────────────────────── 送る（お客様モード） ────────────────

    fn send_to_server(token: &str, zip: &[u8], note: &str) {
        // ⚠ 送る前に確認する（社長のご判断）。お客様が「何が送られるか」を見て決める。
        let summary = format!(
            "つながらなかった原因を調べるため、次の内容を送ります。\n\n{}\n\
             ・入力した文字や画面の内容、ファイルの中身は含まれません。\n\n送ってよろしいですか？",
            note.replace("\r\n", "\n")
        );
        if !confirm(&summary) {
            info("送信を取りやめました。");
            return;
        }

        match upload(token, zip) {
            Ok(()) => info(
                "送信しました。ありがとうございました。\n担当者が確認いたします。この画面は閉じて構いません。",
            ),
            Err(e) => error(&format!(
                "送信できませんでした。\n\nお手数ですが、サポート担当者にご連絡ください。\n\n（{e}）"
            )),
        }
    }

    /// multipart/form-data を自前で組み立てて送る（ureq に multipart 機能は無い）。
    fn upload(token: &str, zip: &[u8]) -> Result<(), String> {
        let boundary = "----RLlogcollectBoundary7a3f";
        let mut body: Vec<u8> = Vec::with_capacity(zip.len() + 256);
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; \
                 filename=\"customer.zip\"\r\nContent-Type: application/zip\r\n\r\n"
            )
            .as_bytes(),
        );
        body.extend_from_slice(zip);
        body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

        let url = format!("{RL_API_BASE}/api/customer/upload-log");
        let resp = ureq::post(&url)
            .timeout(Duration::from_secs(120))
            .set("Authorization", &format!("Bearer {token}"))
            .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"))
            .send_bytes(&body);
        match resp {
            Ok(_) => Ok(()),
            // サーバーが理由を返していれば（期限切れ等）それを見せる。
            Err(ureq::Error::Status(code, r)) => {
                let msg = r
                    .into_string()
                    .ok()
                    .and_then(|s| json_field(&s, "error"))
                    .unwrap_or_else(|| format!("エラー {code}"));
                Err(msg)
            }
            Err(e) => Err(format!("通信できませんでした: {e}")),
        }
    }

    // ──────────────────────────────── 置く（相談員モード） ────────────────

    fn save_for_operator(user: &UserDirs, zip: &[u8]) {
        // 🔴 デスクトップには置かない（OneDrive で自動的にクラウドへ上がる）。
        //   ★「ダウンロード」へ。そこが OneDrive の中なら、このPCだけの場所へ。
        let mut dest = PathBuf::from(&user.downloads);
        let on_onedrive = dest.to_string_lossy().contains("OneDrive");
        if user.downloads.is_empty() || !dest.exists() || on_onedrive {
            dest = PathBuf::from(if user.localappdata.is_empty() {
                std::env::var("LOCALAPPDATA").unwrap_or_default()
            } else {
                user.localappdata.clone()
            })
            .join("REMOHELP PRO")
            .join("logs");
            let _ = std::fs::create_dir_all(&dest);
        }
        let stamp = timestamp();
        let out = dest.join(format!("remohelppro-logs-{stamp}.zip"));
        match std::fs::write(&out, zip) {
            Ok(()) => {
                select_in_explorer(&out);
                let admin = if is_elevated() {
                    ""
                } else {
                    "\n\n⚠ 管理者の確認が許可されなかったため、裏方の記録は入っていません。"
                };
                info(&format!(
                    "ログをまとめました。\n\n{}\n\n開いたフォルダの、選ばれているファイルを、\n\
                     相談員の画面「ログ分析依頼」の枠へドラッグしてください。{admin}",
                    out.display()
                ));
            }
            Err(e) => error(&format!("ログをまとめられませんでした。\n\n（{e}）")),
        }
    }

    /// エクスプローラーで、できたファイルを選んだ状態で開く。
    fn select_in_explorer(path: &Path) {
        let _ = std::process::Command::new("explorer.exe")
            .arg(format!("/select,{}", path.display()))
            .spawn();
    }

    // ──────────────────────────────── 昇格・権限 ────────────────

    fn is_elevated() -> bool {
        use winapi::um::processthreadsapi::{GetCurrentProcess, OpenProcessToken};
        use winapi::um::securitybaseapi::GetTokenInformation;
        use winapi::um::winnt::{TokenElevation, HANDLE, TOKEN_ELEVATION, TOKEN_QUERY};
        unsafe {
            let mut token: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return false;
            }
            let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
            let mut ret_len = 0u32;
            let ok = GetTokenInformation(
                token,
                TokenElevation,
                &mut elevation as *mut _ as *mut _,
                std::mem::size_of::<TOKEN_ELEVATION>() as u32,
                &mut ret_len,
            );
            winapi::um::handleapi::CloseHandle(token);
            ok != 0 && elevation.TokenIsElevated != 0
        }
    }

    /// 管理者で自分を呼び直す（1回だけ）。成功＝昇格側へ引き継げた（手本=.cmd の直し）。
    /// ⚠ 本人のフォルダを引数で渡す（別の管理者IDで昇格されても本人のログを集めるため）。
    fn relaunch_elevated(user: &UserDirs, token: Option<&str>) -> bool {
        use winapi::um::shellapi::ShellExecuteW;
        use winapi::um::winuser::SW_SHOWNORMAL;

        let Ok(exe) = std::env::current_exe() else {
            return false;
        };
        let mut params = format!(
            "--elevated --appdata \"{}\" --localappdata \"{}\" --downloads \"{}\" --user \"{}\"",
            user.appdata, user.localappdata, user.downloads, user.username
        );
        if let Some(t) = token {
            params.push_str(&format!(" --token \"{t}\""));
        }
        let verb = to_wide("runas");
        let file = to_wide(&exe.to_string_lossy());
        let args = to_wide(&params);
        let r = unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                verb.as_ptr(),
                file.as_ptr(),
                args.as_ptr(),
                std::ptr::null(),
                SW_SHOWNORMAL,
            )
        };
        // ShellExecuteW は成功すると 32 より大きい値を返す（断られると SE_ERR_ACCESSDENIED=5 等）。
        (r as usize) > 32
    }

    // ──────────────────────────────── 窓・小物 ────────────────

    fn confirm(text: &str) -> bool {
        use winapi::um::winuser::{MessageBoxW, IDOK, MB_ICONQUESTION, MB_OKCANCEL, MB_TOPMOST};
        unsafe {
            MessageBoxW(
                std::ptr::null_mut(),
                to_wide(text).as_ptr(),
                to_wide(TITLE).as_ptr(),
                MB_OKCANCEL | MB_ICONQUESTION | MB_TOPMOST,
            ) == IDOK
        }
    }

    fn info(text: &str) {
        msg(text, winapi::um::winuser::MB_ICONINFORMATION);
    }
    fn error(text: &str) {
        msg(text, winapi::um::winuser::MB_ICONERROR);
    }
    fn msg(text: &str, icon: u32) {
        use winapi::um::winuser::{MessageBoxW, MB_OK, MB_TOPMOST};
        unsafe {
            MessageBoxW(
                std::ptr::null_mut(),
                to_wide(text).as_ptr(),
                to_wide(TITLE).as_ptr(),
                MB_OK | icon | MB_TOPMOST,
            );
        }
    }

    fn to_wide(s: &str) -> Vec<u16> {
        OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
    }

    fn env_or(k: &str, d: &str) -> String {
        std::env::var(k).unwrap_or_else(|_| d.to_owned())
    }

    fn has_flag(flag: &str) -> bool {
        std::env::args().any(|a| a == flag)
    }

    /// `--key value` の value を取り出す。
    fn arg_value(key: &str) -> Option<String> {
        let mut it = std::env::args();
        while let Some(a) = it.next() {
            if a == key {
                return it.next();
            }
        }
        None
    }

    /// いまの地方時刻を SYSTEMTIME から取る。
    fn local_time() -> winapi::um::minwinbase::SYSTEMTIME {
        unsafe {
            let mut st: winapi::um::minwinbase::SYSTEMTIME = std::mem::zeroed();
            winapi::um::sysinfoapi::GetLocalTime(&mut st);
            st
        }
    }

    /// `20261009-201530` のような、ファイル名向けの読みやすい印。
    fn timestamp() -> String {
        let t = local_time();
        format!(
            "{:04}{:02}{:02}-{:02}{:02}{:02}",
            t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
        )
    }

    /// `2026-10-09 20:15:30` のような、読みやすい採取日時。
    fn now_string() -> String {
        let t = local_time();
        format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
            t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
        )
    }

    /// ごく小さな JSON 取り出し（"key":"value" の value）。依存を増やさないため。
    fn json_field(s: &str, key: &str) -> Option<String> {
        let pat = format!("\"{key}\"");
        let i = s.find(&pat)? + pat.len();
        let rest = &s[i..];
        let c = rest.find(':')? + 1;
        let rest = rest[c..].trim_start();
        let rest = rest.strip_prefix('"')?;
        let end = rest.find('"')?;
        Some(rest[..end].to_string())
    }
}
