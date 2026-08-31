#![windows_subsystem = "windows"]

use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use bin_reader::BinaryReader;

pub mod bin_reader;
#[cfg(windows)]
mod ui;

#[cfg(windows)]
const APP_METADATA: &[u8] = include_bytes!("../app_metadata.toml");
#[cfg(not(windows))]
const APP_METADATA: &[u8] = &[];
const APP_METADATA_CONFIG: &str = "meta.toml";
const META_LINE_PREFIX_TIMESTAMP: &str = "timestamp = ";
/// 展開先フォルダの名前。**ビルドの種類ごとに分ける**（2026-08-06）。
///
/// 🔴 これまでは全ビルドが `%LOCALAPPDATA%\rustdesk` を共有していた。
///    そのため、お客様がワンタイムで接続している最中に常駐を入れると:
///      ① 同じフォルダを丸ごと消しにいく（使用中なので途中で失敗し、しかも
///         その失敗は捨てられる＝**一部だけ消えた壊れた状態**が残る）
///      ② 使用中のファイルを上書きできない（この失敗も捨てられていた）
///      ③ それでも「成功」として、**古いままの実行ファイル**に --install を渡す
///      ④ 結果、常駐版ではなく**顧客版がインストールされる**
///    実機に、①の痕跡（DLLだけ18本残り data\ が消えた 96MB の残骸）が現存する。
///
/// ★場所を分ければ、①〜④は**構造的に起こり得なくなる**。
///
/// ⚠ 渡されなければ従来どおり `rustdesk`。開発ビルドは影響を受けない。
/// ⚠ `bin_reader.rs` と `generate.py` に出てくる `"rustdesk"` は**別物**
///   （データの区切り記号）。あれを一緒に変えると
///   `panic!("bin file is not valid!")` で起動しなくなる。
fn app_prefix() -> &'static str {
    option_env!("RL_APP_PREFIX").unwrap_or("rustdesk")
}

const APPNAME_RUNTIME_ENV_KEY: &str = "RUSTDESK_APPNAME";

/// ワンタイム版の有効期限（UNIX秒）。**CI がワンタイムのビルド時にだけ渡す**。
///
/// 🔴 目的（2026-07-27 実機テストの指摘）＝ お客様のPCに残った古いファイルを
///    ダブルクリックしても、**認証コードの画面すら出さない**ようにする。
///    自己削除は入れたが、それを取りこぼした場合・実行前に別の場所へ複製された
///    場合の**二段目の歯止め**として期限を焼き込む。
///
/// 埋まっていなければ期限なし＝常駐版・相談員版・開発ビルドは一切影響を受けない。
const ONETIME_EXPIRES_AT: Option<&str> = option_env!("RL_ONETIME_EXPIRES_AT");

/// 期限切れか。**判断がつかないときは false（＝起動させる）**。
///
/// ⚠ ここで迷って止めると、目の前で困っているお客様のサポートが始められない。
///    時計が読めない・値が壊れているといった不確かな場合は通す。
///    止めるのは「確実に期限を過ぎている」と言えるときだけにする。
fn is_onetime_expired() -> bool {
    let Some(raw) = ONETIME_EXPIRES_AT else {
        return false;
    };
    let Ok(expires_at) = raw.trim().parse::<u64>() else {
        return false;
    };
    if expires_at == 0 {
        return false;
    }
    let Ok(now) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) else {
        return false;
    };
    now.as_secs() > expires_at
}

/// 期限切れをお客様に伝える。ここで黙って終わると「押しても何も起きない」に
/// なってしまい、お客様が同じファイルを何度も押すことになる。
fn notify_onetime_expired() {
    let text = "このファイルは有効期限が切れています。\n\n\
                お手数ですが、担当者からご案内のページを開いて、\n\
                もう一度ダウンロードしてからお使いください。\n\n\
                （安全のため、サポート用のファイルは一定期間で使えなくなります）";
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        fn wide(s: &str) -> Vec<u16> {
            std::ffi::OsStr::new(s)
                .encode_wide()
                .chain(std::iter::once(0))
                .collect()
        }
        let body = wide(text);
        let title = wide("REMOHELP PRO");
        unsafe {
            winapi::um::winuser::MessageBoxW(
                std::ptr::null_mut(),
                body.as_ptr(),
                title.as_ptr(),
                winapi::um::winuser::MB_OK | winapi::um::winuser::MB_ICONWARNING,
            );
        }
    }
    #[cfg(not(windows))]
    eprintln!("{}", text);
}
#[cfg(windows)]
const SET_FOREGROUND_WINDOW_ENV_KEY: &str = "SET_FOREGROUND_WINDOW";

fn is_timestamp_matches(dir: &Path, ts: &mut u64) -> bool {
    let Ok(app_metadata) = std::str::from_utf8(APP_METADATA) else {
        return true;
    };
    for line in app_metadata.lines() {
        if line.starts_with(META_LINE_PREFIX_TIMESTAMP) {
            if let Ok(stored_ts) = line.replace(META_LINE_PREFIX_TIMESTAMP, "").parse::<u64>() {
                *ts = stored_ts;
                break;
            }
        }
    }
    if *ts == 0 {
        return true;
    }

    if let Ok(content) = std::fs::read_to_string(dir.join(APP_METADATA_CONFIG)) {
        for line in content.lines() {
            if line.starts_with(META_LINE_PREFIX_TIMESTAMP) {
                if let Ok(stored_ts) = line.replace(META_LINE_PREFIX_TIMESTAMP, "").parse::<u64>() {
                    return *ts == stored_ts;
                }
            }
        }
    }
    false
}

fn write_meta(dir: &Path, ts: u64) {
    let meta_file = dir.join(APP_METADATA_CONFIG);
    if ts != 0 {
        let content = format!("{}{}", META_LINE_PREFIX_TIMESTAMP, ts);
        // Ignore is ok here
        let _ = std::fs::write(meta_file, content);
    }
}

/// 展開に失敗したことをお客様に伝える。
///
/// 🔴 ここで黙って進むと「入れたのに何も起こらない」になる。実際そうなっていて、
///    原因に辿り着くまで3日かかった。**入らないなら、入らないと言う。**
#[cfg(windows)]
fn notify_extract_failed(detail: &str) {
    use std::os::windows::ffi::OsStrExt;
    fn wide(s: &str) -> Vec<u16> {
        std::ffi::OsStr::new(s)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }
    // ⚠ 文面は**ワンタイム（お客様）とインストールの両方**で出る（2026-08-27）。
    //   「インストール」と決め打ちしていたが、お客様が使い捨てのアプリを
    //   開いたときにも出るようになったので、どちらでも通じる言い方にする。
    //   ★お客様は電話をしながらこれを読む。**やることを先に、短く**書く。
    let text = format!(
        "準備ができませんでした。\n\n\
         必要なファイルを置けなかったため、中止しました。\n\
         このまま進めても、動かない状態になります。\n\n\
         次の順にお試しください。\n\
         ① REMOHELP PRO の画面をすべて閉じて、もう一度開く\n\
         ② それでも同じなら、パソコンを再起動してから開く\n\
         ③ それでも同じなら、担当者に下の情報をお伝えください\n\n\
         ―― 担当者にお伝えいただく情報 ――\n{}",
        detail
    );
    let body = wide(&text);
    let title = wide("REMOHELP PRO");
    unsafe {
        winapi::um::winuser::MessageBoxW(
            std::ptr::null_mut(),
            body.as_ptr(),
            title.as_ptr(),
            winapi::um::winuser::MB_OK | winapi::um::winuser::MB_ICONERROR,
        );
    }
}

