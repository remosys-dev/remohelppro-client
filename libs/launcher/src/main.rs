#![cfg_attr(windows, windows_subsystem = "windows")]

//! 相談員プログラムのランチャー（autorun 相当）。
//!
//! 相談員はこれを起動する。やることは3つだけ。
//!   ① 当社サーバーに最新の版を聞く
//!   ② 手元より新しければ入れ替える
//!   ③ 本体を起動する
//!
//! 🔴 **更新に失敗しても必ず本体を起動する。**
//!   通信が切れていても、サーバーが落ちていても、相談員の仕事は止めない。
//!   更新できないだけなら古い版で仕事ができるが、起動しなければ何もできない。
//!   ここを「更新できなければ止める」作りにしてはいけない。
//!
//! 🔴 **本体を実行中に上書きしない。**
//!   Windows は実行中の exe を置き換えられない。本体が動く前に差し替える
//!   この順序でなければ、更新のたびに壊れる危険がある。
//!
//! 🔴 **落とし切れていないファイルで置き換えない。**
//!   一時ファイルへ落とし、サイズを確かめてから入れ替える。
//!   壊れた exe に置き換えると、相談員のPCで二度と起動しなくなる。

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const VERSION_API: &str =
    "https://svr.remohelppro.jp/api/app/version?kind=operator_exe";
/// 本体の実行ファイル名（持ち運び版）。ランチャーと同じフォルダに置く。
const APP_EXE: &str = "remohelppro-operator.exe";
/// 手元の版を覚えておくファイル。
const VERSION_FILE: &str = "remohelppro-operator.version";
/// これ未満のサイズは「落とし切れていない」とみなす。
const MIN_SIZE: u64 = 5_000_000;

/// 本体の実行ファイル名（インストーラで入れた場合）。
///
/// 🔴 この2つを取り違えていた（2026-07-31 実機指摘）。
///   `remohelppro://` の受け先をランチャーに向けたが、ランチャーは
///   持ち運び版の名前しか探しておらず、インストーラが置くのは
///   `remohelppro.exe` だった。＝**本体が見つからず、相談員が
///   「操作アプリで開く」を押しても起動しなかった。**
const APP_EXE_INSTALLED: &str = "remohelppro.exe";

/// このフォルダの本体はどちらの形か。
///
/// 🔴 インストール版のときは**更新をしない**。
///   更新で落ちてくるのは「自己展開の持ち運び版」で、インストール版の
///   中身（本体exe＋多数のDLL）とは形が違う。上書きすると**インストールを壊す**。
///   インストール版の更新は MSI で行う別の仕組みが要る（未実装）。
enum AppKind {
    /// 持ち運び版。版を確かめて入れ替えてよい。
    Portable(PathBuf),
    /// インストール版。起動するだけ。
    Installed(PathBuf),
    /// 見つからない。
    Missing,
}

fn find_app(dir: &Path) -> AppKind {
    let portable = dir.join(APP_EXE);
    if portable.exists() {
        return AppKind::Portable(portable);
    }
    let installed = dir.join(APP_EXE_INSTALLED);
    if installed.exists() {
        return AppKind::Installed(installed);
    }
    AppKind::Missing
}

fn main() {
    let dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."));

    match find_app(&dir) {
        AppKind::Portable(app) => {
            // 更新は「できたら嬉しい」もの。失敗は握りつぶして先へ進む。
            if let Err(e) = try_update(&dir) {
                eprintln!("update skipped: {e}");
            }
            launch_app(&app);
        }
        AppKind::Installed(app) => {
            // 🔴 インストール版は**上書きしない**。更新で落ちてくるのは
            //   自己展開の持ち運び版で、インストール版（本体exe＋多数のDLL）
            //   とは形が違う。上書きするとインストールが壊れ、二度と起動しない。
            //
            //   代わりに「新しい版があります」と**知らせるだけ**にする
            //   （2026-07-31 ユーザー判断）。
            //   ⚠ 知らせても**必ず起動する**。相談員の仕事を止めない。
            eprintln!("installed layout: launch without update");
            notify_if_newer();
            launch_app(&app);
        }
        AppKind::Missing => not_found(),
    }
}

