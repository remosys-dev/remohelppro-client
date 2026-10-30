// コンソールの ⚙ 設定のうち、相談員プログラムが持つもの（2026-10-30 社長の確定見本「6 設定」）。
//   ・パソコンの起動時に開く … HKCU の Run に登録する（管理者の「はい」は要らない）
//   ・プロキシサーバー     … proxy.json に保存し、開き直すと効く
//
// ⚠ プロキシのパスワードは Windows の DPAPI で暗号化して保存する（この PC・この利用者だけが戻せる）。
//   ページ（コンソール）には返さない。
// ⚠ 効く範囲: コンソールの画面（WebView2 の起動引数）・起動時の自動更新（update.rs）。

use std::path::{Path, PathBuf};

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

fn run_name(dev: bool) -> &'static str {
    if dev { "REMOHELP PRO 相談員（試験用）" } else { "REMOHELP PRO 相談員" }
}

#[derive(Clone, Default)]
pub struct Proxy {
    /// system / none / manual
    pub mode: String,
    pub host: String,
    pub port: String,
    pub user: String,
    pub pass: String,
}

impl Proxy {
    /// 起動時の自動更新などに渡す URL（manual のときだけ）
    pub fn url(&self) -> Option<String> {
        if self.mode != "manual" || self.host.is_empty() || self.port.is_empty() {
            return None;
        }
        if self.user.is_empty() {
            Some(format!("http://{}:{}", self.host, self.port))
        } else {
            Some(format!("http://{}:{}@{}:{}", enc(&self.user), enc(&self.pass), self.host, self.port))
        }
    }

    /// WebView2（Edge の部品）に渡す起動引数
    pub fn webview_args(&self) -> Option<String> {
        match self.mode.as_str() {
            "none" => Some("--no-proxy-server".to_owned()),
            "manual" if !self.host.is_empty() && !self.port.is_empty() => {
                Some(format!("--proxy-server=http://{}:{}", self.host, self.port))
            }
            _ => None,
        }
    }
}

fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn proxy_file(dir: &Path) -> PathBuf {
    dir.join("proxy.json")
}

pub fn load_proxy(dir: &Path) -> Proxy {
    let Ok(text) = std::fs::read_to_string(proxy_file(dir)) else {
        return Proxy { mode: "system".into(), ..Default::default() };
    };
    let v: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
    let g = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_owned();
    let pass = unprotect(&g("pass_dpapi")).unwrap_or_default();
    let mode = match g("mode").as_str() {
        m @ ("none" | "manual") => m.to_owned(),
        _ => "system".to_owned(),
    };
    Proxy { mode, host: g("host"), port: g("port"), user: g("user"), pass }
}

/// ページから届いた設定を保存する。⚠ パスワードが空なら前の物を残す（ページには返していないため）
pub fn save_proxy(dir: &Path, json: &str) -> bool {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(json) else {
        return false;
    };
    let g = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").trim().to_owned();
    let old = load_proxy(dir);
    let mut pass = g("pass");
    if pass.is_empty() && g("user") == old.user {
        pass = old.pass;
    }
    let mode = match g("mode").as_str() {
        m @ ("none" | "manual") => m.to_owned(),
        _ => "system".to_owned(),
    };
    let port: String = g("port").chars().filter(|c| c.is_ascii_digit()).take(5).collect();
    let host: String = g("host").chars().filter(|c| c.is_ascii_alphanumeric() || ".-_:[]".contains(*c)).collect();
    let out = serde_json::json!({
        "mode": mode,
        "host": host,
        "port": port,
        "user": g("user"),
        "pass_dpapi": if pass.is_empty() { String::new() } else { protect(&pass).unwrap_or_default() },
    });
    let _ = std::fs::create_dir_all(dir);
    std::fs::write(proxy_file(dir), out.to_string()).is_ok()
}

/// ページに渡す今の値（JavaScript の式）。⚠ パスワードは入れない
pub fn page_settings_js(dir: &Path, dev: bool) -> String {
    let p = load_proxy(dir);
    let v = serde_json::json!({
        "autostart": autostart_enabled(dev),
        "proxy": { "mode": p.mode, "host": p.host, "port": p.port, "user": p.user },
    });
    format!("window.rlOperatorSettings = {v};")
}

// ---- 起動時に開く（HKCU\...\Run） ----

fn hkcu_run() -> Option<windows_sys::Win32::System::Registry::HKEY> {
    use windows_sys::Win32::System::Registry::{RegCreateKeyExW, HKEY_CURRENT_USER, KEY_READ, KEY_WRITE, REG_OPTION_NON_VOLATILE};
    let key = super::wide(RUN_KEY);
    let mut h = std::ptr::null_mut();
    let r = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            key.as_ptr(),
            0,
            std::ptr::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_READ | KEY_WRITE,
            std::ptr::null(),
            &mut h,
            std::ptr::null_mut(),
        )
    };
    if r == 0 { Some(h) } else { None }
}

pub fn autostart_enabled(dev: bool) -> bool {
    use windows_sys::Win32::System::Registry::{RegCloseKey, RegQueryValueExW};
    let Some(h) = hkcu_run() else { return false };
    let name = super::wide(run_name(dev));
    let r = unsafe { RegQueryValueExW(h, name.as_ptr(), std::ptr::null(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()) };
    unsafe { RegCloseKey(h) };
    r == 0
}

pub fn set_autostart(dev: bool, on: bool) {
    use windows_sys::Win32::System::Registry::{RegCloseKey, RegDeleteValueW, RegSetValueExW, REG_SZ};
    let Some(h) = hkcu_run() else { return };
    let name = super::wide(run_name(dev));
    if on {
        if let Ok(exe) = std::env::current_exe() {
            let cmd = super::wide(&format!("\"{}\"", exe.display()));
            unsafe {
                RegSetValueExW(h, name.as_ptr(), 0, REG_SZ, cmd.as_ptr() as *const u8, (cmd.len() * 2) as u32);
            }
        }
    } else {
        unsafe { RegDeleteValueW(h, name.as_ptr()) };
    }
    unsafe { RegCloseKey(h) };
}

// ---- DPAPI（パスワードの暗号化） ----

fn protect(s: &str) -> Option<String> {
    use windows_sys::Win32::Security::Cryptography::{CryptProtectData, CRYPT_INTEGER_BLOB};
    let data = s.as_bytes();
    let input = CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 };
    let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    let ok = unsafe { CryptProtectData(&input, std::ptr::null(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut out) };
    if ok == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize) }.to_vec();
    unsafe { windows_sys::Win32::Foundation::LocalFree(out.pbData as _) };
    Some(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

fn unprotect(hex: &str) -> Option<String> {
    use windows_sys::Win32::Security::Cryptography::{CryptUnprotectData, CRYPT_INTEGER_BLOB};
    if hex.is_empty() || hex.len() % 2 != 0 {
        return None;
    }
    let data: Vec<u8> = (0..hex.len()).step_by(2).filter_map(|i| u8::from_str_radix(&hex[i..i + 2], 16).ok()).collect();
    let input = CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 };
    let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    let ok = unsafe {
        CryptUnprotectData(&input, std::ptr::null_mut(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut out)
    };
    if ok == 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize) }.to_vec();
    unsafe { windows_sys::Win32::Foundation::LocalFree(out.pbData as _) };
    String::from_utf8(bytes).ok()
}