/// `strict` = インストールとして起動された経路か。
///
/// 🔴 ここでの失敗の扱いは、経路によって**わざと変えている**（2026-08-06）:
///   - インストール経路 … 1つでも書けなければ**起動せず、理由を出して終わる**。
///       黙って古いものを入れるより、入らない方がまし。
///   - ワンタイム経路 … 記録に残して**続行**する。
///       ここで止めると、目の前で困っているお客様のサポートが始められない
///       （ユーザーの大原則「接続・終了は信頼に関わる」より）。
fn setup(
    reader: BinaryReader,
    dir: Option<PathBuf>,
    clear: bool,
    strict: bool,
    _args: &Vec<String>,
    _ui: &mut bool,
) -> Option<PathBuf> {
    let dir = if let Some(dir) = dir {
        dir
    } else {
        // home dir
        if let Some(dir) = dirs::data_local_dir() {
            // 🔴 旧・共有フォルダ（%LOCALAPPDATA%\rustdesk）は**ここでは消さない**。
            //
            //   一度は「置き土産を片付ける」処理を書いたが、取り下げた。
            //   移行の途中では、**旧フォルダから動いている古いアプリでお客様が
            //   サポートを受けている最中**ということが起こり得る。そこを消しにいけば、
            //   まさに今回直そうとしている事故（使用中のファイルを消して壊す）を
            //   自分で起こすことになる。
            //   残っても場所を取るだけなので、掃除は別途（専用の片付け手段）で行う。
            dir.join(app_prefix())
        } else {
            eprintln!("not found data local dir");
            return None;
        }
    };

    let mut ts = 0;
    if clear || !is_timestamp_matches(&dir, &mut ts) {
        #[cfg(windows)]
        if _args.is_empty() {
            *_ui = true;
            ui::setup();
        }
        std::fs::remove_dir_all(&dir).ok();
    }
    // 🔴🔴 書けなかったものは**一度だけやり直す**（2026-08-27 実顧客で発生）。
    //
    //   前のアプリがまだ動いていると、その部品を握ったままなので上書きできない。
    //   握りは数百ミリ秒で外れることが多いので、間を置いて1度だけ試す。
    //   ⚠ 何度も繰り返さない。起動が遅くなり、お客様を待たせる。
    let mut failed: Vec<String> = Vec::new();
    let mut failed_paths: Vec<String> = Vec::new();
    for file in reader.files.iter() {
        if let Err(e) = file.write_to_file(&dir) {
            eprintln!("RL: 展開に失敗（1回目）{} : {}", &file.path, e);
            std::thread::sleep(std::time::Duration::from_millis(1500));
            if let Err(e2) = file.write_to_file(&dir) {
                eprintln!("RL: 展開に失敗（やり直しも駄目）{} : {}", &file.path, e2);
                failed.push(format!("{} ({})", &file.path, e2));
                failed_paths.push(file.path.clone());
            }
        }
    }
    if !failed.is_empty() {
        // 何件失敗したかと、最初の3件だけ伝える（全部並べても読めない）
        let detail = format!(
            "展開先: {}\n失敗 {} 件:\n{}",
            dir.display(),
            failed.len(),
            failed
                .iter()
                .take(3)
                .map(|s| format!("  - {}", s))
                .collect::<Vec<_>>()
                .join("\n")
        );
        if strict {
            eprintln!("RL: インストールを中止します\n{}", detail);
            #[cfg(windows)]
            notify_extract_failed(&detail);
            return None;
        }
        // ワンタイム経路は続行する（理由は setup のコメント）
        // 🔴🔴 ワンタイムでも、**動かないと分かっているなら黙って進まない**
        //   （2026-08-27 実顧客・4台中1台で発生）。
        //
        //   ⚠ 実際に起きたこと: `librustdesk.dll` を書けないまま続行し、
        //     お客様の画面に Windows の
        //       「librustdesk.dll は Windows 上では実行できないか、エラーを含んでいます。
        //         エラー状態 0xc0e90002」
        //     という**意味の分からない窓**が出た。相談員も原因に辿り着けず、
        //     そのPCは以後まったく使えなくなった。
        //
        //   ★続行してよいのは「**無くても動くもの**」だけ。
        //     実行ファイル(.exe)と部品(.dll)が欠ければアプリは必ず落ちる。
        //     そのときは当社の言葉で理由と手順を出して**止める**。
        //   ⚠ 翻訳や画像が欠けただけならサポートは始められるので、
        //     従来どおり続行する（元の判断「目の前のお客様のサポートを
        //     始められない方が困る」をここで残す）。
        let fatal: Vec<&String> = failed_paths
            .iter()
            .filter(|p| {
                let lower = p.to_lowercase();
                lower.ends_with(".exe") || lower.ends_with(".dll")
            })
            .collect();
        if !fatal.is_empty() {
            let detail2 = format!(
                "{}\n\n動かせない部品: {}",
                detail,
                fatal
                    .iter()
                    .map(|s| s.as_str())
                    .take(3)
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            eprintln!("RL: 動かないので中止します\n{}", detail2);
            #[cfg(windows)]
            notify_extract_failed(&detail2);
            return None;
        }
        eprintln!("RL: 展開に失敗したが、動くので続行します\n{}", detail);
    }
    write_meta(&dir, ts);
    #[cfg(windows)]
    win::copy_runtime_broker(&dir);
    #[cfg(linux)]
    reader.configure_permission(&dir);
    Some(dir.join(&reader.exe))
}

fn use_null_stdio() -> bool {
    #[cfg(windows)]
    {
        // When running in CMD on Windows 7, using Stdio::inherit() with spawn returns an "invalid handle" error.
        // Since using Stdio::null() didn’t cause any issues, and determining whether the program is launched from CMD or by double-clicking would require calling more APIs during startup, we also use Stdio::null() when launched by double-clicking on Windows 7.
        let is_windows_7 = is_windows_7();
        println!("is windows7: {}", is_windows_7);
        return is_windows_7;
    }
    #[cfg(not(windows))]
    false
}

#[cfg(windows)]
fn is_windows_7() -> bool {
    use windows::Wdk::System::SystemServices::RtlGetVersion;
    use windows::Win32::System::SystemInformation::OSVERSIONINFOW;

    unsafe {
        let mut version_info = OSVERSIONINFOW::default();
        version_info.dwOSVersionInfoSize = std::mem::size_of::<OSVERSIONINFOW>() as u32;

        if RtlGetVersion(&mut version_info).is_ok() {
            // Windows 7 is version 6.1
            println!(
                "Windows version: {}.{}",
                version_info.dwMajorVersion, version_info.dwMinorVersion
            );
            return version_info.dwMajorVersion == 6 && version_info.dwMinorVersion == 1;
        }
    }
    false
}

/// 落としたファイルの名前に埋まっている「合言葉」を取り出す。
///
/// 経緯（2026-07-29 ユーザー要望）:
///   これまでお客様は、ページで認証コードを入れ、落としたアプリでも
///   **もう一度**同じコードを入れていた。他社は1回で済むため、乗り換えを
///   お願いする場面で不利だった。ページでコードを確認したブラウザが
///   一回限りの合言葉をファイル名に埋めて配るので、ここで読んで引き渡す。
///
/// 想定する名前:  remohelppro-start-<短ID>.<秘密>.exe
///
/// 🔴 同じ名前のファイルが既にあると、ブラウザが
///   「remohelppro-start-XXXXXX.abcdef (1).exe」のように末尾を変える。
///   **後から落とした方が新しい合言葉**なので、ここを読めないと
///   「2回目に落としたのに繋がらない」という一番起きやすい失敗になる。
///   末尾の「 (1)」は取り除いてから読む。
///
/// 🔴 読めないときは None を返して**黙って従来どおり**にする。
///   お客様の名前変更・別経路での入手など、読めない事情はいくらでもある。
///   ここで止めると「押しても何も起きない」になってしまう。
fn dl_token_from_exe_name(exe: &std::path::Path) -> Option<String> {
    const PREFIX: &str = "remohelppro-start-";
    let stem = exe.file_stem()?.to_string_lossy().to_string();
    // 「 (1)」「 (12)」などの重複回避サフィックスを外す。
    let stem = match stem.rfind(" (") {
        Some(i) if stem.ends_with(')') && stem[i + 2..stem.len() - 1].chars().all(|c| c.is_ascii_digit()) => {
            stem[..i].to_string()
        }
        _ => stem,
    };
    let rest = stem.strip_prefix(PREFIX)?;
    let (short_id, secret) = rest.split_once('.')?;
    // 形式だけ確かめる。正しさの判断はサーバーが行う（ここは通すだけ）。
    let short_ok = short_id.len() == 6
        && short_id
            .chars()
            .all(|c| c.is_ascii_digit() || (c.is_ascii_uppercase() && !"IOLU".contains(c)));
    let secret_ok = (6..=64).contains(&secret.len())
        && secret
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if short_ok && secret_ok {
        Some(format!("{short_id}.{secret}"))
    } else {
        None
    }
}

/// 常駐版の「会社の登録トークン」を、自分のファイル名から取り出す。
///
/// 配布サーバーは `remohelppro-resident-setup__t-<トークン>.exe` という名前で配る。
/// お客様がコマンドを打たずに済ませるための仕組み（名前なので署名は壊れない）。
///
/// 🔴 これが無く、**登録が一度も成立していなかった**（2026-07-31 実機指摘）。
///   本体側（agent.rs）は `current_exe()` の名前から探していたが、
///   常駐版は**自己展開**で配るため、実際に動くのは展開先の `remohelppro.exe`。
///   その名前に `__t-` は無いので、必ず空になっていた。
///   ＝ 端末が1台も登録されない。ダウンロードは成功するのに何も起きない。
///   ワンタイム版の合言葉と同じく、**ランナーが読んで環境変数で渡す**。
///
/// ブラウザが重複ダウンロードで付ける ` (1)` などは捨てる。
/// この自己展開ランナーは、名前に関係なく必ずインストールするか。
///
/// 常駐版のビルドのときだけ CI が `RL_ALWAYS_INSTALL=1` を焼き込む
/// （.github/workflows/flutter-build.yml、RL_APP_PREFIX と同じ場所）。
///
/// 🔴 常駐版の配布物は**インストーラ以外の使い道が無い**。
///   ならば、ファイル名がどう変わっていようとインストールへ進むのが正しい。
///   名前に頼る判定は、ブラウザ・お客様・通信のどれか一つで簡単に外れる。
/// ⚠ ワンタイム版・相談員版には焼き込まないこと。
///   焼き込むと、使い捨てのはずのアプリが居座る。
/// ⚠ 値そのものは比べない。**空でなければ真**。
///   比べる文字列をここに書くと、その文字列は焼き込みの有無に関わらず
///   実行ファイルの中に入ってしまい、grep で確かめても常に見つかる＝確認にならない。
///
/// 🔴 ただし「空かどうか」だけを見ると、**合言葉が実行ファイルから消える**
///   （2026-08-07 build-31 で実際に落とした）。
///   option_env! はコンパイル時の定数なので、`!x.is_empty()` は
///   その場で true に畳み込まれ、文字列そのものは誰も読まない＝捨てられる。
///   焼き込みは成功しているのに、CI の確認だけが失敗する。
///   ★値を**実際に使う**こと。下の println! が値を読むので、
///     文字列は実行ファイルに残り、grep で確かめられる。
///     入っていないときは分岐ごと消えるので、余計な物も残らない。
fn always_install() -> bool {
    let mark = option_env!("RL_ALWAYS_INSTALL").unwrap_or("");
    if mark.is_empty() {
        return false;
    }
    println!("RL: 常駐版なので、ファイル名に関わらずインストールします ({mark})");
    true
}

fn enroll_token_from_exe_name(exe: &std::path::Path) -> Option<String> {
    const MARK: &str = "__t-";
    let stem = exe.file_stem()?.to_string_lossy().to_string();
    let stem = match stem.rfind(" (") {
        Some(i)
            if stem.ends_with(')')
                && stem[i + 2..stem.len() - 1].chars().all(|c| c.is_ascii_digit()) =>
        {
            stem[..i].to_string()
        }
        _ => stem,
    };
    let pos = stem.find(MARK)?;
    let token: String = stem[pos + MARK.len()..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    // 形式だけ確かめる。正しさの判断はサーバーが行う。
    if (8..=64).contains(&token.len()) {
        Some(token)
    } else {
        None
    }
}

#[cfg(test)]
mod enroll_token_tests {
    use super::enroll_token_from_exe_name;
    use std::path::Path;

    fn t(name: &str) -> Option<String> {
        enroll_token_from_exe_name(Path::new(name))
    }

    #[test]
    fn takes_token_from_name() {
        assert_eq!(
            t("remohelppro-resident-setup__t-AbCd1234EfGh.exe"),
            Some("AbCd1234EfGh".to_string())
        );
    }

    #[test]
    fn ignores_browser_duplicate_suffix() {
        assert_eq!(
            t("remohelppro-resident-setup__t-AbCd1234EfGh (1).exe"),
            Some("AbCd1234EfGh".to_string())
        );
    }

    #[test]
    fn none_without_mark() {
        assert_eq!(t("remohelppro-resident-setup.exe"), None);
        assert_eq!(t("remohelppro.exe"), None);
    }

    #[test]
    fn none_when_too_short() {
        assert_eq!(t("remohelppro-resident-setup__t-abc.exe"), None);
    }
}

#[cfg(test)]
mod dl_token_tests {
    use super::dl_token_from_exe_name;
    use std::path::Path;

    fn t(name: &str) -> Option<String> {
        dl_token_from_exe_name(Path::new(name))
    }

    #[test]
    fn reads_plain_name() {
        assert_eq!(t("remohelppro-start-A3K9XZ.Ab_9-x.exe"), Some("A3K9XZ.Ab_9-x".into()));
    }

    #[test]
    fn reads_second_download() {
        // ブラウザが付ける重複回避サフィックス。ここが読めないと
        // 「2回目に落としたのに繋がらない」になる。
        assert_eq!(t("remohelppro-start-A3K9XZ.Ab_9-x (1).exe"), Some("A3K9XZ.Ab_9-x".into()));
        assert_eq!(t("remohelppro-start-A3K9XZ.Ab_9-x (12).exe"), Some("A3K9XZ.Ab_9-x".into()));
    }

    #[test]
    fn ignores_anything_else() {
        assert_eq!(t("remohelppro-customer.exe"), None);
        assert_eq!(t("remohelppro-support.exe"), None);
        // 短IDに紛らわしい文字(I/O/L/U)は使わない規則
        assert_eq!(t("remohelppro-start-AIK9XZ.Ab_9-x.exe"), None);
        // 桁数違い・秘密が短すぎる・区切り無し
        assert_eq!(t("remohelppro-start-A3K9X.Ab_9-x.exe"), None);
        assert_eq!(t("remohelppro-start-A3K9XZ.abc.exe"), None);
        assert_eq!(t("remohelppro-start-A3K9XZ.exe"), None);
        // 括弧が数字でない＝名前の一部なので外さない
        assert_eq!(t("remohelppro-start-A3K9XZ.Ab_9-x (copy).exe"), None);
    }
}

fn execute(path: PathBuf, args: Vec<String>, _ui: bool) {
    println!("executing {}", path.display());
    // setup env
    let exe = std::env::current_exe().unwrap_or_default();
    let exe_name = exe.file_name().unwrap_or_default();
    // 🔴🔴 再起動復帰の「控え」から起動されたときは、自分を消さない
    //   （2026-08-01 実機で判明。私が自己削除を直したことで壊した回帰）。
    //
    //   再起動をまたぐために、落としたファイルの複製を
    //   %LOCALAPPDATA%\REMOHELP PRO\resume\ に置き、RunOnce に登録している。
    //   再起動後はその**控えが起動される**ので、ここでいう「自分」は控えになる。
    //   自己削除をそのまま働かせると、控えが消える。
    //   顧客アプリ側は「同じ大きさなら作り直さない」判断なので複製もされず、
    //   結果 **2回目の再起動から、ログオンしても何も起動しない**。
    //
    //   1.4.23 まではこれが表に出なかった。自己削除そのものが動いていなかったため
    //   （cmd への引数の渡し方が壊れていた）。直したとたんに露出した。
    //
    //   ⚠ 控えを消すのは顧客アプリの clearRebootResume（サポート終了時）。
    //     ここで消さなくても残り続けない。
    let is_resume_copy = {
        let p = exe.to_string_lossy().to_lowercase();
        p.contains("\\remohelp pro\\resume\\") || p.contains("/remohelp pro/resume/")
    };
    // 2026-06-24: ワンタイム版の設定隔離先(展開dir)を子プロセスへ RL_APP_DIR で渡す。
    //   子(rustdesk.exe)の core_main がこれを APP_DIR に設定し、インストール版に触れない。
    let rl_app_dir = path.parent().map(|p| p.to_string_lossy().to_string());
    // 🔴 ワンタイム版かどうかは **同梱した目印ファイル** で判定する（2026-07-26 修正）。
    //
    //   元は内包EXEの名前が "REMOHELP PRO.exe" かどうかで見ていた。しかし CI は
    //   実際には "remohelppro.exe"（空白なし）へリネームしており、**一度も一致して
    //   いなかった**。＝ 自己削除がまったく動かず、お客様の PC に exe が残り、
    //   何度でもダブルクリックで起動できる状態だった（実機で指摘を受けた「使い回し」）。
    //
    //   ファイル名で判定すると、リネーム規則を変えた瞬間に静かに壊れる。
    //   しかも壊れても「消えないだけ」でエラーが出ないので気づけない。
    //   CI が置く目印ファイルの有無で判定すれば、名前を変えても影響しない。
    let is_onetime = path
        .parent()
        .map(|d| d.join(ONETIME_FLAG).exists())
        .unwrap_or(false);
    // run executable
    let mut cmd = Command::new(&path);
    cmd.args(args);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(winapi::um::winbase::CREATE_NO_WINDOW);
        if _ui {
            cmd.env(SET_FOREGROUND_WINDOW_ENV_KEY, "1");
        }
    }

    cmd.env(APPNAME_RUNTIME_ENV_KEY, exe_name);
    if let Some(ref d) = rl_app_dir {
        cmd.env("RL_APP_DIR", d);
    }
    // 🔴 自分（落としてきた1個のファイル）の場所をアプリへ伝える（2026-07-30 追加）。
    //   再起動をまたいでサポートを続けるには、再起動後に**もう一度これを起動する**
    //   必要がある。アプリは自分が展開された先しか知らないため、
    //   元のファイルの場所を渡してやらないと、控えを取ることができない。
    //   ＝ 再起動後の自動再接続はこれが無いと成り立たない。
    if is_onetime {
        cmd.env("RL_RUNNER_EXE", exe.to_string_lossy().to_string());
    }
    // ファイル名に合言葉が埋まっていれば本体へ渡す（＝認証コードの再入力を省く）。
    //   無ければ何も渡さない＝本体は従来どおり認証コード画面を出す。
    if let Some(tok) = dl_token_from_exe_name(&exe) {
        println!("RL: pair token found in file name");
        cmd.env("RL_PAIR_DL_TOKEN", tok);
    }
    // 🔴 常駐版の登録トークンも渡す（2026-07-31 追加）。
    //   本体は展開先で動くので、**自分の名前からは絶対に取れない**。
    //   ここで読んで渡さないと、端末が1台も登録されない。
    if let Some(tok) = enroll_token_from_exe_name(&exe) {
        println!("RL: enroll token found in file name");
        cmd.env("RL_ENROLL_TOKEN", tok);
    }
    if use_null_stdio() {
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
    } else {
        cmd.stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
    }

    if is_onetime {
        // RL build-16 (C): ワンタイムは子プロセス終了まで待機 → 展開dir削除 + 元EXE自己削除。
        //   ランナーは #![windows_subsystem = "windows"] のため窓なし。待機中も非表示・無害(1MB以下)。
        //   → 「1ダウンロード=1接続=自動消滅」を保証(2回目のダブルクリックを不可能にする)。
        if let Ok(mut child) = cmd.spawn() {
            // AllowSetForegroundWindow は wait() より前に呼ぶ
            #[cfg(windows)]
            if _ui {
                unsafe {
                    winapi::um::winuser::AllowSetForegroundWindow(child.id() as u32);
                }
            }

            // 🔴🔴 「Loading...」の板を閉じる（2026-08-20 実機で確定）。
            //
            //   ⚠ この板には**閉じる口が存在しなかった**（上流から引き継いだまま）。
            //     出したあと誰も閉じないので、お客様の画面に**永久に残り**、
            //     本体の窓のボタンを覆っていた。実機で24秒後も残っていた。
            //   ⚠ Flutter 側の子ウィンドウ管理とは**別物**。
            //     そちらを5回直しても、この板には一度も届いていなかった。
            //
            //   ⚠ すぐには閉じない。本体の窓が出る前に消すと、
            //     お客様には「押したのに何も起きない」空白が生まれる。
            //   ★4秒。本体が窓を出すのに十分で、待たされた感じもしない。
            if _ui {
                std::thread::spawn(|| {
                    std::thread::sleep(std::time::Duration::from_secs(4));
                    crate::ui::done();
                });
            }

            // 🔴 落としたファイルは、**アプリの終了を待たずに**消す（2026-07-29 実機指摘）。
            //
            //   元は「子が終わってから消す」だけだった。しかしアプリが終わらなければ
            //   永久に消えない。実際、サポートを終えた後もファイルが残っており、
            //   **同じファイルで何度でも接続できる**状態だった（お客様のPCに残る）。
            //   アプリが終わるかどうかに関係なく、起動した時点で用済みなので先に消す。
            //
            //   展開先(dir)はアプリが使っている最中なので、ここでは触らない。
            //   そちらは下の「子の終了後」の後始末に任せる。
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                let self_path = exe.to_string_lossy().to_string();
                // アプリが立ち上がるまで少し待ってから消す。起動途中に消すと、
                // OS が読み出し中のファイルを掴んでいて失敗することがある。
                // 🔴 消えるまで繰り返す（2026-07-30 実機指摘・作り直し）。
                //
                //   前は「8秒後」と「18秒後」の2回だけ試していた。しかし**実行中の
                //   EXE は OS が掴んでいるので消せない**。ランナーが生きている間は
                //   何度試しても失敗する。サポートが2回の試行より長引けば——つまり
                //   ほぼ常に——ファイルは残ったままになる。実際に残っていた。
                //
                //   時間を当てにするのをやめ、**消えたことを確認するまで**試す。
                //   ランナーが終わった次の一巡で必ず消える。1秒おきに約1時間。
                //   消えたら即座にやめる（無駄に居座らない）。
                //   ⚠ 窓なし・別プロセスなので、お客様には何も見えない。
                //
                //   🔴🔴 2026-08-01 実機検証で判明した**真の原因**（作り直し）。
                //   ここまでの直しは全部「回数」や「目印」の話で、**呼び出しそのもの
                //   が壊れていた**ことに気付いていなかった。自己削除は一度も動いて
                //   いない。
                //
                //   .args(&["/c", cmdline]) だと Rust が引数を逃がす際に、文字列中の
                //   " を \" の形に書き換える。ところが **cmd.exe は \" という書き方を
                //   知らない**（cmd の逃がし記号は ^ で、\ は普通の文字）。結果、
                //   パスの引用が壊れた命令が渡り、cmd は何もせず即座に終わる。
                //   ログにも窓にも何も出ないので、目で追っても気付けない。
                //
                //   raw_arg は Rust の逃がし処理を通さず、書いた通りに渡す。
                //   （実機で確認: .args → 消えない / .raw_arg → 消える）
                //   ⚠ raw_arg を使う以上、パスは自分で "" で囲う責任がある。
                //      展開先は %LOCALAPPDATA% 配下なので " は入り得ないが、
                //      念のため " を含むパスは諦める（壊れた命令を投げない）。
                let del_now = format!(
                    "/c for /L %i in (1,1,3600) do @(if not exist \"{e}\" (exit) else (ping -n 2 127.0.0.1 >nul & del /f /q \"{e}\" >nul 2>nul))",
                    e = self_path
                );
                if !self_path.contains('"') && !is_resume_copy {
                    let _ = Command::new("cmd")
                        .raw_arg(&del_now)
                        .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
                        .spawn();
                }
            }

            let _ = child.wait(); // 子(REMOHELP PRO.exe)が終了するまでブロック
            // ① 展開ディレクトリ削除(子終了後はハンドル解放済み)。
            //    穴C対策: DLLのアンロード遅延でロックされることがあるので数回リトライ。
            //    それでも残れば ② の切離しcmdが後追いで確実に消す。
            if let Some(ref d) = rl_app_dir {
                let mut removed = false;
                for _ in 0..5 {
                    match std::fs::remove_dir_all(d) {
                        Ok(_) => {
                            removed = true;
                            break;
                        }
                        Err(_) => {
                            std::thread::sleep(std::time::Duration::from_millis(500))
                        }
                    }
                }
                if !removed {
                    eprintln!("RL: remove_dir_all pending, retry via detached cmd: {}", d);
                }
            }
            // ② 元EXE＋展開dir を detached cmd で後追い削除(穴C対策)。
            //    実行中EXEは自分では消せず、DLLロックも数秒で解放される想定 → 待機して複数回スイープ。
            //    CREATE_NO_WINDOW で窓なし。EV署名済みEXEからの呼出は誤検知低減。
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                let self_path = exe.to_string_lossy().to_string();
                let dir_path = rl_app_dir.clone().unwrap_or_default();
                // 1スイープ = 展開dir を rmdir ＋ 元EXE を del。待機を挟んで2回繰り返す。
                let sweep = format!(
                    "rmdir /s /q \"{d}\" 2>nul & del /f /q \"{e}\" 2>nul",
                    d = dir_path,
                    e = self_path
                );
                // ⚠ 控えから起動されたときは、展開先だけ片付けて**控えは残す**。
                //   控えを消すと次の再起動で戻れなくなる（上の is_resume_copy 参照）。
                let sweep = if is_resume_copy {
                    format!("rmdir /s /q \"{d}\" 2>nul", d = dir_path)
                } else {
                    sweep
                };
                // ⚠ ここも .args ではなく raw_arg。理由は上の del_now と同じ
                //   （Rust が " を \" に書き換え、cmd が理解できない）。
                let del_cmd = format!(
                    "/c ping -n 3 127.0.0.1 >nul & {s} & ping -n 4 127.0.0.1 >nul & {s}",
                    s = sweep
                );
                if !self_path.contains('"') && !dir_path.contains('"') {
                    let _ = Command::new("cmd")
                        .raw_arg(&del_cmd)
                        .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
                        .spawn();
                }
            }
        }
    } else {
        // フリートポータブル: 従来通り待たずに spawn して即リターン
        let _child = cmd.spawn();
        #[cfg(windows)]
        if _ui {
            match _child {
                Ok(child) => unsafe {
                    winapi::um::winuser::AllowSetForegroundWindow(child.id() as u32);
                },
                Err(e) => {
                    eprintln!("{:?}", e);
                }
            }
        }
        // ⚠ こちらの経路でも板を閉じる。片方だけ直すと、
        //   もう片方で同じ不具合が残る（「OSごとの出し忘れ」と同じ失敗）。
        if _ui {
            std::thread::spawn(|| {
                std::thread::sleep(std::time::Duration::from_secs(4));
                crate::ui::done();
            });
        }
    }
}


