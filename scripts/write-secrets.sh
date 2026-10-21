#!/usr/bin/env bash
# Writes Config/Secrets.xcconfig (gitignored) with the Convex deployment URLs and the API token
# from ~/.config/poddle/api-token. Never prints the token.
#
#   scripts/write-secrets.sh
#   PODDLE_TOKEN_FILE=/path/to/token scripts/write-secrets.sh
set -euo pipefail

cd "$(dirname "$0")/.."
TOKEN_FILE=${PODDLE_TOKEN_FILE:-"$HOME/.config/poddle/api-token"}
OUT=Config/Secrets.xcconfig

if [ ! -r "$TOKEN_FILE" ]; then
  echo "No API token at $TOKEN_FILE" >&2
  exit 1
fi
token=$(tr -d '[:space:]' < "$TOKEN_FILE")
if [ -z "$token" ]; then
  echo "$TOKEN_FILE is empty" >&2
  exit 1
fi
# xcconfig has no quoting: $ starts a variable and // a comment. Refuse anything odd rather than
# writing a token that silently gets cut short.
if [[ ! "$token" =~ ^[A-Za-z0-9._~+=/-]+$ ]]; then
  echo "The token has characters an xcconfig can't hold" >&2
  exit 1
fi
escaped=${token//\/\//\/\$()\/}

umask 077
{
  echo '// Written by scripts/write-secrets.sh. Gitignored; never commit it.'
  echo '// xcconfig treats // as a comment, so URLs are written https:/$()/…'
  echo 'PODDLE_CONVEX_URL_DEBUG = https:/$()/qualified-hedgehog-912.convex.cloud'
  echo 'PODDLE_CONVEX_URL_RELEASE = https:/$()/coordinated-dodo-120.ap-southeast-2.convex.cloud'
  printf 'PODDLE_API_TOKEN = %s\n' "$escaped"
} > "$OUT"
echo "Wrote $OUT"
