#!/bin/bash
# Source this file before every development command. Never change HOME.
crossdiff_project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
crossdiff_requested_data="${CROSSDIFF_DATA_DIR:-$crossdiff_project_root/.build/dev-sessions}"
crossdiff_requested_data="$(/usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$crossdiff_requested_data")"
case "$crossdiff_requested_data" in
  "$crossdiff_project_root"/*) ;;
  *) printf 'CrossDiff development data must remain inside the project.\n' >&2; return 1 ;;
esac
mkdir -p "$crossdiff_project_root/.build/tmp" "$crossdiff_project_root/.build/runtime-home" \
  "$crossdiff_project_root/.build/xdg-cache" "$crossdiff_project_root/.build/xdg-config" \
  "$crossdiff_project_root/.build/module-cache"
export TMPDIR="$crossdiff_project_root/.build/tmp/"
export CFFIXED_USER_HOME="$crossdiff_project_root/.build/runtime-home"
export XDG_CACHE_HOME="$crossdiff_project_root/.build/xdg-cache"
export XDG_CONFIG_HOME="$crossdiff_project_root/.build/xdg-config"
export CLANG_MODULE_CACHE_PATH="$crossdiff_project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export PYTHONDONTWRITEBYTECODE=1
export CROSSDIFF_DATA_DIR="$crossdiff_requested_data"
