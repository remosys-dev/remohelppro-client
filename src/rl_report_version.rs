// 相談員アプリが、自分のバージョンを管理サーバーへ名乗る（2026-10-03 社長のご指示）。
//
// 🔴🔴 なぜ要るか
//   社長「今使ってるバージョンを確認できるように、バージョン確認 をクリックすると
//        今のバージョンが確認できるようにしてください」
//        「使用中 1.4.97 ／ 最新 1.4.98（2026-09-26） ダウンロード　このように」
//
//   ⚠ ブラウザは、そのPCに入っている操作アプリの版を**知らない**。
//     これまでは「このアプリについて を押して自分で見てください」と案内するしかなかった。
//   ⚠ 相談員アプリは身元を持っていない（常駐PCは端末トークンを持つが、操作アプリは持たない）。
//   ★相談員が押した瞬間に渡される「その場限りの札」と、自分の版を送る。
//     サーバーは札からその相談員を特定して覚える。
//
// ⚠ **窓は開かない。** 送って、そのまま終わる。
//   押すたびに本体が起動すると、接続番号や通信路を奪い合う
//   （記録: remohelppro-duplicate-instances-break-everything）。
// ⚠ 送れなくても何も壊さない。黙って終わる（画面側が「確認できませんでした」と出す）。

use hbb_common::{config, log};

/// 札の文字として許す形。⚠ 外から来る文字をそのまま URL やメモリに積まない。
fn is_safe_token(t: &str) -> bool {
    !t.is_empty()
        && t.len() <= 128
        && t.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// `report-version?t=xxxx` の `xxxx` を取り出す。
/// ⚠ 自前で雑に切らない。`?` の後ろを `&` で割り、`t=` だけを見る。
fn token_of(rest: &str) -> Option<String> {
    let q = rest.split_once('?')?.1;
    for kv in q.split('&') {
        if let Some((k, v)) = kv.split_once('=') {
            if k == "t" {
                // ⚠ URL の符号化を戻す。`%2D` のような形で来ることがある。
                let decoded = percent_decode(v);
                if is_safe_token(&decoded) {
                    return Some(decoded);
                }
                return None;
            }
        }
    }
    None
}

/// ごく小さな URL デコード。⚠ 依存を増やさないために自前。失敗したらそのまま返す。
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

/// 版を送る。⚠ 短い時間で諦める（画面が12秒しか待たない）。
pub fn rl_report_version(rest: &str) {
    let Some(token) = token_of(rest) else {
        log::info!("report-version: 札が読めません");
        return;
    };
    let url = format!("{}/api/op/report-version", config::AGENT_API_BASE);
    let body = serde_json::json!({
        "token": token,
        "version": crate::VERSION,
    });
    log::info!("report-version: {} へ版 {} を送ります", url, crate::VERSION);

    // ⚠ ここは起動直後で tokio の実行環境がまだ無い。自分で作る。
    let rt = match hbb_common::tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            log::warn!("report-version: 実行環境を作れません: {}", e);
            return;
        }
    };
    rt.block_on(async move {
        let client = match reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(8))
            .build()
        {
            Ok(c) => c,
            Err(e) => {
                log::warn!("report-version: 送る道具を作れません: {}", e);
                return;
            }
        };
        match client.post(&url).json(&body).send().await {
            Ok(r) => log::info!("report-version: 応答 {}", r.status()),
            // ⚠ 失敗しても何も壊さない。画面側が「確認できませんでした」と出す。
            Err(e) => log::warn!("report-version: 送れませんでした: {}", e),
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_is_read() {
        assert_eq!(token_of("report-version?t=abc-123").as_deref(), Some("abc-123"));
        assert_eq!(token_of("report-version?x=1&t=zz_9").as_deref(), Some("zz_9"));
    }

    #[test]
    fn bad_token_is_refused() {
        // ⚠ 札が無い・空・変な文字は受けない。
        assert!(token_of("report-version").is_none());
        assert!(token_of("report-version?t=").is_none());
        assert!(token_of("report-version?t=../../etc/passwd").is_none());
        assert!(token_of(&format!("report-version?t={}", "a".repeat(200))).is_none());
    }
}
