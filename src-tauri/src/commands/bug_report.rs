//! Facts a GitHub bug report can carry that the error dialog does not
//! already have: the OS, the game build, the patch files currently
//! deployed, and the tail of the log. No API keys.

use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde::Serialize;
use tauri::State;

use crate::steam::{self, parse_buildid};
use crate::AppState;

const PATCH_NAME_CAP: usize = 80;
const LOG_TAIL_BYTES: u64 = 12_000;
const LOG_TAIL_LINES: usize = 80;

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct BugReportFacts {
    pub os: String,
    pub version: String,
    pub game_path: String,
    pub game_build: Option<String>,
    pub deployed_patches: Vec<String>,
    pub patches_truncated: bool,
    pub log_tail: String,
}

#[tauri::command]
pub async fn bug_report_facts(state: State<'_, AppState>) -> Result<BugReportFacts, String> {
    let settings = crate::commands::settings::do_load_settings(&state.base_path)
        .await
        .ok();
    let game = settings
        .as_ref()
        .map(|settings| settings.game_path().to_path_buf())
        .filter(|path| !path.as_os_str().is_empty());
    let game_build = game.as_deref().and_then(read_game_build);
    let (deployed_patches, patches_truncated) = match game.as_deref() {
        Some(path) => deployed_patch_names(&path.join("data")),
        None => (Vec::new(), false),
    };
    let log_tail = log_tail(&crate::data_dir::log_dir(&state.data_dir));
    Ok(BugReportFacts {
        os: operating_system(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        game_path: game.map(|path| path.display().to_string()).unwrap_or_default(),
        game_build,
        deployed_patches,
        patches_truncated,
        log_tail,
    })
}

/// Copy through a clipboard program, not the webview. On Linux both
/// `navigator.clipboard.writeText` and `document.execCommand("copy")` ask
/// GTK for the clipboard from inside the webview and deadlock the window.
/// An in-process X11 clipboard (arboard) from this GTK app does the same.
#[tauri::command]
pub async fn copy_text(text: String) -> Result<(), String> {
    let result = tauri::async_runtime::spawn_blocking(move || set_clipboard(&text))
        .await
        .map_err(|err| err.to_string())?;
    if let Err(err) = &result {
        log::warn!("copy_text failed: {err}");
    }
    result
}

fn set_clipboard(text: &str) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        set_clipboard_linux(text)
    }
    #[cfg(not(target_os = "linux"))]
    {
        set_clipboard_arboard(text)
    }
}

/// Spawn a clipboard tool and let it daemonize. Waiting on `wl-copy` /
/// `xclip` in the foreground would sit until the next paste.
#[cfg(target_os = "linux")]
fn set_clipboard_linux(text: &str) -> Result<(), String> {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let tools: &[(&str, &[&str])] = if wayland {
        &[
            ("wl-copy", &[]),
            ("xclip", &["-selection", "clipboard", "-in"]),
            ("xsel", &["--clipboard", "--input"]),
        ]
    } else {
        &[
            ("xclip", &["-selection", "clipboard", "-in"]),
            ("xsel", &["--clipboard", "--input"]),
            ("wl-copy", &[]),
        ]
    };
    let mut missing = Vec::new();
    for (program, args) in tools {
        match pipe_to_clipboard(program, args, text) {
            Ok(()) => {
                log::info!("Copied text with {program}");
                return Ok(());
            }
            Err(ClipFail::Missing) => missing.push(*program),
            Err(ClipFail::Failed(err)) => return Err(err),
        }
    }
    Err(format!(
        "no clipboard tool available (tried {})",
        missing.join(", ")
    ))
}

#[cfg(target_os = "linux")]
enum ClipFail {
    Missing,
    Failed(String),
}

