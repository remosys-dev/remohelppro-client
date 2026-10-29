use std::{
    collections::HashMap,
    iter::FromIterator,
    sync::{Arc, Mutex},
};

use sciter::Value;

use hbb_common::{
    allow_err,
    config::{LocalConfig, PeerConfig},
    log,
};

#[cfg(not(any(feature = "flutter", feature = "cli")))]
use crate::ui_session_interface::Session;
use crate::{common::get_app_name, ipc, ui_interface::*};

mod cm;
#[cfg(feature = "inline")]
pub mod inline;
pub mod remote;

#[allow(dead_code)]
type Status = (i32, bool, i64, String);

lazy_static::lazy_static! {
    // stupid workaround for https://sciter.com/forums/topic/crash-on-latest-tis-mac-sdk-sometimes/
    static ref STUPID_VALUES: Mutex<Vec<Arc<Vec<Value>>>> = Default::default();
}

#[cfg(not(any(feature = "flutter", feature = "cli")))]
lazy_static::lazy_static! {
    pub static ref CUR_SESSION: Arc<Mutex<Option<Session<remote::SciterHandler>>>> = Default::default();
}

struct UIHostHandler;

/// 32ビット版の操作アプリ（sciter）で `remohelppro://<番号>?password=..` を受ける（2026-10-29）。
/// ⚠ これまで URL の形は Flutter の窓だけが受けていた。sciter では「Wrong command」で黙って終わる。
///   相談員コンソールが送る形（launch-operator-remote.ts）を `--connect` / `--file-transfer` に直す。
fn rl_uri_to_args(args: &[String]) -> Option<Vec<String>> {
    let rest = args.first()?.strip_prefix(&crate::get_uri_prefix())?;
    let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
    let path = path.trim_end_matches('/');
    let (cmd, id) = match path.strip_prefix("file-transfer/") {
        Some(id) => ("--file-transfer", id),
        None => ("--connect", path),
    };
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    let pw = query
        .split('&')
        .find_map(|kv| kv.strip_prefix("password="))
        .map(rl_percent_decode)
        .unwrap_or_default();
    Some(vec![cmd.to_owned(), id.to_owned(), pw])
}

