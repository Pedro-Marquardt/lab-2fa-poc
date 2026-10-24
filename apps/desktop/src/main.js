const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (sel) => document.querySelector(sel);

/** @type {{ pairing?: unknown, mobileOnline?: boolean, bandReady?: boolean, synced?: boolean }} */
let labStatus = { pairing: null, mobileOnline: false, bandReady: false, synced: false };

function appRequires2fa(app) {
  // Tolerate older serialized keys from Rust camelCase quirks.
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
  const list = $("#apps-list");
  list.innerHTML = "";

  for (const app of config.apps) {
    const card = document.createElement("article");
    card.className = "app-card";
    card.dataset.appId = app.id;

    const meta = document.createElement("div");
    meta.className = "app-meta";

    const title = document.createElement("h3");
    title.textContent = app.label;
    meta.appendChild(title);

    const pathInput = document.createElement("input");
    pathInput.className = "app-path";
    pathInput.value = (app.command || []).join(" ");
    pathInput.placeholder = app.curated
      ? "resolved command"
      : "/absolute/path/to/binary [args...]";
    pathInput.dataset.field = "command";
    meta.appendChild(pathInput);

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

    const saveBtn = document.createElement("button");
    saveBtn.type = "button";
    saveBtn.textContent = "Save";
    saveBtn.addEventListener("click", () => saveAppFromCard(card, app));

    const openBtn = document.createElement("button");
    openBtn.type = "button";
    openBtn.className = "primary";
    openBtn.textContent = "Open";
    openBtn.addEventListener("click", () => openApp(card, app));

    // Persist immediately — Open / supervisor / gate wrapper read saved config.
    toggle.addEventListener("change", async () => {
      updateOpenButtons();
      try {
        await saveAppFromCard(card, app, { quiet: true });
        setLaunchMsg(
          toggle.checked
            ? "2FA ligado — gravado."
            : "2FA desligado — gravado.",
          true,
        );
      } catch (err) {
        setLaunchMsg(String(err), false);
      }
    });

    actions.appendChild(saveBtn);
    actions.appendChild(openBtn);

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

function parseCommand(raw) {
  const trimmed = raw.trim();
  if (!trimmed) return [""];
  return trimmed.match(/(?:[^\s"]+|"[^"]*")+/g)?.map((p) => p.replace(/^"|"$/g, "")) || [trimmed];
}

async function saveAppFromCard(card, original, opts = {}) {
  const config = await invoke("get_config");
  const pathInput = card.querySelector('[data-field="command"]');
  const toggle = card.querySelector('[data-field="require2fa"]');
  const next = config.apps.map((a) => {
    if (a.id !== original.id) return a;
    return {
      ...a,
      command: parseCommand(pathInput.value),
      require2fa: toggle.checked,
    };
  });
  const saved = await invoke("save_config", { config: { apps: next } });
  if (!opts.quiet) {
    renderApps(saved);
    setLaunchMsg("Saved.", true);
  } else {
    // Keep focus/toggle; only refresh other cards' derived state from disk keys.
    const updated = saved.apps.find((a) => a.id === original.id);
    if (updated) {
      toggle.checked = appRequires2fa(updated);
    }
    updateOpenButtons();
  }
  return saved;
}

async function openApp(card, original) {
  const toggle = card.querySelector('[data-field="require2fa"]');
  const require2fa = Boolean(toggle?.checked);

  // Ensure backend matches the checkbox before open (avoids stale require2fa=true).
  try {
    await saveAppFromCard(card, original, { quiet: true });
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

  await refreshStatus();
  await loadConfig();

  await listen("lab-status", (event) => {
    renderStatus(event.payload);
  });
});
