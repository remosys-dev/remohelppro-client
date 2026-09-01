#[cfg(any(target_os = "windows", target_os = "macos"))]
use crate::client::translate;
#[cfg(not(debug_assertions))]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::platform::breakdown_callback;
#[cfg(not(debug_assertions))]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use hbb_common::platform::register_breakdown_handler;
use hbb_common::{config, log};
#[cfg(windows)]
use tauri_winrt_notification::{Duration, Sound, Toast};

#[macro_export]
macro_rules! my_println{
    ($($arg:tt)*) => {
        #[cfg(not(windows))]
        println!("{}", format_args!($($arg)*));
        #[cfg(windows)]
        crate::platform::message_box(
            &format!("{}", format_args!($($arg)*))
        );
    };
}

/// shared by flutter and sciter main function
///
/// [Note]
/// If it returns [`None`], then the process will terminate, and flutter gui will not be started.
/// If it returns [`Some`], then the process will continue, and flutter gui will be started.
/// ★★ 戻すときはここを `false` にする（2026-08-30 ご指示「戻せるようにも準備して」）。
///
/// `true`  … ワンタイム版の設定を `C:\Users\Public\Documents\...` に置く。
///           一時サービス（LocalSystem）と**同じ場所**を見るので、
///           身分を写す処理が要らなくなる。
/// `false` … これまでどおり `%APPDATA%`。写して渡す形に戻る。
///
/// ⚠ この1つを変えるだけで完全に元へ戻る。他の場所は触らなくてよい。
#[cfg(windows)]
const RL_PUBLIC_CONFIG: bool = true;

/// ワンタイム版のときだけ、設定の置き場所を差し替える。
///
/// ⚠ 判定は **CI が同梱する目印ファイル**で行う（実行ファイルの隣）。
///   名前で判定すると、名前を変えた瞬間に静かに壊れる（過去に実際に壊れた）。
///   一時サービスの複製にも目印は一緒に写るので、サービス側も同じ場所を見る。
/// ⚠ 消すときの安全確認（`rl_remove_onetime_data`）は「消す場所にアプリ名が
///   入っているか」を見るので、**置き場所にもアプリ名を入れる**。
///   入れ忘れると、⚠ **合言葉入りのファイルがお客様のPCに残り続ける。**
#[cfg(windows)]
fn rl_apply_public_config() {
    if !RL_PUBLIC_CONFIG {
        return;
    }
    // ⚠ 常駐版・相談員版では**絶対にやらない**。呼ぶ側の条件だけに頼らない。
    if config::IS_RESIDENT_BUILD || config::IS_OPERATOR_BUILD {
        return;
    }
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(dir) = exe.parent() else {
        return;
    };
    // 共有識別子OK: 名前ではなく、CI が置く目印ファイルの有無で当社の
    //   ワンタイム版だけに絞っている。他製品の実行ファイルの隣には存在しない。
    if !dir.join("remohelppro-onetime.flag").exists() {
        return;
    }
    let public = std::env::var("PUBLIC").unwrap_or_else(|_| "C:\\Users\\Public".to_string());
    let name = config::APP_NAME.read().unwrap().clone();
    let base = std::path::PathBuf::from(public)
        .join("Documents")
        .join("REMOHELP PRO")
        .join(&name)
        .join("config");
    if let Err(e) = std::fs::create_dir_all(&base) {
        // ⚠ 作れないなら**何もしない**（従来どおり %APPDATA% を使う）。
        //   中途半端に指定して、書けない場所を見に行かせない。
        log::warn!("RL: 共有の設定置き場を作れません {}: {e}", base.display());
        return;
    }
    let s = base.to_string_lossy().to_string();
    log::info!("RL: 設定の置き場所を共有にしました {s}");
    *config::SHARED_CONFIG_DIR.write().unwrap() = s;
}

/// ワンタイム版で、UAC の確認を「普通の画面」に出せるようにする準備。
///
/// ⚠ お客様が落としてきた**署名済みの1個のファイル**を昇格して呼び、
///   設定だけ書かせて終わってもらう。⚠ 展開もしないし、常駐もしない。
#[cfg(windows)]
fn rl_uac_prepare() {
    // 🔴 **待たせない**（2026-08-31）。
    //   ⚠ `run_uac` は、お客様が確認に答えるまで**返ってこない**。
    //     ここで待つと、⚠ **答えるまでアプリの画面が1つも出ない。**
    //     起動が遅い件で既にご指摘をいただいている所なので、繰り返さない。
    //   ★別の流れで行う。⚠ 先にアプリの画面を出してから確認を出す
    //     （いきなり確認だけが出ると、お客様には何の確認か分からない）。
    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_secs(3));
        rl_uac_prepare_inner();
    });
}

