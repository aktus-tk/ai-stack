#!/usr/bin/env bash
# deploy-agent360-browser-mcp.sh — Agent360 Browser MCP 一括デプロイスクリプト
#
# 対象ツール:
#   1. OpenCode:        ~/.config/opencode/opencode.json
#   2. Antigravity CLI: ~/.gemini/config/mcp_config.json
#   3. Codex:           ~/.codex/config.toml
#   4. agent (Cursor):  ~/.cursor/mcp.json
#   5. codebuddy:       ~/.codebuddy/.mcp.json
#
# 使い方:
#   ./scripts/deploy-agent360-browser-mcp.sh                   # デフォルト (latest) で適用
#   ./scripts/deploy-agent360-browser-mcp.sh --dry-run         # 差分確認のみ（ファイル変更なし）
#   ./scripts/deploy-agent360-browser-mcp.sh --version 1.25.0  # バージョン指定

set -euo pipefail

VERSION="latest"
DRY_RUN=false

usage() {
  cat <<USAGE_EOF
Usage: $0 [OPTIONS]

Options:
  --version <version>  MCP package version to use (default: latest)
  --dry-run            Show diffs and planned changes without modifying files
  -h, --help           Show this help message
USAGE_EOF
  exit 1
}

# 引数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ -z "${2:-}" || "$2" =~ ^-- ]]; then
        echo "[error] --version requires an argument" >&2
        exit 1
      fi
      VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "[error] Unknown option: $1" >&2
      usage
      ;;
  esac
done

PKG_NAME="@agent360/browser-mcp@${VERSION}"
MCP_NAME="agent360-browser"

# npx の絶対パス検出 (Volta / 一般 PATH 対応)
NPX_PATH=""
if command -v npx >/dev/null 2>&1; then
  NPX_PATH="$(command -v npx)"
elif [[ -x "${HOME}/.volta/bin/npx" ]]; then
  NPX_PATH="${HOME}/.volta/bin/npx"
fi

if [[ -z "$NPX_PATH" ]]; then
  echo "[error] npx executable not found in PATH or ~/.volta/bin/npx" >&2
  exit 1
fi

# npx パスを正規化
NPX_PATH="$(cd "$(dirname "$NPX_PATH")" && pwd)/$(basename "$NPX_PATH")"

echo "=== Agent360 Browser MCP Deployment ==="
echo "Package: $PKG_NAME"
echo "npx:     $NPX_PATH"
echo "Dry run: $DRY_RUN"
echo ""

# 依存ツール確認 (jq, python3)
if ! command -v jq >/dev/null 2>&1; then
  echo "[error] jq is required but not installed." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[error] python3 is required for TOML manipulation/validation." >&2
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
TMP_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap 'rm -rf "$TMP_DIR"' EXIT

# 旧ブラウザMCPや他Browser MCPの検出・警告
check_other_browser_mcps() {
  local target_file="$1"
  local tool_name="$2"

  if [[ ! -f "$target_file" ]]; then
    return 0
  fi

  # browsermcp.io や @modelcontextprotocol/server-puppeteer などの他ブラウザMCPパターンを検査
  if grep -Eq "browsermcp\.io|puppeteer|playwright|agent360_browser" "$target_file" 2>/dev/null; then
    echo "[warn] [$tool_name] Another browser MCP or legacy configuration detected in: $target_file"
    echo "       (Existing entries will not be automatically deleted)"
  fi
}