fn rl_percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        // ⚠ '+' はそのまま（encodeURIComponent は空白を %20、'+' を %2B にする）
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn start(args: &mut [String]) {
    let mut rl_owned: Vec<String>;
    let args: &mut [String] = match rl_uri_to_args(args) {
        Some(v) => {
            rl_owned = v;
            &mut rl_owned[..]
        }
        None => args,
    };
    #[cfg(target_os = "macos")]
    crate::platform::delegate::show_dock();
    #[cfg(all(target_os = "linux", feature = "inline"))]
    {
        let app_dir = std::env::var("APPDIR").unwrap_or("".to_string());
        let mut so_path = "/usr/share/rustdesk/libsciter-gtk.so".to_owned();
        for (prefix, dir) in [
            ("", "/usr"),
            ("", "/app"),
            (&app_dir, "/usr"),
            (&app_dir, "/app"),
        ]
        .iter()
        {
            let path = format!("{prefix}{dir}/share/rustdesk/libsciter-gtk.so");
            if std::path::Path::new(&path).exists() {
                so_path = path;
                break;
            }
        }
        sciter::set_library(&so_path).ok();
    }
    #[cfg(windows)]
    // Check if there is a sciter.dll nearby.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let sciter_dll_path = parent.join("sciter.dll");
            if sciter_dll_path.exists() {
                // Try to set the sciter dll.
                let p = sciter_dll_path.to_string_lossy().to_string();
                log::debug!("Found dll:{}, \n {:?}", p, sciter::set_library(&p));
            }
        }
    }
    // https://github.com/c-smile/sciter-sdk/blob/master/include/sciter-x-types.h
    // https://github.com/rustdesk/rustdesk/issues/132#issuecomment-886069737
    #[cfg(windows)]
    allow_err!(sciter::set_options(sciter::RuntimeOptions::GfxLayer(
        sciter::GFX_LAYER::WARP
    )));
    use sciter::SCRIPT_RUNTIME_FEATURES::*;
    allow_err!(sciter::set_options(sciter::RuntimeOptions::ScriptFeatures(
        ALLOW_FILE_IO as u8 | ALLOW_SOCKET_IO as u8 | ALLOW_EVAL as u8 | ALLOW_SYSINFO as u8
    )));
    let mut frame = sciter::WindowBuilder::main_window().create();
    #[cfg(windows)]
    allow_err!(sciter::set_options(sciter::RuntimeOptions::UxTheming(true)));
    frame.set_title(&crate::get_app_name());
    #[cfg(target_os = "macos")]
    crate::platform::delegate::make_menubar(frame.get_host(), args.is_empty());
    #[cfg(windows)]
    crate::platform::try_set_window_foreground(frame.get_hwnd() as _);
    let page;
    if args.len() > 1 && args[0] == "--play" {
        args[0] = "--connect".to_owned();
        let path: std::path::PathBuf = (&args[1]).into();
        let id = path
            .file_stem()
            .map(|p| p.to_str().unwrap_or(""))
            .unwrap_or("")
            .to_owned();
        args[1] = id;
    }
    if args.is_empty() {
        std::thread::spawn(move || check_zombie());
        crate::common::check_software_update();
        frame.event_handler(UI {});
        frame.sciter_handler(UIHostHandler {});
        // 32ビット版のお客様用は、番号でつなぐだけの小さな窓（rl_customer.rs）
        #[cfg(windows)]
        let customer = crate::rl_customer::is_customer_build();
        #[cfg(not(windows))]
        let customer = false;
        if customer {
            frame.set_title("遠隔サポート");
            #[cfg(windows)]
            crate::rl_customer::auto_start();
            page = "customer.html";
        } else {
            page = "index.html";
        }
        // Start pulse audio local server.
        #[cfg(target_os = "linux")]
        std::thread::spawn(crate::ipc::start_pa);
    } else if args[0] == "--install" {
        frame.event_handler(UI {});
        frame.sciter_handler(UIHostHandler {});
        page = "install.html";
    } else if args[0] == "--cm" {
        frame.register_behavior("connection-manager", move || {
            Box::new(cm::SciterConnectionManager::new())
        });
        page = "cm.html";
        *cm::HIDE_CM.lock().unwrap() = crate::ipc::get_config("hide_cm")
            .ok()
            .flatten()
            .unwrap_or_default()
            == "true";
    } else if (args[0] == "--connect"
        || args[0] == "--file-transfer"
        || args[0] == "--port-forward"
        || args[0] == "--rdp")
        && args.len() > 1
    {
        #[cfg(windows)]
        {
            let hw = frame.get_host().get_hwnd();
            crate::platform::windows::enable_lowlevel_keyboard(hw as _);
        }
        let mut iter = args.iter();
        let Some(cmd) = iter.next() else {
            log::error!("Failed to get cmd arg");
            return;
        };
        let cmd = cmd.to_owned();
        let Some(id) = iter.next() else {
            log::error!("Failed to get id arg");
            return;
        };
        let id = id.to_owned();
        let pass = iter.next().unwrap_or(&"".to_owned()).clone();
        let args: Vec<String> = iter.map(|x| x.clone()).collect();
        frame.set_title(&id);
        frame.register_behavior("native-remote", move || {
            let handler =
                remote::SciterSession::new(cmd.clone(), id.clone(), pass.clone(), args.clone());
            #[cfg(not(any(feature = "flutter", feature = "cli")))]
            {
                *CUR_SESSION.lock().unwrap() = Some(handler.inner());
            }
            Box::new(handler)
        });
        page = "remote.html";
    } else {
        log::error!("Wrong command: {:?}", args);
        return;
    }
    #[cfg(feature = "inline")]
    {
        let html = if page == "index.html" {
            inline::get_index()
        } else if page == "customer.html" {
            inline::get_customer()
        } else if page == "cm.html" {
            inline::get_cm()
        } else if page == "install.html" {
            inline::get_install()
        } else {
            inline::get_remote()
        };
        frame.load_html(html.as_bytes(), Some(page));
    }
    #[cfg(not(feature = "inline"))]
    frame.load_file(&format!(
        "file://{}/src/ui/{}",
        std::env::current_dir()
            .map(|c| c.display().to_string())
            .unwrap_or("".to_owned()),
        page
    ));
    let hide_cm = *cm::HIDE_CM.lock().unwrap();
    if !args.is_empty() && args[0] == "--cm" && hide_cm {
        // run_app calls expand(show) + run_loop, we use collapse(hide) + run_loop instead to create a hidden window
        frame.collapse(true);
        frame.run_loop();
        return;
    }
    frame.run_app();
}

