#!/usr/bin/env bash
#
# deploy.sh - deploy the static portfolio to a remote server over SSH.
#
# The site is plain HTML/CSS/JS with no build step, so deployment is:
#   1. pack the source tree (excluding repo/dev files)
#   2. stream it over SSH into a staging directory
#   3. atomically swap staging into place (previous release kept for rollback)
#   4. optionally install/configure nginx, then reload it
#
# Usage:
#   ./deploy.sh                       deploy with the defaults below
#   ./deploy.sh --setup               also install + configure nginx
#   ./deploy.sh --domain example.com  set nginx server_name
#   ./deploy.sh --dry-run             show what would happen, change nothing
#   ./deploy.sh --rollback            restore the previous release
#   ./deploy.sh --help
#
set -euo pipefail

# ---------------------------------------------------------------- config ----
HOST="${DEPLOY_HOST:-169.58.83.145}"
USER="${DEPLOY_USER:-root}"
PORT="${DEPLOY_PORT:-22}"
REMOTE_DIR="${DEPLOY_DIR:-/var/www/portfolio}"
DOMAIN="${DEPLOY_DOMAIN:-}"          # empty => nginx answers on any host/IP
WEB_USER="${DEPLOY_WEB_USER:-www-data}"
SSH_OPTS="${DEPLOY_SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=15}"

SETUP_NGINX=0
DRY_RUN=0
ROLLBACK=0
SKIP_RELOAD=0

# Files that live in the repo but must never reach the web root.
EXCLUDES=(
  ".git" ".github" ".gitignore" ".thumbnail"
  "deploy.sh" "README.md" "node_modules" ".DS_Store" ".vscode" ".claude"
  # Anchored to the root: a bare "game" would also match assets/game,
  # which holds the sprites the site actually serves.
  "./game"
  "./Shariorfarhan.png"   # 1MB logo source; the web copies are assets/icons/*
)

# ----------------------------------------------------------------- utils ----
c_reset=$'\033[0m'; c_blue=$'\033[34m'; c_green=$'\033[32m'
c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'

log()  { printf '%s==>%s %s\n' "$c_blue"   "$c_reset" "$*"; }
ok()   { printf '%s  OK%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn() { printf '%s   !%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die()  { printf '%s   x%s %s\n' "$c_red"    "$c_reset" "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '%s  would run:%s %s\n' "$c_dim" "$c_reset" "$*"; else "$@"; fi; }

# Print the header comment block only (everything up to the first blank line).
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

# ------------------------------------------------------------------ args ----
while [ $# -gt 0 ]; do
  case "$1" in
    --host)      HOST="$2"; shift 2 ;;
    --user)      USER="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --dir)       REMOTE_DIR="$2"; shift 2 ;;
    --domain)    DOMAIN="$2"; shift 2 ;;
    --setup)     SETUP_NGINX=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --rollback)  ROLLBACK=1; shift ;;
    --no-reload) SKIP_RELOAD=1; shift ;;
    -h|--help)   usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$USER@$HOST"
# shellcheck disable=SC2206
SSH=(ssh $SSH_OPTS -p "$PORT" "$TARGET")

RELEASE="$(date +%Y%m%d-%H%M%S)"
STAGING="${REMOTE_DIR}.staging.${RELEASE}"
PREVIOUS="${REMOTE_DIR}.previous"

# ------------------------------------------------------- preflight checks ---
log "Deploying $(basename "$SRC_DIR") -> ${TARGET}:${REMOTE_DIR}"
[ "$DRY_RUN" -eq 1 ] && warn "dry run - no remote changes will be made"

[ -f "$SRC_DIR/index.html" ] || die "index.html not found in $SRC_DIR - run this from the project root"

log "Checking SSH connectivity to ${TARGET}:${PORT}"
"${SSH[@]}" true 2>/dev/null || die "cannot reach ${TARGET} on port ${PORT} over SSH (key auth required)"
ok "SSH reachable"

