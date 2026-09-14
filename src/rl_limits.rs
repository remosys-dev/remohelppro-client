//! Safety auto-disconnect for remote-control sessions (REMOHELP PRO).
//!
//! The server delivers per-company values; the customer app stores them as local options:
//!   rl-limit-idle-min     : minutes without any input before the session is closed (0/empty = off)
//!   rl-limit-max-min      : maximum connected minutes for one connection (0/empty = off)
//!   rl-limit-file-max-mb  : maximum size of a single transferred file in MB (0/empty = off)
//!
//! Rules
//!   - If a value was never received, nothing is enforced (fail-open).
//!   - "Activity" is operator input arriving at this machine, local input on this machine
//!     (Windows: GetLastInputInfo), or a file transfer in progress.
//!   - The check runs inside the connection loop (Rust), so it also works while the
//!     pre-logon helper service is handling a reconnect and the UI process is not running.

use hbb_common::config::LocalConfig;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub const OPT_IDLE_MIN: &str = "rl-limit-idle-min";
pub const OPT_MAX_MIN: &str = "rl-limit-max-min";
pub const OPT_FILE_MAX_MB: &str = "rl-limit-file-max-mb";
/// Written when a session is closed by this module: "<reason>:<unix ms>".
/// The one-time UI reads it to show the reason and to tell the server.
pub const OPT_AUTO_END: &str = "rl-auto-end";

pub const REASON_IDLE: &str = "RL_AUTO_END_IDLE";
pub const REASON_MAX: &str = "RL_AUTO_END_MAX";

static LAST_ACTIVITY_MS: AtomicU64 = AtomicU64::new(0);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Record activity now.
pub fn touch() {
    LAST_ACTIVITY_MS.store(now_ms(), Ordering::Relaxed);
}

/// Seconds since the last recorded activity. The first call starts the clock.
pub fn idle_secs() -> u64 {
    let last = LAST_ACTIVITY_MS.load(Ordering::Relaxed);
    if last == 0 {
        touch();
        return 0;
    }
    now_ms().saturating_sub(last) / 1000
}

fn option_u64(key: &str) -> u64 {
    LocalConfig::get_option(key).trim().parse::<u64>().unwrap_or(0)
}

/// Idle limit in seconds (0 = off).
pub fn idle_limit_secs() -> u64 {
    option_u64(OPT_IDLE_MIN).saturating_mul(60)
}

/// Max connected time in seconds (0 = off).
pub fn max_limit_secs() -> u64 {
    option_u64(OPT_MAX_MIN).saturating_mul(60)
}

/// Max single file size in bytes (0 = off).
pub fn file_max_bytes() -> u64 {
    option_u64(OPT_FILE_MAX_MB).saturating_mul(1024 * 1024)
}

/// Reject when any single file is larger than the limit.
pub fn check_file_sizes<I: IntoIterator<Item = u64>>(sizes: I) -> Result<(), String> {
    check_file_sizes_with(file_max_bytes(), sizes)
}

fn check_file_sizes_with<I: IntoIterator<Item = u64>>(max: u64, sizes: I) -> Result<(), String> {
    if max == 0 {
        return Ok(());
    }
    if sizes.into_iter().any(|s| s > max) {
        let mb = max / (1024 * 1024);
        let msg = format!(
            "{}MBを超えるファイルは、この接続では送受信できません。大きなファイルは、共有フォルダやクラウドストレージをご利用ください。",
            mb
        );
        log::warn!("file transfer rejected: a file exceeds {} MB", mb);
        return Err(msg);
    }
    Ok(())
}

/// Treat new local input on this machine as activity.
#[cfg(windows)]
pub fn poll_local_input() {
    use std::sync::atomic::AtomicU32;
    use winapi::um::winuser::{GetLastInputInfo, LASTINPUTINFO};
    static PREV_TICK: AtomicU32 = AtomicU32::new(0);
    let mut info = LASTINPUTINFO {
        cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
        dwTime: 0,
    };
    let ok = unsafe { GetLastInputInfo(&mut info) } != 0;
    if !ok {
        return;
    }
    let prev = PREV_TICK.swap(info.dwTime, Ordering::Relaxed);
    if prev != 0 && prev != info.dwTime {
        touch();
    }
}

#[cfg(not(windows))]
pub fn poll_local_input() {}

/// Remember why the session was closed, for the UI.
pub fn record_auto_end(reason: &str) {
    LocalConfig::set_option(OPT_AUTO_END.to_owned(), format!("{}:{}", reason, now_ms()));
}

/// Warning text sent to the operator one minute before an idle close.
pub fn idle_warning_text() -> &'static str {
    "操作が行われていないため、約1分後に接続を自動的に終了します。続ける場合は、画面の上でマウスを動かすか、キーを押してください。"
}

/// Text shown to the operator when the session was closed by this module.
pub fn end_text(reason: &str) -> &'static str {
    if reason == REASON_MAX {
        "接続時間の上限に達したため、接続を自動的に終了しました。続ける場合は、新しい認証コードで接続し直してください。"
    } else {
        "一定時間操作が行われなかったため、接続を自動的に終了しました。続ける場合は、新しい認証コードで接続し直してください。"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_limit_off_when_zero() {
        assert!(check_file_sizes_with(0, [u64::MAX]).is_ok());
    }

    #[test]
    fn file_limit_rejects_only_larger() {
        let max = 500 * 1024 * 1024;
        assert!(check_file_sizes_with(max, [max]).is_ok());
        assert!(check_file_sizes_with(max, [1, max + 1]).is_err());
    }
}
