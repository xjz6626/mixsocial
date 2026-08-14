#!/usr/bin/env bash

set -Eeuo pipefail

program_name="mixsocial"
sidecar_name="xiaohongshu-mcp"
sidecar_module="github.com/xpzouying/xiaohongshu-mcp"
sidecar_version="v1.2.10-0.20260813065717-84511f19accc"
prepare_browser=true
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
sidecar_patch="$script_dir/_patches/xiaohongshu-login.go"

if [[ -n "${MIXSOCIAL_BIN_DIR:-}" ]]; then
	bin_dir="$MIXSOCIAL_BIN_DIR"
elif [[ -n "${XDG_BIN_HOME:-}" ]]; then
	bin_dir="$XDG_BIN_HOME"
else
	: "${HOME:?HOME is not set; pass --bin-dir explicitly}"
	bin_dir="$HOME/.local/bin"
fi

usage() {
	cat <<'EOF'
Install mixsocial for the current user.

Usage:
  ./install.sh [--bin-dir DIRECTORY] [--skip-browser]

Options:
  --bin-dir DIRECTORY  Installation directory (default: ~/.local/bin)
  --skip-browser       Do not pre-download the Xiaohongshu Chromium runtime
  -h, --help           Show this help

Environment:
  MIXSOCIAL_BIN_DIR    Alternative default installation directory
  XDG_BIN_HOME         Used when MIXSOCIAL_BIN_DIR is unset
EOF
}

