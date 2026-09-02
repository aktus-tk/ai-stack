#!/usr/bin/env bash
# setup-links.sh — ai-stack の AI ツール設定 symlink + Agent360 Browser MCP セットアップ
#
# 何をするか:
#   1. リポジトリの AGENTS.md / skills / opencode config を各 AI ツールの
#      runtime ディレクトリへ symlink する (idempotent)
#   2. Agent360 Browser MCP を各ツールの設定へマージする
#
# SSOT:
#   $REPO_ROOT/AGENTS.md
#   $REPO_ROOT/skills/
#   $REPO_ROOT/config/opencode/
#
# 使い方:
#   ./scripts/setup-links.sh                    # 確認プロンプト付き
#   ./scripts/setup-links.sh --force            # 確認なしで実行
#   ./scripts/setup-links.sh --dry-run          # 変更せず状態・計画のみ表示
#   ./scripts/setup-links.sh --verify             # symlink 検証のみ
#   ./scripts/setup-links.sh --links-only         # symlink のみ (MCP スキップ)
#   ./scripts/setup-links.sh --mcp-only           # MCP のみ
#   ./scripts/setup-links.sh --mcp-version 1.25.0 # MCP バージョン指定

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# --- SSOT ---
REPO_AGENTS="$REPO_ROOT/AGENTS.md"
REPO_SKILLS="$REPO_ROOT/skills"
REPO_OPENCODE_CONFIG="$REPO_ROOT/config/opencode"
REPO_OPENCODE_JSON="$REPO_OPENCODE_CONFIG/opencode.json"
REPO_INSTRUCTIONS="$REPO_OPENCODE_CONFIG/instructions"

OPENCODE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
AGY_CONFIG_DIR="$HOME/.gemini/config"

LINKS=(
  "opencode AGENTS.md|$OPENCODE_CONFIG_DIR/AGENTS.md|$REPO_AGENTS"
  "opencode skills|$OPENCODE_CONFIG_DIR/skills|$REPO_SKILLS"
  "opencode opencode.json|$OPENCODE_CONFIG_DIR/opencode.json|$REPO_OPENCODE_JSON"
  "opencode instructions|$OPENCODE_CONFIG_DIR/instructions|$REPO_INSTRUCTIONS"
  "codebuddy AGENTS.md|$HOME/.codebuddy/AGENTS.md|$REPO_AGENTS"
  "codebuddy skills|$HOME/.codebuddy/skills|$REPO_SKILLS"
  "codex AGENTS.md|$HOME/.codex/AGENTS.md|$REPO_AGENTS"
  "codex skills|$HOME/.codex/skills|$REPO_SKILLS"
  "cursor AGENTS.md|$HOME/.cursor/AGENTS.md|$REPO_AGENTS"
  "cursor skills|$HOME/.cursor/skills|$REPO_SKILLS"
  "claude AGENTS.md|$HOME/.claude/AGENTS.md|$REPO_AGENTS"
  "claude skills|$HOME/.claude/skills|$REPO_SKILLS"
  "agy AGENTS.md|$AGY_CONFIG_DIR/AGENTS.md|$REPO_AGENTS"
  "agy skills|$AGY_CONFIG_DIR/skills|$REPO_SKILLS"
)

MODE="interactive"
LINKS_ONLY=false
MCP_ONLY=false
MCP_VERSION="latest"
MCP_DRY_RUN=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Symlink options:
  (no args)     確認プロンプト付きで symlink + MCP を実行
  --force       確認なしで実行
  --dry-run     変更せず状態・計画のみ表示
  --verify      symlink 検証のみ (0=正常 / 1=要対応)
  --links-only  symlink のみ (MCP スキップ)

MCP options:
  --mcp-only            Agent360 Browser MCP のみ
  --mcp-version <ver>   MCP package version (default: latest)

  -h, --help            このヘルプを表示
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; MCP_DRY_RUN=true; shift ;;
    --verify) MODE="verify"; shift ;;
    --force) MODE="force"; shift ;;
    --links-only) LINKS_ONLY=true; shift ;;
    --mcp-only) MCP_ONLY=true; shift ;;
    --mcp-version)
      if [[ -z "${2:-}" || "$2" =~ ^-- ]]; then
        echo "[error] --mcp-version requires an argument" >&2
        exit 1
      fi
      MCP_VERSION="$2"
      shift 2
      ;;
    -h|--help) usage ;;
    *)
      echo "[error] Unknown option: $1" >&2
      usage
      ;;
  esac
