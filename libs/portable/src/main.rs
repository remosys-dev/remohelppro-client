#![windows_subsystem = "windows"]

use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use bin_reader::BinaryReader;

pub mod bin_reader;
#[cfg(windows)]
mod ui;

#[cfg(windows)]
const APP_METADATA: &[u8] = include_bytes!("../app_metadata.toml");
#[cfg(not(windows))]
const APP_METADATA: &[u8] = &[];
const APP_METADATA_CONFIG: &str = "meta.toml";
const META_LINE_PREFIX_TIMESTAMP: &str = "timestamp = ";
const APP_PREFIX: &str = "rustdesk";
const APPNAME_RUNTIME_ENV_KEY: &str = "RUSTDESK_APPNAME";

/// ワンタイム版の有効期限（UNIX秒）。**CI がワンタイムのビルド時にだけ渡す**。
///
/// 🔴 目的（2026-07-27 実機テストの指摘）＝ お客様のPCに残った古いファイルを
///    ダブルクリックしても、**認証コードの画面すら出さない**ようにする。
///    自己削除は入れたが、それを取りこぼした場合・実行前に別の場所へ複製された
///    場合の**二段目の歯止め**として期限を焼き込む。
///
/// 埋まっていなければ期限なし＝常駐版・相談員版・開発ビルドは一切影響を受けない。
const ONETIME_EXPIRES_AT: Option<&str> = option_env!("RL_ONETIME_EXPIRES_AT");

/// 期限切れか。**判断がつかないときは false（＝起動させる）**。
///
/// ⚠ ここで迷って止めると、目の前で困っているお客様のサポートが始められない。
///    時計が読めない・値が壊れているといった不確かな場合は通す。
///    止めるのは「確実に期限を過ぎている」と言えるときだけにする。
fn is_onetime_expired() -> bool {
    let Some(raw) = ONETIME_EXPIRES_AT else {
        return false;
    };
    let Ok(expires_at) = raw.trim().parse::<u64>() else {
        return false;
    };
    if expires_at == 0 {
        return false;
    }
    let Ok(now) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) else {
        return false;
    };
    now.as_secs() > expires_at
}

/// 期限切れをお客様に伝える。ここで黙って終わると「押しても何も起きない」に
/// なってしまい、お客様が同じファイルを何度も押すことになる。
fn notify_onetime_expired() {
    let text = "このファイルは有効期限が切れています。\n\n\
                お手数ですが、担当者からご案内のページを開いて、\n\
                もう一度ダウンロードしてからお使いください。\n\n\
                （安全のため、サポート用のファイルは一定期間で使えなくなります）";
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        fn wide(s: &str) -> Vec<u16> {
            std::ffi::OsStr::new(s)
                .encode_wide()
                .chain(std::iter::once(0))
                .collect()
        }
        let body = wide(text);
        let title = wide("REMOHELP PRO");
        unsafe {
            winapi::um::winuser::MessageBoxW(
                std::ptr::null_mut(),
                body.as_ptr(),
                title.as_ptr(),
                winapi::um::winuser::MB_OK | winapi::um::winuser::MB_ICONWARNING,
            );
        }
    }
    #[cfg(not(windows))]
    eprintln!("{}", text);
}
#[cfg(windows)]
const SET_FOREGROUND_WINDOW_ENV_KEY: &str = "SET_FOREGROUND_WINDOW";

fn is_timestamp_matches(dir: &Path, ts: &mut u64) -> bool {
    let Ok(app_metadata) = std::str::from_utf8(APP_METADATA) else {
        return true;
    };
    for line in app_metadata.lines() {
        if line.starts_with(META_LINE_PREFIX_TIMESTAMP) {
            if let Ok(stored_ts) = line.replace(META_LINE_PREFIX_TIMESTAMP, "").parse::<u64>() {
                *ts = stored_ts;
                break;
            }
        }
    }
    if *ts == 0 {
        return true;
    }

    if let Ok(content) = std::fs::read_to_string(dir.join(APP_METADATA_CONFIG)) {
        for line in content.lines() {
            if line.starts_with(META_LINE_PREFIX_TIMESTAMP) {
                if let Ok(stored_ts) = line.replace(META_LINE_PREFIX_TIMESTAMP, "").parse::<u64>() {
                    return *ts == stored_ts;
                }
            }
        }
    }
    false
}