struct UI {}

impl UI {
    fn recent_sessions_updated(&self) -> bool {
        recent_sessions_updated()
    }

    fn get_id(&self) -> String {
        ipc::get_id()
    }

    fn temporary_password(&mut self) -> String {
        temporary_password()
    }

    fn update_temporary_password(&self) {
        update_temporary_password()
    }

    fn set_permanent_password(&self, password: String) {
        let _ = set_permanent_password_with_result(password);
    }

    fn is_local_permanent_password_set(&self) -> bool {
        is_local_permanent_password_set()
    }

    fn is_permanent_password_set(&self) -> bool {
        is_permanent_password_set()
    }

    fn get_remote_id(&mut self) -> String {
        LocalConfig::get_remote_id()
    }

    fn set_remote_id(&mut self, id: String) {
        LocalConfig::set_remote_id(&id);
    }

    fn goto_install(&mut self) {
        goto_install();
    }

    fn install_me(&mut self, _options: String, _path: String) {
        install_me(_options, _path, false, false);
    }

    fn update_me(&self, _path: String) {
        update_me(_path);
    }

    fn run_without_install(&self) {
        run_without_install();
    }

    fn show_run_without_install(&self) -> bool {
        show_run_without_install()
    }

    fn get_license(&self) -> String {
        get_license()
    }

    fn get_option(&self, key: String) -> String {
        get_option(key)
    }

    fn get_local_option(&self, key: String) -> String {
        get_local_option(key)
    }

    fn set_local_option(&self, key: String, value: String) {
        set_local_option(key, value);
    }

    fn peer_has_password(&self, id: String) -> bool {
        peer_has_password(id)
    }

    fn forget_password(&self, id: String) {
        forget_password(id)
    }

    fn get_peer_option(&self, id: String, name: String) -> String {
        get_peer_option(id, name)
    }

    fn set_peer_option(&self, id: String, name: String, value: String) {
        set_peer_option(id, name, value)
    }

    fn using_public_server(&self) -> bool {
        crate::using_public_server()
    }

    fn is_incoming_only(&self) -> bool {
        hbb_common::config::is_incoming_only()
    }

    pub fn is_outgoing_only(&self) -> bool {
        hbb_common::config::is_outgoing_only()
    }

    pub fn is_custom_client(&self) -> bool {
        crate::common::is_custom_client()
    }

    pub fn is_disable_settings(&self) -> bool {
        hbb_common::config::is_disable_settings()
    }

    pub fn is_disable_account(&self) -> bool {
        hbb_common::config::is_disable_account()
    }

    pub fn is_disable_installation(&self) -> bool {
        hbb_common::config::is_disable_installation()
    }

    pub fn is_disable_ab(&self) -> bool {
        hbb_common::config::is_disable_ab()
    }

    fn get_options(&self) -> Value {
        let hashmap: HashMap<String, String> =
            serde_json::from_str(&get_options()).unwrap_or_default();
        let mut m = Value::map();
        for (k, v) in hashmap {
            m.set_item(k, v);
        }
        m
    }

