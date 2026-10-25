const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (sel) => document.querySelector(sel);

/** @type {{ pairing?: unknown, mobileOnline?: boolean, bandReady?: boolean, synced?: boolean }} */
let labStatus = { pairing: null, mobileOnline: false, bandReady: false, synced: false };

/** @type {{ apps: Array<Record<string, unknown>> }} */
let currentConfig = { apps: [] };

/** @type {Array<{ id: string, label: string, command: string[], desktopFile?: string }>} */
let installedCatalog = [];

/** @type {Set<string>} */
let pickerSelected = new Set();

function appRequires2fa(app) {
  return Boolean(app.require2fa ?? app.require2Fa ?? app.require_2fa);
}

function isSynced(status = labStatus) {
  if (typeof status.synced === "boolean") return status.synced;
  return Boolean(status.pairing) && Boolean(status.mobileOnline) && Boolean(status.bandReady);
}

function canOpenWith2fa(require2fa) {
  if (!require2fa) return true;
  return isSynced();
}

function updateOpenButtons() {
  document.querySelectorAll(".app-card").forEach((card) => {
    const toggle = card.querySelector('[data-field="require2fa"]');
    const openBtn = card.querySelector("button.primary");
    if (!openBtn || !toggle) return;
    const ok = canOpenWith2fa(toggle.checked);
    openBtn.disabled = !ok;
    openBtn.title = ok
      ? ""
      : "Sincroniza celular + pulseira (HR) antes de abrir com 2FA";
  });
}

function setTab(name) {
  document.querySelectorAll(".tab").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.tab === name);
  });
  document.querySelectorAll(".panel").forEach((panel) => {
    const on = panel.id === `panel-${name}`;
    panel.classList.toggle("active", on);
    panel.hidden = !on;
  });
}

function renderStatus(status) {
  labStatus = status;
  const registered = Boolean(status.pairing);
  const synced = isSynced(status);

  const syncBadge = $("#sync-badge");
  if (synced) {
    syncBadge.textContent = "sincronizado";
    syncBadge.className = "badge paired";
  } else if (registered) {
    syncBadge.textContent = "registrado · offline";
    syncBadge.className = "badge unpaired";
  } else {
    syncBadge.textContent = "não sincronizado";
    syncBadge.className = "badge unpaired";
  }

  const mobileBadge = $("#mobile-badge");
  mobileBadge.textContent = status.mobileOnline ? "mobile online" : "mobile offline";
  mobileBadge.className = `badge ${status.mobileOnline ? "online" : "offline"}`;

  const bandBadge = $("#band-badge");
  bandBadge.textContent = status.bandReady ? "band ready" : "band offline";
  bandBadge.className = `badge ${status.bandReady ? "online" : "offline"}`;

  $("#ws-url").textContent = status.wsUrl || "—";
  $("#desktop-name").textContent = status.desktopName || "lab-pc";
  $("#band-mac").textContent = status.pairing?.bandMac || "—";
  $("#paired-at").textContent = status.pairing?.pairedAt || "—";
  $("#qr-json").textContent = prettyJson(status.qrPayloadJson);
  $("#qr-box").innerHTML = status.qrSvg || "";
  $("#qr-box").classList.toggle("synced", synced);
  $("#btn-unpair").disabled = !registered;
  updateOpenButtons();
}

function prettyJson(raw) {
  try {
    return JSON.stringify(JSON.parse(raw), null, 2);
  } catch {
    return raw || "";
  }
}

async function refreshStatus() {
  const status = await invoke("get_status");
  renderStatus(status);
}