# Everything below writes outside $HOME, so we need root or passwordless sudo.
SUDO=""
if [ "$USER" != "root" ]; then
  if "${SSH[@]}" "sudo -n true" 2>/dev/null; then
    SUDO="sudo -n"
  else
    die "user '$USER' is not root and has no passwordless sudo - needed to write $REMOTE_DIR"
  fi
fi

# Resolve the web user on the remote side: Debian uses www-data, RHEL uses nginx.
RESOLVE_WEB_USER="web_user='$WEB_USER'
  id -u \"\$web_user\" >/dev/null 2>&1 || web_user=nginx
  id -u \"\$web_user\" >/dev/null 2>&1 || web_user=\$(id -un)"

# --------------------------------------------------------------- rollback ---
if [ "$ROLLBACK" -eq 1 ]; then
  log "Rolling back to the previous release"
  run "${SSH[@]}" "set -e
    [ -d '$PREVIOUS' ] || { echo 'no previous release at $PREVIOUS' >&2; exit 1; }
    $SUDO rm -rf '${REMOTE_DIR}.swap'
    $SUDO mv '$REMOTE_DIR' '${REMOTE_DIR}.swap'
    $SUDO mv '$PREVIOUS' '$REMOTE_DIR'
    $SUDO mv '${REMOTE_DIR}.swap' '$PREVIOUS'"
  if [ "$SKIP_RELOAD" -eq 0 ]; then
    run "${SSH[@]}" "$SUDO nginx -t && $SUDO systemctl reload nginx" || warn "nginx reload failed"
  fi
  ok "Rolled back."
  exit 0
fi