/// すでに動いているなら、二重に起動させない。
///
/// 🔴🔴 落としてきた物を2回開くと、2つ動いていた（2026-08-28 実機のスクショ）。
///
///   ⚠ 実際に起きたこと: お客様の画面に REMOHELP PRO の窓が2つ並び、
///     片方は「接続済み」、もう片方は「認証コードを入力」。
///   ⚠ 接続番号は**MACアドレス由来**なので、2つとも**同じ番号**を名乗る。
///     中継サーバーへの登録を奪い合い、相談員の接続が切れる。
///     ＝ 「つなぎ直しています」が出る原因にもなる。
///   ⚠ お客様は「反応が無いから、もう一度ダウンロードした」だけ。
///     操作としてはごく自然なので、**こちらで防ぐしかない**。
///
///   ★Windows の「名前付きの錠」で1つに絞る。
///     ⚠ 錠はプロセスが終われば自動で外れるので、
///       落ちたあとに開けなくなる、という事故が起きない。
///   ⚠ 製品ごとに別の名前にする（相談員版・常駐版を巻き込まない）。
///   ⚠ `Local\` にする。`Global\` だと利用者をまたいで止めてしまい、
///     複数人が使う端末で別の人が開けなくなる。
#[cfg(windows)]
fn acquire_single_instance() -> bool {
    use std::os::windows::ffi::OsStrExt;
    fn wide(s: &str) -> Vec<u16> {
        std::ffi::OsStr::new(s)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }
    // ⚠ 名前は変えないこと。変えると、古い版と新しい版が**互いを見つけられず**
    //   二重に動く（入れ替えの最中に必ず起きる）。
    let name = wide("Local\\REMOHELPPRO_ONETIME_RUNNER");
    unsafe {
        let h = winapi::um::synchapi::CreateMutexW(
            std::ptr::null_mut(),
            winapi::shared::minwindef::FALSE,
            name.as_ptr(),
        );
        if h.is_null() {
            // 錠を作れないときは**止めない**。
            // ⚠ ここで止めると、錠の仕組みが使えない環境でアプリが一切起動しなくなる。
            //   二重起動より、起動しない方が困る。
            println!("RL: 単一起動の錠を作れませんでした（そのまま続行）");
            return true;
        }
        let already =
            winapi::um::errhandlingapi::GetLastError() == winapi::shared::winerror::ERROR_ALREADY_EXISTS;
        if already {
            // ⚠ 取っ手は閉じる。錠そのものは先に動いている方が持っている。
            winapi::um::handleapi::CloseHandle(h);
            return false;
        }
        // ⚠ 取っ手はわざと閉じない（CloseHandle を呼ばない）。閉じると錠が外れる。
        //   このプロセスが終わるまで持ち続ける（終われば Windows が自動で外す）。
        let _ = h;
        true
    }
}