fn write_meta(dir: &Path, ts: u64) {
    let meta_file = dir.join(APP_METADATA_CONFIG);
    if ts != 0 {
        let content = format!("{}{}", META_LINE_PREFIX_TIMESTAMP, ts);
        // Ignore is ok here
        let _ = std::fs::write(meta_file, content);
    }
}

fn setup(
    reader: BinaryReader,
    dir: Option<PathBuf>,
    clear: bool,
    _args: &Vec<String>,
    _ui: &mut bool,
) -> Option<PathBuf> {
    let dir = if let Some(dir) = dir {
        dir
    } else {
        // home dir
        if let Some(dir) = dirs::data_local_dir() {
            dir.join(APP_PREFIX)
        } else {
            eprintln!("not found data local dir");
            return None;
        }
    };

    let mut ts = 0;
    if clear || !is_timestamp_matches(&dir, &mut ts) {
        #[cfg(windows)]
        if _args.is_empty() {
            *_ui = true;
            ui::setup();
        }
        std::fs::remove_dir_all(&dir).ok();
    }
    for file in reader.files.iter() {
        file.write_to_file(&dir);
    }
    write_meta(&dir, ts);
    #[cfg(windows)]
    win::copy_runtime_broker(&dir);
    #[cfg(linux)]
    reader.configure_permission(&dir);
    Some(dir.join(&reader.exe))
}

fn use_null_stdio() -> bool {
    #[cfg(windows)]
    {
        // When running in CMD on Windows 7, using Stdio::inherit() with spawn returns an "invalid handle" error.
        // Since using Stdio::null() didn’t cause any issues, and determining whether the program is launched from CMD or by double-clicking would require calling more APIs during startup, we also use Stdio::null() when launched by double-clicking on Windows 7.
        let is_windows_7 = is_windows_7();
        println!("is windows7: {}", is_windows_7);
        return is_windows_7;
    }
    #[cfg(not(windows))]
    false
}

#[cfg(windows)]
fn is_windows_7() -> bool {
    use windows::Wdk::System::SystemServices::RtlGetVersion;
    use windows::Win32::System::SystemInformation::OSVERSIONINFOW;

    unsafe {
        let mut version_info = OSVERSIONINFOW::default();
        version_info.dwOSVersionInfoSize = std::mem::size_of::<OSVERSIONINFOW>() as u32;

        if RtlGetVersion(&mut version_info).is_ok() {
            // Windows 7 is version 6.1
            println!(
                "Windows version: {}.{}",
                version_info.dwMajorVersion, version_info.dwMinorVersion
            );
            return version_info.dwMajorVersion == 6 && version_info.dwMinorVersion == 1;
        }
    }
    false
}

