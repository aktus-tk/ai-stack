#!/usr/bin/env bash
# deploy-opencode-config.sh — OpenCode config symlink setup (idempotent)
#
# SSOT: /home/tk/github/aktus-tk/ai-stack/config/opencode/
#       + /ai-stack/skills/ (opencode global skills)
# Runtime: ~/.config/opencode/ (via symlinks)
#
# 役割: bootstrap/setup tool として runtime の symlink を構築・検証する
#
# 使い方:
#   ./scripts/deploy-opencode-config.sh          # 確認 + setup
#   ./scripts/deploy-opencode-config.sh --force  # 確認なしで setup
#   ./scripts/deploy-opencode-config.sh --verify # 検証のみ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
REPO_CONFIG_DIR="$REPO_ROOT/config/opencode"
REPO_AGENTS="$REPO_ROOT/AGENTS.md"
REPO_SKILLS="$REPO_ROOT/skills"

RUNTIME_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
RUNTIME_OPENCODE_JSON="$RUNTIME_CONFIG_DIR/opencode.json"
RUNTIME_INSTRUCTIONS="$RUNTIME_CONFIG_DIR/instructions"
RUNTIME_AGENTS="$RUNTIME_CONFIG_DIR/AGENTS.md"
RUNTIME_SKILLS="$RUNTIME_CONFIG_DIR/skills"

# symlink target (絶対パス)
TARGET_OPENCODE_JSON="$REPO_CONFIG_DIR/opencode.json"
TARGET_INSTRUCTIONS="$REPO_CONFIG_DIR/instructions"
TARGET_AGENTS="$REPO_AGENTS"
TARGET_SKILLS="$REPO_SKILLS"

usage() {
  cat <<EOF
Usage: $0 [--force|--verify]
  (no args)  確認 + setup (既に正しければ何もしない)
  --force    確認なしで setup
  --verify   検証のみ（何もしない）
EOF
  exit 1
}

# 引数解析
FORCE=false
VERIFY_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --verify) VERIFY_ONLY=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# SSOT 確認
if [[ ! -f "$TARGET_OPENCODE_JSON" ]]; then
  echo "[error] SSOT not found: $TARGET_OPENCODE_JSON"
  exit 1
fi
if [[ ! -d "$TARGET_INSTRUCTIONS" ]]; then
  echo "[error] SSOT not found: $TARGET_INSTRUCTIONS"
  exit 1
fi
if [[ ! -d "$TARGET_SKILLS" ]]; then
  echo "[error] SSOT not found: $TARGET_SKILLS"
  exit 1
fi

# runtime dir 作成
mkdir -p "$RUNTIME_CONFIG_DIR"

# symlink 状態チェック関数
check_symlink() {
  local link="$1"
  local target="$2"

  if [[ ! -e "$link" ]] && [[ ! -L "$link" ]]; then
    # 存在しない
    echo "missing"
    return 0
  fi

  if [[ ! -L "$link" ]]; then
    # symlink ではなく実ファイル・ディレクトリ
    echo "regular"
    return 0
  fi

  # symlink の target を確認
  local actual_target
  actual_target=$(readlink -f "$link")
  if [[ "$actual_target" == "$target" ]]; then
    echo "ok"
    return 0
  else
    echo "wrong"
    return 0
  fi
}

# 各 symlink をセットアップ
setup_symlink() {
  local link="$1"
  local target="$2"
  local name="$3"

  local status
  status=$(check_symlink "$link" "$target")

  case "$status" in
    ok)
      echo "[ok] $name: already correct"
      ;;
    missing)
      echo "[info] $name: creating symlink"
      if [[ "$VERIFY_ONLY" != true ]]; then
        ln -s "$target" "$link"
        echo "[ok] $name: created"
      fi
      ;;
    regular)
      echo "[error] $name: exists as regular file/directory (not symlink)"
      echo "        Path: $link"
      echo "        To fix: remove or rename it manually, then re-run this script"
      return 1
      ;;
    wrong)
      echo "[error] $name: symlink points to wrong target"
      echo "        Current: $(readlink "$link")"
      echo "        Expected: $target"
      echo "        To fix: remove the symlink and re-run this script"
      return 1
      ;;
  esac
}

# 確認・セットアップ
HAS_ERROR=false

echo "=== Checking OpenCode config symlinks ==="
setup_symlink "$RUNTIME_OPENCODE_JSON" "$TARGET_OPENCODE_JSON" "opencode.json" || HAS_ERROR=true
setup_symlink "$RUNTIME_INSTRUCTIONS" "$TARGET_INSTRUCTIONS" "instructions" || HAS_ERROR=true
setup_symlink "$RUNTIME_AGENTS" "$TARGET_AGENTS" "AGENTS.md" || HAS_ERROR=true
setup_symlink "$RUNTIME_SKILLS" "$TARGET_SKILLS" "skills" || HAS_ERROR=true

if [[ "$HAS_ERROR" == true ]]; then
  echo ""
  echo "[error] Some symlinks need attention"
  exit 1
fi

if [[ "$VERIFY_ONLY" == true ]]; then
  echo ""
  echo "[ok] All symlinks are correct"
  exit 0
fi

# 変更があったか確認
if [[ "$FORCE" != true ]]; then
  # --force がない場合、既に all ok なら何もしない
  echo ""
  echo "[done] All OpenCode config symlinks verified"
  exit 0
fi

echo ""
echo "[done] Setup complete"
