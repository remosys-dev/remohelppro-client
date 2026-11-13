fn main() {
    #[cfg(windows)]
    {
        // 🔴 互換性アシスタントを止めるため manifest を埋め込む（2026-10-10）。
        //   🔴🔴 manifest の中は**英数字だけ**にする（2026-11-13・お客様のPCで起動せず）。
        //     ⚠ 中に日本語と絵文字の説明（<!-- -->）を書いていたら、Windows が
        //       「サイド バイ サイド構成が正しくない」（イベントログ: line 2. Invalid Xml syntax）
        //       で**起動自体を拒んでいた**。10/10 の配布から、どのPCでも起動していなかった。
        //     ★ 説明はこちら（build.rs）に書く。manifest の中身の意味：
        //       ・supportedOS … 互換性アシスタントの「正しく実行されなかった」を止める
        //       ・asInvoker … 起動時は昇格を求めない（必要な時だけ自分で昇格する）
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