fn try_update(dir: &Path) -> Result<(), String> {
    let app = dir.join(APP_EXE);
    let vfile = dir.join(VERSION_FILE);

    let body = ureq::get(VERSION_API)
        .timeout(Duration::from_secs(10))
        .call()
        .map_err(|e| format!("version api: {e}"))?
        .into_string()
        .map_err(|e| format!("read: {e}"))?;

    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("json: {e}"))?;
    let latest = v.get("version").and_then(|x| x.as_str()).unwrap_or("");
    let url = v.get("url").and_then(|x| x.as_str()).unwrap_or("");
    if latest.is_empty() || url.is_empty() {
        return Err("no version info".into());
    }

    // 🔴 落としてくる先を当社に限る（2026-07-30 点検 G5）。
    //   ここは**無人で実行ファイルを入れ替える**経路なので、
    //   返ってきた URL をそのまま信じてはいけない。
    //   サーバー側の設定ミスや書き換えがあっても、別のホストからは取らない。
    //   ⚠ 前方一致で見る。`https://svr.remohelppro.jp.example.com/` のような
    //     紛らわしい名前を通さないため、区切りの `/` まで含めて比べる。
    const ALLOWED_PREFIX: &str = "https://svr.remohelppro.jp/";
    if !url.starts_with(ALLOWED_PREFIX) {
        return Err(format!("refused update url: {url}"));
    }

    let current = fs::read_to_string(&vfile).unwrap_or_default();
    // 本体が無いときは版が同じでも取りに行く（初回・破損時の復旧）。
    if current.trim() == latest && app.exists() {
        return Ok(());
    }

    // 一時ファイルへ落とす。ここで失敗しても本体はそのまま。
    let tmp = dir.join(format!("{APP_EXE}.new"));
    let resp = ureq::get(url)
        .timeout(Duration::from_secs(900))
        .call()
        .map_err(|e| format!("download: {e}"))?;
    let mut buf = Vec::new();
    resp.into_reader()
        .take(300 * 1024 * 1024)
        .read_to_end(&mut buf)
        .map_err(|e| format!("read body: {e}"))?;

    if (buf.len() as u64) < MIN_SIZE {
        return Err(format!("too small: {} bytes", buf.len()));
    }
    fs::write(&tmp, &buf).map_err(|e| format!("write tmp: {e}"))?;

    // 旧版を退避してから入れ替える。入れ替えに失敗したら戻す。
    let bak = dir.join(format!("{APP_EXE}.old"));
    let _ = fs::remove_file(&bak);
    if app.exists() {
        fs::rename(&app, &bak).map_err(|e| format!("backup: {e}"))?;
    }
    if let Err(e) = fs::rename(&tmp, &app) {
        // 戻せるうちに戻す。ここで諦めると本体が消えたまま残る。
        let _ = fs::rename(&bak, &app);
        return Err(format!("replace: {e}"));
    }
    let _ = fs::remove_file(&bak);
    let _ = fs::write(&vfile, latest);
    Ok(())
}

/// 本体が無いときだけ知らせる。
fn not_found() {
    {
        #[cfg(windows)]
        unsafe {
            use std::ffi::OsStr;
            use std::os::windows::ffi::OsStrExt;
            let to_w = |s: &str| {
                OsStr::new(s)
                    .encode_wide()
                    .chain(std::iter::once(0))
                    .collect::<Vec<u16>>()
            };
            winapi::um::winuser::MessageBoxW(
                std::ptr::null_mut(),
                to_w("相談員プログラムが見つかりません。もう一度インストールしてください。")
                    .as_ptr(),
                to_w("REMOHELP PRO").as_ptr(),
                winapi::um::winuser::MB_ICONERROR,
            );
        }
    }
}

