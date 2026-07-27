//! セーフモードでの遠隔サポート（Windows・常駐版のみ）。
//!
//! 相談員が遠隔から「セーフモードで再起動」を実行し、セーフモードで立ち上がった
//! 顧客PCへ繋ぎ直して作業する。サポートツールとしては標準的な機能で、
//! 常駐しているPCが対象になる（ワンタイム版はインストールしないので対象外）。
//!
//! ── 仕組み ──────────────────────────────────────────────
//!   ① 自分のサービスを `SafeBoot\Network` 配下に登録する
//!      （ここに無いサービスはセーフモードで起動しない＝繋ぎ直せない）
//!   ② `bcdedit /set {default} safeboot network` で次回起動をセーフモードにする
//!   ③ 再起動
//!   ④ 作業が終わったら `bcdedit /deletevalue {default} safeboot` で戻して再起動
//!
//! ── 🔴 いちばん大事なこと: 必ず通常モードへ戻すこと ──────────
//!   戻し損ねると、顧客のPCがセーフモードのまま起動し続ける。
//!   お客様は自力で戻せず、業務が止まる。**最も重い事故**なので、
//!   人手を当てにしない歯止めを二重に置いている。
//!
//!     (a) **時限の自動復帰**: セーフモードに入るとき期限を記録する。
//!         セーフモードで起動したら見張りを立て、期限を過ぎたら
//!         こちらから勝手に通常モードへ戻して再起動する。
//!         相談員の回線が切れても、忘れても、必ず戻る。
//!     (b) **起動時の後始末**: 通常モードで起動したのに印が残っていたら、
//!         取り残しとみなして bcdedit の設定を消す（何度実行しても害はない）。
//!
//!   期限は相談員が延長できる（`safemode_extend`）。作業が長引いたときに
//!   途中で再起動されないようにするため。

#![cfg(windows)]

use hbb_common::{bail, log, ResultType};
use std::time::{SystemTime, UNIX_EPOCH};

/// 見張りが期限を確かめる間隔。短くしすぎても意味が無い。
const WATCH_INTERVAL_SECS: u64 = 30;

/// 既定の猶予。相談員が明示的に終わらせない場合、これを過ぎたら通常モードへ戻す。
pub const DEFAULT_DEADLINE_MINUTES: u64 = 60;

/// 印の置き場所。SYSTEM で動くので HKLM に置く。
const MARK_KEY: &str = r"SOFTWARE\REMOHELP PRO";
const MARK_VALUE: &str = "SafeModeDeadline";

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// いまセーフモードで動いているか。
///
/// `SM_CLEANBOOT` は 0=通常 / 1=セーフモード / 2=セーフモード(ネットワークあり)。
pub fn is_safe_mode() -> bool {
    unsafe { winapi::um::winuser::GetSystemMetrics(winapi::um::winuser::SM_CLEANBOOT) != 0 }
}

/// bcdedit などを窓を出さずに実行する。
fn run_hidden(program: &str, args: &[&str]) -> ResultType<()> {
    use std::os::windows::process::CommandExt;
    let out = std::process::Command::new(program)
        .args(args)
        .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
        .output()?;
    if !out.status.success() {
        bail!(
            "{} {:?} が失敗しました: {}",
            program,
            args,
            String::from_utf8_lossy(&out.stderr)
        );
    }
    Ok(())
}

fn service_name() -> String {
    crate::get_app_name()
}

/// 自分のサービスをセーフモード(ネットワークあり)で起動する対象に加える。
///
/// 🔴 これをやらないと、セーフモードで立ち上がってもサービスが動かず、
///   **繋ぎ直せないまま顧客のPCがセーフモードで取り残される**。
///   セーフモードへ入れる前に必ず成功させること。
fn register_for_safeboot() -> ResultType<()> {
    use winreg::{enums::*, RegKey};
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let path = format!(
        r"SYSTEM\CurrentControlSet\Control\SafeBoot\Network\{}",
        service_name()
    );
    let (key, _) = hklm.create_subkey(&path)?;
    // 既定値に "Service" を入れる決まり（サービス名そのものではない）。
    key.set_value("", &"Service")?;
    log::info!("safemode: registered {} for SafeBoot\\Network", service_name());
    Ok(())
}

/// 期限の印を書く／消す。
fn set_deadline(deadline: Option<u64>) -> ResultType<()> {
    use winreg::{enums::*, RegKey};
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    let (key, _) = hklm.create_subkey(MARK_KEY)?;
    match deadline {
        Some(v) => key.set_value(MARK_VALUE, &v)?,
        None => {
            // 既に無くても構わない
            let _ = key.delete_value(MARK_VALUE);
        }
    }
    Ok(())
}

