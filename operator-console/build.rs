// 相談員の専用プログラムのアイコンと版情報（エクスプローラーのプロパティに出る）
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let mut res = winres::WindowsResource::new();
        res.set_icon("../res/icon.ico")
            .set("ProductName", "REMOHELP PRO Console")
            .set("FileDescription", "REMOHELP PRO Console")
            .set("CompanyName", "REMOHELP PRO");
        res.compile().expect("winres");
    }
}