#[cfg(target_os = "linux")]
fn pipe_to_clipboard(program: &str, args: &[&str], text: &str) -> Result<(), ClipFail> {
    use std::io::{Read, Write};
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| {
            if err.kind() == std::io::ErrorKind::NotFound {
                ClipFail::Missing
            } else {
                ClipFail::Failed(format!("{program}: {err}"))
            }
        })?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(text.as_bytes()).map_err(|err| ClipFail::Failed(format!("{program}: {err}")))?;
    }
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => {
                let mut err = String::new();
                if let Some(mut stderr) = child.stderr.take() {
                    let _ = stderr.read_to_string(&mut err);
                }
                let err = err.trim();
                return Err(ClipFail::Failed(if err.is_empty() {
                    format!("{program} exited {status}")
                } else {
                    format!("{program} exited {status}: {err}")
                }));
            }
            Ok(None) if started.elapsed() > Duration::from_secs(3) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ClipFail::Failed(format!("{program} did not exit")));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(err) => return Err(ClipFail::Failed(format!("{program}: {err}"))),
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn set_clipboard_arboard(text: &str) -> Result<(), String> {
    use std::sync::Mutex;
    static CLIPBOARD: Mutex<Option<arboard::Clipboard>> = Mutex::new(None);
    let mut slot = CLIPBOARD.lock().map_err(|err| err.to_string())?;
    if slot.is_none() {
        *slot = Some(arboard::Clipboard::new().map_err(|err| err.to_string())?);
    }
    slot.as_mut().unwrap().set_text(text).map_err(|err| err.to_string())
}

fn operating_system() -> String {
    let arch = std::env::consts::ARCH;
    #[cfg(target_os = "linux")]
    {
        let pretty = std::fs::read_to_string("/etc/os-release").ok().and_then(|text| {
            text.lines().find_map(|line| {
                let value = line.strip_prefix("PRETTY_NAME=")?;
                Some(value.trim_matches('"').to_string())
            })
        });
        let kernel = std::fs::read_to_string("/proc/sys/kernel/osrelease")
            .unwrap_or_default();
        let kernel = kernel.trim();
        return match pretty {
            Some(pretty) if !kernel.is_empty() => format!("{pretty} (kernel {kernel}, {arch})"),
            Some(pretty) => format!("{pretty} ({arch})"),
            None if !kernel.is_empty() => format!("Linux {kernel} ({arch})"),
            None => format!("Linux ({arch})"),
        };
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(version) = windows_version() {
            return format!("{version} ({arch})");
        }
        return format!("Windows ({arch})");
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        format!("{} ({arch})", std::env::consts::OS)
    }
}

#[cfg(target_os = "windows")]
fn windows_version() -> Option<String> {
    use winreg::enums::HKEY_LOCAL_MACHINE;
    use winreg::RegKey;

    let key = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion")
        .ok()?;
    let product: String = key.get_value("ProductName").unwrap_or_default();
    let display: String = key.get_value("DisplayVersion").unwrap_or_default();
    let build: String = key.get_value("CurrentBuild").unwrap_or_default();
    let ubr: u32 = key.get_value("UBR").unwrap_or(0);
    let mut text = product;
    if !display.is_empty() {
        text.push(' ');
        text.push_str(&display);
    }
    if !build.is_empty() {
        text.push_str(&format!(" (build {build}.{ubr})"));
    }
    Some(text)
}

fn read_game_build(game: &Path) -> Option<String> {
    let path = steam_manifest(game)?;
    let text = std::fs::read_to_string(path).ok()?;
    parse_buildid(&text)
}

/// `steamapps/appmanifest_553850.acf`, walking up from the game folder.
fn steam_manifest(game: &Path) -> Option<PathBuf> {
    let name = format!("appmanifest_{}.acf", steam::HELLDIVERS_2_APP_ID);
    let mut current = game.to_path_buf();
    for _ in 0..5 {
        let in_steamapps = current.join("steamapps").join(&name);
        if in_steamapps.is_file() {
            return Some(in_steamapps);
        }
        let here = current.join(&name);
        if here.is_file() {
            return Some(here);
        }
        current = current.parent()?.to_path_buf();
    }
    None
}

fn deployed_patch_names(data: &Path) -> (Vec<String>, bool) {
    let mut names = Vec::new();
    let Ok(entries) = std::fs::read_dir(data) else {
        return (names, false);
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.contains(".patch_") {
            names.push(name);
        }
    }
    names.sort();
    let truncated = names.len() > PATCH_NAME_CAP;
    names.truncate(PATCH_NAME_CAP);
    (names, truncated)
}

