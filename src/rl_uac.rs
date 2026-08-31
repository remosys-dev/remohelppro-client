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

/// 🔴🔴 ワンタイム版が触る値。**確認を消さない**（2026-08-30 ご判断）。
///
///   ⚠ これまでは常駐と同じく `ConsentPromptBehaviorAdmin = 0` も入れ、
///     ⚠ **お客様のUACを実質無効**にしていた。1.4.61 の事故（戻せないまま
///     切りっぱなしになる）も、戻す道を4本も要したのも、ここが原因。
///
///   ★2026-08-30 実機で確認: ⚠ **相談員が UAC の確認を押せた。**
///     当社の入力は SYSTEM 権限で出ているので、Windows の権限の壁を越えられる
///     （`server/portable_service.rs` でマウス・キーを SYSTEM 側へ渡している）。
///     ＝ ⚠ **確認を消す必要がない。「普通の画面に出す」だけでよい。**
///
///   `PromptOnSecureDesktop = 0` … 確認を**暗い専用画面ではなく普通の画面**に出す。
///     これが無いと相談員には見えず、押すこともできない（画面が真っ黒になる）。
///
///   ⚠ 利点: お客様のUACを無効にしない／戻す対象が1つに減る／
///     相談員の画面が真っ黒になる件も同じ設定で直る。
///   ⚠ 代わりに増えるのは「相談員が確認を1回押す」手間だけ。
const VALUES_ONETIME: &[&str] = &["PromptOnSecureDesktop"];

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
    // 🔴 ワンタイムは **確認を消さない**（2026-08-30 ご判断）。触るのは
    //   「暗い専用画面に出さない」1つだけ。相談員が押せることを実機で確認済み。
    //   ⚠ 控え（上）は VALUES の両方を記録している。触らなかった方を戻しても
    //     同じ値を書くだけなので害はなく、古い版が残した 0 も戻せる。
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
/// ■ どうするか
///   ⚠ お客様は**目の前にいらっしゃる**ので、最初の1回だけ押していただく。
///   以後この端末は、確認が普通の画面に出るので、⚠ **相談員が全部できる**
///   （再起動・プログラムの導入）。⚠ UAC は解除しない（社長のご判断どおり）。
///
/// ■ 安全
///   ⚠ 押していただけなくても**支障なく続く**。ただ相談員が押せないだけ。
///   ⚠ 昇格した側は「見張り」として残り、⚠ **お客様のアプリが終われば必ず戻す**。
///     さらに元の3本立て（Drop／次回起動／Windows の予定30分）もそのまま効く。
#[cfg(windows)]
pub fn already_relaxed() -> bool {
    policy_key(false)
        .ok()
        .and_then(|k| k.get_value::<u32, _>("PromptOnSecureDesktop").ok())
        .map_or(false, |v| v == 0)
}

/// 昇格した側で動く見張り。親（お客様のアプリ）が生きている間だけ設定を保つ。
///
/// ⚠ 戻すのは `UacRelaxer` の `Drop`。⚠ **この関数から普通に抜けること**
///   （`std::process::exit` で抜けると Drop が走らず、戻らない）。
#[cfg(windows)]
pub fn keeper(parent_pid: u32) {
    let _relaxer = match UacRelaxer::new() {
        Ok(r) => r,
        Err(e) => {
            log::error!("RL uac: 見張りを始められません: {e}");
            return;
        }
    };
    log::info!("RL uac: 見張りを始めました（親 pid={parent_pid}）");
    loop {
        // ⚠ 1秒ごと。⚠ **親が終わってから戻すまでを短く**する
        //   （お客様のPCの守りを、必要より長く下げない）。
        std::thread::sleep(std::time::Duration::from_secs(1));
        if !process_alive(parent_pid) {
            log::info!("RL uac: お客様のアプリが終了しました。設定を戻します");
            break;
        }
        // ⚠ 誰か（別の後始末・置き土産）が戻していたら、もう一度かけ直す。
        //   ★ここが無いと、サポートの途中で静かに元へ戻り、
        //     以後ずっと相談員が確認を押せなくなる。
        if !already_relaxed() {
            if let Ok(key) = policy_key(true) {
                for name in VALUES_ONETIME {
                    let _ = key.set_value(*name, &0u32);
                }
                log::info!("RL uac: 戻されていたので、かけ直しました");
            }
        }
    }
}

/// pid のプロセスがまだ動いているか。
#[cfg(windows)]
fn process_alive(pid: u32) -> bool {
    use winapi::um::{
        handleapi::CloseHandle, processthreadsapi::OpenProcess, synchapi::WaitForSingleObject,
        winbase::WAIT_OBJECT_0, winnt::SYNCHRONIZE,
    };
    unsafe {
        let h = OpenProcess(SYNCHRONIZE, 0, pid);
        if h.is_null() {
            // ⚠ 開けない＝もう居ない、と見なす。権限で開けないことは
            //   （親は同じお客様の起動した実行ファイルなので）実際には無い。
            return false;
        }
        let r = WaitForSingleObject(h, 0);
        CloseHandle(h);
        r != WAIT_OBJECT_0
    }
}