    fn test_if_valid_server(&self, host: String, test_with_proxy: bool) -> String {
        test_if_valid_server(host, test_with_proxy)
    }

    fn get_sound_inputs(&self) -> Value {
        Value::from_iter(get_sound_inputs())
    }

    fn set_options(&self, v: Value) {
        let mut m = HashMap::new();
        for (k, v) in v.items() {
            if let Some(k) = k.as_string() {
                if let Some(v) = v.as_string() {
                    if !v.is_empty() {
                        m.insert(k, v);
                    }
                }
            }
        }
        set_options(m);
    }

    fn set_option(&self, key: String, value: String) {
        set_option(key, value);
    }

    fn install_path(&mut self) -> String {
        install_path()
    }

    fn install_options(&self) -> String {
        install_options()
    }

    fn get_socks(&self) -> Value {
        Value::from_iter(get_socks())
    }

    fn set_socks(&self, proxy: String, username: String, password: String) {
        set_socks(proxy, username, password)
    }

    fn is_installed(&self) -> bool {
        is_installed()
    }

    fn get_supported_privacy_mode_impls(&self) -> String {
        serde_json::to_string(&crate::privacy_mode::get_supported_privacy_mode_impl())
            .unwrap_or_default()
    }

    fn is_root(&self) -> bool {
        is_root()
    }

    fn is_release(&self) -> bool {
        #[cfg(not(debug_assertions))]
        return true;
        #[cfg(debug_assertions)]
        return false;
    }

    fn is_share_rdp(&self) -> bool {
        is_share_rdp()
    }

    fn set_share_rdp(&self, _enable: bool) {
        set_share_rdp(_enable);
    }

    fn is_installed_lower_version(&self) -> bool {
        is_installed_lower_version()
    }

    fn closing(&mut self, x: i32, y: i32, w: i32, h: i32) {
        crate::server::input_service::fix_key_down_timeout_at_exit();
        LocalConfig::set_size(x, y, w, h);
    }

    fn get_size(&mut self) -> Value {
        let s = LocalConfig::get_size();
        let mut v = Vec::new();
        v.push(s.0);
        v.push(s.1);
        v.push(s.2);
        v.push(s.3);
        Value::from_iter(v)
    }

    fn get_mouse_time(&self) -> f64 {
        get_mouse_time()
    }

    fn check_mouse_time(&self) {
        check_mouse_time()
    }

    fn get_connect_status(&mut self) -> Value {
        let mut v = Value::array(0);
        let x = get_connect_status();
        v.push(x.status_num);
        v.push(x.key_confirmed);
        v.push(x.id);
        v
    }

    #[inline]
    fn get_peer_value(id: String, p: PeerConfig) -> Value {
        let values = vec![
            id,
            p.info.username.clone(),
            p.info.hostname.clone(),
            p.info.platform.clone(),
            p.options.get("alias").unwrap_or(&"".to_owned()).to_owned(),
        ];
        Value::from_iter(values)
    }

    fn get_peer(&self, id: String) -> Value {
        let c = get_peer(id.clone());
        Self::get_peer_value(id, c)
    }

    fn get_fav(&self) -> Value {
        Value::from_iter(get_fav())
    }

    fn store_fav(&self, fav: Value) {
        let mut tmp = vec![];
        fav.values().for_each(|v| {
            if let Some(v) = v.as_string() {
                if !v.is_empty() {
                    tmp.push(v);
                }
            }
        });
        store_fav(tmp);
    }

    fn get_recent_sessions(&mut self) -> Value {
        // to-do: limit number of recent sessions, and remove old peer file
        let peers: Vec<Value> = PeerConfig::peers(None)
            .drain(..)
            .map(|p| Self::get_peer_value(p.0, p.2))
            .collect();
        Value::from_iter(peers)
    }

    fn get_icon(&mut self) -> String {
        get_icon()
    }

    fn remove_peer(&mut self, id: String) {
        PeerConfig::remove(&id);
    }

    fn remove_discovered(&mut self, id: String) {
        remove_discovered(id);
    }

