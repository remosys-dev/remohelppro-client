fn main() {
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