fn log_tail(dir: &Path) -> String {
    let Some(path) = newest_file(dir) else {
        return String::new();
    };
    let Ok(mut file) = std::fs::File::open(&path) else {
        return String::new();
    };
    let Ok(meta) = file.metadata() else {
        return String::new();
    };
    let len = meta.len();
    if len > LOG_TAIL_BYTES {
        let _ = file.seek(SeekFrom::End(-(LOG_TAIL_BYTES as i64)));
    }
    let mut buf = Vec::new();
    if file.read_to_end(&mut buf).is_err() {
        return String::new();
    }
    let text = String::from_utf8_lossy(&buf);
    let text = if len > LOG_TAIL_BYTES {
        text.split_once('\n').map(|(_, rest)| rest).unwrap_or("")
    } else {
        text.as_ref()
    };
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(LOG_TAIL_LINES);
    redact_log(&lines[start..].join("\n"))
}

fn newest_file(dir: &Path) -> Option<PathBuf> {
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let modified = entry
            .metadata()
            .and_then(|meta| meta.modified())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
        if best.as_ref().map(|(when, _)| modified >= *when).unwrap_or(true) {
            best = Some((modified, path));
        }
    }
    best.map(|(_, path)| path)
}

fn redact_log(text: &str) -> String {
    text.lines()
        .map(|line| {
            let lower = line.to_ascii_lowercase();
            if lower.contains("apikey")
                || lower.contains("api_key")
                || lower.contains("authorization")
                || lower.contains("bearer ")
            {
                "[redacted]"
            } else {
                line
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn a_log_line_carrying_a_key_is_redacted() {
        let text = "deploy ok\nAuthorization: Bearer secret-token\napikey=abcd\nstill here";
        let out = redact_log(text);
        assert!(out.contains("deploy ok"));
        assert!(out.contains("still here"));
        assert!(!out.contains("secret-token"));
        assert!(!out.contains("abcd"));
        assert_eq!(out.matches("[redacted]").count(), 2);
    }

    #[test]
    fn patch_names_are_sorted_and_capped() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("readme.txt"), b"no").unwrap();
        std::fs::write(dir.path().join("b.patch_0"), b"").unwrap();
        std::fs::write(dir.path().join("a.patch_1.stream"), b"").unwrap();
        let (names, truncated) = deployed_patch_names(dir.path());
        assert_eq!(names, vec!["a.patch_1.stream".to_string(), "b.patch_0".to_string()]);
        assert!(!truncated);
    }

    #[test]
    fn the_log_tail_keeps_the_end_of_the_newest_file() {
        let dir = tempfile::tempdir().unwrap();
        let mut old = std::fs::File::create(dir.path().join("old.log")).unwrap();
        old.write_all(b"old line\n").unwrap();
        old.set_modified(std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1))
            .unwrap();
        let mut body = String::new();
        for i in 0..100 {
            body.push_str(&format!("line {i}\n"));
        }
        body.push_str("Authorization: Bearer nope\n");
        let mut new = std::fs::File::create(dir.path().join("new.log")).unwrap();
        new.write_all(body.as_bytes()).unwrap();
        new.set_modified(std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(10))
            .unwrap();
        let tail = log_tail(dir.path());
        assert!(tail.contains("line 99"), "{tail}");
        assert!(!tail.contains("line 0\n"), "{tail}");
        assert!(!tail.contains("nope"), "{tail}");
        assert!(!tail.contains("old line"), "{tail}");
    }

    #[test]
    fn a_manifest_beside_steamapps_yields_its_build() {
        let dir = tempfile::tempdir().unwrap();
        let game = dir.path().join("steamapps/common/Helldivers 2");
        std::fs::create_dir_all(&game).unwrap();
        std::fs::write(
            dir.path().join("steamapps/appmanifest_553850.acf"),
            "\"buildid\"\t\t\"26251122\"\n",
        )
        .unwrap();
        assert_eq!(read_game_build(&game).as_deref(), Some("26251122"));
    }
}