/// 見つけた本体を、受け取った引数のまま起動する。
///
/// 🔴 引数（remohelppro://... の URL）を必ず渡すこと。
///   落とすと、相談員が「操作アプリで開く」を押しても
///   **接続先が分からないまま**アプリだけが立ち上がる。
fn launch_app(app: &Path) {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // ⚠ ビュアーが重複して起動する件（2026-08-02 実機指摘・未解決）。
    //   本体には「動いている窓へ渡す」仕組みが元からあり、ランチャーは
    //   引数をそのまま渡しているので、本来はそちらが働くはず。
    //   実機を見たときは本体の窓が1つも無く（背景のプロセスだけ）、
    //   **窓が開いている状態で確かめられていない**。
    //   推測で直すと、また別の壊れ方をする。窓が開いた状態で
    //   もう一度確かめてから直すこと。
    let mut cmd = Command::new(app);
    cmd.args(&args);
    // 起動したら見届けない。ランチャーは即座に終わる。
    let _ = cmd.spawn();
}

// ── インストール版へのお知らせ ────────────────────────────────
//
// 🔴 インストール版は自動更新できない（上書きするとインストールが壊れる）。
//   そこで「新しい版があります」と知らせるだけにする（2026-07-31 ユーザー判断）。
//
// ⚠ 知らせても**必ず本体を起動する**。相談員は電話中で、お客様を待たせている。
//   ここで止めると、更新より大事なことが止まる。
// ⚠ 同じ版のお知らせは**一度だけ**。押すたびに出すと読まなくなる。

/// お知らせ済みの版を覚えておくファイル。
fn notified_file() -> PathBuf {
    std::env::var("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("REMOHELP PRO")
        .join("notified.version")
}

/// いま入っている版（インストーラが登録した値）。
///
/// ⚠ 依存を増やさないため `reg query` の出力から拾う。
///   読めなければ None を返し、**お知らせは出さない**
///   （比べられないのに「新しい版があります」と出すのは害になる）。
fn installed_version() -> Option<String> {
    for root in [
        r"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\remohelppro",
        r"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\remohelppro",
    ] {
        let out = Command::new("reg")
            .args(["query", root, "/v", "DisplayVersion"])
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        for line in text.lines() {
            if line.contains("DisplayVersion") {
                if let Some(v) = line.split_whitespace().last() {
                    return Some(v.trim().to_string());
                }
            }
        }
    }
    None
}

/// 「1.4.22.29757852」→ (1,4,22) のように、前3つだけ比べる。
fn ver3(s: &str) -> (u32, u32, u32) {
    let mut it = s.split('.').map(|x| x.parse::<u32>().unwrap_or(0));
    (
        it.next().unwrap_or(0),
        it.next().unwrap_or(0),
        it.next().unwrap_or(0),
    )
}

fn notify_if_newer() {
    let Some(current) = installed_version() else {
        return; // 比べられないなら黙る
    };
    let Ok(body) = ureq::get("https://svr.remohelppro.jp/api/app/version?kind=operator_msi")
        .timeout(Duration::from_secs(6))
        .call()
        .and_then(|r| Ok(r.into_string()?))
    else {
        return; // 通信できないだけ。仕事は止めない
    };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) else {
        return;
    };
    let latest = v.get("version").and_then(|x| x.as_str()).unwrap_or("");
    if latest.is_empty() || ver3(latest) <= ver3(&current) {
        return;
    }
    // 同じ版で二度は出さない。
    let marker = notified_file();
    if fs::read_to_string(&marker).unwrap_or_default().trim() == latest {
        return;
    }
    if let Some(dir) = marker.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::write(&marker, latest);

    #[cfg(windows)]
    unsafe {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;
        let to_w = |s: &str| {
            OsStr::new(s)
                .encode_wide()
                .chain(std::iter::once(0))
                .collect::<Vec<u16>>()
        };
        let msg = format!(
            "新しい版があります。\n\n\
             お手元: {current}\n\
             最新  : {latest}\n\n\
             svr.remohelppro.jp/download から入れ直してください。\n\
             （このままでも接続できます）"
        );
        winapi::um::winuser::MessageBoxW(
            std::ptr::null_mut(),
            to_w(&msg).as_ptr(),
            to_w("REMOHELP PRO").as_ptr(),
            winapi::um::winuser::MB_OK | winapi::um::winuser::MB_ICONINFORMATION,
        );
    }
}
