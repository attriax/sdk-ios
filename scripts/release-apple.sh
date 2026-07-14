#!/usr/bin/env bash
#
# release-apple.sh — prepare a SwiftPM binary release of the Attriax iOS SDK.
#
# This script PREPARES and INSTRUCTS; it never pulls the trigger. It:
#   1. (re)builds + vendors the AttriaxCore XCFramework (via build-xcframework.sh),
#   2. zips it to AttriaxCore.xcframework.zip,
#   3. computes the SwiftPM sha256 checksum,
#   4. prints the exact remote `.binaryTarget(url:checksum:)` stanza for Package.swift,
#   5. prints the remaining MANUAL steps (GitHub Release upload + git tag/push).
#
# The GitHub Release creation and the git tag push are guarded: they only run with
# an explicit `--yes` flag AND the `gh` CLI available. By default nothing is created,
# uploaded, tagged, or pushed — you review the output and run the final commands
# yourself.
#
# Usage:
#   scripts/release-apple.sh [<version>] [--yes]
#     <version>  release version + git tag (default: read from AttriaxVersion.swift,
#                falling back to 0.6.0).
#     --yes      actually create the GitHub Release + push the tag (needs `gh`).
#                Omit to only prepare + print instructions (the safe default).
#
# Requires a Mac with Xcode + command-line tools (Swift toolchain) and, for --yes,
# the GitHub CLI (`gh`) authenticated against github.com/attriax/sdk-ios.
#
set -euo pipefail

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FRAMEWORKS_DIR="${SDK_IOS_DIR}/Frameworks"
XCFRAMEWORK="${FRAMEWORKS_DIR}/AttriaxCore.xcframework"
ZIP_NAME="AttriaxCore.xcframework.zip"
ZIP_PATH="${FRAMEWORKS_DIR}/${ZIP_NAME}"
VERSION_SWIFT="${SDK_IOS_DIR}/Sources/Attriax/AttriaxVersion.swift"
REPO_SLUG="attriax/sdk-ios"
RELEASE_BASE_URL="https://github.com/${REPO_SLUG}/releases/download"

# --- Args --------------------------------------------------------------------
VERSION=""
DO_RELEASE=0
for arg in "$@"; do
  case "${arg}" in
    --yes) DO_RELEASE=1 ;;
    -*)    echo "ERROR: unknown flag '${arg}'" >&2; exit 1 ;;
    *)     VERSION="${arg}" ;;
  esac
done

# Default the version from AttriaxVersion.swift (packageVersion = "x.y.z"), else 0.6.0.
if [[ -z "${VERSION}" ]]; then
  if [[ -f "${VERSION_SWIFT}" ]]; then
    VERSION="$(sed -n 's/.*packageVersion[^"]*"\([^"]*\)".*/\1/p' "${VERSION_SWIFT}" | head -n1)"
  fi
  VERSION="${VERSION:-0.6.0}"
fi

echo "==> Preparing Attriax iOS SwiftPM binary release ${VERSION}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this must run on macOS (Swift toolchain + Xcode required)." >&2
  exit 1
fi

# --- 1. Build + vendor the XCFramework --------------------------------------
echo "==> [1/5] Building + vendoring the XCFramework"
"${SCRIPT_DIR}/build-xcframework.sh"

if [[ ! -d "${XCFRAMEWORK}" ]]; then
  echo "ERROR: XCFramework missing after build: ${XCFRAMEWORK}" >&2
  exit 1
fi

# --- 2. Zip it ---------------------------------------------------------------
echo "==> [2/5] Zipping the XCFramework -> ${ZIP_NAME}"
rm -f "${ZIP_PATH}"
# Zip with paths RELATIVE to Frameworks/ so the archive root is AttriaxCore.xcframework.
( cd "${FRAMEWORKS_DIR}" && zip -r -q "${ZIP_NAME}" "AttriaxCore.xcframework" )
echo "    Wrote ${ZIP_PATH}"

# --- 3. Compute the SwiftPM checksum ----------------------------------------
echo "==> [3/5] Computing SwiftPM checksum"
# `swift package compute-checksum` must run inside a package dir; point it at the zip.
CHECKSUM="$(cd "${SDK_IOS_DIR}" && swift package compute-checksum "${ZIP_PATH}")"
echo "    sha256: ${CHECKSUM}"

# --- 4. Print the remote binaryTarget stanza --------------------------------
RELEASE_URL="${RELEASE_BASE_URL}/${VERSION}/${ZIP_NAME}"
echo ""
echo "==> [4/5] Paste this into Package.swift to REPLACE the local-path binaryTarget:"
echo "-------------------------------------------------------------------------------"
cat <<EOF
        .binaryTarget(
            name: "AttriaxCore",
            url: "${RELEASE_URL}",
            checksum: "${CHECKSUM}"
        ),
EOF
echo "-------------------------------------------------------------------------------"
echo "    (The current manifest uses \`path: \"Frameworks/AttriaxCore.xcframework\"\` for"
echo "     local dev — swap it for the url/checksum stanza above on the release commit.)"

# --- 5. Remaining manual steps ----------------------------------------------
echo ""
echo "==> [5/5] Remaining steps to publish ${VERSION}:"
if command -v gh >/dev/null 2>&1; then
  RELEASE_CMD="gh release create ${VERSION} \"${ZIP_PATH}\" --repo ${REPO_SLUG} --title \"Attriax iOS ${VERSION}\" --notes \"AttriaxCore XCFramework binary for SwiftPM ${VERSION}.\""
  if [[ "${DO_RELEASE}" -eq 1 ]]; then
    echo "    --yes given: creating the GitHub Release + uploading the zip now."
    eval "${RELEASE_CMD}"
    echo "    Tagging + pushing ${VERSION}."
    ( cd "${SDK_IOS_DIR}" && git tag "${VERSION}" && git push origin "${VERSION}" )
    echo "    Published. Verify the asset at ${RELEASE_URL}"
  else
    echo "    (dry run — re-run with --yes to execute the two commands below automatically)"
    echo ""
    echo "    a) Create the GitHub Release + upload the zip:"
    echo "         ${RELEASE_CMD}"
    echo ""
    echo "    b) Update Package.swift with the stanza above, commit, then tag + push:"
    echo "         git tag ${VERSION} && git push origin ${VERSION}"
  fi
else
  echo "    (\`gh\` CLI not found — do it via the web UI)"
  echo ""
  echo "    a) Open https://github.com/${REPO_SLUG}/releases/new"
  echo "       - Tag: ${VERSION}   Title: Attriax iOS ${VERSION}"
  echo "       - Upload the asset: ${ZIP_PATH}"
  echo ""
  echo "    b) Update Package.swift with the stanza above, commit, then:"
  echo "         git tag ${VERSION} && git push origin ${VERSION}"
fi

echo ""
echo "==> Release asset prepared: ${ZIP_PATH}"
echo "    Keep AttriaxVersion.swift (packageVersion), the git tag, and Attriax.podspec"
echo "    version in lockstep at ${VERSION}."
