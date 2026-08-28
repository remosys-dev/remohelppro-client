// 遠隔サポート中だけ、管理者の確認（UAC）を通しやすくする。
//
// ■ なぜ要るか（2026-08-28 ご判断）
//   ⚠ 遠隔サポートで本当に困るのは UAC そのものではなく、
//     **確認が「暗くなる画面（セキュアデスクトップ）」に出る**こと。
//     あの画面は相談員の画面に**映らず、押すこともできない**。
//     ＝ ソフトの導入などで管理者権限が要る場面で、作業がそこで止まる。
//
// ■ どこを触るか（効き方が違うので、選んで触る）
//     PromptOnSecureDesktop     … 即時。確認を**普通の画面**に出す（＝相談員に見える）
//     ConsentPromptBehaviorAdmin… 即時。確認を出さずに昇格する
//     ⚠ EnableLUA               … **触らない**
//        理由: 変更に**再起動が要る**。切るのも戻すのも再起動が要るので、
//        「その場で助からない」のに「戻すのにも再起動が要る」という
//        いちばん悪い組み合わせになる。お客様のPCを、当社の都合で
//        **再起動しないと元に戻らない状態**にしてはいけない。
//
// ■ 絶対条件：必ず元に戻すこと
//   ⚠ 「終わるときに戻す」だけでは戻らない。今日だけでも、アプリが
//     落ちる／強制終了される／片付けで殺される形を何度も見ている。
//   ★変える**前に**元の値をファイルに残し、
//     ① 切断時に戻す（正常系）
//     ② 次に起動したとき、控えが残っていたら**まず戻す**（保険）
//   の2本立てにする。1つに頼らない。

#![cfg(windows)]

use hbb_common::{log, ResultType};
use std::{io::Write, path::PathBuf};
use winreg::{enums::*, RegKey};

const POLICY_KEY: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System";

/// 触る値。⚠ ここに `EnableLUA` を足さないこと（上の説明）。
const VALUES: &[&str] = &["PromptOnSecureDesktop", "ConsentPromptBehaviorAdmin"];

/// 元の値の控え。⚠ 利用者ごとの場所に置かない（戻すのは SYSTEM のこともある）。
fn backup_path() -> PathBuf {
    let base = std::env::var("ProgramData").unwrap_or_else(|_| "C:\\ProgramData".to_string());
    PathBuf::from(base)
        .join("REMOHELP PRO")
        .join("uac-backup.txt")
}

fn policy_key(write: bool) -> ResultType<RegKey> {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let access = if write {
        KEY_READ | KEY_WRITE
    } else {
        KEY_READ
    };
    Ok(hklm.open_subkey_with_flags(POLICY_KEY, access)?)
}

/// いまの値を読む。無い値は None（＝Windows の既定のまま）。
fn read_current() -> Vec<(String, Option<u32>)> {
    let Ok(key) = policy_key(false) else {
        return VALUES.iter().map(|n| (n.to_string(), None)).collect();
    };
    VALUES
        .iter()
        .map(|n| (n.to_string(), key.get_value::<u32, _>(n).ok()))
        .collect()
}

/// サポート中の状態にする。⚠ **控えを先に書いてから**変える。
///
/// 🔴 順番が肝心。控えを書く前に変えると、そこで落ちたときに
///   **何が元の値だったのか誰も分からなくなる**。
pub fn relax_for_session() -> ResultType<()> {
    let current = read_current();

    // ⚠ 既に控えがあるなら、前回戻せていないということ。上書きしない。
    //   （上書きすると「変更後の値」が控えになり、二度と元に戻せなくなる）
    let path = backup_path();
    if !path.exists() {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut f = std::fs::File::create(&path)?;
        for (name, v) in &current {
            match v {
                Some(v) => writeln!(f, "{name}={v}")?,
                // ⚠ 「値が無かった」ことも残す。戻すときに**消す**必要がある。
                None => writeln!(f, "{name}=none")?,
            }
        }
        log::info!("RL uac: 元の値を控えました → {}", path.display());
    } else {
        log::warn!("RL uac: 前回の控えが残っています（戻せていない）。上書きしません");
    }

    let key = policy_key(true)?;
    for name in VALUES {
        if let Err(e) = key.set_value(*name, &0u32) {
            log::error!("RL uac: {name} を変えられません: {e}");
        }
    }
    log::info!("RL uac: サポート中の設定にしました（確認は普通の画面に出ます）");
    Ok(())
}

/// 元に戻す。控えが無ければ何もしない（＝触っていない）。
pub fn restore() -> ResultType<()> {
    let path = backup_path();
    if !path.exists() {
        return Ok(());
    }
    let text = std::fs::read_to_string(&path)?;
    let key = policy_key(true)?;
    for line in text.lines() {
        let Some((name, value)) = line.split_once('=') else {
            continue;
        };
        let name = name.trim();
        if !VALUES.contains(&name) {
            continue;
        }
        let value = value.trim();
        let r = if value == "none" {
            // ⚠ 元は「値が無かった」。0 を書き戻すのではなく**消す**。
            key.delete_value(name).map_err(|e| e.to_string())
        } else {
            match value.parse::<u32>() {
                Ok(v) => key.set_value(name, &v).map_err(|e| e.to_string()),
                Err(e) => Err(e.to_string()),
            }
        };
        match r {
            Ok(_) => log::info!("RL uac: {name} を元に戻しました（{value}）"),
            Err(e) => log::error!("RL uac: {name} を戻せません: {e}"),
        }
    }
    // ⚠ 戻し終えてから控えを消す。先に消すと、途中で落ちたときに戻せなくなる。
    let _ = std::fs::remove_file(&path);
    log::info!("RL uac: 元の設定に戻しました");
    Ok(())
}

/// 起動時に呼ぶ保険。前回戻せていなければ、ここで戻す。
///
/// 🔴 「終わるときに戻す」だけに頼らない（2026-08-28）。
///   アプリは落ちる。強制終了もされる。⚠ **戻す道は2本用意する。**
pub fn restore_if_pending() {
    if !backup_path().exists() {
        return;
    }
    log::warn!("RL uac: 前回戻せていない設定が見つかりました。戻します");
    if let Err(e) = restore() {
        log::error!("RL uac: 起動時の戻しに失敗しました: {e}");
    }
}

/// サポート中だけ持っておく札。落ちるときに `Drop` で戻る。
///
/// ⚠ `Drop` は「正常に終わったとき」しか走らない。⚠ **それだけに頼らない**
///   ために [`restore_if_pending`] を起動時に呼ぶこと。
pub struct UacRelaxer;

impl UacRelaxer {
    pub fn new() -> ResultType<Self> {
        relax_for_session()?;
        Ok(Self)
    }
}

impl Drop for UacRelaxer {
    fn drop(&mut self) {
        if let Err(e) = restore() {
            log::error!("RL uac: 戻せませんでした: {e}");
        }
    }
}
