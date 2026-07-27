fn main() {
    // ワンタイム版の有効期限（UNIX秒）。値が変わったら必ず作り直す。
    // これが無いと、CI が期限だけ変えたときにキャッシュされた古い実行ファイルが
    // そのまま使われ、期限が更新されないまま配布されてしまう。
    println!("cargo:rerun-if-env-changed=RL_ONETIME_EXPIRES_AT");
    // 🔴 焼き込めたかをビルドログに必ず残す。
    //   出来上がった exe を文字列検索しても確認できない（最適化で literal が消える）。
    //   「入れたつもりで入っていない」が起きても気づけないので、ここで宣言させる。
    match std::env::var("RL_ONETIME_EXPIRES_AT") {
        Ok(v) => println!("cargo:warning=RL: ワンタイム版の有効期限を焼き込みます (unix={v})"),
        Err(_) => println!(
            "cargo:warning=RL: ワンタイム版の有効期限なし（常駐版・相談員版・開発ビルドはこれで正常）"
        ),
    }
    #[cfg(windows)]
    {
        use std::io::Write;
        // Set version strings explicitly so the installer-wrapper exe properties
        // (Details tab) read "REMOHELP PRO", not "RustDesk". Cargo.toml-only winres
        // changes may not retrigger build.rs (winres only emits rerun-if-changed for
        // the icon/manifest), so touch build.rs + rerun-if-changed=Cargo.toml here.
        println!("cargo:rerun-if-changed=Cargo.toml");
        let mut res = winres::WindowsResource::new();
        res.set_icon("../../res/icon.ico")
            .set("ProductName", "REMOHELP PRO")
            .set("FileDescription", "REMOHELP PRO Remote Desktop")
            .set("CompanyName", "株式会社リモシス")
            .set("LegalCopyright", "Copyright © 2026 Remosys Inc. All rights reserved.")
            .set("OriginalFilename", "rustdesk.exe")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("../../res/manifest.xml");
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}