#[cfg(windows)]
fn rl_uac_prepare_inner() {
    // ⚠ 常駐版・相談員版では絶対にやらない。呼ぶ側の条件だけに頼らない。
    if config::IS_RESIDENT_BUILD || config::IS_OPERATOR_BUILD {
        return;
    }
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let Some(dir) = exe.parent() else {
        return;
    };
    // 共有識別子OK: 名前ではなく、CI が置く目印ファイルの有無で当社の
    //   ワンタイム版だけに絞っている。他製品の実行ファイルの隣には存在しない。
    if !dir.join("remohelppro-onetime.flag").exists() {
        return;
    }
    // ⚠ 一時サービスの複製（ログイン前の再接続）では出さない。
    //   誰も見ていない画面に確認を出しても、押す人がいない。
    if crate::rl_prelogon::read_marker(dir).is_some() {
        return;
    }
    // ⚠ 既に「普通の画面に出す」状態なら、何も出さない。
    if crate::rl_uac::already_relaxed() {
        log::info!("RL uac: 既に普通の画面に出る状態です。確認は出しません");
        return;
    }
    // 🔴🔴 **お客様が落としてきた1個のファイルに書かせる**（2026-08-31 実機の失敗で作り直し）。
    //
    //   ⚠ 最初は展開先の実行ファイルを一時フォルダへ写して昇格させたが、
    //     ⚠ **「desktop_drop_plugin.dll が見つからないため、コードの実行を
    //     続行できません」** でお客様の画面にエラーが出た。
    //     ＝ ⚠ **Flutter のアプリは1ファイルでは動かない。**写して動かさない。
    //   ⚠ 展開先の実行ファイルをその場で昇格させる案も採らない。
    //     ① 署名が無いので確認に「発行元不明」と出る（お客様を不安にさせる）
    //     ② 動いている間、⚠ **展開先のフォルダを消せなくなる**
    //   ★落としてきた1個のファイル（`RL_RUNNER_EXE`）は **EV署名済み**で、
    //     ⚠ 単独で動く。⚠ 確認には**当社の会社名**が出る。
    //     そちらに設定だけ書かせて、すぐ終わってもらう（展開もしない）。
    let Ok(runner) = std::env::var("RL_RUNNER_EXE") else {
        log::info!("RL uac: 元のファイルの場所が分からないため、確認は出しません");
        return;
    };
    if runner.is_empty() || !std::path::Path::new(&runner).exists() {
        log::info!("RL uac: 元のファイルが見つかりません（{runner}）。確認は出しません");
        return;
    }
    // ⚠ 控えは**こちら側**（昇格していない）で書く。ProgramData は利用者でも書ける。
    //   昇格側へは元の値2つだけを数字で渡す。長い文字列は引用符で静かに壊れる。
    let values = crate::rl_uac::write_backup_if_absent();
    let a = crate::rl_uac::backup_as_args(&values);
    let arg = format!("--rl-uac-relax {} {}", a.get(0).map(|s| s.as_str()).unwrap_or("none"), a.get(1).map(|s| s.as_str()).unwrap_or("none"));
    match crate::platform::run_uac(&runner, &arg) {
        // ⚠ 「はい」を押していただけたかどうかは、この戻り値では分からない。
        //   断られた場合は false になる（ShellExecuteW が失敗を返す）。
        Ok(true) => log::info!("RL uac: 設定を書きに行きました（{arg}）"),
        Ok(false) => log::warn!(
            "RL uac: お客様が確認を押されませんでした。             相談員は UAC を押せません（サポート自体は続けられます）"
        ),
        Err(e) => log::warn!("RL uac: 確認を出せません: {e}"),
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn core_main() -> Option<Vec<String>> {
    // 🔴 前回のサポートで戻せていない設定があれば、**まずここで戻す**（2026-08-28）。
    //
    //   サポート中は管理者の確認（UAC）の出方を変える。正常に終われば
    //   切断時に戻るが、⚠ **アプリが落ちる／強制終了される形を何度も見ている。**
    //   ＝「終わるときに戻す」だけに頼ると、お客様のPCに変更が残る。
    //   ★次に起動したとき、控えが残っていたら必ず戻す。これが2本目の道。
    //   ⚠ 何もしていなければ、控えが無いので一瞬で通り過ぎる。
    //
    // 🔴🔴 **常駐版ではやらない**（2026-08-29 ご指示「常駐はUAC完全解除」）。
    //   ⚠ 常駐は切ったままにする。ここで戻すと、⚠ **サポートの最中に
    //     裏方のプロセスが立ち上がった拍子に、勝手に元へ戻ってしまう。**
    //     （この関数は `--server` など**すべてのプロセス**が通る。）
    //   ⚠ 古い版が残した控えは、常駐側で片付ける（disable_permanently）。
    #[cfg(windows)]
    if !crate::agent::is_resident() {
        crate::rl_uac::restore_if_pending();
    }
    // 2026-06-24: ワンタイム(ポータブル)版の設定隔離。ポータブルパッカーが展開先を RL_APP_DIR で渡す。
    //   設定/ID/ピアをそこに固定し、インストール版(%APPDATA%\...\REMOHELP PROLink)に一切触れない。
    //   → 既存インストール済みPCでワンタイムを使っても既存の遠隔接続(ID/設定)を壊さない。
    if let Ok(d) = std::env::var("RL_APP_DIR") {
        if !d.is_empty() {
            *config::APP_DIR.write().unwrap() = d;
        }
    }
    // 🔴🔴 ワンタイム版の設定を「全員が読める場所」へ置く（2026-08-30 ご判断）。
    //
    //   ⚠ なぜ要るか: 一時サービスは LocalSystem で動くので、
    //     `%APPDATA%` を**一度も読めない**。そのため設定を写して渡していたが、
    //     写しそこねると「サービスは動くのに永久に見つからない」という
    //     最も分かりにくい壊れ方をする（実機で複数回発生）。
    //     同じ場所を見せれば、写す処理そのものが要らなくなる。
    //
    //   ⚠ 危険は小さい（ご指摘のとおり）: 実行ファイルは数分で自分を消し、
    //     中身は「そのPCに繋ぐための番号と合言葉」だけ。読める人は既にその
    //     PCの前に座っている。⚠ **常駐版・相談員版では絶対に使わない。**
    //
    //   ★戻し方: 下の `RL_PUBLIC_CONFIG` を false にするだけ（2026-08-30 ご指示）。
    //     戻すと、これまでどおり `%APPDATA%` を使い、写す処理が復活する。
    #[cfg(windows)]
    rl_apply_public_config();
    // ログオン前の再接続（一時サービス）として動く場合（2026-08-01）。
    //   サービスに環境変数は渡らないので、**実行ファイルの隣の目印**で判断する。
    //   目印があるときだけ、設定とIDをその場所に固定する。
    //   ここを落とすと別のIDになり、相談員からは永久に見つからない。
    //   ⚠ global_init より先に決めること（後から変えても手遅れ）。
    #[cfg(windows)]
    let mut _rl_prelogon: Option<crate::rl_prelogon::Marker> = None;
    #[cfg(windows)]
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            if let Some(m) = crate::rl_prelogon::read_marker(dir) {
                *config::APP_DIR.write().unwrap() = dir.to_string_lossy().to_string();
                // 🔴🔴 通信路の名前を本体と分ける（2026-08-30 実機で確定）。
                //
                //   ⚠ 複製はアプリ名が本体と同じなので、通信路の名前も同じだった。
                //     先に立った方が握り、もう一方の子プロセスが入ろうとして
                //     実行ファイルの場所が違うため弾かれ、1秒ごとに永久に繰り返す。
                //   ⚠ 症状は「**接続番号が取れません**」。原因が見えない形で出る。
                //   ★この一式のすべてのプロセスが、同じ目印を見て同じ値になる。
                *config::IPC_NAMESPACE_SUFFIX.write().unwrap() = "prelogon".to_owned();
                _rl_prelogon = Some(m);
            }
        }
    }
    // ワンタイム(RL_APP_DIR 有)は、インストール済みPCでも Quick Support(単独)で動かし、
    // 既存インストールの Windows サービスに一切触れない(停止/ID破壊を防ぐ)。
    let _is_rl_onetime = std::env::var("RL_APP_DIR")
        .map(|d| !d.is_empty())
        .unwrap_or(false);
    if !crate::common::global_init() {
        return None;
    }
    crate::load_custom_client();
    // 🔴 接続は**別ウィンドウ**を既定にする（2026-08-09 ご要望）。
    //
    //   RustDesk の既定は「1つの窓にタブで足していく」。相談員が2台3台と
    //   同時に見るときに、**並べて置けない**のが不便だというご指摘。
    //   常駐でもワンタイムでも同じ画面なので、既定を変えれば両方に効く。
    //
    //   ⚠ 固定はしない。DEFAULT_LOCAL_SETTINGS は「利用者が何も選んでいないときの値」で、
    //     設定画面の「Open connection in new tab」で戻せる（そちらが優先される）。
    //     好みが分かれる項目を、こちらで決め打ちにしない。
    //   ⚠ load_custom_client() の**後**に置くこと。あちらも同じ表へ書くので、
    //     先に置くと配布設定に上書きされる。
    config::DEFAULT_LOCAL_SETTINGS.write().unwrap().insert(
        config::keys::OPTION_ENABLE_OPEN_NEW_CONNECTIONS_IN_TABS.to_owned(),
        "N".to_owned(),
    );
    // 🔴🔴 常駐の登録トークンを、**見えた瞬間に設定へ残す**（2026-08-04 実機調査）。
    //
    //   これまで RL_ENROLL_TOKEN を読んでいたのは agent.rs の中だけだった。
    //   ところが agent が動くのは **Windows サービスの中**で、
    //   環境変数を渡されているのは**自己展開のランナーが起動したプロセス**。
    //   つまり ①ランナーが渡す → ②そのプロセスがインストールして終わる
    //         → ③サービスが別に起動する（環境変数は無い）
    //   となり、**agent は一度もトークンを見られない**。
    //   ＝ 入れても端末が登録されない。本番の登録は今日まで0件だった。
    //
    //   ここは全プロセス共通の入口なので、渡された側が誰であれ設定に残せる。
    //   設定はインストール先へ引き継がれるので、あとから起動するサービスも読める。
    //   ⚠ 既に入っていれば上書きしない（会社を移した端末の値を壊さない）。
    //   ⚠ 値そのものは記録に書かない。
    if let Ok(t) = std::env::var("RL_ENROLL_TOKEN") {
        let t = t.trim().to_string();
        let ok_len = (8..=64).contains(&t.len());
        let ok_chars = t
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
        if ok_len && ok_chars {
            // 🔴🔴 設定ファイルだけでは足りない（2026-08-05 実機で判明）。
            //   自己展開のランナーは、設定の置き場所を**展開先の一時フォルダ**に
            //   固定して起動する（RL_APP_DIR）。インストール済みPCの設定を壊さない
            //   ための正しい仕組みだが、そこへ書いたトークンは
            //   **インストールが終わると一緒に消える**。
            //   あとから動く Windows サービスは別の場所を読むので永久に見つからない。
            //   ＝ 常駐が一度も登録できなかった原因の1つ。
            //   → 消えない場所（インストール先の登録簿）にも必ず残す。
            #[cfg(windows)]
            {
                if crate::platform::windows::get_enroll_token_reg().is_empty() {
                    if crate::platform::windows::set_enroll_token_reg(&t) {
                        log::info!("RL: 常駐の登録トークンを登録簿に保存しました");
                    } else {
                        // 昇格していないと書けない。インストールの最中なら書ける。
                        log::warn!("RL: 登録トークンを登録簿に保存できませんでした（権限）");
                    }
                }
            }
            if hbb_common::config::Config::get_option("enroll-token").is_empty() {
                hbb_common::config::Config::set_option("enroll-token".to_owned(), t);
                log::info!("RL: 常駐の登録トークンを設定に保存しました");
            }
        }
    }
    #[cfg(windows)]
    if !crate::platform::windows::bootstrap() {
        // return None to terminate the process
        return None;
    }
    let mut args = Vec::new();
    let mut flutter_args = Vec::new();
    let mut i = 0;
    let mut _is_elevate = false;
    let mut _is_run_as_system = false;
    let mut _is_quick_support = false;
    let mut _is_flutter_invoke_new_connection = false;
    let mut no_server = false;
    let mut arg_exe = Default::default();
    for arg in std::env::args() {
        if i == 0 {
            arg_exe = arg;
        } else if i > 0 {
            #[cfg(feature = "flutter")]
            if [
                "--connect",
                "--play",
                "--file-transfer",
                "--view-camera",
                "--port-forward",
                "--terminal",
                "--rdp",
            ]
            .contains(&arg.as_str())
            {
                _is_flutter_invoke_new_connection = true;
            }
            // 🔴🔴 macOS がダブルクリック起動のときに付ける `-psn_0_xxxxx` を捨てる
            //   （2026-08-15 実機で確定）。
            //
            //   macOS の LaunchServices は、Finder や `open` から起動したとき
            //   `-psn_0_483446` のような引数を渡してくる（プロセス通し番号）。
            //   これを引数として数えていたため `args.is_empty()` が成り立たず、
            //   **画面を配信する処理（start_server）が一度も起動しなかった**。
            //   `is_empty_uni_link()` も `remohelppro://` で始まらないので false。
            //
            //   ⚠ 症状は「接続できません。ネットワーク接続を確認してください」。
            //     中継サーバーへの登録そのものは別経路で成功することがあるため、
            //     **通信のせいに見えて原因にたどり着けない**。
            //   ⚠ 診断で実行ファイルを**直接**起動したときは `-psn_` が付かず、
            //     正しく起動して登録も成立した。
            //     ＝「調べると動く、ダブルクリックだと動かない」という、
            //       いちばん厄介な形になっていた（実際 1日を溶かした）。
            #[cfg(target_os = "macos")]
            if arg.starts_with("-psn_") {
                i += 1;
                continue;
            }
            if arg == "--elevate" {
                _is_elevate = true;
            } else if arg == "--run-as-system" {
                _is_run_as_system = true;
            } else if arg == "--quick_support" {
                _is_quick_support = true;
            } else if arg == "--no-server" {
                no_server = true;
            } else {
                args.push(arg);
            }
        }
        i += 1;
    }
    // 🔴🔴 **お客様に、最初の1回だけ確認を押していただく**（2026-08-31 ご判断「A案」）。
    //
    //   ⚠ 詳しい理由は `rl_uac::keeper` の頭に書いた。要点だけ:
    //     確認を「普通の画面」に出す設定を書くには管理者の権限が要り、
    //     その権限を得るには確認を押す必要があり、⚠ **その確認が真っ黒の画面に
    //     出ている**——という堂々巡りだった。お客様は目の前にいらっしゃるので、
    //     ⚠ **最初の1回だけ**押していただき、以後は相談員が全部できるようにする。
    //
    //   ⚠ ワンタイム版だけ。⚠ 常駐版・相談員版は絶対に通さない
    //     （常駐は別の道でサービスを持ち、相談員は自社の端末なので触らない）。
    //   ⚠ 既に 0 なら**何も出さない**。2回目以降のサポートで毎回出さないため。
    //   ⚠ 押していただけなくても支障なく続く（相談員が押せないだけ）。
    #[cfg(windows)]
    if args.is_empty() {
        // 🔴 前の版の残骸を、⚠ **始めるときに**片付ける（2026-09-01 ご指摘）。
        //   ⚠ 「入れ替えたのに何も変わらない」の正体は毎回これだった。
        //     そのたびに人が手で止めていた。⚠ それでは毎回はまる。
        //   ⚠ 当社のワンタイム版だけを狙う（目印ファイルで見分ける）。
        crate::common::rl_kill_stale_onetime();
        rl_uac_prepare();
    }
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    if args.is_empty() {
        #[cfg(target_os = "linux")]
        let should_check_start_tray = crate::check_process("--server", false);
        // We can use `crate::check_process("--server", false)` on Windows.
        // Because `--server` process is the System user's process. We can't get the arguments in `check_process()`.
        // We can assume that self service running means the server is also running on Windows.
        #[cfg(target_os = "windows")]
        let should_check_start_tray = crate::platform::is_self_service_running()
            && crate::platform::is_cur_exe_the_installed();
        if should_check_start_tray && !crate::check_process("--tray", true) {
            #[cfg(target_os = "linux")]
            hbb_common::allow_err!(crate::platform::check_autostart_config());
            hbb_common::allow_err!(crate::run_me(vec!["--tray"]));
        }
    }
    #[cfg(not(debug_assertions))]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    register_breakdown_handler(breakdown_callback);
    #[cfg(target_os = "linux")]
    #[cfg(feature = "flutter")]
    {
        let (k, v) = ("LIBGL_ALWAYS_SOFTWARE", "1");
        if config::option2bool(
            "allow-always-software-render",
            &config::Config::get_option("allow-always-software-render"),
        ) {
            std::env::set_var(k, v);
        } else {
            std::env::remove_var(k);
        }
    }
    #[cfg(windows)]
    if args.contains(&"--connect".to_string()) || args.contains(&"--view-camera".to_string()) {
        hbb_common::platform::windows::start_cpu_performance_monitor();
    }
    #[cfg(feature = "flutter")]
    if _is_flutter_invoke_new_connection {
        return core_main_invoke_new_connection(std::env::args());
    }
    let click_setup = cfg!(windows) && args.is_empty() && crate::common::is_setup(&arg_exe);
    if click_setup && !config::is_disable_installation() {
        args.push("--install".to_owned());
        flutter_args.push("--install".to_string());
    }
    if args.contains(&"--noinstall".to_string()) {
        args.clear();
    }
    if args.len() > 0 {
        if args[0] == "--version" {
            println!("{}", crate::VERSION);
            return None;
        } else if args[0] == "--build-date" {
            println!("{}", crate::BUILD_DATE);
            return None;
        }
    }
    #[cfg(windows)]
    {
        // ワンタイム版は常に Quick Support(単独)。既存サービスに触れない。
        _is_quick_support |= _is_rl_onetime;
        _is_quick_support |= !crate::platform::is_installed()
            && args.is_empty()
            && (is_quick_support_exe(&arg_exe)
                || config::LocalConfig::get_option("pre-elevate-service") == "Y"
                || (!click_setup && crate::platform::is_elevated(None).unwrap_or(false)));
        crate::portable_service::client::set_quick_support(_is_quick_support);
    }

    // 🔴 「既に導入済みのPCではワンタイムを起動しない」という止め方をやめた
    //   （2026-07-31 実機指摘）。
    //
    //   元は、REMOHELP PRO が入っているPCでワンタイム版を起動すると
    //   メッセージを出して**即終了**していた。「導入済み＝すでに遠隔で
    //   繋がるのだから、ワンタイムは不要」という判断だった。
    //
    //   ★その判断が誤り。見ていたのは `is_installed()` だけで、
    //     **入っているのが相談員アプリでも顧客アプリでも同じ扱い**だった。
    //     相談員アプリは「見る側」であって、そのPCが遠隔操作される
    //     わけではない。にもかかわらず、顧客としては一切繋がれなかった。
    //
    //   ★現場では役割が入れ替わる。
    //     ・相談員のPCが不調で、同僚に繋いでもらう
    //     ・「繋がりますか」の確認で、お互いに繋ぎ合う
    //     ・担当者が自分のPCで動作を見せる
    //     どれも普通に起きる。締め出してよい理由が無い。
    //
    //   ⚠ 当初の心配（入っている方の設定やIDを壊す）は、**別の仕組みで
    //     既に防いでいる**ので、ここで拒否する必要は無い。
    //       ・`RL_APP_DIR` で設定を隔離 → 入っている方の設定に触れない
    //       ・Quick Support で動く      → 入っている方のサービスに触れない
    //     二重に掛けた鍵が、正当な利用を締め出していた。
    //
    //   ⚠ この2つの隔離を外すときは、ここの判断もやり直すこと。
    let mut log_name = "".to_owned();
    // Keep portable-service logs under a stable directory name.
    let has_portable_service_shmem_arg = args
        .iter()
        .any(|arg| arg.starts_with("--portable-service-shmem-name="));
    if has_portable_service_shmem_arg {
        log_name = "portable-service".to_owned();
    } else if args.len() > 0 && args[0].starts_with("--") {
        let name = args[0].replace("--", "");
        if !name.is_empty() {
            log_name = name;
        }
    }
    hbb_common::init_log(false, &log_name);

    // linux uni (url) go here.
    #[cfg(all(target_os = "linux", feature = "flutter"))]
    if args.len() > 0 && args[0].starts_with(&crate::get_uri_prefix()) {
        return try_send_by_dbus(args[0].clone());
    }

    #[cfg(windows)]
    if (_is_rl_onetime || !crate::platform::is_installed())
        && args.is_empty()
        && _is_quick_support
        && !_is_elevate
        && !_is_run_as_system
    {
        use crate::portable_service::client;
        if let Err(e) = client::start_portable_service(client::StartPara::Direct) {
            log::error!("Failed to start portable service: {:?}", e);
        }
    }
    #[cfg(windows)]
    // RL build-14 fix (build-16 でコメント整理): ワンタイムの昇格サブプロセスを Flutter 起動なしで終了。
    // build-16 以降は既導入PCが上記Aガードで弾かれるため (!is_installed || _is_rl_onetime) の
    // _is_rl_onetime 側は「非導入PCのワンタイム」のみに適用される(多重防御として条件は残す)。
    if (!crate::platform::is_installed() || _is_rl_onetime) && (_is_elevate || _is_run_as_system) {
        crate::platform::elevate_or_run_as_system(click_setup, _is_elevate, _is_run_as_system);
        return None;
    }
    #[cfg(all(feature = "flutter", feature = "plugin_framework"))]
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    init_plugins(&args);
    if args.is_empty() || crate::common::is_empty_uni_link(&args[0]) {
        #[cfg(target_os = "macos")]
        {
            crate::platform::macos::try_remove_temp_update_dir(None);
        }

        #[cfg(windows)]
        {
            crate::platform::try_remove_temp_update_files();
            hbb_common::config::PeerConfig::preload_peers();
        }
        std::thread::spawn(move || crate::start_server(false, no_server));
    } else {
        // 🔴🔴 `remohelppro://` で呼ばれたとき、既に動いていればそちらへ渡す
        //   （2026-08-03 実機で確定）。
        //
        //   転送の仕組みは元からあるが、見ているのは `--connect <ID>` の形だけで、
        //   **URL の形はここを通っていなかった**。相談員が
        //   「操作アプリで開く」を押すたびに新しく起動し、実機で本体が
        //   5つ動いていた。しかも接続は1つを共有しているので、
        //   どれか1つを閉じると**全部が終わり、サポートまで終了**する。
        //
        //   ⚠ 渡せたときだけ終わる。渡せなければ（まだ誰も動いていない等）
        //     今までどおり起動する。ここで止めると、相談員は
        //     「押しても何も起きない」になる。
        //   ⚠ 送り先は uni_links_desktop の受け口（WM_USER+2）。
        //     受け側の作りは pub の uni_links_desktop_plugin.cpp で確認済み。
        #[cfg(windows)]
        if args[0].starts_with(&crate::get_uri_prefix()) {
            use winapi::um::winuser::WM_USER;
            let passed = crate::platform::send_message_to_hnwd(
                &crate::platform::FLUTTER_RUNNER_WIN32_WINDOW_CLASS,
                &crate::get_app_name(),
                (WM_USER + 2) as _,
                &args[0],
                // 🔴 ここは必ず false（2026-08-03 実機で確定・私の入れた不具合）。
                //   最後の引数を true にすると ShowWindow + SetForegroundWindow が走る。
                //   ところが見つかる窓は**本体の「あなたのコンピューター」の画面**で、
                //   操作の画面ではない。＝ ずっと隠してきた画面が前面に出てくる。
                //   相談員には、自分のIDとパスワードが並んだ知らない画面が急に開く。
                //   操作の画面は受け側が新しく開くので、こちらで前に出す必要はない。
                //   （元からある転送＝下の方の同じ呼び出しも false にしてある）
                false,
            );
            if passed {
                log::info!("uni link passed to the running instance");
                return None;
            }
        }
        #[cfg(windows)]
        {
            use crate::platform;
            if args[0] == "--uninstall" {
                if let Err(err) = platform::uninstall_me(true) {
                    log::error!("Failed to uninstall: {}", err);
                }
                return None;
            } else if args[0] == "--update" {
                if config::is_disable_installation() {
                    return None;
                }

                let text = match crate::platform::prepare_custom_client_update() {
                    Err(e) => {
                        log::error!("Error preparing custom client update: {}", e);
                        "Update failed!".to_string()
                    }
                    Ok(false) => "Update failed!".to_string(),
                    Ok(true) => match platform::update_me(false) {
                        Ok(_) => "Updated successfully!".to_string(),
                        Err(err) => {
                            log::error!("Failed with error: {err}");
                            "Update failed!".to_string()
                        }
                    },
                };
                Toast::new(Toast::POWERSHELL_APP_ID)
                    .title(&config::APP_NAME.read().unwrap())
                    .text1(&translate(text))
                    .sound(Some(Sound::Default))
                    .duration(Duration::Short)
                    .show()
                    .ok();
                return None;
            } else if args[0] == "--after-install" {
                if let Err(err) = platform::run_after_install() {
                    log::error!("Failed to after-install: {}", err);
                }
                return None;
            } else if args[0] == "--before-uninstall" {
                if let Err(err) = platform::run_before_uninstall() {
                    log::error!("Failed to before-uninstall: {}", err);
                }
                return None;
            } else if args[0] == "--silent-install" {
                if config::is_disable_installation() {
                    return None;
                }
                #[cfg(not(windows))]
                let options = "desktopicon startmenu";
                #[cfg(windows)]
                let options = "desktopicon startmenu printer";
                let res = platform::install_me(options, "".to_owned(), true, args.len() > 1);
                let text = match res {
                    Ok(_) => translate("Installation Successful!".to_string()),
                    Err(err) => {
                        println!("Failed with error: {err}");
                        translate("Installation failed!".to_string())
                    }
                };
                Toast::new(Toast::POWERSHELL_APP_ID)
                    .title(&config::APP_NAME.read().unwrap())
                    .text1(&text)
                    .sound(Some(Sound::Default))
                    .duration(Duration::Short)
                    .show()
                    .ok();
                return None;
            } else if args[0] == "--uninstall-cert" {
                #[cfg(windows)]
                hbb_common::allow_err!(crate::platform::windows::uninstall_cert());
                return None;
            } else if args[0] == "--install-idd" {
                #[cfg(windows)]
                if crate::virtual_display_manager::is_virtual_display_supported() {
                    hbb_common::allow_err!(
                        crate::virtual_display_manager::rustdesk_idd::install_update_driver()
                    );
                }
                return None;
            } else if args[0] == "--portable-service" {
                crate::platform::elevate_or_run_as_system(
                    click_setup,
                    _is_elevate,
                    _is_run_as_system,
                );
                return None;
            } else if args[0] == "--uninstall-amyuni-idd" {
                #[cfg(windows)]
                hbb_common::allow_err!(
                    crate::virtual_display_manager::amyuni_idd::uninstall_driver()
                );
                return None;
            } else if args[0] == "--install-remote-printer" {
                #[cfg(windows)]
                if crate::platform::is_win_10_or_greater() {
                    match remote_printer::install_update_printer(&crate::get_app_name()) {
                        Ok(_) => {
                            log::info!("Remote printer installed/updated successfully");
                        }
                        Err(e) => {
                            log::error!("Failed to install/update the remote printer: {}", e);
                        }
                    }
                } else {
                    log::error!("Win10 or greater required!");
                }
                return None;
            } else if args[0] == "--uninstall-remote-printer" {
                #[cfg(windows)]
                if crate::platform::is_win_10_or_greater() {
                    remote_printer::uninstall_printer(&crate::get_app_name());
                    log::info!("Remote printer uninstalled");
                }
                return None;
            }
        }
        #[cfg(target_os = "macos")]
        {
            use crate::platform;
            if args[0] == "--update" {
                if args.len() > 1 && args[1].ends_with(".dmg") {
                    // Version check is unnecessary unless downgrading to an older version
                    // that lacks "update dmg" support. This is a special case since we cannot
                    // detect the version before extracting the DMG, so we skip the check.
                    let dmg_path = &args[1];
                    println!("Updating from DMG: {}", dmg_path);
                    match platform::update_from_dmg(dmg_path) {
                        Ok(_) => {
                            println!("Update process from DMG started successfully.");
                            // The new process will handle the rest. We can exit.
                        }
                        Err(err) => {
                            eprintln!("Failed to start update from DMG: {}", err);
                        }
                    }
                } else {
                    println!("Starting update process...");
                    log::info!("Starting update process...");
                    let _text = match platform::update_me() {
                        Ok(_) => {
                            println!("{}", translate("Updated successfully!".to_string()));
                            log::info!("Updated successfully!");
                        }
                        Err(err) => {
                            eprintln!("Update failed with error: {}", err);
                            log::error!("Update failed with error: {err}");
                        }
                    };
                }
                return None;
            }
        }
        if args[0] == "--remove" {
            if args.len() == 2 {
                // sleep a while so that process of removed exe exit
                std::thread::sleep(std::time::Duration::from_secs(1));
                std::fs::remove_file(&args[1]).ok();
                return None;
            }
        } else if args[0] == "--tray" {
            if !crate::check_process("--tray", true) {
                crate::tray::start_tray();
            }
            return None;
        } else if args[0] == "--install-service" {
            log::info!("start --install-service");
            crate::platform::install_service();
            return None;
        } else if args[0] == "--enroll" {
            // REMOHELP PRO 常駐: 会社の登録トークンを保存する。
            //   --password と同様に IPC でサービスへ渡す（稼働中サービスのメモリ内configを
            //   即時更新＋永続化）。サービス未起動時はローカル(ディスク)に書く。→ 再起動不要。
            if args.len() == 2 {
                crate::ipc::set_option("enroll-token", &args[1]);
                println!("Enroll token stored.");
            } else {
                println!("Usage: --enroll <token>");
            }
            return None;
        } else if args[0] == "--uninstall-service" {
            log::info!("start --uninstall-service");
            crate::platform::uninstall_service(false, true);
            return None;
        } else if args[0] == "--service" {
            log::info!("start --service");
            // 🔴🔴 常駐は、UAC を**切ったままにする**（2026-08-29 ご指示）。
            //
            //   ご指示「常駐はUAC完全解除、ワンタイムは解除後終了時に戻す」。
            //   ⚠ 会社が管理している業務用PCなので、会社が決められる筋合いのもの。
            //     ⚠ ワンタイム（お客様の私物）は決められないので、あちらは必ず戻す。
            //
            //   ★接続のたびではなく、**サービスが立ち上がったとき**に1回。
            //     ⚠ 接続のたびに触る形は 1.4.61 でやって失敗した。
            //       戻す道が全部死ぬと「切ったまま」になり、しかも
            //       ⚠ **こちらは切ったつもりが無い**という最悪の状態になる。
            //     ＝ 切ると決めたなら、はじめから切って、戻さない。
            //   ⚠ 触るのは2つだけ。`EnableLUA` は触らない
            //     （再起動しないと効かず、Windows 標準アプリが動かなくなる）。
            #[cfg(windows)]
            if crate::agent::is_resident() {
                crate::rl_uac::disable_permanently();
            }
            // 一時サービスなら、起動のたびに見張りを立て直す。
            //   ⚠ 「届かない時間」の砂時計はここで0に戻る（＝再起動で止まっていた
            //     時間を数えない）。詳しくは rl_prelogon.rs の頭。
            #[cfg(windows)]
            if let Some(m) = _rl_prelogon.take() {
                crate::rl_prelogon::start_watchdog(m);
            }
            crate::start_os_service();
            return None;
        } else if args[0] == "--rl-prelogon-install" {
            // 一時サービスを作る（昇格済みで呼ばれる）。
            //   使い方: --rl-prelogon-install <展開先> <短いID> <打ち切りUNIX秒>
            //   ⚠ 4つ目は「サポートの制限時間」ではなく**最後の歯止め**（既定12時間）。
            //     普段はサーバーの「サポート終了」で消える。詳しくは rl_prelogon.rs の頭。
            //   ⚠ 結果は**終了コード**で返す。0=成功／2=権限が無い／1=その他の失敗。
            //     顧客アプリはこれを見て、相談員に理由を伝える。
            #[cfg(windows)]
            {
                if args.len() < 4 {
                    return None;
                }
                let src = std::path::PathBuf::from(&args[1]);
                let hard_limit = args[3].parse::<u64>().unwrap_or(0);
                match crate::rl_prelogon::install(&src, &args[2], hard_limit) {
                    Ok(_) => std::process::exit(0),
                    Err(e) => {
                        log::error!("RL prelogon install failed: {e}");
                        let code = if e.to_string().contains("not elevated") { 2 } else { 1 };
                        std::process::exit(code);
                    }
                }
            }
            #[cfg(not(windows))]
            return None;
        } else if args[0] == "--server" {
            log::info!("start --server with user {}", crate::username());
            #[cfg(target_os = "linux")]
            {
                hbb_common::allow_err!(crate::platform::check_autostart_config());
                std::process::Command::new("pkill")
                    .arg("-f")
                    .arg(&format!("{} --tray", crate::get_app_name().to_lowercase()))
                    .status()
                    .ok();
                hbb_common::allow_err!(crate::run_me(vec!["--tray"]));
            }
            #[cfg(windows)]
            crate::privacy_mode::restore_reg_connectivity(true, false);
            #[cfg(any(target_os = "linux", target_os = "windows"))]
            {
                crate::start_server(true, false);
            }
            #[cfg(target_os = "macos")]
            {
                let handler = std::thread::spawn(move || crate::start_server(true, false));
                crate::tray::start_tray();
                // prevent server exit when encountering errors from tray
                hbb_common::allow_err!(handler.join());
            }
            return None;
        } else if args[0] == "--import-config" {
            if args.len() == 2 {
                let filepath;
                let path = std::path::Path::new(&args[1]);
                if !path.is_absolute() {
                    let mut cur = std::env::current_dir().unwrap();
                    cur.push(path);
                    filepath = cur.to_str().unwrap().to_string();
                } else {
                    filepath = path.to_str().unwrap().to_string();
                }
                import_config(&filepath);
            }
            return None;
        } else if args[0] == "--password" {
            if config::is_disable_settings() {
                println!("Settings are disabled!");
                return None;
            }
            if config::Config::is_disable_change_permanent_password() {
                println!("Changing permanent password is disabled!");
                return None;
            }
            if args.len() == 2 {
                if crate::platform::is_installed() && is_root() {
                    if let Err(err) = crate::ipc::set_permanent_password(args[1].to_owned()) {
                        println!("{err}");
                    } else {
                        println!("Done!");
                    }
                } else {
                    println!("Installation and administrative privileges required!");
                }
            }
            return None;
        } else if args[0] == "--set-unlock-pin" {
            if config::Config::is_disable_unlock_pin() {
                println!("Unlock PIN is disabled!");
                return None;
            }
            #[cfg(feature = "flutter")]
            if args.len() == 2 {
                if crate::platform::is_installed() && is_root() {
                    if let Err(err) = crate::ipc::set_unlock_pin(args[1].to_owned(), false) {
                        println!("{err}");
                    } else {
                        println!("Done!");
                    }
                } else {
                    println!("Installation and administrative privileges required!");
                }
            }
            return None;
        } else if args[0] == "--get-id" {
            println!("{}", crate::ipc::get_id());
            return None;
        } else if args[0] == "--set-id" {
            if config::is_disable_settings() {
                println!("Settings are disabled!");
                return None;
            }
            if config::Config::is_disable_change_id() {
                println!("Changing ID is disabled!");
                return None;
            }
            if args.len() == 2 {
                if crate::platform::is_installed() && is_root() {
                    let old_id = crate::ipc::get_id();
                    let mut res = crate::ui_interface::change_id_shared(args[1].to_owned(), old_id);
                    if res.is_empty() {
                        res = "Done!".to_owned();
                    }
                    println!("{}", res);
                } else {
                    println!("Installation and administrative privileges required!");
                }
            }
            return None;
        } else if args[0] == "--config" {
            if args.len() == 2 && !args[0].contains("host=") {
                if crate::platform::is_installed() && is_root() {
                    // encrypted string used in renaming exe.
                    let name = if args[1].ends_with(".exe") {
                        args[1].to_owned()
                    } else {
                        format!("{}.exe", args[1])
                    };
                    if let Ok(lic) = crate::custom_server::get_custom_server_from_string(&name) {
                        if !lic.host.is_empty() {
                            crate::ui_interface::set_option("key".into(), lic.key);
                            crate::ui_interface::set_option(
                                "custom-rendezvous-server".into(),
                                lic.host,
                            );
                            crate::ui_interface::set_option("api-server".into(), lic.api);
                            crate::ui_interface::set_option("relay-server".into(), lic.relay);
                        }
                    }
                } else {
                    println!("Installation and administrative privileges required!");
                }
            }
            return None;
        } else if args[0] == "--option" {
            if config::is_disable_settings() {
                println!("Settings are disabled!");
                return None;
            }
            if crate::platform::is_installed() && is_root() {
                if args.len() == 2 {
                    let options = crate::ipc::get_options();
                    println!("{}", options.get(&args[1]).unwrap_or(&"".to_owned()));
                } else if args.len() == 3 {
                    crate::ipc::set_option(&args[1], &args[2]);
                }
            } else {
                println!("Installation and administrative privileges required!");
            }
            return None;
        } else if args[0] == "--assign" {
            if config::Config::no_register_device() {
                println!("Cannot assign an unregistrable device!");
            } else if crate::platform::is_installed() && is_root() {
                let max = args.len() - 1;
                let pos = args.iter().position(|x| x == "--token").unwrap_or(max);
                if pos < max {
                    let token = args[pos + 1].to_owned();
                    let id = crate::ipc::get_id();
                    let uuid = crate::encode64(hbb_common::get_uuid());
                    let get_value = |c: &str| {
                        let pos = args.iter().position(|x| x == c).unwrap_or(max);
                        if pos < max {
                            Some(args[pos + 1].to_owned())
                        } else {
                            None
                        }
                    };
                    let user_name = get_value("--user_name");
                    let strategy_name = get_value("--strategy_name");
                    let address_book_name = get_value("--address_book_name");
                    let address_book_tag = get_value("--address_book_tag");
                    let address_book_alias = get_value("--address_book_alias");
                    let address_book_password = get_value("--address_book_password");
                    let address_book_note = get_value("--address_book_note");
                    let device_group_name = get_value("--device_group_name");
                    let note = get_value("--note");
                    let device_username = get_value("--device_username");
                    let device_name = get_value("--device_name");
                    let mut body = serde_json::json!({
                        "id": id,
                        "uuid": uuid,
                    });
                    let header = "Authorization: Bearer ".to_owned() + &token;
                    if user_name.is_none()
                        && strategy_name.is_none()
                        && address_book_name.is_none()
                        && device_group_name.is_none()
                        && note.is_none()
                        && device_username.is_none()
                        && device_name.is_none()
                    {
                        println!(
                            r#"At least one of the following options is required:
  --user_name
  --strategy_name
  --address_book_name
  --device_group_name
  --note
  --device_username
  --device_name"#
                        );
                    } else {
                        if let Some(name) = user_name {
                            body["user_name"] = serde_json::json!(name);
                        }
                        if let Some(name) = strategy_name {
                            body["strategy_name"] = serde_json::json!(name);
                        }
                        if let Some(name) = address_book_name {
                            body["address_book_name"] = serde_json::json!(name);
                            if let Some(name) = address_book_tag {
                                body["address_book_tag"] = serde_json::json!(name);
                            }
                            if let Some(name) = address_book_alias {
                                body["address_book_alias"] = serde_json::json!(name);
                            }
                            if let Some(name) = address_book_password {
                                body["address_book_password"] = serde_json::json!(name);
                            }
                            if let Some(name) = address_book_note {
                                body["address_book_note"] = serde_json::json!(name);
                            }
                        }
                        if let Some(name) = device_group_name {
                            body["device_group_name"] = serde_json::json!(name);
                        }
                        if let Some(name) = note {
                            body["note"] = serde_json::json!(name);
                        }
                        if let Some(name) = device_username {
                            body["device_username"] = serde_json::json!(name);
                        }
                        if let Some(name) = device_name {
                            body["device_name"] = serde_json::json!(name);
                        }
                        let url = crate::ui_interface::get_api_server() + "/api/devices/cli";
                        match crate::post_request_sync(url, body.to_string(), &header) {
                            Err(err) => println!("{}", err),
                            Ok(text) => {
                                if text.is_empty() {
                                    println!("Done!");
                                } else {
                                    println!("{}", text);
                                }
                            }
                        }
                    }
                } else {
                    println!("--token is required!");
                }
            } else {
                println!("Installation and administrative privileges required!");
            }
            return None;
        } else if args[0] == "--check-hwcodec-config" {
            #[cfg(feature = "hwcodec")]
            crate::ipc::hwcodec_process();
            return None;
        } else if args[0] == "--terminal-helper" {
            // Terminal helper process - runs as user to create ConPTY
            // This is needed because ConPTY has compatibility issues with CreateProcessAsUserW
            #[cfg(target_os = "windows")]
            {
                let helper_args: Vec<String> = args[1..].to_vec();
                if let Err(e) = crate::server::terminal_helper::run_terminal_helper(&helper_args) {
                    log::error!("Terminal helper failed: {}", e);
                }
            }
            return None;
        } else if args[0] == "--cm" {
            // call connection manager to establish connections
            // meanwhile, return true to call flutter window to show control panel
            crate::ui_interface::start_option_status_sync();
        } else if args[0] == "--cm-no-ui" {
            #[cfg(feature = "flutter")]
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            {
                crate::ui_interface::start_option_status_sync();
                crate::flutter::connection_manager::start_cm_no_ui();
            }
            return None;
        } else if args[0] == "--whiteboard" {
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            {
                crate::whiteboard::run();
            }
            return None;
        } else if args[0] == "-gtk-sudo" {
            // rustdesk service kill `rustdesk --` processes
            #[cfg(target_os = "linux")]
            if args.len() > 2 {
                crate::platform::gtk_sudo::exec();
            }
            return None;
        } else {
            #[cfg(all(feature = "flutter", feature = "plugin_framework"))]
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            if args[0] == "--plugin-install" {
                if args.len() == 2 {
                    crate::plugin::change_uninstall_plugin(&args[1], false);
                } else if args.len() == 3 {
                    crate::plugin::install_plugin_with_url(&args[1], &args[2]);
                }
                return None;
            } else if args[0] == "--plugin-uninstall" {
                if args.len() == 2 {
                    crate::plugin::change_uninstall_plugin(&args[1], true);
                }
                return None;
            }
        }
    }
    //_async_logger_holder.map(|x| x.flush());
    #[cfg(feature = "flutter")]
    return Some(flutter_args);
    #[cfg(not(feature = "flutter"))]
    return Some(args);
}

