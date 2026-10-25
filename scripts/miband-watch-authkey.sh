#!/usr/bin/env bash
# Captura auth key Huami/Xiaomi a partir dos logs do Mi Fitness (via adb).
# Uso:
#   ./scripts/miband-watch-authkey.sh           # escuta contínua
#   ./scripts/miband-watch-authkey.sh --once    # uma varredura e sai
#   ./scripts/miband-watch-authkey.sh --pull    # baixa os .log para ./lab-logs/

set -euo pipefail

ADB="${ADB:-$(command -v adb || true)}"
if [[ -z "${ADB}" && -x "${HOME}/Android/Sdk/platform-tools/adb" ]]; then
  ADB="${HOME}/Android/Sdk/platform-tools/adb"
fi
if [[ -z "${ADB}" ]]; then
  echo "erro: adb não encontrado. Instale platform-tools ou defina ADB=..." >&2
  exit 1
fi

MODE="watch"
INTERVAL=3
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/lab-logs"

for arg in "$@"; do
  case "$arg" in
    --once) MODE="once" ;;
    --pull) MODE="pull" ;;
    --watch) MODE="watch" ;;
    --help|-h)
      sed -n '2,8p' "$0"
      exit 0
      ;;
  esac
done

PACKAGES=(com.xiaomi.wearable com.mi.health com.xiaomi.hm.health)
LOG_GLOBS=(
  "/sdcard/Android/data/com.xiaomi.wearable/files/log"
  "/sdcard/Android/data/com.mi.health/files/log"
  "/sdcard/Android/data/com.xiaomi.hm.health/files/log"
)

# Campos nos logs Mi Fitness (JSON "authKey": "..." e huamiAuthKey=...)
# Nota: toybox grep do Android é chato com classes POSIX — preferir [0-9a-fA-F]
KEY_RE='(encryptKey|token|authKey|huamiAuthKey|auth_key)[\"=: ]+[0-9a-fA-F]{32}'

found_keys=()

wait_device() {
  echo "→ Aguardando dispositivo adb (USB debugging ligado)..."
  "${ADB}" wait-for-device
  # dispositivo autorizado
  local state
  state="$("${ADB}" get-state 2>/dev/null || true)"
  if [[ "${state}" != "device" ]]; then
    echo "erro: adb state='${state}'. Aceite o diálogo 'Permitir depuração USB' no telemóvel." >&2
    exit 1
  fi
  echo "✓ Dispositivo: $("${ADB}" get-serialno)"
}