done

if [[ "$LINKS_ONLY" == true && "$MCP_ONLY" == true ]]; then
  echo "[error] --links-only and --mcp-only are mutually exclusive" >&2
  exit 1
fi

# =============================================================================
# Symlink helpers
# =============================================================================

check_link() {
  local link="$1"
  local target="$2"

  if [[ -L "$link" ]]; then
    local resolved
    resolved=$(readlink -f "$link" 2>/dev/null || true)
    if [[ "$resolved" == "$target" ]]; then
      echo "ok"
    elif [[ "$(readlink "$link")" == *"ai-stack"* ]]; then
      echo "wrong-repo"
    else
      echo "wrong-other"
    fi
  elif [[ -e "$link" || -d "$link" ]]; then
    echo "regular"
  else
    echo "missing"
  fi
}

process_link() {
  local name="$1"
  local link="$2"
  local target="$3"
  local do_changes="$4"

  local status
  status=$(check_link "$link" "$target")

  case "$status" in
    ok)
      echo "[ok] $name: already correct"
      ;;
    missing)
      echo "[info] $name: missing → 作成予定: $link → $target"
      if [[ "$do_changes" == true ]]; then
        mkdir -p "$(dirname "$link")"
        ln -s "$target" "$link"
        echo "[ok] $name: created ($(readlink "$link"))"
      else
        NEEDS_CHANGE=true
      fi
      ;;
    wrong-repo)
      echo "[info] $name: wrong symlink (ai-stack を参照) → 張り替え"
      echo "        before: $(readlink "$link")"
      if [[ "$do_changes" == true ]]; then
        ln -sfn "$target" "$link"
        echo "        after : $(readlink "$link")"
        echo "[ok] $name: replaced"
      else
        echo "        after : $target (未変更)"
        NEEDS_CHANGE=true
      fi
      ;;
    wrong-other)
      echo "[error] $name: symlink points to unexpected target"
      echo "        Path   : $link"
      echo "        Current: $(readlink "$link")"
      echo "        Expected: $target"
      echo "        To fix : 手動で確認・修正してから再実行してください。"
      HAS_ERROR=true
      ;;
    regular)
      echo "[error] $name: exists as regular file/directory (not symlink)"
      echo "        Path   : $link"
      echo "        To fix : 手動で退避・削除してから再実行してください。"
      HAS_ERROR=true
      ;;
  esac
}

print_all_links() {
  local entry name link target status
  for entry in "${LINKS[@]}"; do
    IFS='|' read -r name link target <<< "$entry"
    status=$(check_link "$link" "$target")
    printf "  [%-11s] %-20s %s\n" "$status" "$name" "$link"
    if [[ -L "$link" ]]; then
      printf "              → %s\n" "$(readlink "$link")"
    fi
  done
}

verify_ssot() {
  local missing=false
  if [[ ! -f "$REPO_AGENTS" ]]; then
    echo "[error] SSOT not found: $REPO_AGENTS"
    missing=true
  fi
  if [[ ! -d "$REPO_SKILLS" ]]; then
    echo "[error] SSOT not found: $REPO_SKILLS"
    missing=true
  fi
  if [[ ! -f "$REPO_OPENCODE_JSON" ]]; then
    echo "[error] SSOT not found: $REPO_OPENCODE_JSON"
    missing=true
  fi
  if [[ ! -d "$REPO_INSTRUCTIONS" ]]; then
    echo "[error] SSOT not found: $REPO_INSTRUCTIONS"
    missing=true
  fi
  if [[ "$missing" == true ]]; then
    exit 1
  fi
}

