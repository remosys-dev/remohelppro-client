use super::{
    server::{Ripple, EVENT_PROXY},
    win_linux::{create_font_face, draw_text},
    Cursor, CustomEvent,
};
use hbb_common::{anyhow::anyhow, log, ResultType};
use softbuffer::{Context, Surface};
use std::{collections::HashMap, num::NonZeroU32, sync::Arc, time::Instant};
use tao::{
    dpi::{PhysicalPosition, PhysicalSize},
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    platform::windows::WindowBuilderExtWindows,
    window::WindowBuilder,
};
use tiny_skia::{Color, FillRule, Paint, PathBuilder, PixmapMut, Stroke, Transform};

/// 描画中／描画済みのひと筆。
struct InkLine {
    /// どの接続が描いたか（相談員が複数いる場合に線を混ぜないため）
    key: String,
    xs: Vec<f32>,
    ys: Vec<f32>,
    argb: u32,
    width: f32,
    /// ひと筆が終わったか
    done: bool,
    /// 最後に点が足された時刻（自動フェード用）
    born: Instant,
}

/// 線が消え始めるまでの時間と、消えきるまでの時間。
/// 指し示すための道具なので、消し忘れた線が残り続けないように既定で薄れて消える。
const INK_HOLD: std::time::Duration = std::time::Duration::from_secs(7);
const INK_FADE: std::time::Duration = std::time::Duration::from_millis(800);

/// 顧客の「自分も描く」を自動的に解除するまでの無操作時間。
/// クリック透過を切ったまま放置すると顧客が自分のPCを操作できなくなるための安全弁。
const PEN_IDLE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// 顧客が描いた点をメインプロセスへ返し、自分の画面にも即座に描く。
fn flush_pen(pen: &mut Vec<(f32, f32)>, key: Option<&str>, end: bool, inks: &mut Vec<InkLine>) {
    let Some(key) = key else {
        pen.clear();
        return;
    };
    if pen.is_empty() && !end {
        return;
    }
    let xs: Vec<f32> = pen.iter().map(|p| p.0).collect();
    let ys: Vec<f32> = pen.iter().map(|p| p.1).collect();

    // 自分の画面にもすぐ出す（相手を経由すると遅れて手書き感が損なわれる）。
    if !xs.is_empty() {
        match inks.last_mut() {
            Some(last) if !last.done && last.key == key => {
                last.xs.extend_from_slice(&xs);
                last.ys.extend_from_slice(&ys);
                last.done = end;
                last.born = Instant::now();
            }
            _ => inks.push(InkLine {
                key: key.to_string(),
                xs: xs.clone(),
                ys: ys.clone(),
                argb: CUSTOMER_INK_ARGB,
                width: 4.0,
                done: end,
                born: Instant::now(),
            }),
        }
    }

    let data = serde_json::json!({
        "kind": "stroke",
        "xs": xs.iter().map(|v| *v as i32).collect::<Vec<i32>>(),
        "ys": ys.iter().map(|v| *v as i32).collect::<Vec<i32>>(),
        "color": CUSTOMER_INK_ARGB,
        "width": 4,
        "display": 0,
        "end": end,
    })
    .to_string();
    super::server::send_back(key.to_string(), data);
    pen.clear();
}

/// 顧客が描く線の色（青）。相談員＝赤と区別できるようにする。
const CUSTOMER_INK_ARGB: u32 = 0xFF1971C2;

impl InkLine {
    /// 経過時間から不透明度（0.0-1.0）を返す。0.0 なら消してよい。
    fn opacity(&self) -> f32 {
        let elapsed = self.born.elapsed();
        if elapsed <= INK_HOLD {
            return 1.0;
        }
        let fading = elapsed - INK_HOLD;
        if fading >= INK_FADE {
            0.0
        } else {
            1.0 - fading.as_secs_f32() / INK_FADE.as_secs_f32()
        }
    }
}