/// 目印ファイルの名前。CI がワンタイム版の展開物にだけ同梱する。
///
/// ⚠ ここを変えるときは、下の `is_onetime` の判定と**必ず一緒に**変える。
///   片方だけ変えても、エラーは出ずに静かに効かなくなる。
#[cfg(windows)]
const ONETIME_FLAG: &str = "remohelppro-onetime.flag";

/// プロセス番号から、その実行ファイルの場所を得る。
///
/// ⚠ 取れないことがある（権限・すでに終了）。取れなければ `None` を返し、
///   ⚠ **その窓は「当社のものではない」として扱う**（安全側に倒す）。
#[cfg(windows)]
fn process_image_path(pid: u32) -> Option<std::path::PathBuf> {
    use winapi::um::handleapi::CloseHandle;
    use winapi::um::processthreadsapi::OpenProcess;
    use winapi::um::winbase::QueryFullProcessImageNameW;
    use winapi::um::winnt::PROCESS_QUERY_LIMITED_INFORMATION;
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if h.is_null() {
            return None;
        }
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, 0, buf.as_mut_ptr(), &mut len);
        CloseHandle(h);
        if ok == 0 || len == 0 {
            return None;
        }
        Some(std::path::PathBuf::from(String::from_utf16_lossy(
            &buf[..len as usize],
        )))
    }
}