# ------------------------------------------------------------ nginx setup ---
if [ "$SETUP_NGINX" -eq 1 ]; then
  if [ -n "$DOMAIN" ]; then
    server_name="$DOMAIN www.$DOMAIN"
  else
    server_name="_"
  fi

  log "Installing and configuring nginx (server_name: $server_name)"
  run "${SSH[@]}" "set -e
    if ! command -v nginx >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        $SUDO apt-get update -qq
        $SUDO apt-get install -y -qq nginx
      elif command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y nginx
      elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y nginx
      else
        echo 'no supported package manager found; install nginx manually' >&2; exit 1
      fi
    fi

    conf_dir=/etc/nginx/sites-available
    [ -d \"\$conf_dir\" ] || conf_dir=/etc/nginx/conf.d

    $SUDO tee \"\$conf_dir/portfolio.conf\" >/dev/null <<'NGINXCONF'
server {
    listen 80;
    listen [::]:80;
    server_name __SERVER_NAME__;

    root __ROOT__;
    index index.html;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Static assets change rarely and are safe to cache hard.
    location ~* \.(?:css|js|jpg|jpeg|png|gif|svg|webp|ico|woff2?|ttf|pdf)\$ {
        expires 30d;
        add_header Cache-Control \"public, max-age=2592000\";
        access_log off;
    }

    # Never cache the entry document, so a deploy is visible immediately.
    location = /index.html {
        add_header Cache-Control \"no-cache, must-revalidate\";
    }

    gzip on;
    gzip_vary on;
    gzip_min_length 256;
    gzip_types text/plain text/css text/javascript application/javascript
               application/json image/svg+xml;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header Referrer-Policy strict-origin-when-cross-origin;

    location ~ /\. { deny all; }
}
NGINXCONF

    $SUDO sed -i \"s|__SERVER_NAME__|$server_name|; s|__ROOT__|$REMOTE_DIR|\" \"\$conf_dir/portfolio.conf\"

    # Debian/Ubuntu layout: enable our site, retire the packaged default.
    if [ -d /etc/nginx/sites-enabled ]; then
      $SUDO ln -sfn \"\$conf_dir/portfolio.conf\" /etc/nginx/sites-enabled/portfolio.conf
      $SUDO rm -f /etc/nginx/sites-enabled/default
    fi

    $SUDO mkdir -p '$REMOTE_DIR'
    $SUDO nginx -t
    $SUDO systemctl enable nginx >/dev/null 2>&1 || true
    $SUDO systemctl restart nginx"
  ok "nginx configured"
fi

# -------------------------------------------------------------- transfer ----
log "Packing site files"
tar_excludes=()
for e in "${EXCLUDES[@]}"; do tar_excludes+=(--exclude="$e"); done

if [ "$DRY_RUN" -eq 1 ]; then
  tar -cf /dev/null -C "$SRC_DIR" "${tar_excludes[@]}" -v . 2>/dev/null \
    | sed 's|^\./||; /^$/d' | sort | sed 's/^/      /'
  printf '%s  would upload the files above to %s%s\n' "$c_dim" "$STAGING" "$c_reset"
else
  # Stream a tarball straight into a staging dir: no rsync needed on either
  # end, and the live directory stays untouched until the swap below.
  tar -czf - -C "$SRC_DIR" "${tar_excludes[@]}" . \
    | "${SSH[@]}" "set -e
        $SUDO rm -rf '$STAGING'
        $SUDO mkdir -p '$STAGING'
        $SUDO tar -xzf - -C '$STAGING'"
  ok "Uploaded to staging"
fi

# --------------------------------------------------------- swap into place --
log "Activating release $RELEASE"
run "${SSH[@]}" "set -e
  $RESOLVE_WEB_USER

  $SUDO chown -R \"\$web_user\":\"\$web_user\" '$STAGING'
  $SUDO find '$STAGING' -type d -exec chmod 755 {} +
  $SUDO find '$STAGING' -type f -exec chmod 644 {} +

  $SUDO mkdir -p '$REMOTE_DIR'
  $SUDO rm -rf '$PREVIOUS'
  $SUDO mv '$REMOTE_DIR' '$PREVIOUS'
  $SUDO mv '$STAGING' '$REMOTE_DIR'

  # SELinux hosts need the web-content label or nginx serves 403s.
  if command -v restorecon >/dev/null 2>&1; then $SUDO restorecon -R '$REMOTE_DIR'; fi"
ok "Release live (previous kept at $PREVIOUS)"

# ---------------------------------------------------------------- reload ----
if [ "$SKIP_RELOAD" -eq 0 ]; then
  log "Reloading nginx"
  if [ "$DRY_RUN" -eq 1 ]; then
    run "${SSH[@]}" "nginx -t && systemctl reload nginx"
  elif "${SSH[@]}" "command -v nginx >/dev/null 2>&1"; then
    if "${SSH[@]}" "$SUDO nginx -t && $SUDO systemctl reload nginx"; then
      ok "nginx reloaded"
    else
      warn "nginx reload failed - check 'nginx -t' on the server"
    fi
  else
    warn "nginx not installed on the server - re-run with --setup to install it"
  fi
fi

# ----------------------------------------------------------- verification ---
if [ "$DRY_RUN" -eq 0 ]; then
  log "Verifying"
  "${SSH[@]}" "test -f '$REMOTE_DIR/index.html'" \
    && ok "index.html present in $REMOTE_DIR" \
    || die "index.html missing after deploy"

  code="$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: ${DOMAIN:-localhost}' http://127.0.0.1/ 2>/dev/null || true")"
  case "$code" in
    200) ok "HTTP 200 from the server" ;;
    "")  warn "could not check HTTP locally (curl missing on server)" ;;
    *)   warn "server returned HTTP $code - check logs: journalctl -u nginx -n 50" ;;
  esac
fi

printf '\n%sDone.%s Site: %shttp://%s/%s\n' \
  "$c_green" "$c_reset" "$c_blue" "${DOMAIN:-$HOST}" "$c_reset"
printf '%sRollback with:%s ./deploy.sh --rollback\n' "$c_dim" "$c_reset"
