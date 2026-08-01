// ログオン前の再接続（2026-08-01 ユーザー指示）。
//
// ■ なぜ要るか
//   サポート中の再起動は日常的に起きる。しかしワンタイム版の復帰は
//   Windows の RunOnce で行っており、**お客様がログオンするまで動かない**。
//   席を離れていれば、そこでサポートが止まる。
//   ログオン画面から続けられるのは **Windows サービス** だけなので、
//   再起動をまたぐときだけ一時的にサービスを作り、終わったら消す。
//
// ■ 絶対条件：消え残らないこと
//   消え残れば「お客様のPCに、気づかれないまま遠隔で入れる口が残った」
//   という意味になる。1台でも起きてはいけない。
//   したがって **サービス自身が自分で消える** 作りにする。
//     ・サポートが終わったのを自分で確かめて消える（4秒〜30秒で気づく）
//     ・期限（既定30分）を過ぎたら、通信できなくても消える
//     ・起動のたびに最初に期限を見る（電源を抜かれて翌日起動でも消える）
//   外の誰かに消してもらうことを当てにしない。アプリが落ちても、
//   通信が切れても、電源が抜かれても消える道を用意する。
//
// ■ お客様への確認は増やさない（ご判断）
//   認証コードを入れた時点でこの回のサポートには同意している。
//   ただし **UAC（管理者の確認）は Windows の仕組み上どうしても出る**。
//   権限が無ければ実行できないので、その旨を相談員に返す。

#![cfg(windows)]