while (($# > 0)); do
	case "$1" in
	--bin-dir)
		if (($# < 2)) || [[ -z "$2" ]]; then
			echo "install.sh: --bin-dir requires a directory" >&2
			exit 2
		fi
		bin_dir="$2"
		shift 2
		;;
	--skip-browser)
		prepare_browser=false
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "install.sh: unknown argument: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

if ! go_bin="$(command -v go)"; then
	echo "install.sh: Go 1.24 or newer is required" >&2
	exit 1
fi

mkdir -p -- "$bin_dir"
bin_dir="$(cd -- "$bin_dir" && pwd -P)"
destination="$bin_dir/$program_name"
sidecar_destination="$bin_dir/$sidecar_name"

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/mixsocial-build.XXXXXX")"
staged_binary=""
staged_sidecar=""
sidecar_source_dir=""
browser_prepare_pid=""
browser_prepare_log="$build_dir/browser-prepare.log"
browser_prepare_session="$build_dir/browser-prepare-session.json"
cleanup() {
	if [[ -n "$browser_prepare_pid" ]] && kill -0 "$browser_prepare_pid" 2>/dev/null; then
		kill "$browser_prepare_pid" 2>/dev/null || true
		wait "$browser_prepare_pid" 2>/dev/null || true
	fi
	if [[ -n "$staged_binary" && -f "$staged_binary" ]]; then
		rm -f -- "$staged_binary"
	fi
	if [[ -n "$staged_sidecar" && -f "$staged_sidecar" ]]; then
		rm -f -- "$staged_sidecar"
	fi
	if [[ -f "$build_dir/$program_name" ]]; then
		rm -f -- "$build_dir/$program_name"
	fi
	if [[ -f "$build_dir/$sidecar_name" ]]; then
		rm -f -- "$build_dir/$sidecar_name"
	fi
	if [[ -n "$sidecar_source_dir" && -d "$sidecar_source_dir" ]]; then
		rm -rf -- "$sidecar_source_dir"
	fi
	if [[ -f "$browser_prepare_log" ]]; then
		rm -f -- "$browser_prepare_log"
	fi
	if [[ -f "$browser_prepare_session" ]]; then
		rm -f -- "$browser_prepare_session"
	fi
	if [[ -d "$build_dir" ]]; then
		rmdir -- "$build_dir" 2>/dev/null || true
	fi
}
trap cleanup EXIT

echo "Building $program_name..."
(
	cd -- "$script_dir"
	CGO_ENABLED=0 "$go_bin" build \
		-trimpath \
		-buildvcs=false \
		-o "$build_dir/$program_name" \
		./cmd/mixsocial
)

echo "Building the bundled Xiaohongshu sidecar..."
sidecar_module_dir="$("$go_bin" list -m -f '{{.Dir}}' "$sidecar_module@$sidecar_version")"
if [[ -z "$sidecar_module_dir" || ! -d "$sidecar_module_dir" ]]; then
	echo "install.sh: unable to locate downloaded sidecar source" >&2
	exit 1
fi
if [[ ! -f "$sidecar_patch" ]]; then
	echo "install.sh: missing sidecar login patch: $sidecar_patch" >&2
	exit 1
fi
sidecar_source_dir="$build_dir/xiaohongshu-mcp-src"
mkdir -p -- "$sidecar_source_dir"
cp -- "$sidecar_module_dir"/*.go "$sidecar_module_dir/go.mod" "$sidecar_module_dir/go.sum" "$sidecar_source_dir/"
for source_part in browser configs cookies errors humanize pkg xiaohongshu; do
	cp -R -- "$sidecar_module_dir/$source_part" "$sidecar_source_dir/$source_part"
done
chmod -R u+w -- "$sidecar_source_dir"
install -m 0644 -- "$sidecar_patch" "$sidecar_source_dir/xiaohongshu/login.go"
(
	cd -- "$sidecar_source_dir"
	CGO_ENABLED=0 "$go_bin" build -trimpath -buildvcs=false -o "$build_dir/$sidecar_name" .
)

if [[ "$prepare_browser" == true ]]; then
	echo "Preparing the bundled Chromium runtime (about 140-190 MB, first install only)..."
	COOKIES_PATH="$browser_prepare_session" \
		"$build_dir/$sidecar_name" -headless=true -port=127.0.0.1:0 \
		>"$browser_prepare_log" 2>&1 &
	browser_prepare_pid=$!
	browser_prepare_deadline=$((SECONDS + 2100))
	while true; do
		if grep -Fq "using browser binary:" "$browser_prepare_log"; then
			kill "$browser_prepare_pid" 2>/dev/null || true
			wait "$browser_prepare_pid" 2>/dev/null || true
			browser_prepare_pid=""
			echo "Chromium runtime is ready."
			break
		fi
		if ! kill -0 "$browser_prepare_pid" 2>/dev/null; then
			wait "$browser_prepare_pid" 2>/dev/null || true
			browser_prepare_pid=""
			echo "install.sh: failed to prepare Chromium; recent sidecar log:" >&2
			tail -n 30 "$browser_prepare_log" >&2 || true
			exit 1
		fi
		if ((SECONDS >= browser_prepare_deadline)); then
			kill "$browser_prepare_pid" 2>/dev/null || true
			wait "$browser_prepare_pid" 2>/dev/null || true
			browser_prepare_pid=""
			echo "install.sh: timed out while preparing Chromium" >&2
			tail -n 30 "$browser_prepare_log" >&2 || true
			exit 1
		fi
		sleep 1
	done
else
	echo "Skipping Chromium preparation; mixsocial will use an existing cache or download it on first Xiaohongshu start."
fi

# Stage both files first. Rename the entry point last, so an interrupted
# install never advertises a mixsocial binary without its managed sidecar.
staged_binary="$(mktemp "$bin_dir/.mixsocial-install.XXXXXX")"
staged_sidecar="$(mktemp "$bin_dir/.xiaohongshu-mcp-install.XXXXXX")"
install -m 0755 -- "$build_dir/$program_name" "$staged_binary"
install -m 0755 -- "$build_dir/$sidecar_name" "$staged_sidecar"
mv -f -- "$staged_sidecar" "$sidecar_destination"
staged_sidecar=""
mv -f -- "$staged_binary" "$destination"
staged_binary=""

echo "Installed: $destination"
echo "Installed: $sidecar_destination (managed automatically by mixsocial)"
if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
	echo
	echo "Add this directory to PATH:"
	echo "  export PATH=\"$bin_dir:\$PATH\""
	command_hint="$destination"
else
	command_hint="$program_name"
fi

echo
echo "Try it:"
echo "  $command_hint --demo"
echo "  $command_hint --tieba-forums=golang,linux"