#[inline]
#[cfg(all(feature = "flutter", feature = "plugin_framework"))]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn init_plugins(args: &Vec<String>) {
    if args.is_empty() || "--server" == (&args[0] as &str) {
        #[cfg(debug_assertions)]
        let load_plugins = true;
        #[cfg(not(debug_assertions))]
        let load_plugins = crate::platform::is_installed();
        if load_plugins {
            crate::plugin::init();
        }
    } else if "--service" == (&args[0] as &str) {
        hbb_common::allow_err!(crate::plugin::remove_uninstalled());
    }
}

fn import_config(path: &str) {
    use hbb_common::{config::*, get_exe_time, get_modified_time};
    let path2 = path.replace(".toml", "2.toml");
    let path2 = std::path::Path::new(&path2);
    let path = std::path::Path::new(path);
    log::info!("import config from {:?} and {:?}", path, path2);
    let config: Config = load_path(path.into());
    if config.is_empty() {
        log::info!("Empty source config, skipped");
        return;
    }
    if get_modified_time(&path) > get_modified_time(&Config::file())
        && get_modified_time(&path) < get_exe_time()
    {
        if store_path(Config::file(), config).is_err() {
            log::info!("config written");
        }
    }
    let config2: Config2 = load_path(path2.into());
    if get_modified_time(&path2) > get_modified_time(&Config2::file()) {
        if store_path(Config2::file(), config2).is_err() {
            log::info!("config2 written");
        }
    }
}

