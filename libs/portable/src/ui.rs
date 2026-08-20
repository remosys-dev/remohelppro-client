use native_windows_gui as nwg;
use nwg::NativeUi;
use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, Ordering};

/// 「Loading...」の板を、もう閉じてよいかの合図。
///
/// 🔴🔴 この窓には**閉じる口が無かった**（2026-08-20 実機で確定）。
///   出したあと誰も閉じないので、お客様の画面に板が**永久に残り**、
///   本体の窓のボタンを覆っていた。
/// ★本体を起動したら `done()` を呼ぶ。板は次の描き替え（30ms）で消える。
static DONE: AtomicBool = AtomicBool::new(false);

/// 本体が立ち上がったので、板を閉じてよい。
pub fn done() {
    DONE.store(true, Ordering::Relaxed);
}

const GIF_DATA: &[u8] = include_bytes!("./res/spin.gif");
const LABEL_DATA: &[u8] = include_bytes!("./res/label.png");
const GIF_SIZE: i32 = 32;
const BG_COLOR: [u8; 3] = [90, 90, 120];
const BORDER_COLOR: [u8; 3] = [40, 40, 40];
const GIF_DELAY: u64 = 30;

#[derive(Default)]
pub struct BasicApp {
    window: nwg::Window,

    border_image: nwg::ImageFrame,
    bg_image: nwg::ImageFrame,
    gif_image: nwg::ImageFrame,
    label_image: nwg::ImageFrame,

    border_layout: nwg::GridLayout,
    bg_layout: nwg::GridLayout,
    inner_layout: nwg::GridLayout,

    timer: nwg::AnimationTimer,
    decoder: nwg::ImageDecoder,
    gif_index: RefCell<usize>,
    gif_images: RefCell<Vec<nwg::Bitmap>>,
}

impl BasicApp {
    fn exit(&self) {
        self.timer.stop();
        nwg::stop_thread_dispatch();
    }

    fn load_gif(&self) -> Result<(), nwg::NwgError> {
        let image_source = self.decoder.from_stream(GIF_DATA)?;
        for frame_index in 0..image_source.frame_count() {
            let image_data = image_source.frame(frame_index)?;
            let image_data = self
                .decoder
                .resize_image(&image_data, [GIF_SIZE as u32, GIF_SIZE as u32])?;
            let bmp = image_data.as_bitmap()?;
            self.gif_images.borrow_mut().push(bmp);
        }
        Ok(())
    }

    fn update_gif(&self) -> Result<(), nwg::NwgError> {
        let images = self.gif_images.borrow();
        if images.len() == 0 {
            return Err(nwg::NwgError::ImageDecoderError(
                -1,
                "no gif images".to_string(),
            ));
        }
        let image_index = *self.gif_index.borrow() % images.len();
        self.gif_image.set_bitmap(Some(&images[image_index]));
        *self.gif_index.borrow_mut() = (image_index + 1) % images.len();
        Ok(())
    }

    fn start_timer(&self) {
        self.timer.start();
    }
}

mod basic_app_ui {
    use super::*;
    use native_windows_gui::{self as nwg, Bitmap};
    use nwg::{Event, GridLayoutItem};
    use std::cell::RefCell;
    use std::ops::Deref;
    use std::rc::Rc;

    pub struct BasicAppUi {
        inner: Rc<BasicApp>,
        default_handler: RefCell<Vec<nwg::EventHandler>>,
    }

