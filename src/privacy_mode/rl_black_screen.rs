// REMOHELP PRO: プライバシーモード（当社方式）。
//
// 🔴🔴 なぜ自前で作るか（2026-08-26 ご判断）
//
//   RustDesk の方式は `CreateWindowInBand`（Windows の**非公開API**）で
//   最前面の特別な層に黒い窓を出す。UAC の画面より上にも被せるためだが、
//   その層を使うには「**Microsoft 署名の実行ファイル**が**保護された場所**
//   （System32 等）から動いている」必要がある。
//   そのために Windows 標準の RuntimeBroker.exe をコピーして使う作りだが、
//   ⚠ コピー先は当社アプリのフォルダで、保護された場所ではない。
//     ＝ コピーした時点で条件を外れ、窓が作られない。
//     実機で「Failed to get hwnd after started」として失敗し続けた。
//     当社が DLL に署名しても、Microsoft の署名にはならないので変わらない。
//
// ★こちらは**公開された正規のAPI**だけで作る。
//   `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` は Windows 10 2004
//   以降の正式なAPIで、Teams などが自分の窓を画面共有から隠すのに使っている。
//
//     当社アプリが 真っ黒な最前面の窓 を画面いっぱいに出す
//        ＋ その窓を「画面キャプチャから除外」に設定する
//            → お客様の目には真っ黒
//            → 相談員の画面には普通に映る（除外されているので写らない）
//
// ⚠ **できないこと**：UAC（「変更を許可しますか」）の画面には被せられない。
//   あれは Windows が別の画面（セキュアデスクトップ）に出すので、
//   どのアプリからも覆えない。一瞬だけお客様に見える。
//   ＝ 非公開APIを使わないことと引き換えの、既知の制限。
//
// ⚠ 窓は**専用のスレッドが持つ**。窓を作ったスレッドしかメッセージを回せない
//   ため。表示/非表示は PostMessage で頼む（他スレッドから直に ShowWindow を
//   呼ばない）。

use super::{PrivacyMode, PrivacyModeState, INVALID_PRIVACY_MODE_CONN_ID};
use hbb_common::{allow_err, bail, log, ResultType};
use std::{
    sync::atomic::{AtomicIsize, Ordering},
    time::{Duration, Instant},
};
use winapi::{
    shared::{
        minwindef::{LPARAM, LRESULT, UINT, WPARAM},
        windef::HWND,
    },
    um::{
        libloaderapi::GetModuleHandleW,
        wingdi::{GetStockObject, BLACK_BRUSH},
        winuser::*,
    },
};

pub(super) const PRIVACY_MODE_IMPL: &str = super::PRIVACY_MODE_IMPL_RL_BLACK;

/// 窓の分類名。⚠ 他社製品とぶつからない名前にする。
const CLASS_NAME: &str = "RemohelpproPrivacyBlackScreen";

/// 表示/非表示を頼むための自前のメッセージ。
const WM_RL_SET_VISIBLE: UINT = WM_APP + 0x51;

/// 画面キャプチャから完全に除外する。
/// ⚠ winapi 0.3 の版によっては定数が無いので、こちらで持つ。
///   値は Windows SDK の winuser.h と同じ（0x00000011）。
const WDA_EXCLUDEFROMCAPTURE_: u32 = 0x0000_0011;


/// 作った窓。0 は「まだ無い」。
/// ⚠ HWND をそのまま静的に持てないので、数値で持って使うときに戻す。
static BLACK_HWND: AtomicIsize = AtomicIsize::new(0);

#[inline]
fn black_hwnd() -> HWND {
    BLACK_HWND.load(Ordering::SeqCst) as HWND
}

