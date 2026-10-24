use std::fs;
use std::path::PathBuf;

use crate::models::{AppConfig, GatedApp, PairingRecord};

fn data_dir() -> Result<PathBuf, String> {
    let base = dirs::data_local_dir().ok_or_else(|| "no local data dir".to_string())?;
    let dir = base.join("bioentropy-lab2fa");
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn pairing_path() -> Result<PathBuf, String> {
    Ok(data_dir()?.join("pairing.json"))
}

fn config_path() -> Result<PathBuf, String> {
    Ok(data_dir()?.join("config.json"))
}

pub fn load_pairing() -> Option<PairingRecord> {
    let path = pairing_path().ok()?;
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn save_pairing(record: &PairingRecord) -> Result<(), String> {
    let path = pairing_path()?;
    let raw = serde_json::to_string_pretty(record).map_err(|e| e.to_string())?;
    fs::write(path, raw).map_err(|e| e.to_string())
}

pub fn clear_pairing() -> Result<(), String> {
    let path = pairing_path()?;
    if path.exists() {
        fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn which(bin: &str) -> Option<String> {
    std::env::var_os("PATH").and_then(|paths| {
        for dir in std::env::split_paths(&paths) {
            let candidate = dir.join(bin);
            if candidate.is_file() {
                return Some(candidate.to_string_lossy().into_owned());
            }
        }
        None
    })
}

fn first_available(candidates: &[&str]) -> Option<String> {
    candidates.iter().find_map(|c| which(c))
}

pub fn default_config() -> AppConfig {
    let browser = first_available(&["firefox", "google-chrome", "chromium", "brave-browser"])
        .map(|p| vec![p])
        .unwrap_or_else(|| vec!["xdg-open".into(), "https://example.com".into()]);

    let terminal = first_available(&[
        "gnome-terminal",
        "konsole",
        "xfce4-terminal",
        "kitty",
        "alacritty",
        "x-terminal-emulator",
    ])
    .map(|p| vec![p])
    .unwrap_or_else(|| vec!["x-terminal-emulator".into()]);

    let files = first_available(&["nautilus", "dolphin", "thunar", "pcmanfm", "nemo"])
        .map(|p| vec![p])
        .unwrap_or_else(|| vec!["xdg-open".into(), ".".into()]);

    let editor = first_available(&["code", "codium", "gedit", "kate", "mousepad"])
        .map(|p| vec![p])
        .unwrap_or_else(|| vec!["xdg-open".into(), ".".into()]);

    AppConfig {
        apps: vec![
            GatedApp {
                id: "browser".into(),
                label: "Browser".into(),
                command: browser,
                require_2fa: true,
                curated: true,
            },
            GatedApp {
                id: "terminal".into(),
                label: "Terminal".into(),
                command: terminal,
                require_2fa: true,
                curated: true,
            },
            GatedApp {
                id: "files".into(),
                label: "File manager".into(),
                command: files,
                require_2fa: true,
                curated: true,
            },
            GatedApp {
                id: "editor".into(),
                label: "Editor".into(),
                command: editor,
                require_2fa: true,
                curated: true,
            },
            GatedApp {
                id: "custom".into(),
                label: "Custom".into(),
                command: vec![String::new()],
                require_2fa: false,
                curated: false,
            },
        ],
    }
}

pub fn load_config() -> AppConfig {
    let path = match config_path() {
        Ok(p) => p,
        Err(_) => return default_config(),
    };
    match fs::read_to_string(&path) {
        Ok(raw) => serde_json::from_str(&raw).unwrap_or_else(|_| default_config()),
        Err(_) => default_config(),
    }
}

pub fn save_config(config: &AppConfig) -> Result<(), String> {
    let path = config_path()?;
    let raw = serde_json::to_string_pretty(config).map_err(|e| e.to_string())?;
    fs::write(path, raw).map_err(|e| e.to_string())
}
