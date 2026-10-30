// 相談員の専用プログラムのアイコンと版情報（エクスプローラーのプロパティに出る）
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let mut res = winres::WindowsResource::new();
        res.set_icon("../res/icon.ico")
            .set("ProductName", "REMOHELP PRO")
            .set("FileDescription", "REMOHELP PRO 相談員プログラム")
            .set("OriginalFilename", "remohelppro-console.exe")
            .set("CompanyName", "REMOHELP PRO");
        res.compile().expect("winres");
    }
}