# 変更適用ヘルパー
apply_update() {
  local file_path="$1"
  local tmp_new_file="$2"
  local tool_name="$3"

  local parent_dir
  parent_dir="$(dirname "$file_path")"

  # symlink の実体を解決
  local real_file_path="$file_path"
  if [[ -L "$file_path" ]]; then
    real_file_path="$(readlink -f "$file_path")"
  fi

  if [[ ! -d "$parent_dir" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "[info] [$tool_name] Would create directory: $parent_dir"
    else
      mkdir -p "$parent_dir"
    fi
  fi

  if [[ ! -f "$real_file_path" ]]; then
    echo "[info] [$tool_name] File does not exist: $file_path (will create new)"
    if [[ "$DRY_RUN" == true ]]; then
      echo "--- /dev/null"
      echo "+++ $file_path"
      diff -u /dev/null "$tmp_new_file" || true
      echo "[dry-run] [$tool_name] Would create $file_path"
    else
      mkdir -p "$parent_dir"
      cp "$tmp_new_file" "$file_path"
      echo "[ok] [$tool_name] Created $file_path"
    fi
    return 0
  fi

  # 変更があるか cmp で確認
  if cmp -s "$real_file_path" "$tmp_new_file"; then
    echo "[ok] [$tool_name] No changes needed (already up to date): $file_path"
    return 0
  fi

  echo "[info] [$tool_name] Differences detected in $file_path:"
  diff -u "$real_file_path" "$tmp_new_file" || true

  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] [$tool_name] Would update $file_path"
  else
    # バックアップ作成 (実体ファイルに対して作成)
    local backup_file="${real_file_path}.bak.${TIMESTAMP}"
    cp -p "$real_file_path" "$backup_file"
    echo "[backup] [$tool_name] Backup created: $backup_file"

    # symlink の実体に対して更新（symlink が壊れないように）
    cp "$tmp_new_file" "$real_file_path"
    echo "[ok] [$tool_name] Updated $file_path"
  fi
}

# -------------------------------------------------------------
# 1. OpenCode (~/.config/opencode/opencode.json)
# -------------------------------------------------------------
update_opencode() {
  local target_file="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
  local tool_name="OpenCode"
  local tmp_file="$TMP_DIR/opencode.json"

  echo "--- Processing $tool_name ($target_file) ---"
  check_other_browser_mcps "$target_file" "$tool_name"

  local base_json="{}"
  if [[ -f "$target_file" ]]; then
    if ! jq empty "$target_file" 2>/dev/null; then
      echo "[error] [$tool_name] Existing $target_file is invalid JSON. Aborting update for this file." >&2
      return 1
    fi
    base_json="$(cat "$target_file")"
  fi

  # OpenCode schema
  echo "$base_json" | jq \
    --arg name "$MCP_NAME" \
    --arg npx "$NPX_PATH" \
    --arg pkg "$PKG_NAME" \
    '
    .mcp = (.mcp // {}) |
    .mcp[$name] = {
      "type": "local",
      "command": [$npx, "-y", $pkg],
      "enabled": true
    }
    ' > "$tmp_file"

  if ! jq empty "$tmp_file" 2>/dev/null; then
    echo "[error] [$tool_name] Generated JSON failed validation." >&2
    return 1
  fi

  apply_update "$target_file" "$tmp_file" "$tool_name"
}

# -------------------------------------------------------------
# 2. Antigravity CLI (~/.gemini/config/mcp_config.json)
# -------------------------------------------------------------
update_antigravity() {
  local target_file="${HOME}/.gemini/config/mcp_config.json"
  local tool_name="Antigravity CLI"
  local tmp_file="$TMP_DIR/mcp_config.json"

  echo "--- Processing $tool_name ($target_file) ---"
  check_other_browser_mcps "$target_file" "$tool_name"

  local base_json="{}"
  if [[ -f "$target_file" ]]; then
    if ! jq empty "$target_file" 2>/dev/null; then
      echo "[error] [$tool_name] Existing $target_file is invalid JSON. Aborting update for this file." >&2
      return 1
    fi
    base_json="$(cat "$target_file")"
  fi

  # agy schema
  echo "$base_json" | jq \
    --arg name "$MCP_NAME" \
    --arg npx "$NPX_PATH" \
    --arg pkg "$PKG_NAME" \
    '
    .mcpServers = (.mcpServers // {}) |
    .mcpServers[$name] = {
      "command": $npx,
      "args": ["-y", $pkg],
      "disabled": false
    }
    ' > "$tmp_file"

  if ! jq empty "$tmp_file" 2>/dev/null; then
    echo "[error] [$tool_name] Generated JSON failed validation." >&2
    return 1
  fi

  apply_update "$target_file" "$tmp_file" "$tool_name"
}

# -------------------------------------------------------------
# 3. Codex (~/.codex/config.toml)
# -------------------------------------------------------------
update_codex() {
  local target_file="${HOME}/.codex/config.toml"
  local tool_name="Codex"
  local tmp_file="$TMP_DIR/config.toml"

  echo "--- Processing $tool_name ($target_file) ---"
  check_other_browser_mcps "$target_file" "$tool_name"

  # Validate existing TOML if file exists
  if [[ -f "$target_file" ]]; then
    if ! python3 -c "
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        sys.exit(0)
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    tomllib.loads(f.read())
" "$target_file" 2>/dev/null; then
      echo "[error] [$tool_name] Existing $target_file is invalid TOML. Aborting update for this file." >&2
      return 1
    fi
  fi

  # Python script to safely parse and merge/update the section
  python3 -c "
import sys

target_file = sys.argv[1]
tmp_file = sys.argv[2]
npx_path = sys.argv[3]
pkg_name = sys.argv[4]

section_header = '[mcp_servers.agent360-browser]'
section_body = f'{section_header}\ncommand = \"{npx_path}\"\nargs = [\"-y\", \"{pkg_name}\"]\n'

content = ''
try:
    with open(target_file, 'r', encoding='utf-8') as f:
        content = f.read()
except FileNotFoundError:
    content = ''

lines = content.splitlines(keepends=True)
in_section = False
start_idx = -1
end_idx = -1

for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        if stripped == section_header:
            in_section = True
            start_idx = i
        elif in_section:
            end_idx = i
            break

if in_section and end_idx == -1:
    end_idx = len(lines)

if in_section:
    new_lines = lines[:start_idx] + [section_body] + lines[end_idx:]
else:
    new_lines = list(lines)
    if new_lines and not new_lines[-1].endswith('\n'):
        new_lines[-1] = new_lines[-1] + '\n'
    if new_lines and new_lines[-1].strip() != '':
        new_lines.append('\n')
    new_lines.append(section_body)

new_content = ''.join(new_lines)

# Validate TOML syntax
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        tomllib = None

if tomllib is not None:
    tomllib.loads(new_content)

with open(tmp_file, 'w', encoding='utf-8') as f:
    f.write(new_content)
" "$target_file" "$tmp_file" "$NPX_PATH" "$PKG_NAME"

  apply_update "$target_file" "$tmp_file" "$tool_name"
}

# -------------------------------------------------------------
# 4. agent (Cursor) (~/.cursor/mcp.json)
# -------------------------------------------------------------
update_cursor() {
  local target_file="${HOME}/.cursor/mcp.json"
  local tool_name="agent (Cursor)"
  local tmp_file="$TMP_DIR/cursor_mcp.json"

  echo "--- Processing $tool_name ($target_file) ---"
  check_other_browser_mcps "$target_file" "$tool_name"

  local base_json="{}"
  if [[ -f "$target_file" ]]; then
    if ! jq empty "$target_file" 2>/dev/null; then
      echo "[error] [$tool_name] Existing $target_file is invalid JSON. Aborting update for this file." >&2
      return 1
    fi
    base_json="$(cat "$target_file")"
  fi

  # Cursor mcp.json standard
  echo "$base_json" | jq \
    --arg name "$MCP_NAME" \
    --arg npx "$NPX_PATH" \
    --arg pkg "$PKG_NAME" \
    '
    .mcpServers = (.mcpServers // {}) |
    .mcpServers[$name] = {
      "command": $npx,
      "args": ["-y", $pkg]
    }
    ' > "$tmp_file"

  if ! jq empty "$tmp_file" 2>/dev/null; then
    echo "[error] [$tool_name] Generated JSON failed validation." >&2
    return 1
  fi

  apply_update "$target_file" "$tmp_file" "$tool_name"
}

# -------------------------------------------------------------
# 5. codebuddy (~/.codebuddy/.mcp.json)
# -------------------------------------------------------------
update_codebuddy() {
  local target_file="${HOME}/.codebuddy/mcp.json"
  local tool_name="codebuddy"
  local tmp_file="$TMP_DIR/codebuddy_mcp.json"

  echo "--- Processing $tool_name ($target_file) ---"
  check_other_browser_mcps "$target_file" "$tool_name"

  local base_json="{}"
  if [[ -f "$target_file" ]]; then
    if ! jq empty "$target_file" 2>/dev/null; then
      echo "[error] [$tool_name] Existing $target_file is invalid JSON. Aborting update for this file." >&2
      return 1
    fi
    base_json="$(cat "$target_file")"
  fi

  # codebuddy schema
  echo "$base_json" | jq \
    --arg name "$MCP_NAME" \
    --arg npx "$NPX_PATH" \
    --arg pkg "$PKG_NAME" \
    '
    .mcpServers = (.mcpServers // {}) |
    .mcpServers[$name] = {
      "command": $npx,
      "args": ["-y", $pkg]
    }
    ' > "$tmp_file"

  if ! jq empty "$tmp_file" 2>/dev/null; then
    echo "[error] [$tool_name] Generated JSON failed validation." >&2
    return 1
  fi

  apply_update "$target_file" "$tmp_file" "$tool_name"
}

# 実行
ERRORS=0

update_opencode || ERRORS=$((ERRORS + 1))
echo ""
update_antigravity || ERRORS=$((ERRORS + 1))
echo ""
update_codex || ERRORS=$((ERRORS + 1))
echo ""
update_cursor || ERRORS=$((ERRORS + 1))
echo ""
update_codebuddy || ERRORS=$((ERRORS + 1))
echo ""

if [[ "$ERRORS" -gt 0 ]]; then
  echo "[done] Finished with $ERRORS error(s)."
  exit 1
else
  echo "[done] All MCP configurations processed successfully."
  exit 0
fi
