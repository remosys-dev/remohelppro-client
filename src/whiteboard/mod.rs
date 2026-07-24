use serde_derive::{Deserialize, Serialize};

mod client;
mod server;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(any(target_os = "windows", target_os = "linux"))]
mod win_linux;

#[cfg(target_os = "windows")]
use windows::create_event_loop;
#[cfg(target_os = "macos")]
use macos::create_event_loop;
#[cfg(target_os = "linux")]
pub use linux::is_supported;

pub use client::*;
pub use server::*;

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "t", content = "c")]
pub enum CustomEvent {
    Cursor(Cursor),
    /// 画面注釈（お絵かき）のひと筆。カーソル表示と同じオーバーレイに重ねて描く。
    /// 描画側の `tiny_skia::Stroke` と紛らわしくないよう InkStroke と名付けている。
    Ink(InkStroke),
    /// 顧客が自分でも描けるようにする／やめる。
    /// true の間だけオーバーレイがクリックを受け取る（＝画面が操作できなくなる）ので、
    /// 呼ぶ側は必ず false に戻すこと。オーバーレイ側にも自動で戻す安全弁がある。
    SetDrawMode(bool),
    Clear,
    Exit,
}

/// 折れ線ひと筆。座標はこの端末の画面の実ピクセル。
#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "t")]
pub struct InkStroke {
    pub xs: Vec<f32>,
    pub ys: Vec<f32>,
    pub argb: u32,
    pub width: f32,
    /// ひと筆の終わり。false の間は同じ線の続きとして繋げる。
    pub end: bool,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(tag = "t")]
pub struct Cursor {
    pub x: f32,
    pub y: f32,
    pub argb: u32,
    pub btns: i32,
    pub text: String,
}
