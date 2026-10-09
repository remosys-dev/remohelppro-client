fn main() {
    #[cfg(windows)]
    {
        // 🔴 互換性アシスタントを止めるため manifest を埋め込む（2026-10-10）。
        //   ⚠ これを変えたらバイナリが変わる＝**再署名が要る**。
        println!("cargo:rerun-if-changed=logcollect.manifest");
        println!("cargo:rerun-if-changed=Cargo.toml");
        let mut res = winres::WindowsResource::new();
        res.set("ProductName", "REMOHELP PRO")
            .set("FileDescription", "REMOHELP PRO ログ集め")
            .set("CompanyName", "株式会社リモシス")
            .set("LegalCopyright", "Copyright © 2026 Remosys Inc. All rights reserved.")
            .set("OriginalFilename", "remohelppro-logs.exe")
            .set_manifest_file("logcollect.manifest");
        if let Err(e) = res.compile() {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
