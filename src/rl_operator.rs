// 32ビット版 Windows の相談員用（操作アプリ・ビュアー）。2026-10-30 社長「次は相談員の操作アプリの32ビット版を進めて」。
//
// 🔴 なぜ別に要るか
//   相談員の操作アプリは Flutter で、Flutter は 32ビットの Windows に対応していない。
//   32ビット版は sciter で組み立てる。遠隔操作の窓（remote.html）は元のものをそのまま使い、
//   コンソールの「接続」が送る remohelppro://<番号>?password=.. を ui::rl_uri_to_args で受ける。
//
// 🔴 元の画面（index.html）は出さない
//   rustdesk.com への案内などが入っている。相談員にも見せない（白ラベル）。
//   引数なしで開いたときは、インストールと案内だけの小さな窓（src/ui/operator.*）を出す。
//
// ⚠ 64ビットの Windows ではインストールしない。
//   同じアプリ名（remohelppro）なので、入れると今の64ビット版の上に重なって壊す。

use serde_json::json;

/// 32ビット版の相談員用として組み立てたか（ワークフローが RL_SCITER_OPERATOR を焼き込む）
pub fn is_operator_build() -> bool {
    option_env!("RL_SCITER_OPERATOR").map_or(false, |v| v == "1")
}

/// 32ビット版の常駐用として組み立てたか（ワークフローが RL_SCITER_RESIDENT を焼き込む・2026-10-30）。
/// 窓は相談員用と同じ operator.html を使い、文だけ替える。
/// ⚠ インストールは自己展開ランナーが自動で行う（常駐は RL_ALWAYS_INSTALL）。窓にはボタンを出さない。
pub fn is_resident_build() -> bool {
    option_env!("RL_SCITER_RESIDENT").map_or(false, |v| v == "1")
}

/// 64ビット版の Windows の上で動いているか（32ビットのプログラムが WOW64 で動いている）
pub fn is_64bit_windows() -> bool {
    #[cfg(target_arch = "x86")]
    {
        extern "system" {
            fn GetCurrentProcess() -> *mut std::ffi::c_void;
            fn IsWow64Process(h: *mut std::ffi::c_void, wow64: *mut i32) -> i32;
        }
        let mut w: i32 = 0;
        let ok = unsafe { IsWow64Process(GetCurrentProcess(), &mut w) };
        return ok != 0 && w != 0;
    }
    #[cfg(not(target_arch = "x86"))]
    true
}

/// 窓に出す文（日本語）。⚠ 日本語は operator.tis に書かない（sciter が Shift_JIS で読む・customer と同じ）
pub fn texts_json() -> String {
    if is_resident_build() {
        return json!({
            "title": "常駐プログラム（32ビット版）",
            "install_lead": "インストール用のファイルから入れてください。",
            "installing": "",
            "installed_lead": "常駐プログラムは動いています。",
            "how": "この PC は、担当者の管理画面から遠隔でサポートできる状態です。この窓は閉じてかまいません。",
            "os64": "この PC は64ビット版の Windows です。64ビット版の常駐プログラムをお使いください（この32ビット版はインストールしません）。",
            "close": "閉じる",
        })
        .to_string();
    }
    json!({
        "title": "REMOHELP PRO 相談員（32ビット版）",
        "install_lead": "この PC に、遠隔操作の画面を開くためのプログラムをインストールします。",
        "install_btn": "インストールする",
        "installing": "インストールしています…（確認の画面が出たら「はい」を押してください）",
        "installed_lead": "インストールされています。",
        "how": "相談員コンソールで「接続」を押すと、ここから遠隔操作の画面が開きます。この窓は閉じてかまいません。",
        "os64": "この PC は64ビット版の Windows です。64ビット版の操作アプリをお使いください（この32ビット版はインストールしません）。",
        "close": "閉じる",
    })
    .to_string()
}

pub fn state_json() -> String {
    json!({
        "installed": crate::platform::is_installed(),
        "os64": is_64bit_windows(),
        "version": crate::VERSION,
        // 常駐用はランナーが入れるので、窓からは入れない
        "can_install": !is_resident_build(),
    })
    .to_string()
}

/// インストール（管理者の確認が出る）。⚠ 64ビットの Windows では何もしない
pub fn install() {
    if is_64bit_windows() || is_resident_build() {
        return;
    }
    crate::ui_interface::install_me(
        "desktopicon startmenu".to_owned(),
        crate::ui_interface::install_path(),
        true,
        false,
    );
}