    fn send_wol(&mut self, id: String) {
        crate::lan::send_wol(id)
    }

    fn new_remote(&mut self, id: String, remote_type: String, force_relay: bool) {
        new_remote(id, remote_type, force_relay)
    }

    fn is_process_trusted(&mut self, _prompt: bool) -> bool {
        is_process_trusted(_prompt)
    }

    fn is_can_screen_recording(&mut self, _prompt: bool) -> bool {
        is_can_screen_recording(_prompt)
    }

    fn is_installed_daemon(&mut self, _prompt: bool) -> bool {
        is_installed_daemon(_prompt)
    }

    fn get_error(&mut self) -> String {
        get_error()
    }

    fn is_login_wayland(&mut self) -> bool {
        is_login_wayland()
    }

    fn current_is_wayland(&mut self) -> bool {
        current_is_wayland()
    }

    fn get_software_update_url(&self) -> String {
        crate::SOFTWARE_UPDATE_URL.lock().unwrap().clone()
    }

    fn get_new_version(&self) -> String {
        get_new_version()
    }

    fn get_version(&self) -> String {
        get_version()
    }

    fn get_fingerprint(&self) -> String {
        get_fingerprint()
    }

    fn get_app_name(&self) -> String {
        get_app_name()
    }

    fn get_software_ext(&self) -> String {
        #[cfg(windows)]
        let p = "exe";
        #[cfg(target_os = "macos")]
        let p = "dmg";
        #[cfg(target_os = "linux")]
        let p = "deb";
        p.to_owned()
    }

    fn get_software_store_path(&self) -> String {
        let mut p = std::env::temp_dir();
        let name = crate::SOFTWARE_UPDATE_URL
            .lock()
            .unwrap()
            .split("/")
            .last()
            .map(|x| x.to_owned())
            .unwrap_or(crate::get_app_name());
        p.push(name);
        format!("{}.{}", p.to_string_lossy(), self.get_software_ext())
    }

    fn create_shortcut(&self, _id: String) {
        #[cfg(windows)]
        create_shortcut(_id)
    }

    fn discover(&self) {
        std::thread::spawn(move || {
            allow_err!(crate::lan::discover());
        });
    }

    fn get_lan_peers(&self) -> String {
        // let peers = get_lan_peers()
        //     .into_iter()
        //     .map(|mut peer| {
        //         (
        //             peer.remove("id").unwrap_or_default(),
        //             peer.remove("username").unwrap_or_default(),
        //             peer.remove("hostname").unwrap_or_default(),
        //             peer.remove("platform").unwrap_or_default(),
        //         )
        //     })
        //     .collect::<Vec<(String, String, String, String)>>();
        serde_json::to_string(&get_lan_peers()).unwrap_or_default()
    }

    fn get_uuid(&self) -> String {
        get_uuid()
    }

    fn open_url(&self, url: String) {
        #[cfg(windows)]
        let p = "explorer";
        #[cfg(target_os = "macos")]
        let p = "open";
        #[cfg(target_os = "linux")]
        let p = if std::path::Path::new("/usr/bin/firefox").exists() {
            "firefox"
        } else {
            "xdg-open"
        };
        allow_err!(std::process::Command::new(p).arg(url).spawn());
    }

    fn change_id(&self, id: String) {
        reset_async_job_status();
        let old_id = self.get_id();
        change_id_shared(id, old_id);
    }

    fn http_request(&self, url: String, method: String, body: Option<String>, header: String) {
        http_request(url, method, body, header)
    }

    fn post_request(&self, url: String, body: String, header: String) {
        post_request(url, body, header)
    }

    fn is_ok_change_id(&self) -> bool {
        hbb_common::machine_uid::get().is_ok()
    }

    fn get_async_job_status(&self) -> String {
        get_async_job_status()
    }

    fn get_http_status(&self, url: String) -> Option<String> {
        get_async_http_status(url)
    }

    fn t(&self, name: String) -> String {
        crate::client::translate(name)
    }

