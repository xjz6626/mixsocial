#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
apk_path="${1:-$repo_root/mobile/build/app/outputs/flutter-apk/app-release.apk}"
expected_abis_csv="${2:-arm64-v8a,x86_64}"
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
IFS=',' read -r -a expected_abis <<< "$expected_abis_csv"
for abi in "${expected_abis[@]}"; do
  case "$abi" in
    arm64-v8a|x86_64) ;;
    *)
      echo "Unsupported expected ABI: $abi" >&2
      exit 1
      ;;
  esac
  grep -q "lib/$abi/libgojni.so" "$contents_file"
done

for abi in arm64-v8a x86_64; do
  if [[ ",$expected_abis_csv," != *",$abi,"* ]] && grep -q "lib/$abi/libgojni.so" "$contents_file"; then
    echo "Unexpected ABI in APK: $abi" >&2
    exit 1
  fi
done

badging="$($aapt dump badging "$apk_path")"
grep -q "package: name='com.xjz.mixsocial'" <<< "$badging"
grep -q "application-label:'Mixsocial'" <<< "$badging"
for abi in "${expected_abis[@]}"; do
  grep -q "native-code:.*'$abi'" <<< "$badging"
done

printf '%s\n' "$badging" | grep -E "^(package:|sdkVersion:|targetSdkVersion:|application-label:|native-code:)"
sha256sum "$apk_path"
