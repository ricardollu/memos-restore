#!/usr/bin/env bash
#
# Verify a Memos WebDAV backup by RESTORING it into a throwaway container and
# comparing its latest non-pinned memo against the live instance.
#
# Flow (drift-proof, by-name):
#   1. rclone-download memos_prod_<date>.db from WebDAV  (default date: yesterday)
#   2. boot a disposable `neosmemo/memos` container on that DB
#   3. anchor = newest non-pinned memo IN THE BACKUP
#        GET /api/v1/memos?pageSize=1&filter=pinned==false  on RESTORED
#   4. fetch LIVE's newest non-pinned memos for that SAME creator
#        GET /api/v1/memos?pageSize=10&filter=pinned==false&&creator=="users/N"  on LIVE
#   5. compare by name; exit 0 = anchor present on live (PASS),
#        exit 1 = absent/missing/empty (FAIL)
#
# Why by-name: live legitimately has memos NEWER than the backup, so comparing
# "live's latest" vs "backup's latest" would false-fail. Anchoring on the backup's
# newest memo and checking live still lists it (within the 10 newest non-pinned for
# that creator) tolerates live being ahead.
#
# Required env (see .envrc):
#   WEBDAV_URL  WEBDAV_USER  WEBDAV_PASS  MEMOS_LIVE_URL  MEMOS_TOKEN
# Optional env:
#   BACKUP_DIR (default: memos)  BACKUP_TZ (default: Asia/Hong_Kong)
#   BACKUP_DATE (default: yesterday)  MEMOS_IMAGE (default: neosmemo/memos:0.29.1)
#   VERIFY_PORT (default: 15230)
#
# NOTE: MEMOS_TOKEN must already exist *inside the backup being verified* — the
# token is created on the live instance and only lands in backups taken after it
# was created. A backup older than the token will return an empty (anonymous)
# result and the run will FAIL.
set -euo pipefail

: "${WEBDAV_URL:?set WEBDAV_URL}"
: "${WEBDAV_USER:?set WEBDAV_USER}"
: "${WEBDAV_PASS:?set WEBDAV_PASS}"
: "${MEMOS_LIVE_URL:?set MEMOS_LIVE_URL}"
: "${MEMOS_TOKEN:?set MEMOS_TOKEN}"

BACKUP_DIR="${BACKUP_DIR:-memos}"
BACKUP_TZ="${BACKUP_TZ:-Asia/Hong_Kong}"
BACKUP_DATE="${BACKUP_DATE:-$(TZ="$BACKUP_TZ" date -d "yesterday" +%Y%m%d)}"
MEMOS_IMAGE="${MEMOS_IMAGE:-neosmemo/memos:stable}"
VERIFY_PORT="${VERIFY_PORT:-15230}"

BACKUP_FILE="${BACKUP_DIR}/memos_prod_${BACKUP_DATE}.db"
CNAME="memos-verify-${BACKUP_DATE}-$$"
WORK="$(mktemp -d)"
DATA="$WORK/data"
mkdir -p "$DATA"

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> Verifying backup: $BACKUP_FILE"

# 1. download via rclone (ephemeral env-only WebDAV remote — no rclone.conf needed)
export RCLONE_CONFIG_NS_TYPE=webdav
export RCLONE_CONFIG_NS_URL="$WEBDAV_URL"
export RCLONE_CONFIG_NS_VENDOR=other
export RCLONE_CONFIG_NS_USER="$WEBDAV_USER"
RCLONE_CONFIG_NS_PASS="$(rclone obscure "$WEBDAV_PASS")"
export RCLONE_CONFIG_NS_PASS
rclone copyto "ns:${BACKUP_FILE}" "$DATA/memos_prod.db"
echo "==> Downloaded $(stat -c %s "$DATA/memos_prod.db" 2>/dev/null || echo '?') bytes -> memos_prod.db"

# 2. boot disposable restored instance (mirrors compose.yml: same image + volume target)
docker rm -f "$CNAME" >/dev/null 2>&1 || true
docker run -d --name "$CNAME" -u "$(id -u):$(id -g)" \
  -p "127.0.0.1:${VERIFY_PORT}:5230" \
  -v "$DATA":/var/opt/memos "$MEMOS_IMAGE" >/dev/null

REST_URL="http://127.0.0.1:${VERIFY_PORT}"
printf '==> Waiting for restored instance'
ready=
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$REST_URL/api/v1/memos?pageSize=1" || echo 000)
  if [ "$code" = "200" ]; then ready=1; echo " ready"; break; fi
  printf '.'; sleep 1
done
if [ -z "$ready" ]; then
  echo " TIMEOUT"; docker logs "$CNAME" 2>&1 | tail -20; exit 1
fi

# 3. anchor = newest non-pinned memo captured in the backup (read from restored)
anchor_json="$(curl -s --max-time 20 \
  "$REST_URL/api/v1/memos?pageSize=1&filter=pinned==false" \
  -H "Authorization: Bearer $MEMOS_TOKEN")"
anchor_name="$(printf '%s' "$anchor_json" | jq -r '.memos[0].name // empty' 2>/dev/null || true)"
anchor_creator="$(printf '%s' "$anchor_json" | jq -r '.memos[0].creator // empty' 2>/dev/null || true)"

if [ -z "$anchor_name" ]; then
  echo "RESULT: FAIL — restored instance returned no memo (token not in this backup? data empty? all pinned?)"
  echo "RESTORED: ${anchor_json:0:200}"
  exit 1
fi
echo "ANCHOR (newest non-pinned in backup): $anchor_name (creator=${anchor_creator:-?})"

# 4. fetch live's newest non-pinned memos for that same creator (tolerates live being ahead).
#    --data-urlencode keeps the '&&' inside the filter value instead of splitting params.
live_json="$(curl -s --max-time 20 -G "$MEMOS_LIVE_URL/api/v1/memos" \
  --data-urlencode "pageSize=10" \
  --data-urlencode "filter=pinned==false&&creator==\"${anchor_creator}\"" \
  -H "Authorization: Bearer $MEMOS_TOKEN")"

# 5. compare by name: PASS iff the backup's anchor name is among live's newest non-pinned
if printf '%s' "$live_json" | jq -e --arg n "$anchor_name" 'any(.memos[]?; .name == $n)' >/dev/null 2>&1; then
  echo "RESULT: PASS — backup's newest memo ($anchor_name) is present on live"
  exit 0
fi
live_names="$(printf '%s' "$live_json" | jq -rc '[.memos[]?.name]' 2>/dev/null || true)"
echo "LIVE (newest non-pinned names): ${live_names:-<none>}"
if [ -z "$live_names" ] || [ "$live_names" = "[]" ]; then echo "LIVE raw: ${live_json:0:200}"; fi
echo "RESULT: FAIL — anchor memo ($anchor_name) not found on live (deleted since backup? out of newest-10 window?)"
exit 1