run_links_setup() {
  HAS_ERROR=false
  NEEDS_CHANGE=false

  echo "=== ai-stack symlink 状態チェック ==="
  echo "SSOT: $REPO_ROOT"

  if [[ "$MODE" != "force" ]]; then
    for entry in "${LINKS[@]}"; do
      IFS='|' read -r name link target <<< "$entry"
      process_link "$name" "$link" "$target" false
    done
  fi

  if [[ "$HAS_ERROR" == true ]]; then
    echo ""
    echo "[error] 自動修正できないリンクがあります。上の To fix に従って手動対応してください"
    return 1
  fi

  case "$MODE" in
    verify)
      echo ""
      echo "[ok] All symlinks are correct"
      return 0
      ;;
    dry-run)
      echo ""
      echo "[dry-run] symlink 変更は行いませんでした (必要なら --force で実行)"
      return 0
      ;;
    interactive)
      if [[ "$NEEDS_CHANGE" != true ]]; then
        echo ""
        echo "[ok] symlink 変更は不要です"
        return 0
      fi
      read -r -p "上記の symlink 変更を実行しますか? [y/N] " ans
      if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
        echo "中止しました。symlink 変更は行いません"
        return 0
      fi
      ;;
  esac

  echo ""
  echo "=== symlink 実行 ==="
  for entry in "${LINKS[@]}"; do
    IFS='|' read -r name link target <<< "$entry"
    process_link "$name" "$link" "$target" true
  done

  echo ""
  echo "=== 実行後の全 symlink 状態 ==="
  print_all_links

  if [[ "$HAS_ERROR" == true ]]; then
    echo ""
    echo "[error] 一部の symlink が修正できませんでした"
    return 1
  fi

  echo ""
  echo "[done] Symlink setup complete"
}

# =============================================================================
# Agent360 Browser MCP deployment
# =============================================================================

