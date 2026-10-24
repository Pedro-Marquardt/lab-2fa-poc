//! Process supervisor: while the lab desktop runs, kill gated apps without a lease.
//!
//! Leases are **time-bounded** (not a refresh token). Launcher PIDs (firefox script,
//! `x-terminal-emulator`, `xdg-open`) often exit immediately after spawning the real
//! app — tying the lease only to that PID caused instant expiry + kill loops.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::models::GatedApp;
use crate::state::SharedState;

const POLL_INTERVAL: Duration = Duration::from_secs(1);
/// Max time a successful challenge keeps the app allowed (usually ends earlier
/// when the app process exits). Restarting Lab 2FA always clears leases.
const LEASE_TTL: Duration = Duration::from_secs(10 * 60);
/// After grant, ignore missing processes while wrappers re-exec.
const LEASE_GRACE: Duration = Duration::from_secs(5);

/// Lease allowing processes of a gated app after a successful challenge spawn.
#[derive(Debug, Clone)]
pub struct AppLease {
    /// Best-effort PID to track (may be reattached to the real binary).
    pub root_pid: u32,
    pub until: Instant,
    pub grace_until: Instant,
}

pub fn spawn_supervisor(state: SharedState) {
    tauri::async_runtime::spawn(async move {
        // Boot: clear leases and kill anything already matching gated binaries.
        {
            let mut guard = state.lock().await;
            guard.leases.clear();
            let targets = gated_targets(&guard.config.apps);
            drop(guard);
            for (app_id, exe) in &targets {
                let pids = find_pids_for_exe(exe);
                if !pids.is_empty() {
                    eprintln!(
                        "[lab-gate] boot kill appId={app_id} exe={} pids={pids:?}",
                        exe.display()
                    );
                    for pid in pids {
                        kill_pid(pid);
                    }
                }
            }
        }

        loop {
            tokio::time::sleep(POLL_INTERVAL).await;
            tick(&state).await;
        }
    });
}

async fn tick(state: &SharedState) {
    let (targets, mut leases) = {
        let guard = state.lock().await;
        (gated_targets(&guard.config.apps), guard.leases.clone())
    };
    let target_map: HashMap<String, PathBuf> = targets.iter().cloned().collect();

    let now = Instant::now();
    let mut dirty = false;
    leases.retain(|app_id, lease| {
        if now >= lease.until {
            eprintln!("[lab-gate] lease TTL expired appId={app_id}");
            dirty = true;
            return false;
        }
        if now < lease.grace_until {
            return true;
        }
        let any_alive = target_map
            .get(app_id)
            .map(|exe| !find_pids_for_exe(exe).is_empty())
            .unwrap_or(false);
        if any_alive || pid_alive(lease.root_pid) {
            return true;
        }
        eprintln!("[lab-gate] lease cleared (app closed) appId={app_id}");
        dirty = true;
        false
    });

    if dirty {
        let mut guard = state.lock().await;
        guard.leases = leases.clone();
    }

    let leased_apps: HashSet<String> = leases.keys().cloned().collect();

    for (app_id, exe) in &targets {
        if leased_apps.contains(app_id) {
            continue;
        }
        for pid in find_pids_for_exe(exe) {
            eprintln!(
                "[lab-gate] kill unauthorized appId={app_id} pid={pid} exe={}",
                exe.display()
            );
            kill_pid(pid);
        }
    }
}

fn gated_targets(apps: &[GatedApp]) -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    for app in apps {
        if !app.require_2fa {
            continue;
        }
        let Some(prog) = app.command.first().map(|s| s.trim()).filter(|s| !s.is_empty()) else {
            continue;
        };
        if let Some(path) = resolve_exe(prog) {
            out.push((app.id.clone(), path));
        }
    }
    out
}

fn resolve_exe(prog: &str) -> Option<PathBuf> {
    let p = Path::new(prog);
    if p.is_absolute() {
        return fs::canonicalize(p).ok().or_else(|| Some(p.to_path_buf()));
    }
    which(prog).and_then(|w| fs::canonicalize(&w).ok().or(Some(w)))
}

fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn find_pids_for_exe(target: &Path) -> Vec<u32> {
    let target_canon = fs::canonicalize(target).unwrap_or_else(|_| target.to_path_buf());
    let names = program_names(&target_canon);

    let Ok(entries) = fs::read_dir("/proc") else {
        return Vec::new();
    };

    let mut pids = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let Ok(pid) = name.parse::<u32>() else {
            continue;
        };
        if pid == std::process::id() {
            continue;
        }
        let exe_link = format!("/proc/{pid}/exe");
        let Ok(exe) = fs::read_link(&exe_link) else {
            continue;
        };
        let exe_str = exe.to_string_lossy();
        let exe_clean = exe_str.split(" (deleted)").next().unwrap_or(&exe_str);
        let exe_path = PathBuf::from(exe_clean);
        let exe_canon = fs::canonicalize(&exe_path).unwrap_or(exe_path);

        if exe_canon == target_canon {
            pids.push(pid);
            continue;
        }
        let Some(exe_name) = exe_canon.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        if names.iter().any(|n| n == exe_name) {
            pids.push(pid);
        }
    }
    pids
}

fn program_names(target: &Path) -> Vec<String> {
    let mut names = Vec::new();
    if let Some(n) = target.file_name().and_then(|s| s.to_str()) {
        names.push(n.to_string());
        if n == "firefox" {
            names.push("firefox-bin".into());
        }
    }
    names
}

fn pid_alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

fn kill_pid(pid: u32) {
    let _ = std::process::Command::new("kill")
        .args(["-TERM", &pid.to_string()])
        .status();
}

/// Drop lease and kill matching processes (failed challenge / explicit reset).
pub async fn revoke_lease(state: &SharedState, app_id: &str, why: &str) {
    let exe = {
        let mut guard = state.lock().await;
        let had = guard.leases.remove(app_id).is_some();
        eprintln!("[lab-gate] revoke lease appId={app_id} had_lease={had} why={why}");
        guard
            .config
            .apps
            .iter()
            .find(|a| a.id == app_id)
            .and_then(|a| a.command.first().cloned())
            .and_then(|p| resolve_exe(p.trim()))
    };
    if let Some(exe) = exe {
        for pid in find_pids_for_exe(&exe) {
            eprintln!(
                "[lab-gate] kill after revoke appId={app_id} pid={pid} exe={}",
                exe.display()
            );
            kill_pid(pid);
        }
    }
}

/// Register a lease after a successful gated spawn (TTL session, not a refresh token).
pub async fn grant_lease(state: &SharedState, app_id: String, root_pid: u32) {
    let now = Instant::now();
    let until = now + LEASE_TTL;
    let grace_until = now + LEASE_GRACE;
    {
        let mut guard = state.lock().await;
        eprintln!(
            "[lab-gate] grant lease appId={app_id} root_pid={root_pid} ttl_secs={}",
            LEASE_TTL.as_secs()
        );
        guard.leases.insert(
            app_id.clone(),
            AppLease {
                root_pid,
                until,
                grace_until,
            },
        );
    }

    // Launcher wrappers exit fast — reattach to the real binary PID when it appears.
    let state_clone = state.clone();
    tauri::async_runtime::spawn(async move {
        for _ in 0..15 {
            tokio::time::sleep(Duration::from_millis(200)).await;
            let exe = {
                let guard = state_clone.lock().await;
                guard
                    .config
                    .apps
                    .iter()
                    .find(|a| a.id == app_id)
                    .and_then(|a| a.command.first().cloned())
                    .and_then(|p| resolve_exe(p.trim()))
            };
            let Some(exe) = exe else {
                continue;
            };
            let pids = find_pids_for_exe(&exe);
            let Some(&pid) = pids.iter().find(|p| pid_alive(**p)) else {
                continue;
            };
            let mut guard = state_clone.lock().await;
            if let Some(lease) = guard.leases.get_mut(&app_id) {
                if lease.root_pid != pid {
                    eprintln!("[lab-gate] reattach lease appId={app_id} root_pid={pid}");
                    lease.root_pid = pid;
                }
            }
            break;
        }
    });
}

/// Snapshot of leases for cloning under the mutex.
pub type LeaseMap = HashMap<String, AppLease>;