pub(super) fn create_event_loop() -> ResultType<()> {
    let face = match create_font_face() {
        Ok(face) => Some(face),
        Err(err) => {
            log::error!("Failed to create font face: {}", err);
            None
        }
    };

    let event_loop = EventLoopBuilder::<(String, CustomEvent)>::with_user_event().build();
    let mut window_builder = WindowBuilder::new()
        .with_title("annotation overlay")
        .with_transparent(true)
        .with_always_on_top(true)
        .with_skip_taskbar(true)
        .with_decorations(false);

    let mut final_size = None;
    if let Ok((x, y, w, h)) = super::server::get_displays_rect() {
        if w > 0 && h > 0 {
            final_size = Some(PhysicalSize::new(w, h));
            window_builder = window_builder
                .with_position(PhysicalPosition::new(x, y))
                .with_inner_size(PhysicalSize::new(1, 1));
        } else {
            window_builder =
                window_builder.with_fullscreen(Some(tao::window::Fullscreen::Borderless(None)));
        }
    } else {
        window_builder =
            window_builder.with_fullscreen(Some(tao::window::Fullscreen::Borderless(None)));
    }

    let window = Arc::new(window_builder.build::<(String, CustomEvent)>(&event_loop)?);
    window.set_ignore_cursor_events(true)?;

    let context = Context::new(window.clone()).map_err(|e| {
        log::error!("Failed to create context: {}", e);
        anyhow!(e.to_string())
    })?;
    let mut surface = Surface::new(&context, window.clone()).map_err(|e| {
        log::error!("Failed to create surface: {}", e);
        anyhow!(e.to_string())
    })?;

    let proxy = event_loop.create_proxy();
    EVENT_PROXY.write().unwrap().replace(proxy);
    let _call_on_ret = crate::common::SimpleCallOnReturn {
        b: true,
        f: Box::new(move || {
            let _ = EVENT_PROXY.write().unwrap().take();
        }),
    };

    let mut ripples: Vec<Ripple> = Vec::new();
    let mut last_cursors: HashMap<String, Cursor> = HashMap::new();
    let mut inks: Vec<InkLine> = Vec::new();
    let mut resized = final_size.is_none();

    // 顧客が自分で描くモード。Some(key) の間だけクリック透過を切っている。
    let mut draw_mode: Option<String> = None;
    let mut pen: Vec<(f32, f32)> = Vec::new();
    let mut pen_down = false;
    let mut last_pen_activity = Instant::now();
    let mut last_pen_send = Instant::now();

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Poll;

        match event {
            Event::WindowEvent { event, .. } => match event {
                WindowEvent::CloseRequested => {
                    *control_flow = ControlFlow::Exit;
                }
                // 顧客が自分で描くモードのときだけマウスを拾う。
                // 普段はクリック透過なのでここには来ない。
                WindowEvent::CursorMoved { position, .. } if draw_mode.is_some() => {
                    if pen_down {
                        pen.push((position.x as f32, position.y as f32));
                        last_pen_activity = Instant::now();
                    }
                }
                WindowEvent::MouseInput { state, button, .. }
                    if draw_mode.is_some() && button == tao::event::MouseButton::Left =>
                {
                    match state {
                        tao::event::ElementState::Pressed => {
                            pen_down = true;
                            pen.clear();
                            last_pen_activity = Instant::now();
                        }
                        tao::event::ElementState::Released => {
                            pen_down = false;
                            flush_pen(&mut pen, draw_mode.as_deref(), true, &mut inks);
                            last_pen_activity = Instant::now();
                        }
                        _ => {}
                    }
                }
                _ => {}
            },
            Event::RedrawRequested(_) => {
                if !resized {
                    if let Some(size) = final_size.take() {
                        window.set_inner_size(size);
                    }
                    resized = true;
                    return;
                }

                let (width, height) = {
                    let size = window.inner_size();
                    (size.width, size.height)
                };

                let (Some(width), Some(height)) = (NonZeroU32::new(width), NonZeroU32::new(height))
                else {
                    return;
                };
                if let Err(e) = surface.resize(width, height) {
                    log::error!("Failed to resize surface: {}", e);
                    return;
                }

                let mut buffer = match surface.buffer_mut() {
                    Ok(buf) => buf,
                    Err(e) => {
                        log::error!("Failed to get buffer: {}", e);
                        return;
                    }
                };
                let Some(mut pixmap) = PixmapMut::from_bytes(
                    bytemuck::cast_slice_mut(&mut buffer),
                    width.get(),
                    height.get(),
                ) else {
                    log::error!("Failed to create pixmap from buffer");
                    return;
                };
                pixmap.fill(Color::TRANSPARENT);

                Ripple::retain_active(&mut ripples);
                for ripple in &ripples {
                    let (radius, alpha) = ripple.get_radius_alpha();

                    let mut ripple_paint = Paint::default();
                    // Note: The real color is bgra here.
                    ripple_paint.set_color_rgba8(64, 64, 255, (alpha * 128.0) as u8);
                    ripple_paint.anti_alias = true;

                    let mut ripple_pb = PathBuilder::new();
                    ripple_pb.push_circle(ripple.x, ripple.y, radius);
                    if let Some(path) = ripple_pb.finish() {
                        pixmap.fill_path(
                            &path,
                            &ripple_paint,
                            FillRule::Winding,
                            Transform::identity(),
                            None,
                        );
                    }
                }

                // 画面注釈（お絵かき）。カーソルより先に描いて、カーソルを前面に残す。
                inks.retain(|ink| ink.opacity() > 0.0);
                for ink in inks.iter() {
                    if ink.xs.len() < 2 {
                        continue;
                    }
                    let mut pb = PathBuilder::new();
                    pb.move_to(ink.xs[0], ink.ys[0]);
                    for i in 1..ink.xs.len() {
                        pb.line_to(ink.xs[i], ink.ys[i]);
                    }
                    if let Some(path) = pb.finish() {
                        let rgba = super::argb_to_rgba(ink.argb);
                        let alpha = (rgba.3 as f32 * ink.opacity()) as u8;
                        let mut paint = Paint::default();
                        // Note: The real color is bgra here.
                        paint.set_color_rgba8(rgba.2, rgba.1, rgba.0, alpha);
                        paint.anti_alias = true;
                        let mut stroke = Stroke::default();
                        stroke.width = ink.width;
                        stroke.line_cap = tiny_skia::LineCap::Round;
                        stroke.line_join = tiny_skia::LineJoin::Round;
                        pixmap.stroke_path(&path, &paint, &stroke, Transform::identity(), None);
                    }
                }

                for cursor in last_cursors.values() {
                    let (x, y) = (cursor.x, cursor.y);
                    let size = 1.5f32;

                    let mut pb = PathBuilder::new();
                    pb.move_to(x, y);
                    pb.line_to(x, y + 16.0 * size);
                    pb.line_to(x + 4.0 * size, y + 13.0 * size);
                    pb.line_to(x + 7.0 * size, y + 20.0 * size);
                    pb.line_to(x + 9.0 * size, y + 19.0 * size);
                    pb.line_to(x + 6.0 * size, y + 12.0 * size);
                    pb.line_to(x + 11.0 * size, y + 12.0 * size);
                    pb.close();

                    if let Some(path) = pb.finish() {
                        let rgba = super::argb_to_rgba(cursor.argb);
                        let mut arrow_paint = Paint::default();
                        // Note: The real color is bgra here.
                        arrow_paint.set_color_rgba8(rgba.2, rgba.1, rgba.0, rgba.3);
                        arrow_paint.anti_alias = true;
                        pixmap.fill_path(
                            &path,
                            &arrow_paint,
                            FillRule::Winding,
                            Transform::identity(),
                            None,
                        );

                        let mut black_paint = Paint::default();
                        black_paint.set_color_rgba8(0, 0, 0, 255);
                        black_paint.anti_alias = true;
                        let mut stroke = Stroke::default();
                        stroke.width = 1.0f32;
                        pixmap.stroke_path(
                            &path,
                            &black_paint,
                            &stroke,
                            Transform::identity(),
                            None,
                        );

                        face.as_ref().map(|face| {
                            draw_text(
                                &mut pixmap,
                                face,
                                &cursor.text,
                                x + 24.0 * size,
                                y + 24.0 * size,
                                &arrow_paint,
                                14.0f32,
                            );
                        });
                    }
                }

                if let Err(e) = buffer.present() {
                    log::error!("Failed to present surface: {}", e);
                    return;
                }
            }
            Event::MainEventsCleared => {
                if draw_mode.is_some() {
                    // 描いている途中の点を 16ms ごとに送る（毎秒60回が上限）。
                    if pen_down
                        && !pen.is_empty()
                        && last_pen_send.elapsed() >= std::time::Duration::from_millis(16)
                    {
                        flush_pen(&mut pen, draw_mode.as_deref(), false, &mut inks);
                        last_pen_send = Instant::now();
                    }
                    // 安全弁：一定時間なにも描かれなければ強制的にクリック透過へ戻す。
                    // ここを落とすと顧客のPCが操作不能のままになる。
                    if !pen_down && last_pen_activity.elapsed() >= PEN_IDLE_TIMEOUT {
                        draw_mode = None;
                        pen.clear();
                        let _ = window.set_ignore_cursor_events(true);
                        log::info!("annotation: draw mode auto-released");
                    }
                }
                window.request_redraw();
            }
            Event::UserEvent((k, evt)) => match evt {
                CustomEvent::Cursor(cursor) => {
                    if cursor.btns != 0 {
                        ripples.push(Ripple {
                            x: cursor.x,
                            y: cursor.y,
                            start_time: Instant::now(),
                        });
                    }
                    last_cursors.insert(k, cursor);
                }
                CustomEvent::Ink(ink) => {
                    // ひと筆の途中は直前の線に繋げ、end で確定させる。
                    // 送信側が間引いているので、ここでは受け取った点をそのまま積む。
                    match inks.last_mut() {
                        Some(last) if !last.done && last.key == k => {
                            last.xs.extend_from_slice(&ink.xs);
                            last.ys.extend_from_slice(&ink.ys);
                            last.done = ink.end;
                            last.born = Instant::now();
                        }
                        _ => inks.push(InkLine {
                            key: k,
                            xs: ink.xs,
                            ys: ink.ys,
                            argb: ink.argb,
                            width: ink.width.max(1.0),
                            done: ink.end,
                            born: Instant::now(),
                        }),
                    }
                }
                CustomEvent::SetDrawMode(on) => {
                    // クリック透過を切ると顧客は画面を操作できなくなる。
                    // 戻し損ねが致命的なので、下の MainEventsCleared に自動復帰を置いている。
                    if on {
                        draw_mode = Some(k);
                        last_pen_activity = Instant::now();
                        let _ = window.set_ignore_cursor_events(false);
                    } else {
                        draw_mode = None;
                        pen_down = false;
                        pen.clear();
                        let _ = window.set_ignore_cursor_events(true);
                    }
                }
                CustomEvent::Clear => {
                    inks.clear();
                }
                CustomEvent::Exit => {
                    *control_flow = ControlFlow::Exit;
                }
            },
            _ => (),
        }
    });
}
