// ============================================================
//  ログを書く時点で暗号化する（2026-10-09 社長のご指示）
//
//  🔴 なぜ要るか
//    ⚠ お客様側のログは `C:\Users\Public\Documents\...` に平文で置かれ、
//      **そのPCを使う人全員が読める**状態だった。
//      中身に合言葉や認証コードは無いが、接続番号・相手のIP・
//      「いつ誰に繋いだか」という取引の事実が分かる。
//    社長「ログを平文にしないで暗号化するのは」→ 書く時点から暗号化すると決定。
//
//  ★方式（公開鍵だけをアプリに入れる）
//    ・アプリに入っているのは **公開鍵だけ**。解析されても読めない。
//    ・1行ずつ封をする（sealed box = 使い捨ての鍵で包む）。
//      ⚠ ファイル単位にしなかった理由:
//        ローテーション（日付替わり）や強制終了でファイルが途中で切れても、
//        **1行単位なら残りが読める**。障害調査は「落ちた直前」を見たいので、
//        壊れたら全部読めない形にしてはいけない。
//    ・読めるのは秘密鍵を持つ当社だけ（`C:\remohelppro\log-keys\`）。
//
//  ⚠ 代償（社長と合意ずみ・2026-10-09 Q-C「逃げ道なし」）
//    お客様のPCでも相談員のPCでも、その場では読めない。
//    調査は「集める → 手元で復号」の形になる。
//
//  ⚠ 古い平文のログはそのまま残す（Q-B「ア」）。31日で自然に消える。
// ============================================================

/// 🔴 当社の**公開鍵**（2026-10-09 作成）。
///   ⚠ これは秘密ではない。ソースに書いてよい（焼き込みの仕掛けは使わない＝
///     `option_env!` が畳まれる罠を踏まない）。
///   ⚠ 対になる秘密鍵は `C:\remohelppro\log-keys\rl-log-private.key`。
///     **失うと過去のログを二度と読めない。** 別の場所にも控えを取ること。
const RL_LOG_PUBKEY_HEX: &str = "a8672b9dcf3a83afb3e95a51e075c98df4a4baf75042efc0e02de1fb94369854";

/// 暗号化した行の目印。復号する道具がこれを見て判断する。
pub const RL_LOG_PREFIX: &str = "#1|";

fn pubkey() -> Option<sodiumoxide::crypto::box_::PublicKey> {
    use sodiumoxide::crypto::box_::PublicKey;
    let mut raw = [0u8; 32];
    let b = RL_LOG_PUBKEY_HEX.as_bytes();
    if b.len() != 64 {
        return None;
    }
    for i in 0..32 {
        let hi = (b[i * 2] as char).to_digit(16)?;
        let lo = (b[i * 2 + 1] as char).to_digit(16)?;
        raw[i] = (hi * 16 + lo) as u8;
    }
    Some(PublicKey(raw))
}

/// 1行を封じる。⚠ 失敗したら `None`（呼び出し側は**書かない**ことを選ぶ）。
pub fn seal_line(plain: &str) -> Option<String> {
    use base64::Engine;
    let pk = pubkey()?;
    let sealed = sodiumoxide::crypto::sealedbox::seal(plain.as_bytes(), &pk);
    Some(format!(
        "{}{}",
        RL_LOG_PREFIX,
        base64::engine::general_purpose::STANDARD.encode(sealed)
    ))
}
