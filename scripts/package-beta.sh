#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Loci"
EXECUTABLE_NAME="Loci"
CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${ROOT_DIR}/dist"
INFO_TEMPLATE="${ROOT_DIR}/Support/Loci.Info.plist"
APP_ICON_ICNS="${ROOT_DIR}/Sources/Loci/Resources/Loci.icns"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_TEMPLATE}")}"
BUILD="${BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_TEMPLATE}")}"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-b${BUILD}.dmg"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-b${BUILD}.zip"
FINAL_APP_DIR="${DIST_DIR}/${APP_NAME}.app"
ALLOW_ADHOC="${ALLOW_ADHOC:-0}"
KEEP_APP="${KEEP_APP:-0}"
REQUIRE_NOTARIZATION="${REQUIRE_NOTARIZATION:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loci-package.XXXXXX")"
APP_DIR="${WORK_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"

trap 'rm -rf "${WORK_DIR}"' EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

strip_xattrs() {
  xattr -cr "$@" 2>/dev/null || true
  xattr -dr com.apple.provenance "$@" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "$@" 2>/dev/null || true
  xattr -dr 'com.apple.fileprovider.fpfs#P' "$@" 2>/dev/null || true
}

auto_developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/Developer ID Application/ { print $2; exit }'
}

resolve_signing_identity() {
  local identity="${CODESIGN_IDENTITY:-}"
  if [[ -z "${identity}" ]]; then
    identity="$(auto_developer_id_identity)"
  fi
  echo "${identity}"
}

sign_app() {
  local identity="$1"

  if [[ -n "${identity}" ]]; then
    echo "Signing ${APP_NAME}.app with ${identity}"
    codesign --force --deep --options runtime --timestamp --sign "${identity}" "${APP_DIR}"
    codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
    return
  fi

  if [[ "${ALLOW_ADHOC}" == "1" ]]; then
    echo "Signing ${APP_NAME}.app ad-hoc for local testing only"
    codesign --force --deep --sign - "${APP_DIR}"
    codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
    return
  fi

  cat >&2 <<'EOF'
error: No valid Developer ID Application signing identity was found.

Market/beta distribution must be signed with Developer ID. Install the certificate
in Keychain Access, or pass it explicitly:

  CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package-beta.sh

For local-only testing, opt in to ad-hoc signing:

  ALLOW_ADHOC=1 scripts/package-beta.sh
EOF
  exit 2
}

sign_dmg() {
  local identity="$1"
  [[ -n "${identity}" ]] || return 0

  echo "Signing ${DMG_PATH}"
  codesign --force --timestamp --sign "${identity}" "${DMG_PATH}"
  codesign --verify --verbose=2 "${DMG_PATH}"
}

notarize_if_requested() {
  if [[ -z "${NOTARY_PROFILE}" ]]; then
    if [[ "${REQUIRE_NOTARIZATION}" == "1" ]]; then
      cat >&2 <<'EOF'
error: REQUIRE_NOTARIZATION=1 was set, but NOTARY_PROFILE is empty.

Create a notarytool profile first:

  xcrun notarytool store-credentials loci-notary

Then rerun:

  NOTARY_PROFILE=loci-notary REQUIRE_NOTARIZATION=1 scripts/package-beta.sh
EOF
      exit 3
    fi
    echo "NOTARY_PROFILE not set; skipping notarization."
    return 0
  fi

  echo "Submitting ${DMG_PATH} for notarization"
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${DMG_PATH}"
  xcrun stapler validate "${DMG_PATH}"
}

echo "Packaging ${APP_NAME} ${VERSION} build ${BUILD}"

rm -rf "${FINAL_APP_DIR}" "${DMG_PATH}" "${ZIP_PATH}"
mkdir -p "${DIST_DIR}" "${MACOS_DIR}" "${RESOURCES_DIR}"

swift build -c "${CONFIGURATION}" --package-path "${ROOT_DIR}"

cp "${ROOT_DIR}/.build/${CONFIGURATION}/${EXECUTABLE_NAME}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
cp "${INFO_TEMPLATE}" "${INFO_PLIST}"
cp "${APP_ICON_ICNS}" "${RESOURCES_DIR}/Loci.icns"
cp "${ROOT_DIR}/Sources/Loci/Resources/AppIcon.png" "${RESOURCES_DIR}/AppIcon.png"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "${INFO_PLIST}"

X_CLIENT_ID="${LOCI_X_CLIENT_ID:-${ATLAS_X_CLIENT_ID:-}}"
if [[ -n "${X_CLIENT_ID}" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :LociXClientID" "${INFO_PLIST}" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :LociXClientID string ${X_CLIENT_ID}" "${INFO_PLIST}"
fi

strip_xattrs "${APP_DIR}"
SIGNING_IDENTITY="$(resolve_signing_identity)"
sign_app "${SIGNING_IDENTITY}"

(
  cd "${WORK_DIR}"
  ditto -c -k --norsrc --keepParent "${APP_NAME}.app" "${ZIP_PATH}"
)

hdiutil create -volname "${APP_NAME}" -srcfolder "${APP_DIR}" -ov -format UDZO "${DMG_PATH}"
sign_dmg "${SIGNING_IDENTITY}"
notarize_if_requested

strip_xattrs "${DMG_PATH}" "${ZIP_PATH}"

if [[ "${KEEP_APP}" == "1" ]]; then
  ditto --norsrc "${APP_DIR}" "${FINAL_APP_DIR}"
  strip_xattrs "${FINAL_APP_DIR}"
  if ! codesign --verify --deep --strict --verbose=2 "${FINAL_APP_DIR}"; then
    echo "warning: strict verification failed on ${FINAL_APP_DIR}; verifying sanitized temp copy instead." >&2
    VERIFY_APP_DIR="${WORK_DIR}/verify-${APP_NAME}.app"
    rm -rf "${VERIFY_APP_DIR}"
    ditto --norsrc "${FINAL_APP_DIR}" "${VERIFY_APP_DIR}"
    strip_xattrs "${VERIFY_APP_DIR}"
    codesign --verify --deep --strict --verbose=2 "${VERIFY_APP_DIR}"
  fi
  echo "APP ${FINAL_APP_DIR}"
fi

echo "ZIP ${ZIP_PATH}"
echo "DMG ${DMG_PATH}"