/// 落としたファイルの名前に埋まっている「合言葉」を取り出す。
///
/// 経緯（2026-07-29 ユーザー要望）:
///   これまでお客様は、ページで認証コードを入れ、落としたアプリでも
///   **もう一度**同じコードを入れていた。他社は1回で済むため、乗り換えを
///   お願いする場面で不利だった。ページでコードを確認したブラウザが
///   一回限りの合言葉をファイル名に埋めて配るので、ここで読んで引き渡す。
///
/// 想定する名前:  remohelppro-start-<短ID>.<秘密>.exe
///
/// 🔴 同じ名前のファイルが既にあると、ブラウザが
///   「remohelppro-start-XXXXXX.abcdef (1).exe」のように末尾を変える。
///   **後から落とした方が新しい合言葉**なので、ここを読めないと
///   「2回目に落としたのに繋がらない」という一番起きやすい失敗になる。
///   末尾の「 (1)」は取り除いてから読む。
///
/// 🔴 読めないときは None を返して**黙って従来どおり**にする。
///   お客様の名前変更・別経路での入手など、読めない事情はいくらでもある。
///   ここで止めると「押しても何も起きない」になってしまう。
fn dl_token_from_exe_name(exe: &std::path::Path) -> Option<String> {
    const PREFIX: &str = "remohelppro-start-";
    let stem = exe.file_stem()?.to_string_lossy().to_string();
    // 「 (1)」「 (12)」などの重複回避サフィックスを外す。
    let stem = match stem.rfind(" (") {
        Some(i) if stem.ends_with(')') && stem[i + 2..stem.len() - 1].chars().all(|c| c.is_ascii_digit()) => {
            stem[..i].to_string()
        }
        _ => stem,
    };
    let rest = stem.strip_prefix(PREFIX)?;
    let (short_id, secret) = rest.split_once('.')?;
    // 形式だけ確かめる。正しさの判断はサーバーが行う（ここは通すだけ）。
    let short_ok = short_id.len() == 6
        && short_id
            .chars()
            .all(|c| c.is_ascii_digit() || (c.is_ascii_uppercase() && !"IOLU".contains(c)));
    let secret_ok = (6..=64).contains(&secret.len())
        && secret
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if short_ok && secret_ok {
        Some(format!("{short_id}.{secret}"))
    } else {
        None
    }
}

#[cfg(test)]
mod dl_token_tests {
    use super::dl_token_from_exe_name;
    use std::path::Path;

    fn t(name: &str) -> Option<String> {
        dl_token_from_exe_name(Path::new(name))
    }

    #[test]
    fn reads_plain_name() {
        assert_eq!(t("remohelppro-start-A3K9XZ.Ab_9-x.exe"), Some("A3K9XZ.Ab_9-x".into()));
    }

    #[test]
    fn reads_second_download() {
        // ブラウザが付ける重複回避サフィックス。ここが読めないと
        // 「2回目に落としたのに繋がらない」になる。
        assert_eq!(t("remohelppro-start-A3K9XZ.Ab_9-x (1).exe"), Some("A3K9XZ.Ab_9-x".into()));
        assert_eq!(t("remohelppro-start-A3K9XZ.Ab_9-x (12).exe"), Some("A3K9XZ.Ab_9-x".into()));
    }

    #[test]
    fn ignores_anything_else() {
        assert_eq!(t("remohelppro-customer.exe"), None);
        assert_eq!(t("remohelppro-support.exe"), None);
        // 短IDに紛らわしい文字(I/O/L/U)は使わない規則
        assert_eq!(t("remohelppro-start-AIK9XZ.Ab_9-x.exe"), None);
        // 桁数違い・秘密が短すぎる・区切り無し
        assert_eq!(t("remohelppro-start-A3K9X.Ab_9-x.exe"), None);
        assert_eq!(t("remohelppro-start-A3K9XZ.abc.exe"), None);
        assert_eq!(t("remohelppro-start-A3K9XZ.exe"), None);
        // 括弧が数字でない＝名前の一部なので外さない
        assert_eq!(t("remohelppro-start-A3K9XZ.Ab_9-x (copy).exe"), None);
    }
}