    impl nwg::NativeUi<BasicAppUi> for BasicApp {
        fn build_ui(mut data: BasicApp) -> Result<BasicAppUi, nwg::NwgError> {
            data.decoder = nwg::ImageDecoder::new()?;
            let col_cnt: i32 = 7;
            let row_cnt: i32 = 3;
            let border_width: i32 = 1;
            let window_size = (
                GIF_SIZE * col_cnt + 2 * border_width,
                GIF_SIZE * row_cnt + 2 * border_width,
            );

            // Controls
            nwg::Window::builder()
                .flags(nwg::WindowFlags::POPUP | nwg::WindowFlags::VISIBLE)
                .size(window_size)
                .center(true)
                .build(&mut data.window)?;

            nwg::ImageFrame::builder()
                .parent(&data.window)
                .size(window_size)
                .background_color(Some(BORDER_COLOR))
                .build(&mut data.border_image)?;

            nwg::ImageFrame::builder()
                .parent(&data.border_image)
                .size((row_cnt * GIF_SIZE, col_cnt * GIF_SIZE))
                .background_color(Some(BG_COLOR))
                .build(&mut data.bg_image)?;

            nwg::ImageFrame::builder()
                .parent(&data.bg_image)
                .size((GIF_SIZE, GIF_SIZE))
                .background_color(Some(BG_COLOR))
                .build(&mut data.gif_image)?;

            nwg::ImageFrame::builder()
                .parent(&data.bg_image)
                .background_color(Some(BG_COLOR))
                .bitmap(Some(&Bitmap::from_bin(LABEL_DATA)?))
                .build(&mut data.label_image)?;

            nwg::AnimationTimer::builder()
                .parent(&data.window)
                .interval(std::time::Duration::from_millis(GIF_DELAY))
                .build(&mut data.timer)?;

            // Wrap-up
            let ui = BasicAppUi {
                inner: Rc::new(data),
                default_handler: Default::default(),
            };

            // Layouts
            nwg::GridLayout::builder()
                .parent(&ui.window)
                .spacing(0)
                .margin([0, 0, 0, 0])
                .max_column(Some(1))
                .max_row(Some(1))
                .child_item(GridLayoutItem::new(&ui.border_image, 0, 0, 1, 1))
                .build(&ui.border_layout)?;

            nwg::GridLayout::builder()
                .parent(&ui.border_image)
                .spacing(0)
                .margin([
                    border_width as _,
                    border_width as _,
                    border_width as _,
                    border_width as _,
                ])
                .max_column(Some(1))
                .max_row(Some(1))
                .child_item(GridLayoutItem::new(&ui.bg_image, 0, 0, 1, 1))
                .build(&ui.bg_layout)?;

            nwg::GridLayout::builder()
                .parent(&ui.bg_image)
                .spacing(0)
                .margin([0, 0, 0, 0])
                .max_column(Some(col_cnt as _))
                .max_row(Some(row_cnt as _))
                .child_item(GridLayoutItem::new(&ui.gif_image, 2, 1, 1, 1))
                .child_item(GridLayoutItem::new(&ui.label_image, 3, 1, 3, 1))
                .build(&ui.inner_layout)?;

            // Events
            let evt_ui = Rc::downgrade(&ui.inner);
            let handle_events = move |evt, _evt_data, _handle| {
                if let Some(evt_ui) = evt_ui.upgrade().as_mut() {
                    match evt {
                        Event::OnWindowClose => {
                            evt_ui.exit();
                        }
                        Event::OnTimerTick => {
                            // 🔴🔴 本体が立ち上がったら、自分で閉じる（2026-08-20）。
                            //
                            //   ⚠ この窓には**閉じる口が存在しなかった**（上流から
                            //     引き継いだまま）。出したあと誰も閉じないので、
                            //     お客様の画面に「Loading...」の板が**永久に残る**。
                            //   ⚠ 板は本体の窓に重なり、下のボタンを覆う。
                            //     お客様は閉じ方が分からない。
                            //
                            //   ★子ウィンドウの管理（Flutter 側）とは**別物**。
                            //     そちらをいくら直しても、この板には届かない。
                            //     5回直して効かなかったのはこのため。
                            if DONE.load(Ordering::Relaxed) {
                                evt_ui.exit();
                                return;
                            }
                            if let Err(e) = evt_ui.update_gif() {
                                eprintln!("{:?}", e);
                            }
                        }
                        _ => {}
                    }
                }
            };

            ui.default_handler
                .borrow_mut()
                .push(nwg::full_bind_event_handler(
                    &ui.window.handle,
                    handle_events,
                ));

            return Ok(ui);
        }
    }

    impl Drop for BasicAppUi {
        /// To make sure that everything is freed without issues, the default handler must be unbound.
        fn drop(&mut self) {
            let mut handlers = self.default_handler.borrow_mut();
            for handler in handlers.drain(0..) {
                nwg::unbind_event_handler(&handler);
            }
        }
    }

    impl Deref for BasicAppUi {
        type Target = BasicApp;

        fn deref(&self) -> &BasicApp {
            &self.inner
        }
    }
}

fn ui() -> Result<(), nwg::NwgError> {
    nwg::init()?;
    let app = BasicApp::build_ui(Default::default())?;
    app.load_gif()?;
    app.start_timer();
    nwg::dispatch_thread_events();
    Ok(())
}

pub fn setup() {
    std::thread::spawn(move || {
        if let Err(e) = ui() {
            eprintln!("{:?}", e);
        }
    });
}