unsafe extern "system" fn wnd_proc(
    hwnd: HWND,
    msg: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_RL_SET_VISIBLE => {
            if wparam != 0 {
                // ⚠ 出すたびに位置と大きさを取り直す。お客様が画面を
                //   増やしたり解像度を変えたりしても、隙間ができないように。
                let (x, y, w, h) = virtual_screen();
                SetWindowPos(hwnd, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
                ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            } else {
                ShowWindow(hwnd, SW_HIDE);
            }
            0
        }
        // ⚠ 閉じる操作を受け付けない。お客様が Alt+F4 で外せてしまうと、
        //   「隠している」という約束が守れない。
        WM_CLOSE => 0,
        WM_DESTROY => {
            BLACK_HWND.store(0, Ordering::SeqCst);
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// 全部の画面を覆う範囲（左上と大きさ）。
fn virtual_screen() -> (i32, i32, i32, i32) {
    unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
        )
    }
}

fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 窓を持つ専用スレッドを立てる。
///
/// ⚠ 窓は作ったスレッドがメッセージを回し続けないと固まる。
///   だから作りっぱなしにせず、このスレッドが最後まで面倒を見る。
fn spawn_window_thread() {
    std::thread::spawn(|| unsafe {
        let class = to_wide(CLASS_NAME);
        let hinst = GetModuleHandleW(std::ptr::null());

        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            style: 0,
            lpfnWndProc: Some(wnd_proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hinst,
            hIcon: std::ptr::null_mut(),
            hCursor: LoadCursorW(std::ptr::null_mut(), IDC_ARROW),
            hbrBackground: GetStockObject(BLACK_BRUSH as i32) as _,
            lpszMenuName: std::ptr::null(),
            lpszClassName: class.as_ptr(),
            hIconSm: std::ptr::null_mut(),
        };
        // ⚠ 既に登録済みでも失敗するが、その場合はそのまま作れるので止めない。
        RegisterClassExW(&wc);

        // ⚠ 変数に持たせてから渡す。to_wide("").as_ptr() のように書くと、
        //   その場で捨てられた領域を指すことになる（動くこともあるので厄介）。
        let title = to_wide("");
        let (x, y, w, h) = virtual_screen();
        let hwnd = CreateWindowExW(
            // ⚠ NOACTIVATE … 出しても入力の焦点を奪わない。奪うと、相談員が
            //   操作している最中に文字が入らなくなる。
            // ⚠ TOOLWINDOW … Alt+Tab の一覧に出さない。
            //
            // 🔴🔴 TRANSPARENT … **クリックを素通りさせる**（2026-08-29 実機で判明）。
            //
            //   ⚠ ご報告:「プライバシーモードにすると顧客PCは真っ黒になるが、
            //     相談員はマウスは動くけどクリックができない」。
            //   ⚠ 正体: この窓は画面いっぱいの**最前面**にある。
            //     ＝ 相談員のクリックは、下のアプリではなく**この黒い窓が
            //       受け取っていた**。マウスの矢印は動くので、
            //       「動くのに押せない」という分かりにくい壊れ方になる。
            //   ⚠ `NOACTIVATE` は「焦点を奪わない」だけで、
            //     ⚠ **クリックを通す指定ではない**。ここを取り違えていた。
            //   ★`WS_EX_TRANSPARENT` を足す。当たり判定から外れ、
            //     クリックは下のアプリに届く。
            //   ⚠ `WS_EX_LAYERED` と対で使う。TRANSPARENT だけだと
            //     描画の扱いが変わり、黒く塗られないことがある。
            //     下で不透明度を 255（完全に不透明）に設定する。
            WS_EX_TOPMOST
                | WS_EX_TOOLWINDOW
                | WS_EX_NOACTIVATE
                | WS_EX_LAYERED
                | WS_EX_TRANSPARENT,
            class.as_ptr(),
            title.as_ptr(),
            WS_POPUP,
            x,
            y,
            w,
            h,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            hinst,
            std::ptr::null_mut(),
        );
        if hwnd.is_null() {
            log::error!("REMOHELP PRO: 黒い窓を作れませんでした");
            return;
        }

        // 🔴 これが肝。この窓だけを画面キャプチャから外す。
        //   ⚠ 失敗したら**窓を出してはいけない**。相談員の画面まで真っ黒になり、
        //     何も見えないまま操作することになる（お客様より危ない状態）。
        // 🔴 完全に不透明にする（2026-08-29）。
        //   ⚠ `WS_EX_LAYERED` を付けた窓は、不透明度を決めるまで
        //     **何も描かれない**ことがある。＝ お客様の画面が黒くならない。
        //   ★255 ＝ 透けない。クリックを通すのは `WS_EX_TRANSPARENT` の役目で、
        //     見た目の透明度とは**別の話**。ここを混同しないこと。
        if SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA) == 0 {
            log::error!("REMOHELP PRO: 黒い窓を不透明にできませんでした。使いません");
            DestroyWindow(hwnd);
            return;
        }

        if SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE_) == 0 {
            log::error!(
                "REMOHELP PRO: 画面キャプチャからの除外に失敗しました。黒い窓は使いません"
            );
            DestroyWindow(hwnd);
            return;
        }

        BLACK_HWND.store(hwnd as isize, Ordering::SeqCst);
        log::info!("REMOHELP PRO: プライバシーモードの窓を用意しました");

        let mut msg = std::mem::zeroed::<MSG>();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    });
}

