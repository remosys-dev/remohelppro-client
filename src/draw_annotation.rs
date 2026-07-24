// 画面注釈（双方向お絵かき）の DrawAction ↔ JSON 変換。
//
// 顧客側は connection.rs（通信）と CM プロセス（オーバーレイ表示）が IPC で分かれており、
// IPC は serde ベースなので protobuf 型をそのまま流せない。ここで JSON に落として運ぶ。
// 相談員側の Flutter へ渡すときも同じ形を使い、両側で表現を揃える。

use hbb_common::message_proto::*;
use serde_json::{json, Value};

/// DrawAction を JSON 文字列にする。
pub fn to_json(action: &DrawAction) -> String {
    let v = match &action.union {
        Some(draw_action::Union::Stroke(s)) => json!({
            "kind": "stroke",
            "xs": s.xs,
            "ys": s.ys,
            "color": s.color,
            "width": s.width,
            "display": s.display,
            "end": s.end,
        }),
        Some(draw_action::Union::Clear(_)) => json!({ "kind": "clear" }),
        Some(draw_action::Union::Enable(e)) => json!({ "kind": "enable", "enable": e }),
        None => json!({ "kind": "none" }),
    };
    v.to_string()
}

/// JSON 文字列から DrawAction を組み立てる。壊れていれば None。
pub fn from_json(s: &str) -> Option<DrawAction> {
    let v: Value = serde_json::from_str(s).ok()?;
    let kind = v.get("kind")?.as_str()?;
    let mut action = DrawAction::new();
    match kind {
        "stroke" => {
            let xs = num_array(v.get("xs")?)?;
            let ys = num_array(v.get("ys")?)?;
            // 点列が食い違っていると描画側で落ちるので、ここで弾く。
            if xs.len() != ys.len() || xs.is_empty() {
                return None;
            }
            action.set_stroke(DrawStroke {
                xs,
                ys,
                color: v.get("color").and_then(|x| x.as_u64()).unwrap_or(0xFFFF0000) as u32,
                width: v.get("width").and_then(|x| x.as_u64()).unwrap_or(4) as u32,
                display: v.get("display").and_then(|x| x.as_i64()).unwrap_or(0) as i32,
                end: v.get("end").and_then(|x| x.as_bool()).unwrap_or(false),
                ..Default::default()
            });
        }
        "clear" => action.set_clear(true),
        "enable" => action.set_enable(v.get("enable").and_then(|x| x.as_bool()).unwrap_or(false)),
        _ => return None,
    }
    Some(action)
}

fn num_array(v: &Value) -> Option<Vec<i32>> {
    let arr = v.as_array()?;
    // 極端に長い点列は送信側の間引き漏れなので、ここで切り捨てる（DoS 対策も兼ねる）。
    const MAX_POINTS: usize = 4096;
    if arr.len() > MAX_POINTS {
        return None;
    }
    arr.iter().map(|x| x.as_i64().map(|n| n as i32)).collect()
}