    fn is_xfce(&self) -> bool {
        crate::platform::is_xfce()
    }

    fn get_api_server(&self) -> String {
        get_api_server()
    }

    fn has_hwcodec(&self) -> bool {
        has_hwcodec()
    }

    fn has_vram(&self) -> bool {
        has_vram()
    }

    fn get_langs(&self) -> String {
        get_langs()
    }

    fn video_save_directory(&self, root: bool) -> String {
        video_save_directory(root)
    }

    fn handle_relay_id(&self, id: String) -> String {
        handle_relay_id(&id).to_owned()
    }

    fn get_login_device_info(&self) -> String {
        get_login_device_info_json()
    }

    fn support_remove_wallpaper(&self) -> bool {
        support_remove_wallpaper()
    }

    fn has_valid_2fa(&self) -> bool {
        has_valid_2fa()
    }

    fn generate2fa(&self) -> String {
        generate2fa()
    }

    pub fn verify2fa(&self, code: String) -> bool {
        verify2fa(code)
    }

    fn verify_login(&self, raw: String, id: String) -> bool {
        crate::verify_login(&raw, &id)
    }

    fn generate_2fa_img_src(&self, data: String) -> String {
        let v = qrcode_generator::to_png_to_vec(data, qrcode_generator::QrCodeEcc::Low, 128)
            .unwrap_or_default();
        let s = hbb_common::sodiumoxide::base64::encode(
            v,
            hbb_common::sodiumoxide::base64::Variant::Original,
        );
        format!("data:image/png;base64,{s}")
    }

    pub fn check_hwcodec(&self) {
        check_hwcodec()
    }

    fn is_option_fixed(&self, key: String) -> bool {
        crate::ui_interface::is_option_fixed(&key)
    }

    fn get_builtin_option(&self, key: String) -> String {
        crate::ui_interface::get_builtin_option(&key)
    }

    fn is_remote_modify_enabled_by_control_permissions(&self) -> String {
        match crate::ui_interface::is_remote_modify_enabled_by_control_permissions() {
            Some(true) => "true",
            Some(false) => "false",
            None => "",
        }
        .to_string()
    }
}

// 32ビット版のお客様用の窓から呼ぶ（src/ui/customer.tis）。⚠ windows 以外では中身なし
impl UI {
    fn rl_customer_state(&self) -> String {
        #[cfg(windows)]
        return crate::rl_customer::state_json();
        #[cfg(not(windows))]
        return String::new();
    }
    fn rl_customer_texts(&self) -> String {
        #[cfg(windows)]
        return crate::rl_customer::texts_json();
        #[cfg(not(windows))]
        return String::new();
    }
    fn rl_customer_start(&self, _code: String) {
        #[cfg(windows)]
        crate::rl_customer::start(_code)
    }
    fn rl_customer_end(&self) {
        #[cfg(windows)]
        crate::rl_customer::end_by_customer()
    }
    fn rl_customer_close(&self) {
        #[cfg(windows)]
        crate::rl_customer::on_close()
    }
}