/// `EnumWindows` に渡す入れ物。見つけた窓と、それが見えているかを持ち帰る。
#[cfg(windows)]
struct FoundWindow {
    hwnd: winapi::shared::windef::HWND,
    visible: bool,
}

/// 窓を1つずつ見て、当社のワンタイム版が持っている窓だけを拾う。
///
/// 共有識別子OK: 窓の種類（FLUTTER_RUNNER_WIN32_WINDOW）は RustDesk 系の全製品で
///   共通なので、それだけでは絞れない。窓を持っているプロセスの実行ファイルの隣に
///   CI が置く目印 `remohelppro-onetime.flag` があることまで確かめて、
///   当社のワンタイム版だけに絞っている。
#[cfg(windows)]
unsafe extern "system" fn enum_onetime_window(
    hwnd: winapi::shared::windef::HWND,
    lparam: winapi::shared::minwindef::LPARAM,
) -> winapi::shared::minwindef::BOOL {
    use winapi::um::winuser::{GetClassNameW, GetWindowThreadProcessId, IsWindowVisible};
    let mut cls = [0u16; 128];
    let n = GetClassNameW(hwnd, cls.as_mut_ptr(), cls.len() as i32);
    if n <= 0 {
        return 1;
    }
    if String::from_utf16_lossy(&cls[..n as usize]) != "FLUTTER_RUNNER_WIN32_WINDOW" {
        return 1;
    }
    let mut pid: u32 = 0;
    GetWindowThreadProcessId(hwnd, &mut pid);
    if pid == 0 {
        return 1;
    }
    // ★ここが要。窓の種類ではなく「誰が持っているか」で見分ける。
    let is_ours = match process_image_path(pid) {
        Some(exe) => match exe.parent() {
            Some(dir) => dir.join(ONETIME_FLAG).exists(),
            None => false,
        },
        None => false,
    };
    if !is_ours {
        return 1;
    }
    let out = &mut *(lparam as *mut FoundWindow);
    let visible = IsWindowVisible(hwnd) != 0;
    // 見えている窓を優先する。最小化・隠してある窓しか無いときは、それを使う。
    if out.hwnd.is_null() || (visible && !out.visible) {
        out.hwnd = hwnd;
        out.visible = visible;
    }
    // 見えている窓が見つかったら、そこで打ち切る。
    if out.visible {
        return 0;
    }
    1
}

