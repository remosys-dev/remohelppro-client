// 起動のときの自動更新（2026-10-30 社長「起動前に自動でチェックしてアップデートをしてから起動する」）。
//
// 🔴 流れ
//   1. サーバーに配っている版を聞く（GET /api/operator-console → { version }）。3秒で諦める。
//   2. 自分より新しければ、入れ替えの画面を出して実行ファイルを受け取る（?file=1）。
//   3. 署名を確かめ、動いている自分を .old に名前替えし、新しい物を同じ名前で置いて起動し直す。
//
// ⚠ セットアップは使わない。インストール先は利用者が書き換えられるようにしてある（console.iss の
//   Permissions）ので、管理者の「はい」を毎回出さずに済む。書けなければ黙って今の版で開く。
// ⚠ 本番は署名（WinVerifyTrust）が通らない物は置かない。試験用は署名前の物を配るので確かめない。
// ⚠ どこで失敗しても、相談員の仕事を止めない（今の版でコンソールを開く）。

use std::path::{Path, PathBuf};
use std::time::Duration;

fn agent() -> Option<ureq::Agent> {
    let tls = native_tls::TlsConnector::new().ok()?;
    Some(
        ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(3))
            .timeout(Duration::from_secs(120))
            .tls_connector(std::sync::Arc::new(tls))
            .build(),
    )
}

fn parse(v: &str) -> Vec<u32> {
    v.split('.').map(|x| x.parse().unwrap_or(0)).collect()
}

/// サーバーの版が自分より新しければ、その版を返す
pub fn newer_version(base: &str) -> Option<String> {
    let a = agent()?;
    let body = a
        .get(&format!("{base}/api/operator-console"))
        .timeout(Duration::from_secs(3))
        .call()
        .ok()?
        .into_string()
        .ok()?;
    // {"version":"1.0.5"} だけなので、JSON の部品を足さずに取り出す
    let v = body.split("\"version\":\"").nth(1)?.split('"').next()?.to_owned();
    if v.is_empty() || !v.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return None;
    }
    if parse(&v) > parse(env!("CARGO_PKG_VERSION")) {
        Some(v)
    } else {
        None
    }
}

/// 前回の入れ替えで残った古い実行ファイルを消す
pub fn cleanup_old() {
    if let Ok(exe) = std::env::current_exe() {
        let _ = std::fs::remove_file(exe.with_extension("old"));
        let _ = std::fs::remove_file(exe.with_extension("new"));
    }
}

/// 受け取って入れ替える。成功したら新しい実行ファイルの場所を返す
pub fn download_and_swap(base: &str, verify_signature: bool) -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let new = exe.with_extension("new");
    let old = exe.with_extension("old");
    let a = agent().ok_or("tls")?;
    let resp = a
        .get(&format!("{base}/api/operator-console?file=1"))
        .call()
        .map_err(|e| e.to_string())?;
    let mut buf = Vec::new();
    std::io::Read::read_to_end(&mut resp.into_reader(), &mut buf).map_err(|e| e.to_string())?;
    if buf.len() < 64 * 1024 || &buf[..2] != b"MZ" {
        return Err("not an exe".into());
    }
    std::fs::write(&new, &buf).map_err(|e| e.to_string())?;
    if verify_signature && !signed(&new) {
        let _ = std::fs::remove_file(&new);
        return Err("signature".into());
    }
    let _ = std::fs::remove_file(&old);
    // ⚠ 動いている実行ファイルは消せないが、名前は変えられる
    std::fs::rename(&exe, &old).map_err(|e| {
        let _ = std::fs::remove_file(&new);
        e.to_string()
    })?;
    if let Err(e) = std::fs::rename(&new, &exe) {
        // 戻せるだけ戻す（相談員の PC にプログラムが無い状態にしない）
        let _ = std::fs::rename(&old, &exe);
        return Err(e.to_string());
    }
    Ok(exe)
}

/// Windows の署名の確かめ（改ざん・壊れた物を置かない）
fn signed(path: &Path) -> bool {
    use windows_sys::Win32::Security::WinTrust::{
        WinVerifyTrust, WINTRUST_ACTION_GENERIC_VERIFY_V2, WINTRUST_DATA, WINTRUST_FILE_INFO, WTD_CHOICE_FILE,
        WTD_REVOKE_NONE, WTD_STATEACTION_CLOSE, WTD_STATEACTION_VERIFY, WTD_UI_NONE,
    };
    let wpath = super::wide(&path.to_string_lossy());
    unsafe {
        let mut file: WINTRUST_FILE_INFO = std::mem::zeroed();
        file.cbStruct = std::mem::size_of::<WINTRUST_FILE_INFO>() as u32;
        file.pcwszFilePath = wpath.as_ptr();
        let mut data: WINTRUST_DATA = std::mem::zeroed();
        data.cbStruct = std::mem::size_of::<WINTRUST_DATA>() as u32;
        data.dwUIChoice = WTD_UI_NONE;
        data.fdwRevocationChecks = WTD_REVOKE_NONE;
        data.dwUnionChoice = WTD_CHOICE_FILE;
        data.Anonymous.pFile = &mut file;
        data.dwStateAction = WTD_STATEACTION_VERIFY;
        let mut action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
        let r = WinVerifyTrust(std::ptr::null_mut(), &mut action, &mut data as *mut _ as *mut _);
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        WinVerifyTrust(std::ptr::null_mut(), &mut action, &mut data as *mut _ as *mut _);
        r == 0
    }
}

/// 入れ替えの画面（見本の「5 起動のとき」）。⚠ 製品名はここだけ・ビット数は出さない
pub fn splash_html(from: &str, to: &str) -> String {
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><style>
body{{margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;
font-family:"Yu Gothic UI","Meiryo",sans-serif;background:#fff;color:#1f2937;user-select:none}}
.row{{display:flex;gap:12px;align-items:center}}
.lg{{width:44px;height:44px;border-radius:10px;background:#1565c0;color:#fff;font-weight:900;font-size:20px;display:grid;place-items:center}}
.t1{{font-weight:900;font-size:18px;color:#1565c0}}.t2{{font-weight:700}}
.pg{{width:300px;height:12px;background:#e5e7eb;border:1px solid #9ca3af;overflow:hidden}}
.pg i{{display:block;height:100%;width:40%;background:#22a04b;animation:m 1.2s ease-in-out infinite alternate}}
@keyframes m{{from{{margin-left:0}}to{{margin-left:60%}}}}
.s{{font-size:12px;color:#4b5563}}</style></head><body>
<div class="row"><div class="lg">R</div><div><div class="t1">REMOHELP PRO</div><div class="t2">相談員プログラム</div></div></div>
<div class="pg"><i></i></div><div class="s">新しい版に入れ替えています（{from} → {to}）…</div></body></html>"#
    )
}
