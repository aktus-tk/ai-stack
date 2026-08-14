#!/bin/bash
# Google Drive を ~/gdrive に rclone マウントする (WSL 用)
# 初回は rclone config create で OAuth 認証が必要 (runbooks/mount-gdrive.md 参照)
set -euo pipefail

MOUNT_POINT="$HOME/gdrive"
LOG_FILE="${RCLONE_LOG_FILE:-/tmp/rclone_mount.log}"

if mountpoint -q "$MOUNT_POINT"; then
  echo "already mounted: $MOUNT_POINT"
  exit 0
fi

mkdir -p "$MOUNT_POINT"

if ! command -v rclone >/dev/null 2>&1; then
  echo "ERROR: rclone not found. sudo apt-get install -y rclone" >&2
  exit 1
fi

if ! rclone listremotes | grep -q '^gdrive:$'; then
  echo "ERROR: gdrive remote not configured. run: rclone config create gdrive drive scope=drive" >&2
  exit 1
fi

rclone mount gdrive: "$MOUNT_POINT" \
  --vfs-cache-mode full \
  --vfs-cache-max-size "${RCLONE_CACHE_MAX:-1G}" \
  --daemon \
  --log-file "$LOG_FILE"

echo "mounted: $MOUNT_POINT"
