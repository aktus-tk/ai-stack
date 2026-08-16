# ai-stack OpenCode image
# opencode CLI / opencode-server / harness-mem daemon を同一 image で提供する。
#
#   - OpenCode (opencode CLI)
#   - harness-mem (MCP サーバー + memory daemon)
#   - Node.js / bun (harness-mem 実行に必要)
#   - git / shell (OpenCode 実作業に必要な CLI)
#
# ビルド:
#   docker compose build opencode

FROM node:22-slim AS base

# 基本ツール (ネイティブビルド不要のため最小限)
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
      curl \
      ca-certificates \
      unzip \
      bash \
      && rm -rf /var/lib/apt/lists/*

# bun (harness-mem daemon / UI 実行に必要)
RUN curl -fsSL https://bun.sh/install | bash

# リソース制約下でも確実にビルドできるよう npm の並列数を抑える
ENV NODE_OPTIONS="--max-old-space-size=512" \
    npm_config_audit=false \
    npm_config_fund=false

# OpenCode CLI (npm)
ARG OPENCODE_VERSION=1.18.18
RUN npm install -g --no-audit --no-fund --maxsockets 4 opencode-ai@${OPENCODE_VERSION}

# harness-mem (MCP server + memory daemon + UI)
ARG HARNESS_MEM_VERSION=0.29.3
RUN npm install -g --no-audit --no-fund --maxsockets 4 @chachamaru127/harness-mem@${HARNESS_MEM_VERSION}

# harness-mem の固定パス (scripts/harness-memd が参照する場所)
RUN HARNESS_PKG="$(npm root -g)/@chachamaru127/harness-mem" \
    && mkdir -p /opt/harness-mem \
    && ln -s "${HARNESS_PKG}" /opt/harness-mem/current

ENV HOME="/home/tk" \
    PATH="/root/.bun/bin:${PATH}" \
    HARNESS_MEM_HOME="/home/tk/.harness-mem" \
    OPENCODE_DATA="/home/tk/.local/share/opencode" \
    OPENCODE_CONFIG_DIR="/home/tk/.config/opencode"

# 作業プロジェクト用ディレクトリ作成
RUN mkdir -p /home/tk/ai-stack /home/tk/scratch

WORKDIR /workspace

# バージョン確認 (build 時の検証)
RUN opencode --version \
    && bun --version \
    && node --version \
    && ls /opt/harness-mem/current/bin/harness-mcp-server

# ENTRYPOINT は設定しない。
# opencode (CLI/Server) と harness-memd の両方を同一 image から起動するため、
# compose の command で実行コマンドを指定する。
#   - opencode-server: ["opencode", "web", ...]
#   - opencode CLI:    docker compose run ... opencode
#   - harness-memd:    ["bun", "run", "/opt/harness-mem/memory-server/src/index.ts"]