fn execute(path: PathBuf, args: Vec<String>, _ui: bool) {
    println!("executing {}", path.display());
    // setup env
    let exe = std::env::current_exe().unwrap_or_default();
    let exe_name = exe.file_name().unwrap_or_default();
    // 2026-06-24: ワンタイム版の設定隔離先(展開dir)を子プロセスへ RL_APP_DIR で渡す。
    //   子(rustdesk.exe)の core_main がこれを APP_DIR に設定し、インストール版に触れない。
    let rl_app_dir = path.parent().map(|p| p.to_string_lossy().to_string());
    // 🔴 ワンタイム版かどうかは **同梱した目印ファイル** で判定する（2026-07-26 修正）。
    //
    //   元は内包EXEの名前が "REMOHELP PRO.exe" かどうかで見ていた。しかし CI は
    //   実際には "remohelppro.exe"（空白なし）へリネームしており、**一度も一致して
    //   いなかった**。＝ 自己削除がまったく動かず、お客様の PC に exe が残り、
    //   何度でもダブルクリックで起動できる状態だった（実機で指摘を受けた「使い回し」）。
    //
    //   ファイル名で判定すると、リネーム規則を変えた瞬間に静かに壊れる。
    //   しかも壊れても「消えないだけ」でエラーが出ないので気づけない。
    //   CI が置く目印ファイルの有無で判定すれば、名前を変えても影響しない。
    let is_onetime = path
        .parent()
        .map(|d| d.join("remohelppro-onetime.flag").exists())
        .unwrap_or(false);
    // run executable
    let mut cmd = Command::new(&path);
    cmd.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(winapi::um::winbase::CREATE_NO_WINDOW);
        if _ui {
            cmd.env(SET_FOREGROUND_WINDOW_ENV_KEY, "1");
        }
    }

    cmd.env(APPNAME_RUNTIME_ENV_KEY, exe_name);
    if let Some(ref d) = rl_app_dir {
        cmd.env("RL_APP_DIR", d);
    }
    // ファイル名に合言葉が埋まっていれば本体へ渡す（＝認証コードの再入力を省く）。
    //   無ければ何も渡さない＝本体は従来どおり認証コード画面を出す。
    if let Some(tok) = dl_token_from_exe_name(&exe) {
        println!("RL: pair token found in file name");
        cmd.env("RL_PAIR_DL_TOKEN", tok);
    }
    if use_null_stdio() {
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
    } else {
        cmd.stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
    }

    if is_onetime {
        // RL build-16 (C): ワンタイムは子プロセス終了まで待機 → 展開dir削除 + 元EXE自己削除。
        //   ランナーは #![windows_subsystem = "windows"] のため窓なし。待機中も非表示・無害(1MB以下)。
        //   → 「1ダウンロード=1接続=自動消滅」を保証(2回目のダブルクリックを不可能にする)。
        if let Ok(mut child) = cmd.spawn() {
            // AllowSetForegroundWindow は wait() より前に呼ぶ
            #[cfg(windows)]
            if _ui {
                unsafe {
                    winapi::um::winuser::AllowSetForegroundWindow(child.id() as u32);
                }
            }
            let _ = child.wait(); // 子(REMOHELP PRO.exe)が終了するまでブロック
            // ① 展開ディレクトリ削除(子終了後はハンドル解放済み)。
            //    穴C対策: DLLのアンロード遅延でロックされることがあるので数回リトライ。
            //    それでも残れば ② の切離しcmdが後追いで確実に消す。
            if let Some(ref d) = rl_app_dir {
                let mut removed = false;
                for _ in 0..5 {
                    match std::fs::remove_dir_all(d) {
                        Ok(_) => {
                            removed = true;
                            break;
                        }
                        Err(_) => {
                            std::thread::sleep(std::time::Duration::from_millis(500))
                        }
                    }
                }
                if !removed {
                    eprintln!("RL: remove_dir_all pending, retry via detached cmd: {}", d);
                }
            }
            // ② 元EXE＋展開dir を detached cmd で後追い削除(穴C対策)。
            //    実行中EXEは自分では消せず、DLLロックも数秒で解放される想定 → 待機して複数回スイープ。
            //    CREATE_NO_WINDOW で窓なし。EV署名済みEXEからの呼出は誤検知低減。
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                let self_path = exe.to_string_lossy().to_string();
                let dir_path = rl_app_dir.clone().unwrap_or_default();
                // 1スイープ = 展開dir を rmdir ＋ 元EXE を del。待機を挟んで2回繰り返す。
                let sweep = format!(
                    "rmdir /s /q \"{d}\" 2>nul & del /f /q \"{e}\" 2>nul",
                    d = dir_path,
                    e = self_path
                );
                let del_cmd = format!(
                    "ping -n 3 127.0.0.1 >nul & {s} & ping -n 4 127.0.0.1 >nul & {s}",
                    s = sweep
                );
                let _ = Command::new("cmd")
                    .args(&["/c", &del_cmd])
                    .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
                    .spawn();
            }
        }
    } else {
        // フリートポータブル: 従来通り待たずに spawn して即リターン
        let _child = cmd.spawn();
        #[cfg(windows)]
        if _ui {
            match _child {
                Ok(child) => unsafe {
                    winapi::um::winuser::AllowSetForegroundWindow(child.id() as u32);
                },
                Err(e) => {
                    eprintln!("{:?}", e);
                }
            }
        }
    }
}