function renderApps(config) {
  currentConfig = config;
  const list = $("#apps-list");
  list.innerHTML = "";

  if (!config.apps.length) {
    const empty = document.createElement("p");
    empty.className = "apps-empty";
    empty.textContent = "No apps yet — click Add apps to pick from your system.";
    list.appendChild(empty);
    updateOpenButtons();
    return;
  }

  for (const app of config.apps) {
    const card = document.createElement("article");
    card.className = "app-card";
    card.dataset.appId = app.id;

    const meta = document.createElement("div");
    meta.className = "app-meta";

    const title = document.createElement("h3");
    title.textContent = app.label;
    meta.appendChild(title);

    const cmd = document.createElement("p");
    cmd.className = "app-cmd";
    cmd.textContent = (app.command || []).join(" ");
    cmd.title = cmd.textContent;
    meta.appendChild(cmd);

    const toggleRow = document.createElement("div");
    toggleRow.className = "toggle-row";
    const toggleText = document.createElement("span");
    toggleText.className = "toggle-label";
    toggleText.textContent = "2FA";
    const toggleLabel = document.createElement("label");
    toggleLabel.className = "switch";
    toggleLabel.title = "Exigir autenticação de dois fatores";
    const toggle = document.createElement("input");
    toggle.type = "checkbox";
    toggle.checked = appRequires2fa(app);
    toggle.dataset.field = "require2fa";
    toggle.setAttribute("role", "switch");
    toggle.setAttribute("aria-label", "Exigir 2FA");
    const slider = document.createElement("span");
    slider.className = "slider";
    toggleLabel.appendChild(toggle);
    toggleLabel.appendChild(slider);
    toggleRow.appendChild(toggleText);
    toggleRow.appendChild(toggleLabel);
    meta.appendChild(toggleRow);

    const actions = document.createElement("div");
    actions.className = "app-actions";

    const openBtn = document.createElement("button");
    openBtn.type = "button";
    openBtn.className = "primary";
    openBtn.textContent = "Open";
    openBtn.addEventListener("click", () => openApp(card, app));

    const removeBtn = document.createElement("button");
    removeBtn.type = "button";
    removeBtn.className = "danger";
    removeBtn.textContent = "Remove";
    removeBtn.addEventListener("click", () => removeApp(app.id));

    toggle.addEventListener("change", async () => {
      updateOpenButtons();
      try {
        await saveAppToggle(app.id, toggle.checked);
        setLaunchMsg(
          toggle.checked ? "2FA ligado — gravado." : "2FA desligado — gravado.",
          true,
        );
      } catch (err) {
        setLaunchMsg(String(err), false);
      }
    });

    actions.appendChild(openBtn);
    actions.appendChild(removeBtn);

    card.appendChild(meta);
    card.appendChild(actions);
    list.appendChild(card);
  }
  updateOpenButtons();
}

async function loadConfig() {
  const config = await invoke("get_config");
  renderApps(config);
}

async function saveAppToggle(appId, require2fa) {
  const next = {
    apps: currentConfig.apps.map((a) =>
      a.id === appId ? { ...a, require2fa } : a,
    ),
  };
  const saved = await invoke("save_config", { config: next });
  currentConfig = saved;
  updateOpenButtons();
  return saved;
}

async function removeApp(appId) {
  const next = {
    apps: currentConfig.apps.filter((a) => a.id !== appId),
  };
  const saved = await invoke("save_config", { config: next });
  renderApps(saved);
  setLaunchMsg("App removed.", true);
}

async function openApp(card, original) {
  const toggle = card.querySelector('[data-field="require2fa"]');
  const require2fa = Boolean(toggle?.checked);

  try {
    await saveAppToggle(original.id, require2fa);
  } catch (err) {
    setLaunchMsg(String(err), false);
    return;
  }

  if (require2fa && !canOpenWith2fa(true)) {
    setLaunchMsg("não sincronizado (celular + pulseira) — não abre", false);
    return;
  }

  setLaunchMsg(require2fa ? "À espera do challenge…" : "A abrir (2FA off)…", null);
  try {
    const result = await invoke("open_gated_app", { appId: original.id });
    setLaunchMsg(result.message, result.launched);
  } catch (err) {
    setLaunchMsg(String(err), false);
  }
}

function setLaunchMsg(text, ok) {
  const el = $("#launch-msg");
  el.textContent = text;
  el.className = "launch-msg";
  if (ok === true) el.classList.add("ok");
  if (ok === false) el.classList.add("err");
}

