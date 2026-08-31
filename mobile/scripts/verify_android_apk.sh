#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
apk_path="${1:-$repo_root/mobile/build/app/outputs/flutter-apk/app-release.apk}"
android_sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
build_tools_version="${ANDROID_BUILD_TOOLS_VERSION:-36.0.0}"

if [[ -z "$android_sdk" && -d /opt/android-sdk ]]; then
  android_sdk=/opt/android-sdk
fi

if [[ ! -f "$apk_path" ]]; then
  echo "APK not found: $apk_path" >&2
  exit 1
fi
if [[ -z "$android_sdk" ]]; then
  echo "ANDROID_HOME or ANDROID_SDK_ROOT must point to the Android SDK." >&2
  exit 1
fi

apksigner="$android_sdk/build-tools/$build_tools_version/apksigner"
aapt="$android_sdk/build-tools/$build_tools_version/aapt"
for tool in "$apksigner" "$aapt"; do
  if [[ ! -x "$tool" ]]; then
    echo "Required Android build tool not found: $tool" >&2
    exit 1
  fi
done

contents_file="$(mktemp)"
trap 'rm -f "$contents_file"' EXIT

"$apksigner" verify --verbose "$apk_path"
unzip -l "$apk_path" > "$contents_file"
grep -q 'lib/arm64-v8a/libgojni.so' "$contents_file"
grep -q 'lib/x86_64/libgojni.so' "$contents_file"

badging="$($aapt dump badging "$apk_path")"
grep -q "package: name='com.xjz.mixsocial'" <<< "$badging"
grep -q "application-label:'Mixsocial'" <<< "$badging"
grep -q "native-code: 'arm64-v8a' 'x86_64'" <<< "$badging"

printf '%s\n' "$badging" | grep -E "^(package:|sdkVersion:|targetSdkVersion:|application-label:|native-code:)"
sha256sum "$apk_path"
