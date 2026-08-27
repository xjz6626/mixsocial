#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_dir="$(cd -- "$script_dir/../.." && pwd -P)"
output="$repo_dir/mobile/packages/mixsocial_core/android/libs/mobilecore.aar"

if ! command -v gomobile >/dev/null 2>&1; then
	printf '%s\n' 'gomobile is required. Install the version pinned by go.mod: go install golang.org/x/mobile/cmd/gomobile@v0.0.0-20250911085028-6912353760cf' >&2
	exit 1
fi

if ! command -v gobind >/dev/null 2>&1; then
	printf '%s\n' 'gobind is required. Install the version pinned by go.mod: go install golang.org/x/mobile/cmd/gobind@v0.0.0-20250911085028-6912353760cf' >&2
	exit 1
fi

if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
	printf '%s\n' 'ANDROID_HOME or ANDROID_SDK_ROOT must point to an Android SDK.' >&2
	exit 1
fi

if ! command -v javac >/dev/null 2>&1; then
	printf '%s\n' 'JDK 17 is required and javac must be available on PATH.' >&2
	exit 1
fi

mkdir -p -- "$(dirname -- "$output")"
cd -- "$repo_dir"
go_flags="${GOFLAGS:-}"
go_flags="${go_flags:+$go_flags }-buildvcs=false"
GOFLAGS="$go_flags" gomobile bind \
	-target=android/arm64,android/amd64 \
	-androidapi=24 \
	-javapkg=com.xjz.mixsocial.go \
	-trimpath \
	-o "$output" \
	./mobilecore

printf 'Built %s\n' "$output"
