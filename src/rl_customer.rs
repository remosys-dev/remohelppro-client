// 32ビット版 Windows のお客様用（2026-10-29 社長「32ビットにも対応したい。RemoHelp はどちらも入れる」）。
//
// 🔴 なぜ別に要るか
//   お客様用アプリの画面は Flutter で、Flutter は 32ビットの Windows に対応していない。
//   32ビット版は RustDesk の古い画面（sciter）で組み立てる。番号でつなぐ手順は
//   これまで Dart（flutter/lib/remohelppro_pairing.dart）にしか無かったので、
//   **同じサーバーの口を同じ順に叩く**ものをここに書く。
//
//   ① 番号の確認  … ダウンロードしたファイル名の合鍵（RL_PAIR_DL_TOKEN）→ pair-init
//                    無ければ 6桁の手入力 → verify-pin
//   ② 接続の許可  … 接続番号の登録を待つ → grant-control → 受け取った合言葉を自分のパスワードにする
//   ③ 見張り      … 4秒ごとに session-status。active=false なら終わる
//   ④ 終わり      … 全接続を閉じ、合言葉を潰し、session-end を知らせる
//
// ⚠ 32ビット版でできるのは遠隔操作だけ（画面共有・カメラはブラウザで使う物なので、ここでは断る）。
// ⚠ 窓（src/ui/customer.tis）は state() を 0.5秒ごとに読むだけ。処理はすべてこちらの1本の糸で行う。

use hbb_common::{config, log};
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::Duration;

#[derive(Clone, Default, serde_derive::Serialize)]
pub struct State {
    /// input（番号を入れる）/ working（つないでいる）/ connected / ended / error
    pub phase: String,
    pub message: String,
    pub support_name: String,
    pub support_tel: String,
    pub operator: String,
    /// 接続した時刻（UNIX 秒）。窓が経過時間を出す
    pub connected_at: i64,
    #[serde(skip)]
    short_id: String,
    #[serde(skip)]
    cust_token: String,
}

lazy_static::lazy_static! {
    static ref STATE: Mutex<State> = Mutex::new(State { phase: "input".to_owned(), ..Default::default() });
    static ref BUSY: Mutex<bool> = Mutex::new(false);
}

/// 32ビット版のお客様用として組み立てたか（ワークフローが RL_SCITER_CUSTOMER を焼き込む）
pub fn is_customer_build() -> bool {
    option_env!("RL_SCITER_CUSTOMER").map_or(false, |v| v == "1")
}

/// 窓に出す文（日本語）。
/// 🔴 日本語は customer.tis に書かない（2026-10-29 真っ白になった）。
///   sciter はページを Shift_JIS として読み、「。」で終わるコメント行が次の行を巻き込んで
///   スクリプトが壊れた（ERROR:TIS bad syntax）。Rust から渡す文字は正しく出る（窓の題名と同じ）。
pub fn texts_json() -> String {
    json!({
        "title": "遠隔サポート",
        "title_connected": "遠隔サポート中",
        "title_ended": "サポートは終了しました",
        "prompt": "担当者からお伝えした6桁の認証コードを入力してください。",
        "go": "接続する",
        "safe_input": "認証コードを入れて「接続する」を押すまで、誰もお客様のパソコンに接続できません。",
        "connecting": "接続しています…",
        "connected": "担当者と接続しています",
        "elapsed": "経過時間",
        "end": "接続を終了する",
        "safe_connected": "「接続を終了する」を押すと、すぐに誰も接続できなくなります。",
        "ended_note": "もう誰もお客様のパソコンに接続できません。",
        "dest": "接続先",
        "tel": "電話番号",
        "operator": "担当者",
    })
    .to_string()
}

pub fn state_json() -> String {
    serde_json::to_string(&*STATE.lock().unwrap()).unwrap_or_default()
}

fn set_phase(phase: &str, message: &str) {
    let mut s = STATE.lock().unwrap();
    s.phase = phase.to_owned();
    s.message = message.to_owned();
}

fn api(path: &str) -> String {
    format!("{}{}", config::AGENT_API_BASE, path)
}

fn client() -> Option<reqwest::blocking::Client> {
    reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .ok()
}

