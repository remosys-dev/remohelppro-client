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
// ■ 誰が変えるか（2026-08-29 実測で確定・ご判断「A案」）
//   ⚠ この設定は `HKLM` にあり、**管理者でないと書けない**。
//   ⚠ ここで一度取り違えた。「ワンタイムには管理者権限が無い」と考えたが、
//     ⚠ **同じアプリの中に、権限の違う部品が2つある。**
//     画面を出している本体はログインした人の権限、
//     画面を取り込む部品（`--run-as-system`）は SYSTEM。
//     ＝ 変えられるのは後者。前者から呼んでいたので一度も成功していなかった。
//     実機の記録: `変更できませんでした: アクセスが拒否されました。(os error 5)`
//
// ■ 製品ごとの方針（2026-08-29 ご指示「常駐はUAC完全解除、ワンタイムは
//   解除後終了時に戻す」）
//
//   常駐   … サービスが立ち上がったときに**切って、戻さない**
//            （core_main の `--service` → [`disable_permanently`]）
//            ⚠ 会社が管理している業務用PC。会社が決められる筋合いのもの。
//            ⚠ **接続のたびには触らない。** 1.4.61 でそれをやって失敗した
//              （戻す道が全部死んで「切ったまま・こちらは切ったつもりが無い」
//               という最悪の状態を実機で作った）。
//   ワンタイム … 権限のある部品（`--run-as-system`）が緩めて、
//            **終わったら必ず戻す**（platform/windows.rs → [`UacRelaxer`]）
//            ⚠ お客様の私物PC。⚠ **こちらが決めてよいものではない。**
//   相談員 … ⚠ **変えない**（自社の端末の守りを下げる理由が無い）
//
// ■ ワンタイムの絶対条件：必ず元に戻すこと
//   ⚠ 「終わるときに戻す」だけでは戻らない。アプリが
//     落ちる／強制終了される／片付けで殺される形を何度も見ている。
//   ⚠ とくにワンタイムは**終わると自分を消す**。
//     ＝ こちらの実行ファイルを当てにした戻し方は、必ず破綻する。
//   ★変える**前に**元の値をファイルに残し、戻る道を5本用意する。
//     ① 誰も繋がっていなくなったとき（正常系・常駐）
//     ② プロセスが終わるとき（Drop / shutdown hook）
//     ③ 次に起動したとき、控えが残っていたら戻す（core_main）
//     ④ 常駐の見張りが、印の時刻が古いのを見つけたとき（restore_if_stale）
//     ⑤ ⚠ **Windows 自身に置いた予定**（arm_deadman）。
//        ①〜④が全部死んでも、止まってから30分で必ず戻る。
//        ⚠ 予定の中身は `reg` だけ。**当社の実行ファイルに依存しない。**
//   ⚠ 1本に頼らない。1本でも通れば戻る形にする。

#![cfg(windows)]

use hbb_common::{bail, log, ResultType};
use std::{io::Write, path::PathBuf};
use winreg::{enums::*, RegKey};

const POLICY_KEY: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System";

/// 触る値。⚠ ここに `EnableLUA` を足さないこと（上の説明）。
///
/// 🔴 常駐版だけが両方を 0 にする（＝確認を一切出さない）。
///   常駐は誰も居ないPCに繋ぐためのものなので、押す人が居ない。
const VALUES: &[&str] = &["PromptOnSecureDesktop", "ConsentPromptBehaviorAdmin"];