fn main() {
    // 🔴 展開より前に見る。期限切れなら一時フォルダにも何も置かず、そのまま終わる。
    if is_onetime_expired() {
        notify_onetime_expired();
        return;
    }
    let mut args = Vec::new();
    let mut arg_exe = Default::default();
    let mut i = 0;
    for arg in std::env::args() {
        if i == 0 {
            arg_exe = arg.clone();
        } else {
            args.push(arg);
        }
        i += 1;
    }
    let click_setup = args.is_empty() && arg_exe.to_lowercase().ends_with("install.exe");
    #[cfg(windows)]
    let quick_support = args.is_empty() && win::is_quick_support_exe(&arg_exe);
    #[cfg(not(windows))]
    let quick_support = false;

    let mut ui = false;
    let reader = BinaryReader::default();
    if let Some(exe) = setup(
        reader,
        None,
        click_setup || args.contains(&"--silent-install".to_owned()),
        &args,
        &mut ui,
    ) {
        if click_setup {
            args = vec!["--install".to_owned()];
        } else if quick_support {
            args = vec!["--quick_support".to_owned()];
        }
        execute(exe, args, ui);
    }
}

#[cfg(windows)]
mod win {
    use std::{fs, os::windows::process::CommandExt, path::Path, process::Command};

    // Used for privacy mode(magnifier impl).
    pub const RUNTIME_BROKER_EXE: &'static str = "C:\\Windows\\System32\\RuntimeBroker.exe";
    pub const WIN_TOPMOST_INJECTED_PROCESS_EXE: &'static str = "RuntimeBroker_rustdesk.exe";

    pub(super) fn copy_runtime_broker(dir: &Path) {
        let src = RUNTIME_BROKER_EXE;
        let tgt = WIN_TOPMOST_INJECTED_PROCESS_EXE;
        let target_file = dir.join(tgt);
        if target_file.exists() {
            if let (Ok(src_file), Ok(tgt_file)) = (fs::read(src), fs::read(&target_file)) {
                let src_md5 = format!("{:x}", md5::compute(&src_file));
                let tgt_md5 = format!("{:x}", md5::compute(&tgt_file));
                if src_md5 == tgt_md5 {
                    return;
                }
            }
        }
        let _allow_err = Command::new("taskkill")
            .args(&["/F", "/IM", "RuntimeBroker_rustdesk.exe"])
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .output();
        let _allow_err = std::fs::copy(src, &format!("{}\\{}", dir.to_string_lossy(), tgt));
    }

    /// Check if the executable is a Quick Support version.
    /// Note: This function must be kept in sync with `src/core_main.rs`.
    #[inline]
    pub(super) fn is_quick_support_exe(exe: &str) -> bool {
        let exe = exe.to_lowercase();
        exe.contains("-qs-") || exe.contains("-qs.exe") || exe.contains("_qs.exe")
    }
}