/// invoke a new connection
///
/// [Note]
/// this is for invoke new connection from dbus.
/// If it returns [`None`], then the process will terminate, and flutter gui will not be started.
/// If it returns [`Some`], then the process will continue, and flutter gui will be started.
#[cfg(feature = "flutter")]
fn core_main_invoke_new_connection(mut args: std::env::Args) -> Option<Vec<String>> {
    let mut authority = None;
    let mut id = None;
    let mut param_array = vec![];
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--connect" | "--play" | "--file-transfer" | "--view-camera" | "--port-forward"
            | "--terminal" | "--rdp" => {
                authority = Some((&arg.to_string()[2..]).to_owned());
                id = args.next();
            }
            "--password" => {
                if let Some(password) = args.next() {
                    param_array.push(format!("password={password}"));
                }
            }
            "--relay" => {
                param_array.push(format!("relay=true"));
            }
            // inner
            "--switch_uuid" => {
                if let Some(switch_uuid) = args.next() {
                    param_array.push(format!("switch_uuid={switch_uuid}"));
                }
            }
            _ => {}
        }
    }
    let mut uni_links = Default::default();
    if let Some(authority) = authority {
        if let Some(mut id) = id {
            let app_name = crate::get_app_name();
            let ext = format!(".{}", app_name.to_lowercase());
            if id.ends_with(&ext) {
                id = id.replace(&ext, "");
            }
            let params = param_array.join("&");
            let params_flag = if params.is_empty() { "" } else { "?" };
            uni_links = format!(
                "{}{}/{}{}{}",
                crate::get_uri_prefix(),
                authority,
                id,
                params_flag,
                params
            );
        }
    }
    if uni_links.is_empty() {
        return None;
    }

    #[cfg(target_os = "linux")]
    return try_send_by_dbus(uni_links);

    #[cfg(windows)]
    {
        use winapi::um::winuser::WM_USER;
        let res = crate::platform::send_message_to_hnwd(
            &crate::platform::FLUTTER_RUNNER_WIN32_WINDOW_CLASS,
            &crate::get_app_name(),
            (WM_USER + 2) as _, // referred from unilinks desktop pub
            uni_links.as_str(),
            false,
        );
        return if res { None } else { Some(Vec::new()) };
    }
    #[cfg(target_os = "macos")]
    {
        return if let Err(_) = crate::ipc::send_url_scheme(uni_links) {
            Some(Vec::new())
        } else {
            None
        };
    }
}

#[cfg(all(target_os = "linux", feature = "flutter"))]
fn try_send_by_dbus(uni_links: String) -> Option<Vec<String>> {
    use crate::dbus::invoke_new_connection;

    match invoke_new_connection(uni_links) {
        Ok(()) => {
            return None;
        }
        Err(err) => {
            log::error!("{}", err.as_ref());
            // return Some to invoke this url by self
            return Some(Vec::new());
        }
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn is_root() -> bool {
    #[cfg(windows)]
    {
        return crate::platform::is_elevated(None).unwrap_or_default()
            || crate::platform::is_root();
    }
    #[allow(unreachable_code)]
    crate::platform::is_root()
}

/// Check if the executable is a Quick Support version.
/// Note: This function must be kept in sync with `libs/portable/src/main.rs`.
#[cfg(windows)]
#[inline]
fn is_quick_support_exe(exe: &str) -> bool {
    let exe = exe.to_lowercase();
    exe.contains("-qs-") || exe.contains("-qs.exe") || exe.contains("_qs.exe")
}