/// 🔴🔴 ワンタイム版が触る値。**確認を出さない**（2026-09-02 ご判断B）。
///
/// ■ 経緯（2回変えている。両方の理由をここに残す）
///
///   8/30: `PromptOnSecureDesktop` だけにした。相談員が確認を押せると
///         実機で分かったので、⚠ **消す必要がない**と考えたため。
///   9/02: ⚠ **実機のスクショで、確認が2回出ていた。**
///         ① 🟡 取り出された実行ファイル（署名が無く「発行元: 不明」）
///         ② 🔵 当社の署名済みファイル
///         ⚠ お客様には何を押しているのか分からない。⚠ しかも1回目は
///           Windows の一番強い警告色で出る。
///         ＝ ご判断で **確認そのものを出さない**（B案）に変更。
///
/// ■ なぜ「不明」が消せるのか
///
///   `ConsentPromptBehaviorAdmin = 0` にすると、⚠ **以降の昇格は確認なし**。
///   署名済みの外側（libs/portable）が最初に一度だけ確認を出して両方を 0 に
///   すれば、そのあとの取り出された実行ファイルの昇格は⚠ **無音**になる。
///   ＝ 黄色い「発行元: 不明」は一度も出ない。署名を増やさずに解決できる。
///
/// ■ 値の意味
///   `PromptOnSecureDesktop = 0`    … 確認を暗い専用画面ではなく普通の画面に出す
///   `ConsentPromptBehaviorAdmin=0` … 管理者には確認を出さずに昇格させる
///
/// 🔴 ⚠ **お客様のPCの守りを下げている。必ず戻すこと。**
///   戻す道は3本（`UacRelaxer` が落ちる／次の起動／Windows の予定30分）。
///   ⚠ ここを増やしたら、⚠ **戻す側も必ず両方を戻せているか確かめる**。
///     1.4.61 の事故（切りっぱなし）は、まさにこの値で起きた。
///   ⚠ `EnableLUA` は絶対に足さない（再起動が必要になり、戻せなくなる）。
const VALUES_ONETIME: &[&str] = &["PromptOnSecureDesktop", "ConsentPromptBehaviorAdmin"];

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
    // 🔴 ワンタイムは **確認を出さない**（2026-09-02 ご判断B）。両方を 0 にする。
    //   ⚠ 8/30 は1つだけにしていた。実機で確認が2回出ていることが分かり変更。
    //     経緯は VALUES_ONETIME の説明に全部残してある。
    //   ⚠ 控え（上）は VALUES の両方を記録しているので、戻す側は変わらない。
    //   ⚠ ここは**普通は通らない**。UAC を緩めるのは、いまは署名済みの外側
    //     （libs/portable）が起動直後に1回だけ行う。ここは残り物を拾う保険。
    for name in VALUES_ONETIME {
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

    // 🔴 変えたら、**同じ呼吸で置き土産を置く**（2026-08-29 ご判断「A案」）。
    //   ⚠ ここを別の場所に離すと、間で落ちたときに
    //     「変えたのに戻す手立てが無い」という最悪の状態ができる。
    arm_deadman(&read_backup());

    log::info!("RL uac: サポート中の設定にしました（{changed} 件・確認は普通の画面に出ます）");
    Ok(())
}

/// 🔴🔴 常駐版：**戻さずに切ったままにする**（2026-08-29 ご指示）。
///
/// ご指示「常駐はUAC完全解除、ワンタイムは解除後終了時に戻す」。
///
/// ■ ワンタイムとの違い
///   ワンタイム … その回だけ緩めて、⚠ **終わったら必ず戻す**（お客様の私物PC）
///   常駐       … ⚠ **切ったままにする**（会社が管理している業務用PC）
///   ＝ 会社が「自社の端末はこうする」と決められる筋合いのもの。
///     ⚠ ワンタイムは決められない（その場限りで、持ち主の同意もその回だけ）。
///
/// ■ 触らないもの
///   ⚠ `EnableLUA` は触らない。⚠ **再起動しないと効かない**うえ、
///     0 にすると Windows 標準アプリ（設定・写真など）が起動しなくなる。
///     上の2つで「確認が一切出ない」状態にはなる。
///
/// ■ 前の版の後始末
///   ⚠ 1.4.61 までは常駐でも「接続のたびに緩めて、切れたら戻す」形だった。
///     控えや置き土産が残っていると、⚠ **せっかく切ったのを勝手に戻される。**
///   ★切ると決めたなら、戻す仕掛けは**自分で片付ける**。
pub fn disable_permanently() {
    let key = match policy_key(true) {
        Ok(k) => k,
        Err(e) => {
            log::warn!("RL uac: 常駐: 設定を開けません（管理者ではない？）: {e}");
            return;
        }
    };
    let mut changed = 0usize;
    for name in VALUES {
        match key.get_value::<u32, _>(name) {
            // 既に 0 なら書かない（毎回書くと記録が無駄に増える）
            Ok(0) => {}
            _ => match key.set_value(*name, &0u32) {
                Ok(_) => changed += 1,
                Err(e) => log::error!("RL uac: 常駐: {name} を変えられません: {e}"),
            },
        }
    }
    if changed > 0 {
        log::info!("RL uac: 常駐: 管理者の確認を出さない設定にしました（{changed} 件）");
    }
    // ⚠ 戻す仕掛けが残っていたら消す。残すと勝手に戻される。
    let b = backup_path();
    if b.exists() {
        let _ = std::fs::remove_file(&b);
        let _ = std::fs::remove_file(heartbeat_path());
        log::info!("RL uac: 常駐: 古い版が残した控えを片付けました（戻しません）");
    }
    disarm_deadman();
}