use hbb_common::{bail, log, ResultType};
use std::{
    io::Write,
    os::windows::process::CommandExt,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// サービス名。常駐版とは**必ず別の名前**にする。
///   同じ名前だと、片方を消したときにもう片方を巻き込む。
pub const SERVICE_NAME: &str = "REMOHELPPRO_PRELOGON";

/// 置き場所。サービスは SYSTEM で動くので、利用者ごとの場所は使えない。
pub fn svc_dir() -> PathBuf {
    let base = std::env::var("ProgramData").unwrap_or_else(|_| "C:\\ProgramData".to_string());
    PathBuf::from(base).join("REMOHELP PRO").join("prelogon")
}

/// 目印。これがあるときだけ、その実行ファイルは「一時サービス」として振る舞う。
pub fn marker_in(dir: &Path) -> PathBuf {
    dir.join("rl-prelogon.txt")
}

/// 目印の中身。行区切りの素朴な形にする（JSON を足して壊す余地を作らない）。
///   1行目: 短いセッションID
///   2行目: 期限（UNIX秒）
pub struct Marker {
    pub short_id: String,
    pub deadline: u64,
}

pub fn read_marker(dir: &Path) -> Option<Marker> {
    let s = std::fs::read_to_string(marker_in(dir)).ok()?;
    let mut it = s.lines();
    let short_id = it.next()?.trim().to_string();
    let deadline = it.next()?.trim().parse::<u64>().ok()?;
    if short_id.is_empty() {
        return None;
    }
    Some(Marker { short_id, deadline })
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ───────────────────────────────────────── 入れる（管理者権限で動く）

/// 一時サービスを作る。**昇格済みのプロセスから呼ぶこと。**
///
/// `src_dir` は今動いているアプリ一式（展開先）。設定とIDもここにあるので、
/// **丸ごと複製する**。複製を落とすと別のIDになり、相談員からは
/// 「サービスは動いているのに永久に見つからない」という最も分かりにくい壊れ方をする。
pub fn install(src_dir: &Path, short_id: &str, deadline: u64) -> ResultType<()> {
    if !is_elevated() {
        bail!("not elevated");
    }
    // 前回の残りがあれば先に片付ける。重ねて作らない。
    let _ = remove_service_only();

    let dst = svc_dir();
    if dst.exists() {
        let _ = std::fs::remove_dir_all(&dst);
    }
    std::fs::create_dir_all(&dst)?;
    copy_dir(src_dir, &dst)?;

    // 目印を書く。サービスはこれを見て、自分の期限と見張る相手を知る。
    {
        let mut f = std::fs::File::create(marker_in(&dst))?;
        writeln!(f, "{short_id}")?;
        writeln!(f, "{deadline}")?;
    }

    let exe = dst.join(format!("{}.exe", crate::get_app_name()));
    if !exe.exists() {
        bail!("copied exe not found: {}", exe.display());
    }

    // sc create → start。失敗したら黙って諦めず、複製も消して跡を残さない。
    let bin = format!("\"{}\" --service", exe.display());
    let ok = sc(&["create", SERVICE_NAME, "binpath=", &bin, "start=", "auto",
                  "DisplayName=", "REMOHELP PRO (一時)"])
        && sc(&["start", SERVICE_NAME]);
    if !ok {
        let _ = remove_service_only();
        let _ = std::fs::remove_dir_all(&dst);
        bail!("failed to create service");
    }
    log::info!("RL prelogon: service installed, deadline={deadline}");
    Ok(())
}

fn sc(args: &[&str]) -> bool {
    match Command::new("sc")
        .args(args)
        .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
        .status()
    {
        Ok(s) => s.success(),
        Err(e) => {
            log::error!("RL prelogon: sc {args:?} failed: {e}");
            false
        }
    }
}

fn is_elevated() -> bool {
    crate::platform::is_elevated(None).unwrap_or(false)
}

fn copy_dir(src: &Path, dst: &Path) -> ResultType<()> {
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let ft = entry.file_type()?;
        let to = dst.join(entry.file_name());
        if ft.is_dir() {
            std::fs::create_dir_all(&to)?;
            copy_dir(&entry.path(), &to)?;
        } else if ft.is_file() {
            // 使用中で読めないものがあっても止めない（ログだけ残す）。
            if let Err(e) = std::fs::copy(entry.path(), &to) {
                log::warn!("RL prelogon: copy skipped {:?}: {e}", entry.path());
            }
        }
    }
    Ok(())
}

// ───────────────────────────────────────── 消える（サービス自身が行う）

fn remove_service_only() -> bool {
    sc(&["stop", SERVICE_NAME]);
    sc(&["delete", SERVICE_NAME])
}

/// 自分を消して終わる。**サービスの中から呼ぶ。**
///
/// 🔴 cmd への渡し方に注意（2026-08-01 に痛い目を見た）。
///   `.args(["/c", ...])` は Rust が `"` を `\"` に書き換え、cmd は
///   その書き方を知らないため**何もせず終わる**。必ず `raw_arg` を使う。
pub fn self_remove_and_exit() -> ! {
    log::info!("RL prelogon: removing myself");
    let dir = svc_dir();
    let d = dir.to_string_lossy().to_string();
    // 自分が動いている間はフォルダを消せない。消えるまで繰り返す。
    // sc delete は「実行中」でも登録を消せるので先に打つ。
    let line = format!(
        "/c sc stop {n} >nul 2>nul & sc delete {n} >nul 2>nul & \
         for /L %i in (1,1,600) do @(if not exist \"{d}\" (exit) else \
         (ping -n 3 127.0.0.1 >nul & rmdir /s /q \"{d}\" >nul 2>nul))",
        n = SERVICE_NAME,
        d = d
    );
    if !d.contains('"') {
        let _ = Command::new("cmd")
            .raw_arg(&line)
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .spawn();
    }
    std::thread::sleep(Duration::from_millis(300));
    std::process::exit(0);
}

/// サービスとして起動したときの見張り。
///
/// ⚠ 呼ぶ前に、必ず「目印がある」ことを確かめること。
///   目印が無い実行ファイルは常駐版か相談員版なので、ここに来てはいけない。
pub fn start_watchdog(m: Marker) {
    // ① まず期限。通信できなくても、電源を抜かれて翌日でも、ここで消える。
    if now_unix() >= m.deadline {
        log::info!("RL prelogon: deadline passed at boot");
        self_remove_and_exit();
    }
    std::thread::spawn(move || {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .ok();
        // 通信できない状態が続いても、期限が来れば必ず消える。
        loop {
            if now_unix() >= m.deadline {
                log::info!("RL prelogon: deadline reached");
                self_remove_and_exit();
            }
            if let Some(c) = client.as_ref() {
                let url = format!(
                    "https://svr.remohelppro.jp/api/customer/session-status?shortId={}",
                    m.short_id
                );
                if let Ok(r) = c.get(&url).send() {
                    if let Ok(t) = r.text() {
                        // 素朴に見る。JSON を組み立てるほどの中身ではない。
                        // active が false ＝ サポートは終わっている。
                        if t.contains("\"active\":false") {
                            log::info!("RL prelogon: support ended");
                            self_remove_and_exit();
                        }
                    }
                }
            }
            std::thread::sleep(Duration::from_secs(20));
        }
    });
}