/// 先に動いている「当社ワンタイム版」の窓を探す。無ければ null。
///
/// ⚠ 見つからないときは **何も前に出さない**。
///   ここで種類だけの検索に戻すと、また他製品の窓を掴む。
///   窓が出せなくても、案内の文言が「タスクバーをご確認ください」と伝える。
/// ⚠ 継続用（keep_mode）のビルドには目印を置いていないので、ここでは見つからない。
///   継続用は配布から外してあるため、いまは実害なし。配布を戻すときは要検討。
#[cfg(windows)]
fn find_onetime_window() -> winapi::shared::windef::HWND {
    let mut found = FoundWindow {
        hwnd: std::ptr::null_mut(),
        visible: false,
    };
    unsafe {
        winapi::um::winuser::EnumWindows(
            Some(enum_onetime_window),
            &mut found as *mut FoundWindow as winapi::shared::minwindef::LPARAM,
        );
    }
    found.hwnd
}

/// すでに動いていることを、お客様に伝える。
///
/// ⚠ 黙って終わらない。何も起きないと「壊れている」と思われ、
///   さらに何度も開かれる（今日ずっと直してきた形と同じ）。
/// ★先に動いている窓を前に出してから伝える。探させない。
#[cfg(windows)]
fn notify_already_running() {
    use std::os::windows::ffi::OsStrExt;
    fn wide(s: &str) -> Vec<u16> {
        std::ffi::OsStr::new(s)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }
    unsafe {
        // 先に動いている窓を前面に出す。
        //
        // 🔴 2026-08-29 修正: ここは種類だけで探していた。
        //   `FindWindowW("FLUTTER_RUNNER_WIN32_WINDOW", NULL)`
        //   ⚠ この窓の種類は **RustDesk 系（Flutter）の全製品で同じ**。
        //     実機で数えたところ RemosysLink の窓が同じ種類で並んでいた。
        //   ＝ 種類だけで探すと ⚠ **まったく別の製品の窓を前に出す**。
        //     お客様には「これが REMOHELP PRO です」と見えるため、
        //     別のアプリを操作させることになる（2026-08-29 実機で発生）。
        //   ★窓を持っているプロセスの実行ファイルの隣に、CI が置く目印
        //     `remohelppro-onetime.flag` があるかどうかで確かめる。
        //     ＝ 実行ファイルの名前を変えても、他製品と取り違えない。
        let hwnd = find_onetime_window();
        if !hwnd.is_null() {
            winapi::um::winuser::ShowWindow(hwnd, winapi::um::winuser::SW_RESTORE);
            winapi::um::winuser::SetForegroundWindow(hwnd);
        }
        let body = wide(
            "REMOHELP PRO はすでに起動しています。\n\n\
             開いている画面をお使いください。\n\
             見当たらないときは、画面下のタスクバーをご確認ください。",
        );
        let title = wide("REMOHELP PRO");
        winapi::um::winuser::MessageBoxW(
            std::ptr::null_mut(),
            body.as_ptr(),
            title.as_ptr(),
            winapi::um::winuser::MB_OK | winapi::um::winuser::MB_ICONINFORMATION,
        );
    }
}

