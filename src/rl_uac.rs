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
// ■ どこで効くか（2026-08-29 実測で確定）
//   ⚠ この設定は `HKLM` にあり、**管理者でないと書けない**。
//     ワンタイム（持ち運び版）はログインした人の権限で動くので**書けない**。
//     実機の記録: `変更できませんでした: アクセスが拒否されました。(os error 5)`
//   ★効くのは**常駐版**（LocalSystem のサービス）。
//     当社の既存の同種製品も同じ形で、
//     インストール型のサービスが接続中だけ変えて終了時に戻している。
//   ⚠ 相談員版では変えない（自社の端末の防御を下げる理由が無い）。
//
// ■ 絶対条件：必ず元に戻すこと（ご指示「サポート終了後削除する」）
//   ⚠ 「終わるときに戻す」だけでは戻らない。アプリが
//     落ちる／強制終了される／片付けで殺される形を何度も見ている。
//   ⚠ **常駐は入れっぱなし**なので、起動時の保険が効くのは次の再起動。
//     それでは遅い。だから見張りを足した。
//   ★変える**前に**元の値をファイルに残し、戻す道を4本用意する。
//     ① 誰も繋がっていなくなったとき（正常系）
//     ② プロセスが終わるとき（shutdown hook）
//     ③ 次に起動したとき、控えが残っていたら戻す（core_main）
//     ④ 常駐の見張りが、印の時刻が古いのを見つけたとき（restore_if_stale）
//   ⚠ 1本に頼らない。1本でも通れば戻る形にする。

#![cfg(windows)]

use hbb_common::{bail, log, ResultType};
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
    // 🔴🔴 **書ける身分かどうかを、控えを作る前に確かめる**（2026-08-29 実機で修正）。
    //
    //   ⚠ 実際に起きたこと（お客様のPCの記録）:
    //       RL uac: 元の値を控えました → C:\ProgramData\REMOHELP PRO\uac-backup.txt
    //       RL uac: 変更できませんでした: アクセスが拒否されました。(os error 5)
    //     ⚠ **1つも変えていないのに、控えだけが残った。**
    //   ⚠ 控えが残っていると、次回は「前回戻せていない」と判断して
    //     上書きを避ける作りなので、⚠ **一度失敗すると、以後ずっと控えが古いまま**。
    //     さらに起動時の restore_if_pending が、⚠ **触ってもいない設定を
    //     「戻し」に行く**（＝古い値を書き込む）。害のある残り方だった。
    //   ★開けるかどうかを先に見る。開けないなら、何も作らずに終わる。
    let key = policy_key(true)?;

    let current = read_current();

    // ⚠ 既に控えがあるなら、前回戻せていないということ。上書きしない。
    //   （上書きすると「変更後の値」が控えになり、二度と元に戻せなくなる）
    let path = backup_path();
    let fresh = !path.exists();
    if fresh {
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

    let mut changed = 0usize;
    let mut last_err = None;
    for name in VALUES {
        match key.set_value(*name, &0u32) {
            Ok(_) => changed += 1,
            Err(e) => {
                log::error!("RL uac: {name} を変えられません: {e}");
                last_err = Some(e);
            }
        }
    }

    // ⚠ 1つも変えられなかったのに控えを残さない。**残すと次回を塞ぐ。**
    //   ★自分で作った控えだけを消す。前から在ったものには触らない。
    if changed == 0 {
        if fresh {
            let _ = std::fs::remove_file(&path);
        }
        let msg = last_err
            .map(|e| e.to_string())
            .unwrap_or_else(|| "理由不明".to_string());
        bail!("UAC の設定を変えられません（{msg}）");
    }

    log::info!("RL uac: サポート中の設定にしました（{changed} 件・確認は普通の画面に出ます）");
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

/// 「まだサポート中」を書き続ける印。
///
/// 🔴 常駐版は**入れっぱなし**なので、起動時の保険（[`restore_if_pending`]）が
///   効くまでに何日もかかりうる。⚠ その間ずっと UAC が緩いままになる。
///   ★生きている間だけ、この印の時刻を更新し続ける。
///     止まれば時刻が古くなるので、⚠ **別のプロセスから「終わった」と分かる。**
fn heartbeat_path() -> PathBuf {
    backup_path().with_file_name("uac-active.txt")
}

fn touch_heartbeat() {
    let p = heartbeat_path();
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    // ⚠ 中身は使わない。見るのは**更新時刻**だけ。
    let _ = std::fs::write(&p, b"1");
}

/// 印が古ければ戻す。⚠ **常駐版の見張りから、繰り返し呼ぶ。**
///
/// 🔴 ご指示「常駐にする。しかしサポート終了後削除する」（2026-08-29）。
///   ⚠ 常駐で緩めるからには、⚠ **戻し損ねが一度もあってはいけない。**
///   ★① 切断時 ② プロセス終了時 ③ 次の起動時 に加えて、これが4本目。
///     ⚠ 一本でも通れば戻る、という形にしておく。
pub fn restore_if_stale(max_age: std::time::Duration) {
    let b = backup_path();
    if !b.exists() {
        return; // 触っていない
    }
    let hb = heartbeat_path();
    let fresh = std::fs::metadata(&hb)
        .and_then(|m| m.modified())
        .map(|t| t.elapsed().map(|d| d < max_age).unwrap_or(false))
        .unwrap_or(false);
    if fresh {
        return; // まだサポート中
    }
    log::warn!("RL uac: サポートが終わっているのに設定が残っています。戻します");
    if let Err(e) = restore() {
        log::error!("RL uac: 見張りからの戻しに失敗しました: {e}");
    }
}

/// サポート中だけ持っておく札。落ちるときに `Drop` で戻る。
///
/// ⚠ `Drop` は「正常に終わったとき」しか走らない。⚠ **それだけに頼らない**
///   ために [`restore_if_pending`] を起動時に、[`restore_if_stale`] を
///   常駐の見張りから呼ぶこと。
pub struct UacRelaxer {
    alive: std::sync::Arc<std::sync::atomic::AtomicBool>,
}

impl UacRelaxer {
    pub fn new() -> ResultType<Self> {
        relax_for_session()?;
        touch_heartbeat();
        let alive = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let flag = alive.clone();
        // ⚠ 生きている間だけ印を新しくし続ける。⚠ **止まれば古くなる**のが要点。
        std::thread::spawn(move || {
            while flag.load(std::sync::atomic::Ordering::Relaxed) {
                touch_heartbeat();
                std::thread::sleep(std::time::Duration::from_secs(30));
            }
        });
        Ok(Self { alive })
    }
}

impl Drop for UacRelaxer {
    fn drop(&mut self) {
        self.alive
            .store(false, std::sync::atomic::Ordering::Relaxed);
        let _ = std::fs::remove_file(heartbeat_path());
        if let Err(e) = restore() {
            log::error!("RL uac: 戻せませんでした: {e}");
        }
    }
}
