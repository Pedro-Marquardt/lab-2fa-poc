//! Discover installed GUI apps from FreeDesktop `.desktop` files (Linux).

use std::fs;
use std::path::{Path, PathBuf};

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledApp {
    /// Stable id from desktop file stem, e.g. `firefox`.
    pub id: String,
    pub label: String,
    pub command: Vec<String>,
    pub desktop_file: String,
}

/// Scan standard application directories for launchable apps.
pub fn list_installed_apps() -> Result<Vec<InstalledApp>, String> {
    let mut dirs = Vec::new();
    if let Some(home) = dirs::home_dir() {
        dirs.push(home.join(".local/share/applications"));
    }
    dirs.push(PathBuf::from("/usr/local/share/applications"));
    dirs.push(PathBuf::from("/usr/share/applications"));
    if let Ok(xdg) = std::env::var("XDG_DATA_DIRS") {
        for part in xdg.split(':').filter(|s| !s.is_empty()) {
            dirs.push(PathBuf::from(part).join("applications"));
        }
    }

    let mut by_id: std::collections::BTreeMap<String, InstalledApp> =
        std::collections::BTreeMap::new();

    for dir in dirs {
        if !dir.is_dir() {
            continue;
        }
        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
                continue;
            }
            if let Some(app) = parse_desktop_file(&path) {
                // Prefer user-local over system (first write wins if we reverse;
                // insert only if vacant so earlier dirs — home first — win).
                by_id.entry(app.id.clone()).or_insert(app);
            }
        }
    }

    Ok(by_id.into_values().collect())
}

fn parse_desktop_file(path: &Path) -> Option<InstalledApp> {
    let raw = fs::read_to_string(path).ok()?;
    let mut in_desktop_entry = false;
    let mut name: Option<String> = None;
    let mut name_en: Option<String> = None;
    let mut exec: Option<String> = None;
    let mut no_display = false;
    let mut hidden = false;
    let mut app_type_ok = true;
    let mut try_exec_ok = true;

    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            in_desktop_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_desktop_entry {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "Type" => {
                if value != "Application" {
                    app_type_ok = false;
                }
            }
            "Name" => name = Some(value.to_string()),
            "Name[en]" | "Name[en_US]" => name_en = Some(value.to_string()),
            "Exec" => exec = Some(value.to_string()),
            "NoDisplay" => no_display = value.eq_ignore_ascii_case("true"),
            "Hidden" => hidden = value.eq_ignore_ascii_case("true"),
            "TryExec" => {
                let bin = value.trim();
                if !bin.is_empty() && which(bin).is_none() && !Path::new(bin).is_file() {
                    try_exec_ok = false;
                }
            }
            _ => {}
        }
    }

    if !app_type_ok || no_display || hidden || !try_exec_ok {
        return None;
    }
    let exec = exec?;
    let command = parse_exec(&exec)?;
    if command.is_empty() || command[0].is_empty() {
        return None;
    }
    // Skip if binary not found (relative names only).
    let prog = &command[0];
    if !prog.contains('/') && which(prog).is_none() {
        return None;
    }
    if prog.contains('/') && !Path::new(prog).is_file() {
        return None;
    }

    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("app")
        .to_string();
    let label = name_en.or(name).unwrap_or_else(|| stem.clone());

    Some(InstalledApp {
        id: stem,
        label,
        command,
        desktop_file: path.to_string_lossy().into_owned(),
    })
}

/// Split Exec= into argv; strip FreeDesktop field codes.
fn parse_exec(exec: &str) -> Option<Vec<String>> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => in_quotes = !in_quotes,
            ' ' if !in_quotes => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            '%' if !in_quotes => {
                // Skip field code (%f, %F, %u, %U, %i, %c, %k, %%)
                if let Some(next) = chars.next() {
                    if next == '%' {
                        cur.push('%');
                    }
                    // else drop the code
                }
            }
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn which(bin: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        for dir in std::env::split_paths(&paths) {
            let candidate = dir.join(bin);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
        None
    })
}

#[cfg(test)]
mod tests {
    use super::parse_exec;

    #[test]
    fn strips_field_codes() {
        assert_eq!(
            parse_exec(r#"firefox %u"#).unwrap(),
            vec!["firefox".to_string()]
        );
        assert_eq!(
            parse_exec(r#"/usr/bin/code --new-window %F"#).unwrap(),
            vec!["/usr/bin/code".to_string(), "--new-window".to_string()]
        );
    }
}