/// 🔴🔴 **UAC の確認を「普通の画面」に出す設定だけを書いて終わる**
///   （2026-08-31 ご判断「A案」）。
///
/// ■ なぜ**この1個のファイル**が書くのか
///   ⚠ この設定を書くには管理者の権限が要り、⚠ 権限を得るには UAC を押す必要があり、
///     ⚠ **その確認が暗い専用画面に出ている**——という堂々巡りだった。
///     お客様は目の前にいらっしゃるので、⚠ **最初の1回だけ**押していただく。
///   ⚠ 押していただく相手は**署名されている物**でなければならない。
///     展開された中身の実行ファイルは署名が無く、⚠ 確認に「発行元不明」と出る。
///     ⚠ この1個のファイルは EV 署名済みなので、⚠ **当社の会社名が出る。**
///   ⚠ 展開もしない・中身も動かさない。⚠ **設定を書いて即座に終わる。**
///     （写した実行ファイルを昇格させて DLL 不足で落ちた失敗の作り直し）
///
/// ■ 使い方（本体が昇格して呼ぶ）
///   `--rl-uac-relax <PromptOnSecureDesktop の元の値> <ConsentPromptBehaviorAdmin の元の値>`
///   値は `0` / `1` / `none`（値が無かった＝Windows の既定）。
///   ⚠ 控えのファイルは**本体側が先に書いている**。ここでは戻す命令を
///     Windows の予定に置くためだけに使う。長い文字列を引数で渡さない。
///
/// ■ 戻す道は3本のまま
///   ① 相談員が昇格した後は SYSTEM 側の見張りが引き継ぐ（既存）
///   ② ここで置く Windows の予定（30分後に必ず戻す）
///   ③ 次に起動したときの戻し（既存）
#[cfg(windows)]
fn rl_uac_relax(args: &[String]) {
    use std::os::windows::process::CommandExt;
    const KEY: &str =
        r"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System";
    const NAMES: [&str; 2] = ["PromptOnSecureDesktop", "ConsentPromptBehaviorAdmin"];
    const TASK: &str = "REMOHELPPRO_UAC_RESTORE";
    let run = |exe: &str, a: Vec<String>| -> bool {
        Command::new(exe)
            .args(a)
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    // ① 確認を普通の画面に出す。⚠ 触るのはこの1つだけ。
    //   ⚠ ConsentPromptBehaviorAdmin は触らない（＝UAC は解除しない。ご判断どおり）。
    let ok = run(
        "reg",
        vec![
            "add".into(),
            KEY.into(),
            "/v".into(),
            "PromptOnSecureDesktop".into(),
            "/t".into(),
            "REG_DWORD".into(),
            "/d".into(),
            "0".into(),
            "/f".into(),
        ],
    );
    println!("RL uac: PromptOnSecureDesktop=0 {}", if ok { "書けました" } else { "書けません" });
    if !ok {
        return;
    }
    // ② 戻す命令を Windows の予定に置く。⚠ 当社の実行ファイルに依存させない
    //   （この1個のファイルは、使い終わると自分を消すため）。
    let mut parts: Vec<String> = Vec::new();
    for (i, name) in NAMES.iter().enumerate() {
        match args.get(i).map(|s| s.as_str()) {
            Some("none") | None => {
                parts.push(format!("reg delete \"{KEY}\" /v {name} /f >nul 2>&1"))
            }
            Some(v) => parts.push(format!(
                "reg add \"{KEY}\" /v {name} /t REG_DWORD /d {v} /f >nul 2>&1"
            )),
        }
    }
    parts.push(format!("schtasks /delete /tn {TASK} /f >nul 2>&1"));
    let cmd = parts.join(" & ");
    let at = std::time::SystemTime::now() + std::time::Duration::from_secs(30 * 60);
    let dt: chrono::DateTime<chrono::Local> = at.into();
    let ok2 = run(
        "schtasks",
        vec![
            "/create".into(),
            "/tn".into(),
            TASK.into(),
            "/sc".into(),
            "once".into(),
            "/sd".into(),
            dt.format("%Y/%m/%d").to_string(),
            "/st".into(),
            dt.format("%H:%M").to_string(),
            "/tr".into(),
            format!("cmd /c {cmd}"),
            "/ru".into(),
            "SYSTEM".into(),
            "/rl".into(),
            "HIGHEST".into(),
            "/f".into(),
        ],
    );
    println!("RL uac: 戻す予定 {}", if ok2 { "置きました" } else { "置けません" });
}

fn main() {
    // 🔴 これだけは、展開も二重起動の確認もせずに、真っ先に片づける。
    //   ⚠ 本体が昇格して呼ぶ。⚠ 展開すると2つ目が動いてしまうので、
    //     ⚠ **どの確認よりも前に**判断して、書いたら終わる。
    #[cfg(windows)]
    {
        let a: Vec<String> = std::env::args().skip(1).collect();
        if a.first().map(|s| s == "--rl-uac-relax").unwrap_or(false) {
            rl_uac_relax(&a[1..]);
            return;
        }
    }
    // 🔴 展開より前に見る。期限切れなら一時フォルダにも何も置かず、そのまま終わる。
    if is_onetime_expired() {
        notify_onetime_expired();
        return;
    }
    // 🔴🔴 **二重に起動させない**（2026-08-28 ご指摘）。
    //   ⚠ 展開より前に見る。ここを通すと2つ目が展開を始め、1つ目の部品を
    //     上書きしようとして「正しくないイメージ」の元にもなる。
    //
    // ⚠⚠ **常駐版の導入は止めない**（2026-08-28「他は壊さないでね」）。
    //   ⚠ 常駐は**サポートの最中に入れていただく**ことがある。
    //     ワンタイムが動いている状態で常駐のインストーラを開くのは
    //     ごく普通の流れなので、そこで「すでに起動しています」と止めると、
    //     ⚠ **常駐を入れられなくなる**。
    //   ★見分けは焼き込みで行う（常駐版のビルドにだけ入る目印）。
    //     ⚠ ファイル名で見分けない。ブラウザの `(1)` や改名で簡単に外れる。
    #[cfg(windows)]
    if !always_install() && !acquire_single_instance() {
        // ⚠ 再起動からの復帰で起こされたときは、**黙って終わる**。
        //
        //   復帰の命令書は「起動したか確かめて、駄目ならもう2回試す」作りなので、
        //   ⚠ 既に立ち上がっていると2回目・3回目がここに来る。
        //     そこで案内を出すと、⚠ **お客様の画面に身に覚えのない窓**が出る
        //     （しかも再起動直後、席を離れているかもしれない場面で）。
        //   ★人が押して開いたときだけ知らせる。仕掛けが起こしたときは黙る。
        let quiet = std::env::current_exe()
            .map(|p| {
                let s = p.to_string_lossy().to_lowercase();
                s.contains("\\remohelp pro\\resume\\") || s.contains("/remohelp pro/resume/")
            })
            .unwrap_or(false);
        if !quiet {
            notify_already_running();
        }
        return;
    }
    let mut args = Vec::new();
    let mut arg_exe = Default::default();
    let mut i = 0;
    for arg in std::env::args() {
        if i == 0 {
            arg_exe = arg.clone();
        } else {
            args.push(arg);
        }
        i += 1;
    }
    // 🔴🔴 インストールかどうかを「ファイル名」だけで決めない（2026-08-07）。
    //
    //   元は `install.exe` で終わるかだけを見ていた。配布サーバーは
    //   `...__t-<トークン>.d<日時>.install.exe` という名前で配っているので
    //   普通は当たる。しかし当たらない道がいくつもある:
    //     ・ブラウザが同名回避で ` (1)` を付ける → `...install (1).exe`
    //     ・お客様が分かりやすい名前に変える
    //     ・Content-Disposition が届かず URL の名前で保存される
    //       → `remohelppro-resident-setup.exe`
    //   どれも**ただ展開して起動するだけ**で終わる。サービスは作られず、
    //   登録も走らない。お客様には「入れたのに何も起こらない」としか見えず、
    //   画面にもログにも理由が出ない。実際に1台、ここで止まっていた。
    //
    //   ★決め手を3つ持つ。1つでも当たればインストールとして扱う。
    //     ① 常駐ビルドの焼き印（名前に一切依存しない・これが本命）
    //     ② 従来どおりの名前（既に配った物を壊さないために残す）
    //     ③ 名前の中の登録トークン（`__t-`。常駐版にしか付かない）
    //   ⚠ ③ がワンタイム版を巻き込まないこと。ワンタイム版の名前は
    //     `remohelppro-start-<短ID>.<合言葉>.exe` で `__t-` を含まない
    //     （svr-fork/src/app/api/customer/pair-launcher/route.ts:35）。
    //     ここを取り違えると、**お客様の使い捨てアプリが勝手に居座る**。
    let exe_path = std::path::Path::new(&arg_exe);
    let click_setup = args.is_empty()
        && (always_install()
            || arg_exe.to_lowercase().ends_with("install.exe")
            || enroll_token_from_exe_name(exe_path).is_some());
    #[cfg(windows)]
    let quick_support = args.is_empty() && win::is_quick_support_exe(&arg_exe);
    #[cfg(not(windows))]
    let quick_support = false;

    let mut ui = false;
    let reader = BinaryReader::default();
    // インストールとして起動された経路か。展開に失敗したとき、
    // 黙って古いものを起動しないための判断に使う（setup の説明を参照）。
    let is_install = click_setup || args.contains(&"--silent-install".to_owned());
    if let Some(exe) = setup(reader, None, is_install, is_install, &args, &mut ui) {
        if click_setup {
            args = vec!["--install".to_owned()];
        } else if quick_support {
            args = vec!["--quick_support".to_owned()];
        }
        execute(exe, args, ui);
    }
}

#[cfg(windows)]
mod win {
    use std::{fs, os::windows::process::CommandExt, path::Path, process::Command};

    // Used for privacy mode(magnifier impl).
    pub const RUNTIME_BROKER_EXE: &'static str = "C:\\Windows\\System32\\RuntimeBroker.exe";
    pub const WIN_TOPMOST_INJECTED_PROCESS_EXE: &'static str = "RuntimeBroker_rustdesk.exe";

    pub(super) fn copy_runtime_broker(dir: &Path) {
        let src = RUNTIME_BROKER_EXE;
        let tgt = WIN_TOPMOST_INJECTED_PROCESS_EXE;
        let target_file = dir.join(tgt);
        if target_file.exists() {
            if let (Ok(src_file), Ok(tgt_file)) = (fs::read(src), fs::read(&target_file)) {
                let src_md5 = format!("{:x}", md5::compute(&src_file));
                let tgt_md5 = format!("{:x}", md5::compute(&tgt_file));
                if src_md5 == tgt_md5 {
                    return;
                }
            }
        }
        let _allow_err = Command::new("taskkill")
            .args(&["/F", "/IM", "RuntimeBroker_rustdesk.exe"])
            .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
            .output();
        let _allow_err = std::fs::copy(src, &format!("{}\\{}", dir.to_string_lossy(), tgt));
    }

    /// Check if the executable is a Quick Support version.
    /// Note: This function must be kept in sync with `src/core_main.rs`.
    #[inline]
    pub(super) fn is_quick_support_exe(exe: &str) -> bool {
        let exe = exe.to_lowercase();
        exe.contains("-qs-") || exe.contains("-qs.exe") || exe.contains("_qs.exe")
    }
}
