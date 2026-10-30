// 相談員の専用プログラム（2026-10-29 社長「この相談員プログラム、専用に作れない？」）。
//
// 🔴 なぜ要るか
//   これまでは Edge を --app で開いていた（相談員プログラム-見本/相談員コンソール-開発機.cmd）。
//   専用にすると、アイコン1つでコンソールだけの窓が開き、起動時の更新もこちらで持てる。
//
// 🔴 作り
//   Windows に入っている WebView2（Edge の部品）で /console を出すだけの窓。Electron ではない（数MBで済む）。
//   ⚠ 32ビット用（i686）の1個で 32/64 どちらの Windows にも入る（社長と合意 2026-10-29）。
//
// ⚠ remohelppro:// （遠隔操作アプリの起動）は WebView2 の中では開けないので、Windows に渡す。
// ⚠ 当社のサーバー以外のページは、いつものブラウザで開く（この窓の中で他所を見せない）。
#![windows_subsystem = "windows"]

use tao::{
    dpi::LogicalSize,
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    window::WindowBuilder,
};
use wry::{WebContext, WebViewBuilder};

mod settings;
mod update;

/// 入れ替えの手伝いから本体へ知らせる
enum UserEv {
    /// 新しい版の確認が終わった（新しい版があればその版）
    Checked(Option<String>),
    UpdateDone(Result<std::path::PathBuf, String>),
    /// コンソールの「終了」（右下）
    Quit,
    /// つながったらタスクバーを点滅（⚙「音と点滅」）
    Flash,
    /// ⚙ のプロキシを保存したので開き直す
    Relaunch,
}

/// 窓の題名（2026-10-30 確定見本「REMOHELP PRO 相談員」）
fn title(dev: bool) -> &'static str {
    if dev { "REMOHELP PRO 相談員（試験用）" } else { "REMOHELP PRO 相談員" }
}

/// 窓の左上・タスクバーのアイコン（実行ファイルに入れたアイコンをそのまま使う）
fn app_icon() -> Option<tao::window::Icon> {
    use tao::platform::windows::IconExtWindows;
    tao::window::Icon::from_resource(1, None).ok()
}

/// 同じ引数で起動し直す（入れ替えの後・入れ替えに失敗した後）
fn relaunch(exe: &std::path::Path, no_update: bool) {
    let mut c = std::process::Command::new(exe);
    c.args(std::env::args().skip(1).filter(|a| a != "--no-update"));
    if no_update {
        c.arg("--no-update");
    }
    let _ = c.spawn();
}

const PROD: &str = "https://svr.remohelppro.jp";
const DEV: &str = "https://dev.remohelppro.jp";

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

fn message(text: &str) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONWARNING, MB_OK};
    let t = wide(text);
    let c = wide("REMOHELP PRO");
    unsafe { MessageBoxW(std::ptr::null_mut(), t.as_ptr(), c.as_ptr(), MB_OK | MB_ICONWARNING) };
}

/// いつものブラウザ・遠隔操作アプリなど、Windows に開いてもらう
fn open_external(url: &str) {
    use windows_sys::Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL};
    let op = wide("open");
    let u = wide(url);
    unsafe {
        ShellExecuteW(std::ptr::null_mut(), op.as_ptr(), u.as_ptr(), std::ptr::null(), std::ptr::null(), SW_SHOWNORMAL)
    };
}

