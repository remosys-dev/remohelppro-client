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
            // 🔴 インストール版は更新しない（上書きすると壊れる）。そのまま起動する。
            eprintln!("installed layout: launch without update");
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
    let mut cmd = Command::new(app);
    cmd.args(&args);
    // 起動したら見届けない。ランチャーは即座に終わる。
    let _ = cmd.spawn();
}