deploy_agent360_mcp() {
  local pkg_name="@agent360/browser-mcp@${MCP_VERSION}"
  local mcp_name="agent360-browser"
  local dry_run="$MCP_DRY_RUN"

  local npx_path=""
  if command -v npx >/dev/null 2>&1; then
    npx_path="$(command -v npx)"
  elif [[ -x "${HOME}/.volta/bin/npx" ]]; then
    npx_path="${HOME}/.volta/bin/npx"
  fi

  if [[ -z "$npx_path" ]]; then
    echo "[error] npx executable not found in PATH or ~/.volta/bin/npx" >&2
    return 1
  fi
  npx_path="$(cd "$(dirname "$npx_path")" && pwd)/$(basename "$npx_path")"

  if ! command -v jq >/dev/null 2>&1; then
    echo "[error] jq is required but not installed." >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[error] python3 is required for TOML manipulation/validation." >&2
    return 1
  fi

  echo ""
  echo "=== Agent360 Browser MCP Deployment ==="
  echo "Package: $pkg_name"
  echo "npx:     $npx_path"
  echo "Dry run: $dry_run"
  echo ""

  local timestamp tmp_dir
  timestamp="$(date +%Y%m%d_%H%M%S)"
  tmp_dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap 'rm -rf "$tmp_dir"' RETURN

  local mcp_errors=0

  check_other_browser_mcps() {
    local target_file="$1"
    local tool_name="$2"
    if [[ ! -f "$target_file" ]]; then
      return 0
    fi
    if grep -Eq "browsermcp\.io|puppeteer|playwright|agent360_browser" "$target_file" 2>/dev/null; then
      echo "[warn] [$tool_name] Another browser MCP or legacy configuration detected in: $target_file"
      echo "       (Existing entries will not be automatically deleted)"
    fi
  }

  apply_update() {
    local file_path="$1"
    local tmp_new_file="$2"
    local tool_name="$3"

    local parent_dir
    parent_dir="$(dirname "$file_path")"

    local real_file_path="$file_path"
    if [[ -L "$file_path" ]]; then
      real_file_path="$(readlink -f "$file_path")"
    fi

    if [[ ! -d "$parent_dir" ]]; then
      if [[ "$dry_run" == true ]]; then
        echo "[info] [$tool_name] Would create directory: $parent_dir"
      else
        mkdir -p "$parent_dir"
      fi
    fi

    if [[ ! -f "$real_file_path" ]]; then
      echo "[info] [$tool_name] File does not exist: $file_path (will create new)"
      if [[ "$dry_run" == true ]]; then
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

    if cmp -s "$real_file_path" "$tmp_new_file"; then
      echo "[ok] [$tool_name] No changes needed (already up to date): $file_path"
      return 0
    fi

    echo "[info] [$tool_name] Differences detected in $file_path:"
    diff -u "$real_file_path" "$tmp_new_file" || true

    if [[ "$dry_run" == true ]]; then
      echo "[dry-run] [$tool_name] Would update $file_path"
    else
      local backup_file="${real_file_path}.bak.${timestamp}"
      cp -p "$real_file_path" "$backup_file"
      echo "[backup] [$tool_name] Backup created: $backup_file"
      cp "$tmp_new_file" "$real_file_path"
      echo "[ok] [$tool_name] Updated $file_path"
    fi
  }

  update_json_mcp() {
    local target_file="$1"
    local tool_name="$2"
    local tmp_file="$3"
    local jq_expr="$4"

    echo "--- Processing $tool_name ($target_file) ---"
    check_other_browser_mcps "$target_file" "$tool_name"

    local base_json="{}"
    if [[ -f "$target_file" ]]; then
      if ! jq empty "$target_file" 2>/dev/null; then
        echo "[error] [$tool_name] Existing $target_file is invalid JSON." >&2
        return 1
      fi
      base_json="$(cat "$target_file")"
    fi

    echo "$base_json" | jq \
      --arg name "$mcp_name" \
      --arg npx "$npx_path" \
      --arg pkg "$pkg_name" \
      "$jq_expr" > "$tmp_file"

    if ! jq empty "$tmp_file" 2>/dev/null; then
      echo "[error] [$tool_name] Generated JSON failed validation." >&2
      return 1
    fi

    apply_update "$target_file" "$tmp_file" "$tool_name"
  }

  update_opencode_mcp() {
    update_json_mcp \
      "${OPENCODE_CONFIG_DIR}/opencode.json" \
      "OpenCode" \
      "$tmp_dir/opencode.json" \
      '
      .mcp = (.mcp // {}) |
      .mcp[$name] = {
        "type": "local",
        "command": [$npx, "-y", $pkg],
        "enabled": true
      }
      ' || mcp_errors=$((mcp_errors + 1))
    echo ""
  }

  update_antigravity_mcp() {
    update_json_mcp \
      "${AGY_CONFIG_DIR}/mcp_config.json" \
      "Antigravity CLI" \
      "$tmp_dir/mcp_config.json" \
      '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers[$name] = {
        "command": $npx,
        "args": ["-y", $pkg],
        "disabled": false
      }
      ' || mcp_errors=$((mcp_errors + 1))
    echo ""
  }

  update_codex_mcp() {
    local target_file="${HOME}/.codex/config.toml"
    local tool_name="Codex"
    local tmp_file="$tmp_dir/config.toml"

    echo "--- Processing $tool_name ($target_file) ---"
    check_other_browser_mcps "$target_file" "$tool_name"

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
        echo "[error] [$tool_name] Existing $target_file is invalid TOML." >&2
        mcp_errors=$((mcp_errors + 1))
        echo ""
        return
      fi
    fi

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
" "$target_file" "$tmp_file" "$npx_path" "$pkg_name"

    apply_update "$target_file" "$tmp_file" "$tool_name" || mcp_errors=$((mcp_errors + 1))
    echo ""
  }

  update_cursor_mcp() {
    update_json_mcp \
      "${HOME}/.cursor/mcp.json" \
      "agent (Cursor)" \
      "$tmp_dir/cursor_mcp.json" \
      '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers[$name] = {
        "command": $npx,
        "args": ["-y", $pkg]
      }
      ' || mcp_errors=$((mcp_errors + 1))
    echo ""
  }

  update_codebuddy_mcp() {
    update_json_mcp \
      "${HOME}/.codebuddy/mcp.json" \
      "codebuddy" \
      "$tmp_dir/codebuddy_mcp.json" \
      '
      .mcpServers = (.mcpServers // {}) |
      .mcpServers[$name] = {
        "command": $npx,
        "args": ["-y", $pkg]
      }
      ' || mcp_errors=$((mcp_errors + 1))
    echo ""
  }

  update_opencode_mcp
  update_antigravity_mcp
  update_codex_mcp
  update_cursor_mcp
  update_codebuddy_mcp

  if [[ "$mcp_errors" -gt 0 ]]; then
    echo "[done] MCP deployment finished with $mcp_errors error(s)."
    return 1
  fi

  echo "[done] MCP configurations processed successfully."
}

# =============================================================================
# Main
# =============================================================================

verify_ssot

EXIT_CODE=0

if [[ "$MCP_ONLY" != true ]]; then
  run_links_setup || EXIT_CODE=1
fi

if [[ "$LINKS_ONLY" != true && "$MODE" != "verify" ]]; then
  if [[ "$MODE" == "interactive" && "$EXIT_CODE" -ne 0 ]]; then
    echo "[skip] MCP deployment skipped due to symlink errors"
  else
    deploy_agent360_mcp || EXIT_CODE=1
  fi
fi

exit "$EXIT_CODE"
