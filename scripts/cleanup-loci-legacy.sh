#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
TRASH_DIR="${HOME}/.Trash/Loci legacy cleanup ${STAMP}"
REPORT="${ROOT_DIR}/work/loci-legacy-cleanup-${STAMP}.log"

mkdir -p "${TRASH_DIR}" "$(dirname "${REPORT}")"

log() {
  printf '%s\n' "$*" | tee -a "${REPORT}"
}

unique_path() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    printf '%s\n' "${path}"
    return
  fi
  local base="${path}"
  local index=1
  while [[ -e "${base}.${index}" ]]; do
    index=$((index + 1))
  done
  printf '%s\n' "${base}.${index}"
}

move_to_trash() {
  local path="$1"
  [[ -e "${path}" ]] || return 0
  local destination
  destination="$(unique_path "${TRASH_DIR}/$(basename "${path}")")"
  mv "${path}" "${destination}"
  log "moved to Trash: ${path} -> ${destination}"
}

move_if_absent() {
  local source="$1"
  local destination="$2"
  [[ -e "${source}" ]] || return 0
  if [[ -e "${destination}" ]]; then
    move_to_trash "${source}"
    return 0
  fi
  mv "${source}" "${destination}"
  log "migrated: ${source} -> ${destination}"
}

rename_inside() {
  local root="$1"
  local source_name="$2"
  local destination_name="$3"
  [[ -d "${root}" ]] || return 0
  [[ -e "${root}/${source_name}" ]] || return 0
  if [[ -e "${root}/${destination_name}" ]]; then
    move_to_trash "${root}/${source_name}"
    return 0
  fi
  mv "${root}/${source_name}" "${root}/${destination_name}"
  log "renamed: ${root}/${source_name} -> ${root}/${destination_name}"
}

migrate_default() {
  local new_key="$1"
  local old_key="$2"
  local current
  current="$(defaults read com.codex.loci "${new_key}" 2>/dev/null || true)"
  [[ -n "${current}" ]] && return 0

  local domain
  for domain in ReferenceAtlas com.codex.reference-atlas; do
    local value
    value="$(defaults read "${domain}" "${old_key}" 2>/dev/null || true)"
    [[ -n "${value}" ]] || continue
    defaults write com.codex.loci "${new_key}" "${value}"
    log "migrated default: ${domain}:${old_key} -> com.codex.loci:${new_key}"
    return 0
  done
}

log "Loci legacy cleanup started at ${STAMP}"

APP_SUPPORT="${HOME}/Library/Application Support"
move_if_absent "${APP_SUPPORT}/ReferenceAtlas" "${APP_SUPPORT}/Loci"
move_if_absent "${APP_SUPPORT}/ReferenceAtlas Vault" "${APP_SUPPORT}/Loci Vault"

rename_inside "${APP_SUPPORT}/Loci" "ReferenceAtlas.sqlite" "Loci.sqlite"
rename_inside "${APP_SUPPORT}/Loci" "ReferenceAtlas.sqlite-wal" "Loci.sqlite-wal"
rename_inside "${APP_SUPPORT}/Loci" "ReferenceAtlas.sqlite-shm" "Loci.sqlite-shm"
rename_inside "${APP_SUPPORT}/Loci" "atlas.env" "loci.env"

migrate_default "LociXClientID" "AtlasXClientID"
migrate_default "LociXRedirectMode" "AtlasXRedirectMode"
migrate_default "LociXUsername" "AtlasXUsername"
migrate_default "LociXUserID" "AtlasXUserID"
migrate_default "Loci.APIToken" "ReferenceAtlas.APIToken"
migrate_default "LociTelemetryEnabled" "AtlasTelemetryEnabled"
migrate_default "LociTelemetryEndpointURL" "AtlasTelemetryEndpointURL"
migrate_default "LociTelemetryInstallID" "AtlasTelemetryInstallID"

move_to_trash "${HOME}/Applications/ReferenceAtlas.app"
move_to_trash "${HOME}/Desktop/ReferenceAtlas.app"
move_to_trash "${HOME}/Library/WebKit/com.codex.reference-atlas"
move_to_trash "${HOME}/Library/WebKit/ReferenceAtlas"
move_to_trash "${HOME}/Library/HTTPStorages/com.codex.reference-atlas"
move_to_trash "${HOME}/Library/HTTPStorages/com.codex.reference-atlas.binarycookies"
move_to_trash "${HOME}/Library/HTTPStorages/ReferenceAtlas"
move_to_trash "${HOME}/Library/HTTPStorages/ReferenceAtlas.binarycookies"
move_to_trash "${HOME}/Library/Caches/com.codex.reference-atlas"
move_to_trash "${HOME}/Library/Caches/ReferenceAtlas"

while IFS= read -r crash_file; do
  move_to_trash "${crash_file}"
done < <(find "${HOME}/Library/Application Support/CrashReporter" -maxdepth 1 -name 'ReferenceAtlas_*.plist' -print 2>/dev/null)

move_to_trash "${ROOT_DIR}/dist/ReferenceAtlas-0.1-b1.zip"
move_to_trash "${ROOT_DIR}/dist/ReferenceAtlas-0.1-b1.dmg"
move_to_trash "${ROOT_DIR}/build/ReferenceAtlas.app"
move_to_trash "${ROOT_DIR}/outputs/ReferenceAtlas.app"

while IFS= read -r work_file; do
  move_to_trash "${work_file}"
done < <(find "${ROOT_DIR}/work" -maxdepth 1 -name 'reference-atlas-*' -print 2>/dev/null)

log "Trash staging folder: ${TRASH_DIR}"
log "Report: ${REPORT}"
log "Loci legacy cleanup completed."