fn main() {
    // 開発機向け：起動の引数 --dev か、ファイル名に dev を含む（例 remohelppro-console-dev.exe）
    let exe = std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_lowercase()))
        .unwrap_or_default();
    let dev = std::env::args().any(|a| a == "--dev") || exe.contains("dev");
    let base = if dev { DEV } else { PROD };

    // ログインを覚えておく場所（開発機と本番で分ける）
    let data = std::env::var("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir())
        .join(if dev { "RemohelpproConsoleDev" } else { "RemohelpproConsole" });

    update::cleanup_old();
    log(&data, &format!("start {} dev={dev}", env!("CARGO_PKG_VERSION")));
    // ⚙ のプロキシ（settings.rs）。⚠ WebView2 を作る前に渡す
    let proxy = settings::load_proxy(&data);
    if let Some(a) = proxy.webview_args() {
        std::env::set_var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", a);
    }
    let proxy_url = proxy.url();
    let event_loop = EventLoopBuilder::<UserEv>::with_user_event().build();
    // 🔴 窓はすぐ出す（2026-10-30 社長「起動しない」＝新しい版の確認の間、何も出ていなかった）。
    //   まず「起動しています…」を出し、確認は裏で行う。新しい版が無ければコンソールへ進む
    let window = match WindowBuilder::new()
        .with_title(title(dev))
        .with_window_icon(app_icon())
        // 🔴 今の RemoHelp と同じ外寸 1000×545（2026-10-30 社長の確定見本）。題名の帯の分を引いた中身の大きさ。
        //   ⚠ この大きさで札 12枚が 4列×3段で全部見える。小さくすると札が隠れるので、最小もページの最小に合わせる
        .with_inner_size(LogicalSize::new(1000.0, 514.0))
        .with_min_inner_size(LogicalSize::new(800.0, 500.0))
        .build(&event_loop)
    {
        Ok(w) => w,
        Err(e) => {
            log(&data, &format!("window error {e}"));
            message(&format!("窓を開けませんでした。
{e}"));
            return;
        }
    };

    let quit_proxy = event_loop.create_proxy();
    let data_ipc = data.clone();
    let mut ctx = WebContext::new(Some(data.join("webview")));
    let base_nav = base.to_owned();
    let webview = WebViewBuilder::new(&window)
        .with_web_context(&mut ctx)
        .with_html(update::splash_html(None))
        // ページに相談員プログラムの版を知らせる（ロゴの右に「相談員 1.0.x」と出す・確定見本）
        .with_initialization_script(&format!(
            "window.rlOperatorVersion = {:?};{}",
            env!("CARGO_PKG_VERSION"),
            settings::page_settings_js(&data, dev)
        ))
        // 🔴 ビュアーの起動はページから直接受け取る（2026-10-30 実機で、remohelppro:// へのページ移動が
        //   Windows まで届かず、ビュアーが起動しなかった）。ページは window.ipc.postMessage("open:<URL>") を送る。
        //   ⚠ 受け付けるのは当社の操作アプリのスキームだけ（他の物を開かせない）。
        .with_ipc_handler(move |req: wry::http::Request<String>| {
            // コンソール右下の「終了」＝相談員プログラムを終わる（10/30 社長・RemoHelp と同じ）
            let body = req.body();
            if body == "quit" {
                let _ = quit_proxy.send_event(UserEv::Quit);
                return;
            }
            if body == "flash" {
                let _ = quit_proxy.send_event(UserEv::Flash);
                return;
            }
            // ⚙ 設定（settings.rs）
            if let Some(v) = body.strip_prefix("set:autostart:") {
                settings::set_autostart(dev, v == "1");
                return;
            }
            if let Some(j) = body.strip_prefix("set:proxy:") {
                if settings::save_proxy(&data_ipc, j) {
                    let _ = quit_proxy.send_event(UserEv::Relaunch);
                }
                return;
            }
            if let Some(u) = req.body().strip_prefix("open:") {
                if u.starts_with("remohelppro://") || u.starts_with("remohelppro-dev://") {
                    open_external(u);
                }
            }
        })
        .with_navigation_handler(move |url: String| {
            if url.starts_with(&base_nav) || url.starts_with("about:") || url.starts_with("data:") {
                return true;
            }
            // 遠隔操作アプリの起動・他所のページ・電話/メールは Windows に渡す
            open_external(&url);
            false
        })
        .build();
    let webview = match webview {
        Ok(w) => w,
        Err(e) => {
            log(&data, &format!("webview error {e}"));
            // ⚠ 古い Windows 10 で WebView2 が入っていないとここに来る
            message(&format!(
                "画面を表示する部品（Microsoft Edge WebView2）が見つかりませんでした。
                 Microsoft のサイトから「WebView2 ランタイム」を入れてから、もう一度開いてください。

{e}"
            ));
            open_external("https://developer.microsoft.com/microsoft-edge/webview2/");
            return;
        }
    };
    log(&data, "window shown");

    // 新しい版の確認（裏で・3秒で諦める）
    let proxy = event_loop.create_proxy();
    let b = base.to_owned();
    let skip = std::env::args().any(|a| a == "--no-update");
    let purl = proxy_url.clone();
    std::thread::spawn(move || {
        let v = if skip { None } else { update::newer_version(&b, purl.as_deref()) };
        let _ = proxy.send_event(UserEv::Checked(v));
    });

    let console_url = format!("{base}/console");
    let base_owned = base.to_owned();
    let proxy2 = event_loop.create_proxy();
    let mut updating = false;
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        let _keep = &window;
        match event {
            Event::UserEvent(UserEv::Checked(None)) => {
                log(&data, "no update -> console");
                let _ = webview.load_url(&console_url);
            }
            Event::UserEvent(UserEv::Checked(Some(to))) => {
                log(&data, &format!("update -> {to}"));
                updating = true;
                let _ = webview.load_html(&update::splash_html(Some((env!("CARGO_PKG_VERSION"), &to))));
                let b = base_owned.clone();
                let p = proxy2.clone();
                let pu = proxy_url.clone();
                std::thread::spawn(move || {
                    let r = update::download_and_swap(&b, !dev, pu.as_deref());
                    let _ = p.send_event(UserEv::UpdateDone(r));
                });
            }
            Event::UserEvent(UserEv::UpdateDone(r)) => {
                log(&data, &format!("update done {:?}", r.as_ref().map(|_| ())));
                match r {
                    Ok(exe) => relaunch(&exe, false),
                    Err(_) => {
                        if let Ok(me) = std::env::current_exe() {
                            relaunch(&me, true);
                        }
                    }
                }
                *control_flow = ControlFlow::Exit;
            }
            Event::UserEvent(UserEv::Quit) if !updating => {
                *control_flow = ControlFlow::Exit;
            }
            Event::UserEvent(UserEv::Flash) => {
                use tao::platform::windows::WindowExtWindows;
                use windows_sys::Win32::UI::WindowsAndMessaging::{FlashWindowEx, FLASHWINFO, FLASHW_ALL, FLASHW_TIMERNOFG};
                let fi = FLASHWINFO {
                    cbSize: std::mem::size_of::<FLASHWINFO>() as u32,
                    hwnd: window.hwnd() as _,
                    dwFlags: FLASHW_ALL | FLASHW_TIMERNOFG,
                    uCount: 0,
                    dwTimeout: 0,
                };
                unsafe { FlashWindowEx(&fi) };
            }
            Event::UserEvent(UserEv::Relaunch) if !updating => {
                if let Ok(me) = std::env::current_exe() {
                    relaunch(&me, false);
                }
                *control_flow = ControlFlow::Exit;
            }
            // ⚠ 入れ替えの途中で閉じるボタンは効かせない（半端な状態にしない）
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } if !updating => {
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}

/// 起動の記録（どこで止まったか後から分かるように）。⚠ 個人の情報は書かない
fn log(dir: &std::path::Path, msg: &str) {
    use std::io::Write;
    let _ = std::fs::create_dir_all(dir);
    let p = dir.join("console.log");
    // 大きくなりすぎたら作り直す
    if std::fs::metadata(&p).map(|m| m.len() > 256 * 1024).unwrap_or(false) {
        let _ = std::fs::remove_file(&p);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&p) {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let _ = writeln!(f, "{t} {msg}");
    }
}
