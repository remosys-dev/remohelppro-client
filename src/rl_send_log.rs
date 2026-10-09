// 相談員アプリが、自分のPCのログを集めて管理サーバーへ送る（2026-10-09 社長のご指示）。
//
// 🔴🔴 なぜ要るか
//   社長「相談員ログは相談員PCにあるんだから、自動で収集できるよね」
//        「自動でログフォルダの中身を圧縮して送るようにすればいいかな」
//   ⚠ ブラウザの画面からは、そのPCの中のファイルを読めない（Webの決まり）。
//     これまでは道具を落として実行し、できた ZIP を画面へドラッグする3手順だった。
//   ★画面の［📤 ログ分析依頼］から `remohelppro://sendlog?t=札` で呼ばれ、
//     集める・まとめる・送る を **1回の操作**で済ませる。
//
// ⚠ **窓は開かない。** 送って、そのまま終わる。
//   押すたびに本体が起動すると、接続番号や通信路を奪い合う
//   （記録: remohelppro-duplicate-instances-break-everything）。
//
// 🔴 管理者の確認（UAC）を1回だけ出す（2026-10-09 社長のご判断「あ」）。
//   ⚠ 接続を**受ける側**の記録は SYSTEM の場所にあり、ふつうの権限では
//     フォルダの有無すら分からない。いちばん肝心な部分なので昇格して取る。
//   ⚠ 断られたら**集まる分だけ送る**。手ぶらで終わらせない。
//
// ⚠ ログは 2026-10-09 以降の版では**暗号化して書かれている**（rl_logcrypt.rs）。
//   ＝ 送る途中も、サーバーの置き場でも中身は読めない。読めるのは当社の秘密鍵だけ。
//
// ⚠ 依存を増やしていない。
//   reqwest に multipart の機能が入っていないため、送る形は**自前で組み立てる**。
//   ここで Cargo.toml を触ると3製品すべての組み立てに影響する。

use hbb_common::{config, log};
use std::io::Write;
use std::path::{Path, PathBuf};

/// 札の文字として許す形。⚠ 外から来る文字をそのまま URL に積まない。
fn is_safe_token(t: &str) -> bool {
    !t.is_empty()
        && t.len() <= 128
        && t.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// `sendlog?t=xxxx&code=yyyy` から値を取り出す。
/// ⚠ 版の報告（rl_report_version.rs）と同じ考え方。自前で雑に切らない。
fn param_of(rest: &str, key: &str) -> Option<String> {
    let q = rest.split_once('?')?.1;
    for kv in q.split('&') {
        if let Some((k, v)) = kv.split_once('=') {
            if k == key {
                return Some(percent_decode(v));
            }
        }
    }
    None
}

/// ごく小さな URL デコード。⚠ 依存を増やさないために自前。
fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).unwrap_or("");
            if let Ok(v) = u8::from_str_radix(hex, 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| s.to_owned())
}

