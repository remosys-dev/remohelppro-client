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

fn execute(path: PathBuf, args: Vec<String>, _ui: bool) {
    println!("executing {}", path.display());
    // setup env
    let exe = std::env::current_exe().unwrap_or_default();
    let exe_name = exe.file_name().unwrap_or_default();
    // 2026-06-24: ワンタイム版の設定隔離先(展開dir)を子プロセスへ RL_APP_DIR で渡す。
    //   子(rustdesk.exe)の core_main がこれを APP_DIR に設定し、インストール版に触れない。
    let rl_app_dir = path.parent().map(|p| p.to_string_lossy().to_string());
    // RL build-16 (C): 内包EXEが REMOHELP PRO.exe ならワンタイムビルドと判定。
    //   CI(flutter-build.yml) が onetime 時のみ inner exe を REMOHELP PRO.exe にリネームする。
    //   フリートポータブルは inner=rustdesk.exe → false → 従来動作(即spawn・自己削除なし)。
    let is_onetime = path
        .file_name()
        .map(|n| n.to_str().unwrap_or("").eq_ignore_ascii_case("REMOHELP PRO.exe"))
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