/// 窓ができるまで待つ。⚠ 待てなければ諦める（黙って半端に進めない）。
fn ensure_window(timeout: Duration) -> ResultType<HWND> {
    if !black_hwnd().is_null() {
        return Ok(black_hwnd());
    }
    spawn_window_thread();
    let begin = Instant::now();
    loop {
        let hwnd = black_hwnd();
        if !hwnd.is_null() {
            return Ok(hwnd);
        }
        if begin.elapsed() > timeout {
            bail!("プライバシーモードの窓を用意できませんでした");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn set_visible(show: bool) -> ResultType<()> {
    let hwnd = ensure_window(Duration::from_secs(5))?;
    unsafe {
        PostMessageW(hwnd, WM_RL_SET_VISIBLE, if show { 1 } else { 0 }, 0);
    }
    Ok(())
}

pub struct PrivacyModeImpl {
    impl_key: String,
    conn_id: i32,
}

impl PrivacyModeImpl {
    pub fn new(impl_key: &str) -> Self {
        Self {
            impl_key: impl_key.to_owned(),
            conn_id: INVALID_PRIVACY_MODE_CONN_ID,
        }
    }
}

impl PrivacyMode for PrivacyModeImpl {
    fn is_async_privacy_mode(&self) -> bool {
        false
    }

    fn init(&self) -> ResultType<()> {
        Ok(())
    }

    fn clear(&mut self) {
        allow_err!(self.turn_off_privacy(self.conn_id, None));
    }

    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {
        if self.check_on_conn_id(conn_id)? {
            log::debug!("Privacy mode of conn {} is already on", conn_id);
            return Ok(true);
        }

        set_visible(true)?;

        // ⚠ お客様側の操作を止める。止めないと、真っ暗な画面のまま手探りで
        //   触られて、意図しない操作が起きる。
        //   ⚠ ただし**失敗しても続ける**。隠せているだけでも意味があるので、
        //     ここで諦めて真っ暗を解除する方が悪い。
        if let Err(e) = super::win_input::hook() {
            log::warn!("REMOHELP PRO: 入力の停止に失敗しました（表示は続けます）: {e}");
        }

        self.conn_id = conn_id;
        Ok(true)
    }

    fn turn_off_privacy(
        &mut self,
        conn_id: i32,
        state: Option<PrivacyModeState>,
    ) -> ResultType<()> {
        self.check_off_conn_id(conn_id)?;
        allow_err!(super::win_input::unhook());
        allow_err!(set_visible(false));

        if self.conn_id != INVALID_PRIVACY_MODE_CONN_ID {
            if let Some(state) = state {
                allow_err!(super::set_privacy_mode_state(
                    conn_id,
                    state,
                    PRIVACY_MODE_IMPL.to_string(),
                    1_000
                ));
            }
            self.conn_id = INVALID_PRIVACY_MODE_CONN_ID;
        }
        Ok(())
    }

    fn pre_conn_id(&self) -> i32 {
        self.conn_id
    }

    fn get_impl_key(&self) -> &str {
        &self.impl_key
    }
}

/// Windows 10 の 2004（ビルド19041）以降で使える。
/// ⚠ それより古いと除外できず、相談員の画面まで真っ黒になる。出さないこと。
pub(super) fn is_supported() -> bool {
    hbb_common::platform::windows::is_windows_version_or_greater(10, 0, 19041, 0, 0)
}
