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
//   外の誰かに消してもらうことを当てにしない。アプリが落ちても、
//   通信が切れても、電源が抜かれても消える道を用意する。
//
// ■ 消える条件は3つ（2026-08-03 に作り直した）
//     ① サーバーが「このサポートは終わった」と答えた … 20秒以内に消える（正しい終わり方）
//     ② サーバーに一度も届かない状態が30分続いた   … 通信が死んだ／戻ってこなかった
//     ③ 作ってから12時間経った                     … 最後の歯止め
//
//   🔴 **「作った時刻＋30分」で消してはいけない**（2026-08-01 の作りの誤り）。
//     当初はそう書いていた。しかし一時サービスを作るのは**再起動する前**なので、
//     30分の砂時計はお客様のPCが落ちている間も、戻ってきて相談員が作業して
//     いる間も進み続ける。
//     ＝ **30分を超えるサポートは、作業の途中で必ず切れる。**
//     しかも切れ方は「サービスが自分を消す」なので、相談員には理由が分からない。
//     ②の砂時計は**サーバーに届くたびに巻き戻す**。届いている限り、
//     終わりを決めるのはサーバー（＝相談員）であって、こちらの時計ではない。
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

/// サーバーに一度も届かないまま、この時間が過ぎたら自分を消す。
///
/// 🔴 これは「作った時刻からの制限時間」ではない。**最後に届いた時刻から**数える。
///   届いている限り巻き戻るので、長いサポートを途中で切ることはない。
pub const NO_CONTACT_LIMIT_SECS: u64 = 30 * 60;

/// 見張りの間隔。
const POLL_SECS: u64 = 20;

/// 目印の中身。行区切りの素朴な形にする（JSON を足して壊す余地を作らない）。
///   1行目: 短いセッションID
///   2行目: 打ち切り時刻（UNIX秒・最後の歯止め）
pub struct Marker {
    pub short_id: String,
    /// ここを過ぎたら、通信の可否にかかわらず消す。**最後の歯止め**であって、
    /// 普段の終わり方ではない（普段はサーバーの「終わった」で消える）。
    pub hard_limit: u64,
}

pub fn read_marker(dir: &Path) -> Option<Marker> {
    let s = std::fs::read_to_string(marker_in(dir)).ok()?;
    let mut it = s.lines();
    let short_id = it.next()?.trim().to_string();
    let hard_limit = it.next()?.trim().parse::<u64>().ok()?;
    if short_id.is_empty() {
        return None;
    }
    Some(Marker {
        short_id,
        hard_limit,
    })
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
pub fn install(src_dir: &Path, short_id: &str, hard_limit: u64) -> ResultType<()> {
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

    // 目印を書く。サービスはこれを見て、見張る相手と最後の歯止めを知る。
    {
        let mut f = std::fs::File::create(marker_in(&dst))?;
        writeln!(f, "{short_id}")?;
        writeln!(f, "{hard_limit}")?;
    }

    // 🔴 実行ファイルの名前を決め打ちしない（2026-08-06）。
    //   お客様用のアプリは、常駐の taskkill に巻き込まれないよう
    //   `remohelppro-support.exe` という別の名前で配るようにした。
    //   ここで `remohelppro.exe` と決め打ちすると、複製の中に見つからず
    //   **ログオン前の接続が丸ごと動かなくなる**。
    //   ★いま動いている自分の名前をそのまま使う。名前を変えても壊れない。
    let my_name = std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()))
        .unwrap_or_else(|| format!("{}.exe", crate::get_app_name()));
    let exe = dst.join(&my_name);
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
    log::info!("RL prelogon: service installed, hard_limit={hard_limit}");
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
    // ③ 最後の歯止め。電源を抜かれて翌日起動でも、ここで消える。
    if now_unix() >= m.hard_limit {
        log::info!("RL prelogon: hard limit already passed at start");
        self_remove_and_exit();
    }
    std::thread::spawn(move || {
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .ok();

        // 🔴 「届かない時間」の砂時計は**ここで0に戻す**。
        //   ここに来るのはサービスが起動したときだけ＝再起動のたびに0から。
        //   お客様のPCが落ちていた時間を数えてしまわないための起点。
        let mut last_ok = now_unix();

        loop {
            let now = now_unix();

            // ③ 最後の歯止め。
            if now >= m.hard_limit {
                log::info!("RL prelogon: hard limit reached");
                self_remove_and_exit();
            }
            // ② サーバーに届かないまま30分。通信が死んだか、戻ってこなかった。
            //   ⚠ 時計が巻き戻ってもここで慌てないよう saturating_sub を使う。
            if now.saturating_sub(last_ok) >= NO_CONTACT_LIMIT_SECS {
                log::info!("RL prelogon: no contact for {NO_CONTACT_LIMIT_SECS}s");
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
                        // ① active が false ＝ サポートは終わっている。正しい終わり方。
                        if t.contains("\"active\":false") {
                            log::info!("RL prelogon: support ended");
                            self_remove_and_exit();
                        }
                        // ⚠ 砂時計を巻き戻すのは、**答えの中身を確かめられたときだけ**。
                        //   途中の機器が返すエラーページや 429 を「届いた」と数えると、
                        //   サーバーが落ちていても永久に消えなくなる。
                        if t.contains("\"active\":true") {
                            last_ok = now_unix();
                        }
                    }
                }
            }
            std::thread::sleep(Duration::from_secs(POLL_SECS));
        }
    });
}