fn get_deadline() -> Option<u64> {
    use winreg::{enums::*, RegKey};
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);
    hklm.open_subkey(MARK_KEY)
        .ok()?
        .get_value::<u64, _>(MARK_VALUE)
        .ok()
}

/// 次回の起動をセーフモード(ネットワークあり)にする。**再起動はしない。**
///
/// 呼ぶ側は、成功を確かめてから再起動すること。
pub fn arm(deadline_minutes: u64) -> ResultType<()> {
    if !crate::agent::is_resident() {
        bail!("セーフモードは常駐版のみ対応しています");
    }
    // ① 先にサービスを登録する。ここが失敗したまま②へ進むと、
    //    セーフモードで起動しても繋げず、戻す手立てが無くなる。
    register_for_safeboot()?;

    // ② 期限を先に書く。②と③の間で電源が落ちても、次の起動で後始末が効くようにする。
    let minutes = deadline_minutes.clamp(5, 6 * 60);
    set_deadline(Some(now_secs() + minutes * 60))?;

    // ③ 次回起動をセーフモードに
    if let Err(e) = run_hidden("bcdedit", &["/set", "{default}", "safeboot", "network"]) {
        // 失敗したら印を戻しておく（中途半端な状態を残さない）
        let _ = set_deadline(None);
        return Err(e);
    }
    log::info!("safemode: armed (deadline {} min)", minutes);
    Ok(())
}

/// 通常モードに戻す。**再起動はしない。**
///
/// 何度呼んでも害は無い（既に戻っていても成功扱い）。
pub fn disarm() -> ResultType<()> {
    // bcdedit は値が無いときも失敗を返すので、結果を握りつぶす。
    // 「戻せていない」ほうが重大なので、消せるものは全部消しにいく。
    let r = run_hidden("bcdedit", &["/deletevalue", "{default}", "safeboot"]);
    if let Err(e) = &r {
        log::info!("safemode: bcdedit deletevalue: {} (値が無い場合も出る)", e);
    }
    set_deadline(None)?;
    log::info!("safemode: disarmed");
    Ok(())
}

/// 期限を延ばす。作業が長引いたときに、途中で勝手に再起動されないようにする。
pub fn extend(minutes: u64) -> ResultType<()> {
    if get_deadline().is_none() {
        bail!("セーフモードの予定がありません");
    }
    let minutes = minutes.clamp(5, 6 * 60);
    set_deadline(Some(now_secs() + minutes * 60))?;
    log::info!("safemode: extended {} min", minutes);
    Ok(())
}

/// サービス起動時に必ず呼ぶ。取り残しの後始末と、見張りの開始を行う。
pub fn on_service_start() {
    let deadline = get_deadline();
    let safe = is_safe_mode();

    match (deadline, safe) {
        // 印はあるが通常モードで起動している＝役目は終わっている。
        // 相談員が戻した／お客様が自分で戻した／途中で電源が落ちた、のいずれか。
        // bcdedit に設定が残っていると次にまたセーフモードで起動してしまうので消す。
        (Some(_), false) => {
            log::info!("safemode: 通常モードで起動。取り残しを片づけます");
            let _ = disarm();
        }
        // セーフモードで起動した＝ここからが本番。見張りを立てる。
        (Some(d), true) => {
            log::info!("safemode: セーフモードで起動しました。自動復帰の見張りを開始します");
            std::thread::spawn(move || watch(d));
        }
        // 印が無いのにセーフモードで起動している＝お客様が自分でセーフモードにした。
        // こちらの都合で勝手に再起動してはいけないので、何もしない。
        (None, true) => {
            log::info!("safemode: 当方の指示ではないセーフモードです。何もしません");
        }
        (None, false) => {}
    }
}

/// 期限を過ぎたら通常モードへ戻して再起動する見張り。
///
/// 🔴 ここが最後の砦。相談員が忘れても、回線が切れても、これで必ず戻る。
fn watch(mut deadline: u64) {
    loop {
        std::thread::sleep(std::time::Duration::from_secs(WATCH_INTERVAL_SECS));

        // 相談員が延長しているかもしれないので毎回読み直す。
        match get_deadline() {
            Some(d) => deadline = d,
            None => {
                // 印が消えた＝相談員が終わらせた。再起動はそちらが行う。
                log::info!("safemode: 印が消えたので見張りを終了します");
                return;
            }
        }

        if now_secs() < deadline {
            continue;
        }

        log::warn!("safemode: 期限を過ぎました。通常モードへ戻して再起動します");
        if let Err(e) = disarm() {
            // 戻せないのは最悪の事態。諦めずに次の周回で再試行する。
            log::error!("safemode: 復帰に失敗しました（再試行します）: {}", e);
            continue;
        }
        let _ = system_shutdown::reboot();
        return;
    }
}
