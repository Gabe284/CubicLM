#!/usr/bin/env bash
set -Eeuo pipefail

# Package MLC's Android runtime and configured model libraries on a host
# machine. This does not patch or build CubicLM itself.
#
# Required:
#   MLC_LLM_SOURCE_DIR=/absolute/path/to/mlc-llm
# Optional:
#   MLC_CHAT_DIR=/absolute/path/to/mlc-llm/android/MLCChat
#
# Configure the model list in MLCChat/mlc-package-config.json first. This
# script intentionally does not assert that LFM2.5 is supported by MLC.

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }

[[ "$(uname -s)" == "Linux" || "$(uname -s)" == "Darwin" ]] ||
  die "Run on a supported build host, not Android/Termux."

: "${MLC_LLM_SOURCE_DIR:?Set MLC_LLM_SOURCE_DIR to the absolute MLC LLM source path}"
[[ "$MLC_LLM_SOURCE_DIR" = /* ]] ||
  die "MLC_LLM_SOURCE_DIR must be an absolute path."
[[ -d "$MLC_LLM_SOURCE_DIR/.git" ]] ||
  die "No Git checkout found at MLC_LLM_SOURCE_DIR=$MLC_LLM_SOURCE_DIR"

MLC_CHAT_DIR="${MLC_CHAT_DIR:-$MLC_LLM_SOURCE_DIR/android/MLCChat}"
[[ -d "$MLC_CHAT_DIR" ]] || die "MLC Chat project not found: $MLC_CHAT_DIR"
[[ -f "$MLC_CHAT_DIR/mlc-package-config.json" ]] ||
  die "Missing $MLC_CHAT_DIR/mlc-package-config.json; configure the model list first."
command -v mlc_llm >/dev/null 2>&1 ||
  die "mlc_llm CLI is not on PATH. Install the Python package in an isolated build environment."
command -v python3 >/dev/null 2>&1 ||
  die "python3 is required for the post-build artifact checks."

note "MLC source: $MLC_LLM_SOURCE_DIR"
note "Android package project: $MLC_CHAT_DIR"
note "Configured model list (review this before compiling):"
python3 - "$MLC_CHAT_DIR/mlc-package-config.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    cfg = json.load(f)
print(json.dumps({
    "device": cfg.get("device"),
    "models": [
        {
            "model_id": item.get("model_id"),
            "model": item.get("model"),
            "bundle_weight": item.get("bundle_weight", False),
        }
        for item in cfg.get("model_list", [])
    ],
}, indent=2))
if cfg.get("device") != "android":
    raise SystemExit("ERROR: package config device must be 'android'")
if not cfg.get("model_list"):
    raise SystemExit("ERROR: package config model_list is empty")
PY

export MLC_LLM_SOURCE_DIR
cd "$MLC_CHAT_DIR"
note "Running mlc_llm package (this can take a long time and requires host build dependencies)"
mlc_llm package

DIST="$MLC_CHAT_DIR/dist/lib/mlc4j"
[[ -f "$DIST/output/arm64-v8a/libtvm4j_runtime_packed.so" ]] ||
  die "Missing ARM64 runtime library: $DIST/output/arm64-v8a/libtvm4j_runtime_packed.so"
[[ -f "$DIST/output/tvm4j_core.jar" ]] ||
  die "Missing TVM Java binding: $DIST/output/tvm4j_core.jar"
[[ -f "$DIST/src/main/assets/mlc-app-config.json" ]] ||
  die "Missing generated mlc-app-config.json under $DIST"

note "MLC Android package artifacts verified"
printf 'Runtime: %s\n' "$DIST/output/arm64-v8a/libtvm4j_runtime_packed.so"
printf 'Java API: %s\n' "$DIST/output/tvm4j_core.jar"
printf 'App config: %s\n' "$DIST/src/main/assets/mlc-app-config.json"
printf '\nNOTE: artifact presence does not prove the selected model is supported or runs on Mali. Test on the target device before app integration.\n'