/// 集める場所の一覧（名札, 置き場）。
///
/// ⚠ ここの一覧は、手で集める道具（`public/download/remohelppro-collect-logs.cmd`）と
///   **同じ場所**を見ること。片方だけ足すと
///   「手で集めた物にはあるのに、自動には無い」が起きて原因を見失う。
#[cfg(windows)]
fn log_sources() -> Vec<(String, PathBuf)> {
    let mut v: Vec<(String, PathBuf)> = Vec::new();
    let appdata = std::env::var("APPDATA").unwrap_or_default();
    let windir = std::env::var("windir").unwrap_or_else(|_| "C:\\Windows".to_owned());
    let public = std::env::var("PUBLIC").unwrap_or_else(|_| "C:\\Users\\Public".to_owned());

    // お客様用（ワンタイム）は「全員が読める場所」に置かれる
    let pub_root = Path::new(&public).join("Documents").join("REMOHELP PRO");
    if let Ok(rd) = std::fs::read_dir(&pub_root) {
        for e in rd.flatten() {
            if e.path().is_dir() {
                let name = e.file_name().to_string_lossy().to_string();
                v.push((format!("1-お客様用-{}", name), e.path().join("log")));
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
    // ⚠ ここから下は管理者でないと**フォルダの有無すら分からない**。
    v.push((
        "5-裏方(SYSTEM)のログ".to_owned(),
        Path::new(&windir)
            .join("System32")
            .join("config")
            .join("systemprofile")
            .join("AppData")
            .join("Roaming")
            .join("remohelppro")
            .join("log"),
    ));
    v.push((
        "6-サービスのログ".to_owned(),
        Path::new(&windir)
            .join("ServiceProfiles")
            .join("LocalService")
            .join("AppData")
            .join("Roaming")
            .join("remohelppro")
            .join("log"),
    ));
    v
}

#[cfg(not(windows))]
fn log_sources() -> Vec<(String, PathBuf)> {
    vec![("2-相談員のログ".to_owned(), config::Config::log_path())]
}

/// この端末のことを1枚にまとめる。
///
/// ⚠ どのPCから出たログかが分からないと、届いても調べようがない
///   （2026-10-09 社長のご指摘）。
/// ⚠ 合言葉・認証コードは書かない。端末を見分けるのに要る物だけ。
fn machine_note(elevated: bool) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "採取日時      : {}\n",
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S %:z")
    ));
    s.push_str(&format!("PC名          : {}\n", hbb_common::whoami::hostname()));
    s.push_str(&format!("利用者        : {}\n", hbb_common::whoami::username()));
    s.push_str(&format!(
        "管理者で実行  : {}\n",
        if elevated {
            "はい"
        } else {
            "いいえ（裏方のログは集まりません）"
        }
    ));
    s.push_str(&format!("OS            : {}\n", hbb_common::whoami::platform()));
    s.push_str(&format!("アプリの版    : {}\n", crate::VERSION));
    s.push_str(&format!(
        "アプリ名      : {}\n",
        config::APP_NAME.read().unwrap()
    ));
    s.push_str(&format!(
        "ログの置き場  : {}\n",
        config::Config::log_path().display()
    ));
    s
}

/// 1つの ZIP にまとめる。⚠ 読めない物は飛ばす（1つで全部を止めない）。
fn build_zip(elevated: bool) -> std::io::Result<(PathBuf, usize)> {
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S").to_string();
    let out = std::env::temp_dir().join(format!("remohelppro-evidence-{}.zip", stamp));
    let file = std::fs::File::create(&out)?;
    let mut zip = zip::ZipWriter::new(file);
    let opts = zip::write::FileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);

    zip.start_file("0-この端末.txt", opts)?;
    zip.write_all(machine_note(elevated).as_bytes())?;

    let mut n = 0usize;
    for (label, dir) in log_sources() {
        let Ok(rd) = std::fs::read_dir(&dir) else {
            continue;
        };
        for e in rd.flatten() {
            let p = e.path();
            if !p.is_file() {
                continue;
            }
            let name = e.file_name().to_string_lossy().to_string();
            // ⚠ ログだけ。設定や鍵を巻き込まない。
            if !name.ends_with(".log") && !name.ends_with(".txt") {
                continue;
            }
            let Ok(data) = std::fs::read(&p) else {
                continue;
            };
            if zip.start_file(format!("{}/{}", label, name), opts).is_err() {
                continue;
            }
            if zip.write_all(&data).is_ok() {
                n += 1;
            }
        }
    }
    zip.finish()?;
    Ok((out, n))
}

#[cfg(windows)]
fn is_elevated() -> bool {
    crate::platform::is_elevated(None).unwrap_or(false)
}

#[cfg(not(windows))]
fn is_elevated() -> bool {
    true
}

/// 管理者で自分をもう一度動かす（1回だけ）。
/// ⚠ 無限に自分を呼ばないよう、合図（環境変数）を付ける。
#[cfg(windows)]
fn relaunch_elevated(rest: &str) -> bool {
    if std::env::var("RL_SENDLOG_ELEVATED").is_ok() {
        // ⚠ すでに1回やっている。これ以上 UAC を出さない。
        return false;
    }
    let Ok(exe) = std::env::current_exe() else {
        return false;
    };
    let scheme = config::APP_NAME.read().unwrap().to_lowercase();
    let arg = format!("{}://{}", scheme, rest);
    // ⚠ 単引用符は PowerShell の決まりで2つ重ねて逃がす。
    let ps = format!(
        "$env:RL_SENDLOG_ELEVATED='1'; Start-Process -FilePath '{}' -ArgumentList '{}' -Verb RunAs",
        exe.display().to_string().replace('\'', "''"),
        arg.replace('\'', "''")
    );
    std::process::Command::new("powershell")
        .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", &ps])
        .spawn()
        .is_ok()
}