fn read_contact(j: &Value) {
    let mut s = STATE.lock().unwrap();
    if let Some(c) = j.get("supportContact") {
        let n = c.get("name").and_then(|v| v.as_str()).unwrap_or("").trim();
        let t = c.get("tel").and_then(|v| v.as_str()).unwrap_or("").trim();
        // ⚠ 社名だけは出さない（偽物でも名乗れる。番号があって初めて照合できる・Dart と同じ）
        if !n.is_empty() && !t.is_empty() {
            s.support_name = n.to_owned();
            s.support_tel = t.to_owned();
        }
    }
    let op = j
        .get("operator")
        .and_then(|o| o.get("name"))
        .or_else(|| j.get("operatorName"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim();
    if !op.is_empty() && op != "担当者" {
        s.operator = op.to_owned();
    }
}

/// 起動したとき。ファイル名の合鍵があれば、番号の入力なしで始める。
pub fn auto_start() {
    let tok = std::env::var("RL_PAIR_DL_TOKEN").unwrap_or_default();
    if !tok.trim().is_empty() {
        start(String::new());
    }
}

/// 「接続する」。code が空ならファイル名の合鍵で始める。
pub fn start(code: String) {
    {
        let mut b = BUSY.lock().unwrap();
        if *b {
            return;
        }
        *b = true;
    }
    set_phase("working", "接続の準備をしています…");
    std::thread::spawn(move || {
        if let Err(msg) = run(code) {
            log::warn!("rl_customer: {}", msg);
            set_phase("error", &msg);
        }
        *BUSY.lock().unwrap() = false;
    });
}

fn run(code: String) -> Result<(), String> {
    let c = client().ok_or("通信の準備ができませんでした。もう一度お試しください。")?;
    let pin: String = code.chars().filter(|ch| ch.is_ascii_digit()).collect();

    // ① 番号の確認
    let (short_id, mode, j) = if pin.is_empty() {
        let tok = std::env::var("RL_PAIR_DL_TOKEN").unwrap_or_default();
        let r = c
            .post(api("/api/customer/pair-init"))
            .json(&json!({ "dlToken": tok.trim() }))
            .send()
            .map_err(|_| "通信できませんでした。回線をご確認ください。".to_owned())?;
        if !r.status().is_success() {
            // 使用済み・期限切れ → 手入力へ（壊さない・Dart と同じ）
            set_phase("input", "");
            return Ok(());
        }
        let j: Value = r.json().map_err(|_| "応答を読めませんでした。".to_owned())?;
        let sid = j["shortId"].as_str().unwrap_or("").to_owned();
        (sid, "pending_control".to_owned(), j)
    } else {
        if pin.len() != 6 {
            return Err("6桁の認証コードを入力してください。".to_owned());
        }
        let r = c
            .post(api("/api/customer/verify-pin"))
            .json(&json!({ "pin": pin }))
            .send()
            .map_err(|_| "通信できませんでした。回線をご確認ください。".to_owned())?;
        if !r.status().is_success() {
            return Err("認証コードが違うか、有効期限が切れています。".to_owned());
        }
        let j: Value = r.json().map_err(|_| "応答を読めませんでした。".to_owned())?;
        let sid = j["shortId"].as_str().unwrap_or("").to_owned();
        let mode = j["mode"].as_str().unwrap_or("view_only").to_owned();
        (sid, mode, j)
    };
    if short_id.is_empty() {
        return Err("応答を読めませんでした。もう一度お試しください。".to_owned());
    }
    if mode == "camera" {
        return Err("このコードはブラウザでご利用ください。担当者にお尋ねください。".to_owned());
    }
    let view_only = mode == "view_only";
    {
        let mut s = STATE.lock().unwrap();
        s.short_id = short_id.clone();
        s.cust_token = j["customerToken"].as_str().unwrap_or("").to_owned();
    }
    read_contact(&j);

    // 見るだけの番号では、キーボード等を許さない（Dart の view_only と同じ）
    let yn = if view_only { "N" } else { "Y" };
    for k in [
        "enable-keyboard",
        "enable-clipboard",
        "enable-file-transfer",
        "enable-file-copy-paste",
        "enable-tunnel",
        "enable-remote-printer",
    ] {
        crate::ui_interface::set_option(k.to_owned(), yn.to_owned());
    }

    // ② 接続番号の登録を待つ（最大60秒）
    crate::ui_interface::start_option_status_sync();
    set_phase("working", "接続の準備をしています…（少しお待ちください）");
    let mut my_id = String::new();
    for _ in 0..120 {
        let st = crate::ui_interface::get_connect_status();
        let id = crate::ipc::get_id(); // ⚠ ui_interface::get_id は flutter 用だけ
        if st.status_num == 1 && !id.is_empty() {
            my_id = id;
            break;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    if my_id.is_empty() {
        return Err("接続の準備に時間がかかっています。回線をご確認のうえ、もう一度お試しください。".to_owned());
    }

    let token = STATE.lock().unwrap().cust_token.clone();
    let mut req = c.post(api("/api/remote/grant-control")).json(&json!({
        "shortId": short_id,
        "rustdeskId": my_id,
        "viewOnly": view_only,
    }));
    if !token.is_empty() {
        req = req.header("x-customer-token", token);
    }
    let r = req
        .send()
        .map_err(|_| "通信できませんでした。回線をご確認ください。".to_owned())?;
    if !r.status().is_success() {
        return Err(format!("接続の準備に失敗しました（{}）。", r.status().as_u16()));
    }
    let g: Value = r.json().map_err(|_| "応答を読めませんでした。".to_owned())?;
    let onetime = g["onetimeToken"].as_str().unwrap_or("").to_owned();
    if onetime.is_empty() {
        return Err("接続の準備に失敗しました。".to_owned());
    }
    // ⚠ 書けなかったら成立させない。相談員が「パスワードが間違っています」で弾かれる
    let mut ok = false;
    for _ in 0..6 {
        if crate::ui_interface::set_permanent_password_with_result(onetime.clone()) {
            ok = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(700));
    }
    if !ok {
        return Err("接続の準備ができませんでした。このアプリを閉じて、開き直してください。".to_owned());
    }

    {
        let mut s = STATE.lock().unwrap();
        s.phase = "connected".to_owned();
        s.message = String::new();
        s.connected_at = hbb_common::get_time() / 1000;
    }

    // ③ 見張り。相談員が終えたら、こちらも終わる
    let mut errors = 0;
    loop {
        std::thread::sleep(Duration::from_secs(4));
        if STATE.lock().unwrap().phase != "connected" {
            return Ok(());
        }
        match c
            .get(api(&format!("/api/customer/session-status?shortId={}", short_id)))
            .send()
        {
            Ok(r) if r.status().is_success() => {
                errors = 0;
                if let Ok(j) = r.json::<Value>() {
                    if j["active"] == Value::Bool(false) {
                        finish(false, "サポートは終了しました。この画面は閉じていただいて大丈夫です。");
                        return Ok(());
                    }
                }
            }
            // ⚠ 一時的な通信の失敗では終わらない（回線が揺れただけで切ると、対応中に落ちる）
            _ => errors += 1,
        }
        if errors > 0 && errors % 15 == 0 {
            log::warn!("rl_customer: 見張りの失敗が続いています（{}回）", errors);
        }
    }
}

/// お客様が「終了」を押した。
pub fn end_by_customer() {
    finish(true, "接続を終了しました。この画面は閉じていただいて大丈夫です。");
}

/// 終わりの片付け。⚠ 二度目は何もしない。
fn finish(notify: bool, message: &str) {
    let (short_id, token) = {
        let mut s = STATE.lock().unwrap();
        if s.phase == "ended" {
            return;
        }
        s.phase = "ended".to_owned();
        s.message = message.to_owned();
        (s.short_id.clone(), s.cust_token.clone())
    };
    // 全接続を閉じる → 合言葉を潰す（もう誰も入れない）
    crate::server::CLIENT_SERVER
        .write()
        .unwrap()
        .close_connections_with_reason("お客様が接続を終了しました");
    let rnd = format!("end-{}", hbb_common::get_time());
    crate::ui_interface::set_permanent_password_with_result(rnd);
    if notify && !short_id.is_empty() {
        std::thread::spawn(move || {
            if let Some(c) = client() {
                let mut req = c
                    .post(api("/api/customer/session-end"))
                    .json(&json!({ "shortId": short_id }));
                if !token.is_empty() {
                    req = req.header("x-customer-token", token);
                }
                let _ = req.send();
            }
        });
    }
}

/// 窓を閉じるとき。接続中なら終了を知らせてから閉じる（置き去りにしない）。
pub fn on_close() {
    if STATE.lock().unwrap().phase == "connected" {
        end_by_customer();
        std::thread::sleep(Duration::from_millis(1500));
    }
}
