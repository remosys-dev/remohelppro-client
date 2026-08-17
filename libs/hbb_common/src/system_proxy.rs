// パソコンに元から入っているプロキシの設定を読む。
//
// 🔴🔴 なぜ要るか（2026-08-17）。
//   プロキシ必須の会社で繋ぐには、プロキシの場所が要る。
//   ⚠ しかし、
//     ・お客様は自分の会社のプロキシの場所を**知らない**（担当者しか知らない）
//     ・常駐の端末は**画面が無い**ので、そもそも誰も入れられない
//   ＝ 手で入れてもらう道だけでは、実際には届かない。
//
//   ★会社の端末には、既にプロキシが入っている（そうでないと Web が見られない）。
//     それを読めば、**手間ゼロ**で通る。
//
// ⚠ ここで読んだ設定を、勝手に保存しない。
//   保存すると、あとで会社がプロキシをやめたときに**古い設定で繋がらなくなる**。
//   使うのは「直につないで駄目だったとき」だけの、その場かぎりの逃げ道。
//
// ⚠ 読めなくても、決して失敗にしない。読めなければ「無い」と答えるだけ。

use crate::config::Socks5Server;

/// `ProxyServer` の書き方はいくつかある。
///   ① `proxy.example.co.jp:8080`（全部これを通す）
///   ② `http=a:80;https=b:8080;ftp=c:21`（種類ごと）
/// ⚠ ②のとき `http=` の方を取ると、443 の道が通らないことがある。
///   当社が通したいのは **https（443）** なので、そちらを優先する。
fn pick_proxy(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    if !raw.contains('=') {
        return Some(with_scheme(raw));
    }
    let mut http = None;
    for part in raw.split(';') {
        let mut it = part.splitn(2, '=');
        let key = it.next().unwrap_or("").trim().to_lowercase();
        let val = it.next().unwrap_or("").trim();
        if val.is_empty() {
            continue;
        }
        match key.as_str() {
            "https" => return Some(with_scheme(val)),
            "http" => http = Some(with_scheme(val)),
            _ => {}
        }
    }
    http
}

/// ⚠ Windows のこの設定は **HTTP の CONNECT を使うプロキシ**。
///   種類を書かずに渡すと socks5 と取られてしまうので、必ず `http://` を付ける。
fn with_scheme(v: &str) -> String {
    let v = v.trim();
    if v.contains("://") {
        v.to_string()
    } else {
        format!("http://{}", v)
    }
}

fn to_conf(proxy: String) -> Socks5Server {
    Socks5Server {
        proxy,
        username: String::new(),
        password: String::new(),
    }
}

#[cfg(target_os = "windows")]
pub fn detect() -> Option<Socks5Server> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;

    // ① 今ログオンしている人の設定（＝ブラウザが使っているもの）。
    //    お客様版（ワンタイム）はこの人として動くので、まずここ。
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    if let Ok(k) = hkcu.open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Internet Settings")
    {
        let enabled: u32 = k.get_value("ProxyEnable").unwrap_or(0);
        if enabled != 0 {
            if let Ok(server) = k.get_value::<String, _>("ProxyServer") {
                if let Some(p) = pick_proxy(&server) {
                    log::info!("RL: パソコンに入っているプロキシの設定を使います（利用者の設定）");
                    return Some(to_conf(p));
                }
            }
        }
    }

    // ② 常駐は SYSTEM として動くので、①には**その人の設定が無い**。
    //    会社が `netsh winhttp import proxy source=ie` を流していれば、
    //    ここに入っている。⚠ 入っていなければ常駐は繋がらないので、
    //    手順書にこの一行を必ず書くこと。
    detect_winhttp()
}

/// WinHTTP の設定は、決まった並びの生の値で入っている。
///   4バイト 版 ／ 4バイト 種別 ／ 4バイト 長さ ／ プロキシの文字列 ／ …
/// ⚠ 種別が 3（プロキシを使う）のときだけ意味がある。
#[cfg(target_os = "windows")]
fn detect_winhttp() -> Option<Socks5Server> {
    use winreg::enums::HKEY_LOCAL_MACHINE;
    use winreg::RegKey;

    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let k = hklm
        .open_subkey(
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections",
        )
        .ok()?;
    let raw: Vec<u8> = k.get_raw_value("WinHttpSettings").ok()?.bytes;
    if raw.len() < 12 {
        return None;
    }
    let kind = u32::from_le_bytes([raw[4], raw[5], raw[6], raw[7]]);
    if kind != 3 {
        return None;
    }
    let len = u32::from_le_bytes([raw[8], raw[9], raw[10], raw[11]]) as usize;
    if len == 0 || 12 + len > raw.len() {
        return None;
    }
    let server = String::from_utf8_lossy(&raw[12..12 + len]).to_string();
    let p = pick_proxy(&server)?;
    log::info!("RL: パソコンに入っているプロキシの設定を使います（WinHTTP の設定）");
    Some(to_conf(p))
}

/// ⚠ macOS・Linux はまだ読んでいない。
///   macOS は `scutil --proxy`、Linux は `https_proxy` などで取れるが、
///   実機で確かめられないうちは**入れない**。
///   「読めたつもりで読めていない」方が、無いより悪い。
#[cfg(not(target_os = "windows"))]
pub fn detect() -> Option<Socks5Server> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pick_proxy() {
        assert_eq!(
            pick_proxy("proxy.example.co.jp:8080"),
            Some("http://proxy.example.co.jp:8080".to_string())
        );
        // 種類ごとに書かれていたら https を取る（443 の道を通したいので）
        assert_eq!(
            pick_proxy("http=a:80;https=b:8080;ftp=c:21"),
            Some("http://b:8080".to_string())
        );
        // https が無ければ http で我慢する
        assert_eq!(
            pick_proxy("ftp=c:21;http=a:80"),
            Some("http://a:80".to_string())
        );
        // 種類が書いてあるのに中身が空なら、取らない
        assert_eq!(pick_proxy("https=;ftp=c:21"), None);
        assert_eq!(pick_proxy(""), None);
        assert_eq!(pick_proxy("   "), None);
        // 既に種類が書いてあれば、そのまま
        assert_eq!(
            pick_proxy("socks5://a:1080"),
            Some("socks5://a:1080".to_string())
        );
    }
}
