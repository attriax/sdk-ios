#!/usr/bin/env bash
#
# build-xcframework.sh — build the shared Attriax KMP core and vendor it into sdk-ios.
#
# Produces `sdk-ios/Frameworks/AttriaxCore.xcframework` from the sibling `sdk-kmp`
# repo. The engine lives in `sdk-kmp` (Kotlin Multiplatform); `sdk-ios` is a thin
# Swift facade that consumes this XCFramework via a `.binaryTarget` (see Package.swift).
# The framework binary is git-ignored — this script IS the reproduce recipe from
# `.gitignore`.
#
# Requires a Mac with Xcode + command-line tools: the Kotlin/Native Apple targets that
# emit the XCFramework only build on macOS (declared-but-disabled off-Mac).
#
# Run this before:
#   * `swift build` against the standalone `Attriax` SwiftPM package, and
#   * testing the Flutter iOS plugin locally (`attriax_flutter_ios` vendors the same
#     XCFramework from a LOCAL path via its own path-sourced pod — see PUBLISHING.md).
#
set -euo pipefail

# --- Resolve paths (robust to being invoked from any cwd) --------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_IOS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SDK_KMP_DIR="$(cd "${SDK_IOS_DIR}/../sdk-kmp" && pwd)"

# Gradle task + output path (from sdk-kmp/core/build.gradle.kts — XCFramework("AttriaxCore")).
GRADLE_TASK=":core:assembleAttriaxCoreReleaseXCFramework"
BUILT_XCFRAMEWORK="${SDK_KMP_DIR}/core/build/XCFrameworks/release/AttriaxCore.xcframework"
DEST_DIR="${SDK_IOS_DIR}/Frameworks"
DEST_XCFRAMEWORK="${DEST_DIR}/AttriaxCore.xcframework"

echo "==> Attriax iOS: building the AttriaxCore XCFramework"
echo "    sdk-ios : ${SDK_IOS_DIR}"
echo "    sdk-kmp : ${SDK_KMP_DIR}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this must run on macOS — Kotlin/Native Apple targets require Xcode." >&2
  exit 1
fi

if [[ ! -x "${SDK_KMP_DIR}/gradlew" ]]; then
  echo "ERROR: gradle wrapper not found/executable at ${SDK_KMP_DIR}/gradlew" >&2
  exit 1
fi

# --- Build -------------------------------------------------------------------
echo "==> Running ${GRADLE_TASK} in sdk-kmp (this compiles the Apple slices + assembles the XCFramework)"
( cd "${SDK_KMP_DIR}" && ./gradlew "${GRADLE_TASK}" )

if [[ ! -d "${BUILT_XCFRAMEWORK}" ]]; then
  echo "ERROR: expected build output missing: ${BUILT_XCFRAMEWORK}" >&2
  echo "       (did the gradle task name or output path change in sdk-kmp/core/build.gradle.kts?)" >&2
  exit 1
fi

# --- Vendor ------------------------------------------------------------------
echo "==> Vendoring into ${DEST_XCFRAMEWORK}"
mkdir -p "${DEST_DIR}"
rm -rf "${DEST_XCFRAMEWORK}"
cp -R "${BUILT_XCFRAMEWORK}" "${DEST_XCFRAMEWORK}"

echo ""
echo "==> Done: framework vendored, ready for \`swift build\` (SwiftPM) or the Flutter iOS plugin's local \`pod install\`."
echo "    Vendored: ${DEST_XCFRAMEWORK}"
