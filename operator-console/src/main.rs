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
    event_loop::{ControlFlow, EventLoop, EventLoopBuilder},
    window::WindowBuilder,
};
use wry::{WebContext, WebViewBuilder};

mod update;

/// 入れ替えの手伝いから本体へ知らせる
enum UserEv {
    UpdateDone(Result<std::path::PathBuf, String>),
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

/// 新しい版を受け取って入れ替え、起動し直す（見本の「5 起動のとき」）。
/// ⚠ 失敗したら今の版のまま開き直す（--no-update を付けて、もう一度は確かめない）
fn run_update(event_loop: EventLoop<UserEv>, base: &str, dev: bool, to: String) {
    let window = WindowBuilder::new()
        .with_title(title(dev))
        .with_window_icon(app_icon())
        .with_inner_size(LogicalSize::new(420.0, 200.0))
        .with_resizable(false)
        .build(&event_loop);
    let webview = window
        .as_ref()
        .ok()
        .and_then(|w| WebViewBuilder::new(w).with_html(update::splash_html(env!("CARGO_PKG_VERSION"), &to)).build().ok());
    let proxy = event_loop.create_proxy();
    let b = base.to_owned();
    std::thread::spawn(move || {
        let r = update::download_and_swap(&b, !dev);
        let _ = proxy.send_event(UserEv::UpdateDone(r));
    });
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        let _keep = (&window, &webview);
        if let Event::UserEvent(UserEv::UpdateDone(r)) = event {
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
        // ⚠ 入れ替えの途中で閉じるボタンは効かせない（半端な状態にしない）
    });
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
        .join(if dev { "RemohelpproConsoleDev" } else { "RemohelpproConsole" })
        .join("webview");

    update::cleanup_old();
    let event_loop = EventLoopBuilder::<UserEv>::with_user_event().build();
    // 🔴 起動のたびに、まず新しい版を確かめる（3秒で諦めて今の版で開く）
    if !std::env::args().any(|a| a == "--no-update") {
        if let Some(to) = update::newer_version(base) {
            run_update(event_loop, base, dev, to);
            return;
        }
    }
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
            message(&format!("窓を開けませんでした。\n{e}"));
            return;
        }
    };

    let mut ctx = WebContext::new(Some(data));
    let base_nav = base.to_owned();
    let webview = WebViewBuilder::new(&window)
        .with_web_context(&mut ctx)
        .with_url(format!("{base}/console"))
        // ページに相談員プログラムの版を知らせる（ロゴの右に「相談員 1.0.x」と出す・確定見本）
        .with_initialization_script(&format!(
            "window.rlOperatorVersion = {:?};",
            env!("CARGO_PKG_VERSION")
        ))
        // 🔴 ビュアーの起動はページから直接受け取る（2026-10-30 実機で、remohelppro:// へのページ移動が
        //   Windows まで届かず、ビュアーが起動しなかった）。ページは window.ipc.postMessage("open:<URL>") を送る。
        //   ⚠ 受け付けるのは当社の操作アプリのスキームだけ（他の物を開かせない）。
        .with_ipc_handler(|req: wry::http::Request<String>| {
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
    let _webview = match webview {
        Ok(w) => w,
        Err(e) => {
            // ⚠ 古い Windows 10 で WebView2 が入っていないとここに来る
            message(&format!(
                "画面を表示する部品（Microsoft Edge WebView2）が見つかりませんでした。\n\
                 Microsoft のサイトから「WebView2 ランタイム」を入れてから、もう一度開いてください。\n\n{e}"
            ));
            open_external("https://developer.microsoft.com/microsoft-edge/webview2/");
            return;
        }
    };

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        if let Event::WindowEvent { event: WindowEvent::CloseRequested, .. } = event {
            *control_flow = ControlFlow::Exit;
        }
    });
}