extract_from_remote() {
  local dir="$1"
  # Lista ficheiros; ignore erros se pasta não existir
  local files
  files="$("${ADB}" shell "ls -1 '${dir}'/*.log '${dir}'/*.log.* 2>/dev/null" | tr -d '\r' || true)"
  [[ -z "${files}" ]] && return 0

  while IFS= read -r f; do
    [[ -z "$f" || "$f" == *"No such"* ]] && continue
    # grep no device (busybox/toybox)
    local hits
    hits="$("${ADB}" shell "grep -Eo '${KEY_RE}' '${f}' 2>/dev/null" | tr -d '\r' || true)"
    [[ -z "${hits}" ]] && continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local hex
      hex="$(echo "$line" | grep -oE '[0-9a-fA-F]{32}' | tail -1)"
      [[ -z "$hex" ]] && continue
      if [[ "$hex" =~ ^(0+|[fF]+|[aA]+)$ ]]; then
        continue
      fi
      local field
      field="$(echo "$line" | grep -oE 'encryptKey|token|authKey|huamiAuthKey|auth_key' | head -1)"
      echo "${hex}|${field}|${f}"
    done <<< "${hits}"
  done <<< "${files}"
}

scan_all() {
  local out=""
  for dir in "${LOG_GLOBS[@]}"; do
    out+="$(extract_from_remote "$dir" || true)"
    out+=$'\n'
  done
  # também tenta logcat recente (às vezes vaza)
  local lc
  lc="$("${ADB}" logcat -d -t 2000 2>/dev/null | grep -Eo "${KEY_RE}" | tr -d '\r' || true)"
  if [[ -n "${lc}" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local hex field
      hex="$(echo "$line" | grep -oE '[0-9a-fA-F]{32}' | tail -1)"
      field="$(echo "$line" | grep -oE 'encryptKey|token|authKey|huamiAuthKey|auth_key' | head -1)"
      [[ -n "$hex" ]] && echo "${hex}|${field}|logcat"
    done <<< "${lc}"
  fi
  printf "%s" "${out}"
}

print_new_keys() {
  local raw="$1"
  local any=0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    local hex field src
    IFS='|' read -r hex field src <<< "$row"
    [[ -z "$hex" ]] && continue
    local id="${hex}"
    local seen=0
    if ((${#found_keys[@]})); then
      for k in "${found_keys[@]}"; do
        [[ "$k" == "$id" ]] && seen=1 && break
      done
    fi
    if [[ "$seen" -eq 0 ]]; then
      found_keys+=("$id")
      any=1
      echo ""
      echo "╔══════════════════════════════════════════════╗"
      echo "║  AUTH KEY encontrada                         ║"
      echo "╠══════════════════════════════════════════════╣"
      echo "║  key:   ${hex}"
      echo "║  campo: ${field:-?}"
      echo "║  fonte: ${src}"
      echo "║  (cole no app / Gadgetbridge; NÃO faça commit)"
      echo "╚══════════════════════════════════════════════╝"
      mkdir -p "${OUT_DIR}"
      echo "${hex}  # ${field} @ ${src}  $(date -Iseconds)" >> "${OUT_DIR}/authkeys.txt"
      echo "→ salva em ${OUT_DIR}/authkeys.txt"
    fi
  done <<< "$raw"
  # exit 0 = achou; 1 = nada novo (para --once)
  if [[ "$any" -eq 1 ]]; then return 0; else return 1; fi
}

pull_logs() {
  mkdir -p "${OUT_DIR}"
  for dir in "${LOG_GLOBS[@]}"; do
    local pkg base
    base="$(basename "$(dirname "$(dirname "$dir")")")" # files -> data path awkward
    pkg="$(echo "$dir" | sed -n 's|.*/Android/data/\([^/]*\)/.*|\1|p')"
    local dest="${OUT_DIR}/${pkg}"
    mkdir -p "${dest}"
    echo "→ pull ${dir} → ${dest}"
    "${ADB}" pull "${dir}/." "${dest}/" 2>/dev/null || echo "  (pasta ausente ou sem permissão: ${pkg})"
  done
  echo "✓ Logs em ${OUT_DIR}"
  echo "→ A procurar keys nos ficheiros locais..."
  if grep -REo "${KEY_RE}" "${OUT_DIR}" 2>/dev/null | grep -oE '[0-9a-fA-F]{32}' | sort | uniq; then
    :
  else
    echo "Nenhuma key nos ficheiros puxados."
  fi
}

echo "Mi Band / Mi Fitness — watcher de auth key"
echo "adb: ${ADB}"
wait_device

case "${MODE}" in
  pull)
    pull_logs
    ;;
  once)
    echo "→ Varredura única nos logs do telemóvel..."
    raw="$(scan_all | sed '/^$/d' | sort -u)"
    if print_new_keys "$raw"; then
      exit 0
    fi
    echo ""
    echo "Nenhuma key encontrada ainda."
    echo "Dicas:"
    echo "  1) Abra o Mi Fitness, force sync com a pulseira"
    echo "  2) Feche e reabra o app (gera mais log)"
    echo "  3) Rode de novo: $0 --once"
    echo "  4) Ou modo contínuo: $0"
    exit 2
    ;;
  watch)
    echo "→ Escuta contínua (Ctrl+C para parar)."
    echo "  Abra o Mi Fitness e sincronize a Mi Band agora."
    echo ""
    while true; do
      raw="$(scan_all | sed '/^$/d' | sort -u || true)"
      print_new_keys "$raw" || true
      sleep "${INTERVAL}"
    done
    ;;
esac