#[cfg(not(windows))]
fn relaunch_elevated(_rest: &str) -> bool {
    false
}

/// 送る形（multipart/form-data）を自前で組み立てる。
/// ⚠ reqwest に multipart の機能が入っていないため。ここで Cargo.toml を触らない。
fn multipart_body(boundary: &str, zip: Vec<u8>, code: &str) -> Vec<u8> {
    let mut body: Vec<u8> = Vec::with_capacity(zip.len() + 512);
    if !code.is_empty() {
        body.extend_from_slice(
            format!(
                "--{}\r\nContent-Disposition: form-data; name=\"code\"\r\n\r\n{}\r\n",
                boundary, code
            )
            .as_bytes(),
        );
    }
    body.extend_from_slice(
        format!(
            "--{}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"evidence.zip\"\r\n\
             Content-Type: application/zip\r\n\r\n",
            boundary
        )
        .as_bytes(),
    );
    body.extend_from_slice(&zip);
    body.extend_from_slice(format!("\r\n--{}--\r\n", boundary).as_bytes());
    body
}

/// 入口。`remohelppro://sendlog?t=札&code=認証コード` で呼ばれる。
pub fn rl_send_log(rest: &str) {
    let Some(token) = param_of(rest, "t").filter(|t| is_safe_token(t)) else {
        log::info!("sendlog: 札が読めません");
        return;
    };
    // ⚠ 認証コード／接続番号。英数6文字だけ通す（外から来る文字をそのまま積まない）。
    let code = param_of(rest, "code")
        .map(|c| c.trim().to_uppercase())
        .filter(|c| c.len() == 6 && c.chars().all(|ch| ch.is_ascii_alphanumeric()))
        .unwrap_or_default();

    // 🔴 管理者でなければ、1回だけ昇格して取り直す（社長のご判断「あ」）。
    //   ⚠ 断られたら、そのまま集まる分だけ送る。手ぶらで終わらせない。
    let elevated = is_elevated();
    if !elevated && relaunch_elevated(rest) {
        log::info!("sendlog: 管理者で取り直します");
        return;
    }

    let (zip_path, n) = match build_zip(elevated) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("sendlog: まとめられません: {}", e);
            return;
        }
    };
    log::info!("sendlog: {} 本を {} にまとめました", n, zip_path.display());

    let Ok(bytes) = std::fs::read(&zip_path) else {
        log::warn!("sendlog: まとめた物を読めません");
        let _ = std::fs::remove_file(&zip_path);
        return;
    };
    let url = format!("{}/api/op/upload-log", config::AGENT_API_BASE);
    let boundary = format!("----RLsendlog{}", chrono::Local::now().timestamp_nanos_opt().unwrap_or(0));
    let body = multipart_body(&boundary, bytes, &code);

    // ⚠ ここは起動直後で tokio の実行環境がまだ無い。自分で作る。
    let rt = match hbb_common::tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            log::warn!("sendlog: 実行環境を作れません: {}", e);
            let _ = std::fs::remove_file(&zip_path);
            return;
        }
    };
    rt.block_on(async move {
        let client = match reqwest::Client::builder()
            // ⚠ 版の報告（8秒）より長く取る。ログは数MBになる。
            .timeout(std::time::Duration::from_secs(120))
            .build()
        {
            Ok(c) => c,
            Err(e) => {
                log::warn!("sendlog: 送る道具を作れません: {}", e);
                return;
            }
        };
        match client
            .post(&url)
            .header("Authorization", format!("Bearer {}", token))
            .header(
                "Content-Type",
                format!("multipart/form-data; boundary={}", boundary),
            )
            .body(body)
            .send()
            .await
        {
            Ok(r) if r.status().is_success() => log::info!("sendlog: 送りました"),
            Ok(r) => log::warn!("sendlog: 送れません（{}）", r.status()),
            Err(e) => log::warn!("sendlog: 送れません: {}", e),
        }
    });
    // ⚠ 送っても送れなくても、作った物は残さない（PCを汚さない）。
    let _ = std::fs::remove_file(&zip_path);
}