impl sciter::EventHandler for UI {
    sciter::dispatch_script_call! {
        fn rl_customer_state();
        fn rl_customer_texts();
        fn rl_customer_start(String);
        fn rl_customer_end();
        fn rl_customer_close();
        fn t(String);
        fn get_api_server();
        fn is_xfce();
        fn using_public_server();
        fn is_custom_client();
        fn is_outgoing_only();
        fn is_incoming_only();
        fn is_disable_settings();
        fn is_disable_account();
        fn is_disable_installation();
        fn is_disable_ab();
        fn get_id();
        fn temporary_password();
        fn update_temporary_password();
        fn set_permanent_password(String);
        fn is_local_permanent_password_set();
        fn is_permanent_password_set();
        fn get_remote_id();
        fn set_remote_id(String);
        fn closing(i32, i32, i32, i32);
        fn get_size();
        fn new_remote(String, String, bool);
        fn send_wol(String);
        fn remove_peer(String);
        fn remove_discovered(String);
        fn get_connect_status();
        fn get_mouse_time();
        fn check_mouse_time();
        fn get_recent_sessions();
        fn get_peer(String);
        fn get_fav();
        fn store_fav(Value);
        fn recent_sessions_updated();
        fn get_icon();
        fn install_me(String, String);
        fn is_installed();
        fn get_supported_privacy_mode_impls();
        fn is_root();
        fn is_release();
        fn set_socks(String, String, String);
        fn get_socks();
        fn is_share_rdp();
        fn set_share_rdp(bool);
        fn is_installed_lower_version();
        fn install_path();
        fn install_options();
        fn goto_install();
        fn is_process_trusted(bool);
        fn is_can_screen_recording(bool);
        fn is_installed_daemon(bool);
        fn get_error();
        fn is_login_wayland();
        fn current_is_wayland();
        fn get_options();
        fn get_option(String);
        fn get_local_option(String);
        fn set_local_option(String, String);
        fn get_peer_option(String, String);
        fn peer_has_password(String);
        fn forget_password(String);
        fn set_peer_option(String, String, String);
        fn get_license();
        fn test_if_valid_server(String, bool);
        fn get_sound_inputs();
        fn set_options(Value);
        fn set_option(String, String);
        fn get_software_update_url();
        fn get_new_version();
        fn get_version();
        fn get_fingerprint();
        fn update_me(String);
        fn show_run_without_install();
        fn run_without_install();
        fn get_app_name();
        fn get_software_store_path();
        fn get_software_ext();
        fn open_url(String);
        fn change_id(String);
        fn get_async_job_status();
        fn post_request(String, String, String);
        fn is_ok_change_id();
        fn create_shortcut(String);
        fn discover();
        fn get_lan_peers();
        fn get_uuid();
        fn has_hwcodec();
        fn has_vram();
        fn get_langs();
        fn video_save_directory(bool);
        fn handle_relay_id(String);
        fn get_login_device_info();
        fn support_remove_wallpaper();
        fn has_valid_2fa();
        fn generate2fa();
        fn generate_2fa_img_src(String);
        fn verify2fa(String);
        fn check_hwcodec();
        fn verify_login(String, String);
        fn is_option_fixed(String);
        fn get_builtin_option(String);
        fn is_remote_modify_enabled_by_control_permissions();
    }
}

impl sciter::host::HostHandler for UIHostHandler {
    fn on_graphics_critical_failure(&mut self) {
        log::error!("Critical rendering error: e.g. DirectX gfx driver error. Most probably bad gfx drivers.");
    }
}

#[cfg(not(target_os = "linux"))]
fn get_sound_inputs() -> Vec<String> {
    let mut out = Vec::new();
    use cpal::traits::{DeviceTrait, HostTrait};
    let host = cpal::default_host();
    if let Ok(devices) = host.devices() {
        for device in devices {
            if device.default_input_config().is_err() {
                continue;
            }
            if let Ok(name) = device.name() {
                out.push(name);
            }
        }
    }
    out
}

#[cfg(target_os = "linux")]
fn get_sound_inputs() -> Vec<String> {
    crate::platform::linux::get_pa_sources()
        .drain(..)
        .map(|x| x.1)
        .collect()
}

// sacrifice some memory
pub fn value_crash_workaround(values: &[Value]) -> Arc<Vec<Value>> {
    let persist = Arc::new(values.to_vec());
    STUPID_VALUES.lock().unwrap().push(persist.clone());
    persist
}

pub fn get_icon() -> String {
    // 128x128
    #[cfg(target_os = "macos")]
    // 128x128 on 160x160 canvas, then shrink to 128, mac looks better with padding
    {
        "data:image/png;base64,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".into()
    }
    #[cfg(not(target_os = "macos"))] // 128x128 no padding. 2026-10-29: REMOHELP PRO icon (res/128x128.png), was the upstream logo
    {
        "data:image/png;base64,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".into()
    }
}