/// 控えを読む。⚠ 読み方を1か所に集める（戻す側と置き土産の側で食い違わせない）。
fn read_backup() -> Vec<(String, Option<u32>)> {
    let Ok(text) = std::fs::read_to_string(backup_path()) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| {
            let (name, value) = line.split_once('=')?;
            let name = name.trim();
            if !VALUES.contains(&name) {
                return None;
            }
            let value = value.trim();
            Some((
                name.to_string(),
                if value == "none" {
                    None
                } else {
                    value.parse::<u32>().ok()
                },
            ))
        })
        .collect()
}

/// 元に戻す。控えが無ければ何もしない（＝触っていない）。
pub fn restore() -> ResultType<()> {
    let path = backup_path();
    if !path.exists() {
        return Ok(());
    }
    let key = policy_key(true)?;
    for (name, value) in read_backup() {
        let r = match value {
            // ⚠ 元は「値が無かった」。0 を書き戻すのではなく**消す**。
            None => key.delete_value(&name).map_err(|e| e.to_string()),
            Some(v) => key.set_value(&name, &v).map_err(|e| e.to_string()),
        };
        match r {
            Ok(_) => log::info!("RL uac: {name} を元に戻しました（{value:?}）"),
            Err(e) => log::error!("RL uac: {name} を戻せません: {e}"),
        }
    }
    // ⚠ 戻し終えてから控えを消す。先に消すと、途中で落ちたときに戻せなくなる。
    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(heartbeat_path());
    // ⚠ 置き土産も片付ける。残すと、次のサポート中に割り込んで戻してしまう。
    disarm_deadman();
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

/// 万一のときに Windows 自身へ戻させる「置き土産」の名前。
const DEADMAN_TASK: &str = "REMOHELPPRO_UAC_RESTORE";

/// 元の値へ戻す `reg` の一行を作る。
///
/// ⚠ 「値が無かった」ことも表せるようにする。0 を書き戻すのと**意味が違う**。
fn reg_restore_cmd(values: &[(String, Option<u32>)]) -> String {
    let key = format!(r"HKLM\{POLICY_KEY}");
    let mut parts: Vec<String> = values
        .iter()
        .map(|(name, v)| match v {
            Some(v) => format!(
                "reg add \"{key}\" /v {name} /t REG_DWORD /d {v} /f >nul 2>&1"
            ),
            None => format!("reg delete \"{key}\" /v {name} /f >nul 2>&1"),
        })
        .collect();
    // ⚠ 戻したら自分（予定）も消す。残すと、次のサポート中に割り込んで戻してしまう。
    parts.push(format!("schtasks /delete /tn {DEADMAN_TASK} /f >nul 2>&1"));
    parts.join(" & ")
}

/// 🔴🔴 **こちらが消えても、Windows が戻す**（2026-08-29 ご判断「A案」）。
///
///   ⚠ ワンタイムは「その場限り」の物なので、⚠ **強制終了されると
///     戻す人が誰もいなくなる。** お客様のPCの守りを弱めたまま、
///     当社が二度と触れない——これがいちばん避けたい形だった。
///
///   ★Windows の「予定」に、元の値へ戻す命令そのものを置く。
///     ⚠ **当社の実行ファイルに一切依存しない**（`reg` だけを使う）。
///       ワンタイムは終わると自分を消すので、自分を呼ぶ予定にすると
///       ファイルが無くなった時点で戻せなくなる。
///     ⚠ 元の値は、置くときに分かっているので命令に**焼き込む**。
///
///   ★生きている間は、この予定の時刻を先へ押し続ける（下の心臓の鼓動）。
///     ＝ 止まった瞬間から30分で必ず戻る。長いサポートの途中で
///       割り込むことはない。
fn arm_deadman(values: &[(String, Option<u32>)]) {
    use chrono::{Duration as CDur, Local};
    let at = Local::now() + CDur::minutes(30);
    let cmd = reg_restore_cmd(values);
    // ⚠ 日付も渡す。時刻だけだと日をまたぐときに「今日の過去の時刻」になる。
    let args = [
        "/create".to_string(),
        "/tn".to_string(),
        DEADMAN_TASK.to_string(),
        "/sc".to_string(),
        "once".to_string(),
        "/sd".to_string(),
        at.format("%Y/%m/%d").to_string(),
        "/st".to_string(),
        at.format("%H:%M").to_string(),
        "/tr".to_string(),
        format!("cmd /c {cmd}"),
        "/ru".to_string(),
        "SYSTEM".to_string(),
        "/rl".to_string(),
        "HIGHEST".to_string(),
        "/f".to_string(),
    ];
    match run_hidden("schtasks", &args) {
        Ok(true) => log::info!("RL uac: 30分後に元へ戻す予定を置きました"),
        Ok(false) => log::warn!("RL uac: 戻す予定を置けませんでした（schtasks が失敗）"),
        Err(e) => log::warn!("RL uac: 戻す予定を置けませんでした: {e}"),
    }
}

fn disarm_deadman() {
    let args = [
        "/delete".to_string(),
        "/tn".to_string(),
        DEADMAN_TASK.to_string(),
        "/f".to_string(),
    ];
    let _ = run_hidden("schtasks", &args);
}

/// 黒い窓を出さずにコマンドを動かす。
/// ⚠ お客様の画面に一瞬でも窓を出さない（サポート中に何度も走るため）。
fn run_hidden(exe: &str, args: &[String]) -> std::io::Result<bool> {
    use std::os::windows::process::CommandExt;
    Ok(std::process::Command::new(exe)
        .args(args)
        .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
        .status()?
        .success())
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

/// 印が古ければ戻す。
///
/// ⚠ **いまはどこからも呼んでいない**（2026-08-29 ご指示で作りが変わった）。
///   常駐は「切ったまま」になったので、見張って戻す相手が居なくなった。
///   ワンタイムは Windows に置いた予定（[`arm_deadman`]）で戻る。
/// ★消さずに残してある。⚠ **「戻す方針」に戻すときは、ここを常駐の
///   見張りから呼べばよい。**作り直す手間を残さないため。
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
        //
        // 🔴 置き土産（Windows の予定）の時刻も、生きている間だけ先へ押す。
        //   ⚠ 押さないと、長いサポートの**途中で勝手に元へ戻る**。
        //   ★止まった瞬間から30分で必ず戻る、という形にそろえる。
        //   ⚠ 押す間隔（10分）は、予定の猶予（30分）より**十分短く**すること。
        //     近づけると、押す前に予定が走って途中で戻る。
        std::thread::spawn(move || {
            let mut ticks: u32 = 0;
            while flag.load(std::sync::atomic::Ordering::Relaxed) {
                touch_heartbeat();
                // 30秒ごとに回るので、20回＝10分ごとに押し直す。
                if ticks % 20 == 0 {
                    arm_deadman(&read_backup());
                }
                ticks = ticks.wrapping_add(1);
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

/// 🔴🔴 **お客様が起動したときに、確認を1回だけ通していただく**（2026-08-31 ご判断「A案」）。
///
/// ■ なぜ要るか（2026-08-31 実機で確定）
///   ⚠ この設定（`PromptOnSecureDesktop=0`）を書くには **管理者の権限が要る**。
///   ⚠ 権限を得るには UAC の確認に「はい」を押す必要がある。
///   ⚠ その確認は、まだ**暗い専用画面**に出ている＝相談員には見えず押せない。
///   ＝ ⚠ **入口で堂々巡り**になっていた。
///
///   ⚠ 今まで気づけなかったのは、⚠ **前のサポートで残った 0 が毎回助けていた**から。
///     実機で `PromptOnSecureDesktop = 1`（素の状態）を初めて見て分かった。
///     ＝ ⚠ 「1.4.83 は自然だった」のは版の違いではなく、**残り物**だった。
///
/// ■ 誰が書くか
///   ⚠ **お客様が落としてきた1個のファイル**（署名済み・`RL_RUNNER_EXE`）に
///     書かせる。⚠ 展開された中身の実行ファイルは**署名されていない**ので、
///     昇格の確認に「発行元不明」と出てしまう（お客様に不安を与える）。
///   ⚠ 一度は展開先の実行ファイルを写して昇格させたが、⚠ **部品（DLL）が
///     揃わず「desktop_drop_plugin.dll が見つからない」で落ちた**（実機・私の失敗）。
///     ＝ ⚠ **Flutter のアプリは1ファイルでは動かない。**写して動かさない。
///
/// ■ 受け渡し
///   控えはここ（昇格していない側）で書く。ProgramData は利用者でも書ける。
///   昇格側へは**元の値2つだけ**を数字で渡す。長い文字列を渡さない
///   （Windows の引数の引用符で静かに壊れるため）。
#[cfg(windows)]
/// もう緩んでいるか。
///
/// 🔴🔴 ⚠ **「触る値の全部」が 0 のときだけ true**（2026-09-02 修正）。
///
///   ⚠ 以前は `PromptOnSecureDesktop` 1つだけを見ていた。9/2 に
///     `ConsentPromptBehaviorAdmin` を足したので、1つだけ見ていると
///     ⚠ **古い版が 0 にした片方だけを見て「もう済んでいる」と判断し、
///       もう片方を一生書かない。** ＝ 確認が出続けるのに原因が見えない。
///   ★値を足したら、⚠ **判定側も必ず一緒に直す。**片方だけ直す事故を
///     この製品で何度も起こしている。
fn all_relaxed(names: &[&str]) -> bool {
    let Ok(k) = policy_key(false) else {
        return false;
    };
    names
        .iter()
        .all(|n| k.get_value::<u32, _>(*n).map_or(false, |v: u32| v == 0))
}

/// 🔴 ⚠ **2026-09-02 以降、本体からは呼ばれていない。**
///   UAC を緩めるのは、署名済みの外側（`libs/portable`）が起動直後に
///   1回だけ行う形にした（黄色い「発行元: 不明」を出さないため）。
///   ⚠ ここから呼び戻さないこと。⚠ **2か所で控えを書くと、
///     取り合いになって元に戻せなくなる。**
#[allow(dead_code)]
pub fn already_relaxed() -> bool {
    all_relaxed(VALUES_ONETIME)
}

/// 控えを書く（既にあれば書かない）。戻り値は VALUES の順の元の値。
///
/// ⚠ 既にあるものを上書きしない。⚠ 上書きすると「変更後の値」が控えになり、
///   二度と元へ戻せなくなる（`relax_for_session` と同じ流儀）。
#[cfg(windows)]
/// 🔴 ⚠ **2026-09-02 以降、本体からは呼ばれていない**（外側のパッカーが同じことをする）。
///   ⚠ ここを呼び戻さないこと。控えを2か所で書くと元に戻せなくなる。
#[allow(dead_code)]
pub fn write_backup_if_absent() -> Vec<(String, Option<u32>)> {
    let current = read_current();
    let path = backup_path();
    if path.exists() {
        log::info!("RL uac: 控えは既にあります（上書きしません）");
        return current;
    }
    let write = || -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let mut f = std::fs::File::create(&path)?;
        for (name, v) in &current {
            match v {
                Some(v) => writeln!(f, "{name}={v}")?,
                None => writeln!(f, "{name}=none")?,
            }
        }
        Ok(())
    };
    match write() {
        Ok(_) => log::info!("RL uac: 元の値を控えました → {}", path.display()),
        Err(e) => log::warn!("RL uac: 控えを書けません {}: {e}", path.display()),
    }
    current
}

/// 昇格側へ渡す引数にする（`0` / `1` / `none`）。⚠ 順番は VALUES と同じ。
#[cfg(windows)]
/// 🔴 ⚠ **2026-09-02 以降、本体からは呼ばれていない**（外側のパッカーが同じことをする）。
///   ⚠ ここを呼び戻さないこと。控えを2か所で書くと元に戻せなくなる。
#[allow(dead_code)]
pub fn backup_as_args(values: &[(String, Option<u32>)]) -> Vec<String> {
    VALUES
        .iter()
        .map(|name| {
            values
                .iter()
                .find(|(n, _)| n == name)
                .and_then(|(_, v)| *v)
                .map(|v| v.to_string())
                .unwrap_or_else(|| "none".to_string())
        })
        .collect()
}