function renderPickerList(filter = "") {
  const root = $("#add-apps-list");
  root.innerHTML = "";
  const q = filter.trim().toLowerCase();
  const items = installedCatalog.filter((app) => {
    if (!q) return true;
    const hay = `${app.label} ${app.id} ${(app.command || []).join(" ")}`.toLowerCase();
    return hay.includes(q);
  });

  if (!items.length) {
    const empty = document.createElement("p");
    empty.className = "apps-empty";
    empty.textContent = installedCatalog.length
      ? "No matches."
      : "No installed apps found.";
    root.appendChild(empty);
    return;
  }

  for (const app of items) {
    const row = document.createElement("label");
    row.className = "add-apps-row";

    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = pickerSelected.has(app.id);
    cb.addEventListener("change", () => {
      if (cb.checked) pickerSelected.add(app.id);
      else pickerSelected.delete(app.id);
    });

    const text = document.createElement("div");
    const label = document.createElement("span");
    label.className = "label";
    label.textContent = app.label;
    const cmd = document.createElement("span");
    cmd.className = "cmd";
    cmd.textContent = (app.command || []).join(" ");
    cmd.title = cmd.textContent;
    text.appendChild(label);
    text.appendChild(cmd);

    row.appendChild(cb);
    row.appendChild(text);
    root.appendChild(row);
  }
}

async function openAddAppsDialog() {
  const dialog = $("#add-apps-dialog");
  const search = $("#add-apps-search");
  setLaunchMsg("Loading installed apps…", null);
  try {
    installedCatalog = await invoke("list_installed_apps");
    pickerSelected = new Set(currentConfig.apps.map((a) => a.id));
    search.value = "";
    renderPickerList("");
    setLaunchMsg("", null);
    dialog.showModal();
    search.focus();
  } catch (err) {
    setLaunchMsg(String(err), false);
  }
}

async function applyPickerSelection() {
  const byId = new Map(installedCatalog.map((a) => [a.id, a]));
  const existing = new Map(currentConfig.apps.map((a) => [a.id, a]));
  const nextApps = [];

  for (const id of pickerSelected) {
    const prev = existing.get(id);
    const catalog = byId.get(id);
    if (prev) {
      nextApps.push({
        ...prev,
        // Refresh command/label from desktop file when available.
        label: catalog?.label ?? prev.label,
        command: catalog?.command ?? prev.command,
      });
      continue;
    }
    if (!catalog) continue;
    nextApps.push({
      id: catalog.id,
      label: catalog.label,
      command: catalog.command,
      require2fa: true,
      curated: false,
    });
  }

  // Keep a stable-ish order: previously listed first, then new by label.
  nextApps.sort((a, b) => {
    const ai = currentConfig.apps.findIndex((x) => x.id === a.id);
    const bi = currentConfig.apps.findIndex((x) => x.id === b.id);
    if (ai >= 0 && bi >= 0) return ai - bi;
    if (ai >= 0) return -1;
    if (bi >= 0) return 1;
    return String(a.label).localeCompare(String(b.label));
  });

  const saved = await invoke("save_config", { config: { apps: nextApps } });
  renderApps(saved);
  setLaunchMsg(`Saved ${saved.apps.length} app(s).`, true);
}

window.addEventListener("DOMContentLoaded", async () => {
  document.querySelectorAll(".tab").forEach((btn) => {
    btn.addEventListener("click", () => setTab(btn.dataset.tab));
  });

  $("#btn-refresh").addEventListener("click", async () => {
    const status = await invoke("refresh_qr");
    renderStatus(status);
  });
  $("#btn-unpair").addEventListener("click", async () => {
    const status = await invoke("unpair");
    renderStatus(status);
  });

  $("#btn-add-apps").addEventListener("click", () => openAddAppsDialog());
  $("#add-apps-search").addEventListener("input", (e) => {
    renderPickerList(e.target.value);
  });
  $("#add-apps-form").addEventListener("submit", async (e) => {
    const submitter = e.submitter;
    const value = submitter?.value || "cancel";
    if (value === "apply") {
      e.preventDefault();
      try {
        await applyPickerSelection();
        $("#add-apps-dialog").close();
      } catch (err) {
        setLaunchMsg(String(err), false);
      }
    }
  });

  await refreshStatus();
  await loadConfig();

  await listen("lab-status", (event) => {
    renderStatus(event.payload);
  });
});
