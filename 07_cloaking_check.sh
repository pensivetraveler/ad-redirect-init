#!/usr/bin/env bash
# Cloaking quick check: compare Human vs AdsBot(-Mobile) vs (optional) Origin-bypass
# Usage:
#   ./cloaking_check.sh "https://sparkling-acc.shop/?gclid=TEST&utm_source=ads" [ORIGIN_IP]

set -euo pipefail

URL="${1:-}"
ORIGIN_IP="${2:-}"   # optional (EC2 public IPv4)
[[ -z "$URL" ]] && { echo "Usage: $0 <URL> [ORIGIN_IP]"; exit 1; }

OUTDIR="$(mktemp -d -t cloakingcheck.XXXXXX)"
trap 'echo; echo "📁 Artifacts saved in: $OUTDIR"' EXIT

hash256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
status_of() { awk '/^HTTP\//{code=$2} END{print code+0}' "$1"; }
len_of()    { wc -c < "$1" | tr -d ' '; }
cf_of()     { awk 'BEGIN{IGNORECASE=1} /^CF-Cache-Status:/{print $0}' "$1" | tail -n1; }
loc_chain() { awk 'BEGIN{IGNORECASE=1} /^Location:/{print $2}' "$1"; }
host_from_url() { echo "$1" | sed -E 's#^https?://([^/]+)/?.*#\1#'; }

HOST="$(host_from_url "$URL")"
PATTERN='http-equiv="refresh"|<meta[^>]+refresh|window\.location|location\.href|setTimeout\(|__cf_chl|cf-.*challenge|noscript|data-cf|rocket-loader'

UA_HUMAN='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
UA_ADSBOT='Mozilla/5.0 (compatible; AdsBot-Google; +http://www.google.com/adsbot.html)'
UA_ADSBOT_M='Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) AdsBot-Google-Mobile'

fetch() { # label ua url [--origin]
  local label="$1"; local ua="$2"; local url="$3"; local origin="${4:-}"
  local H="$OUTDIR/${label}.h"; local B="$OUTDIR/${label}.html"; local U="$OUTDIR/${label}.url"
  if [[ "$origin" == "--origin" && -n "$ORIGIN_IP" ]]; then
    # 원본 인증서가 CF Origin Cert일 수 있어 -k 사용(진단용)
    curl -sSL -k --compressed -m 45 -A "$ua" --resolve "${HOST}:443:${ORIGIN_IP}" \
      -D "$H" -o "$B" -w '%{url_effective}\n' "$url" >"$U"
  else
    curl -sSL --compressed -m 45 -A "$ua" \
      -D "$H" -o "$B" -w '%{url_effective}\n' "$url" >"$U"
  fi
}

report_one() { # label
  local L="$1"; local H="$OUTDIR/${L}.h"; local B="$OUTDIR/${L}.html"; local U="$OUTDIR/${L}.url"
  echo "---- $L ----"
  echo "URL: $(cat "$U")"
  echo "Status: $(status_of "$H")"
  echo "Body: $(len_of "$B") bytes, sha256=$(hash256 "$B")"
  echo "CF: $(cf_of "$H")"
  echo "Redirect chain:"; loc_chain "$H" | sed 's/^/  -> /' || true
  echo "Heuristics (meta refresh / JS redirect / CF challenge markers):"
  if grep -qiE "$PATTERN" "$B"; then grep -niE "$PATTERN" "$B" | head -n 8; else echo "  (none detected)"; fi
  echo
}

compare_headers() { # a b
  local A="$1"; local Bf="$2"
  echo "==== diff headers: $(basename "$A") vs $(basename "$Bf") ===="
  diff -u "$A" "$Bf" || true
  echo
}

summary_line() { # label
  local L="$1"; local B="$OUTDIR/${L}.html"
  printf "%-16s %10s  %s\n" "$L" "$(len_of "$B")" "$(hash256 "$B")"
}

echo "Fetching… (artifacts: $OUTDIR)"
# Cloudflare 경유
fetch human        "$UA_HUMAN"    "$URL"
fetch adsbot       "$UA_ADSBOT"   "$URL"
fetch adsbotm      "$UA_ADSBOT_M" "$URL"
# 원본(옵션)
if [[ -n "$ORIGIN_IP" ]]; then
  fetch human_origin   "$UA_HUMAN"    "$URL" --origin
  fetch adsbot_origin  "$UA_ADSBOT"   "$URL" --origin
  fetch adsbotm_origin "$UA_ADSBOT_M" "$URL" --origin
fi

# 개별 리포트
report_one human
report_one adsbot
report_one adsbotm
[[ -n "$ORIGIN_IP" ]] && { report_one human_origin; report_one adsbot_origin; report_one adsbotm_origin; }

# 헤더 비교 (edge 간)
compare_headers "$OUTDIR/human.h"  "$OUTDIR/adsbot.h"
compare_headers "$OUTDIR/human.h"  "$OUTDIR/adsbotm.h"

# 헤더 비교 (edge ↔ origin 교차)
if [[ -n "$ORIGIN_IP" ]]; then
  compare_headers "$OUTDIR/human.h"     "$OUTDIR/human_origin.h"
  compare_headers "$OUTDIR/adsbot.h"    "$OUTDIR/adsbot_origin.h"
  compare_headers "$OUTDIR/adsbotm.h"   "$OUTDIR/adsbotm_origin.h"
  # 원본 내 사람 vs 봇
  compare_headers "$OUTDIR/human_origin.h" "$OUTDIR/adsbot_origin.h"
fi

# 바디 요약 표
echo "==== body summary (bytes / sha256) ===="
printf "%-16s %10s  %s\n" "label" "bytes" "sha256"
summary_line human
summary_line adsbot
summary_line adsbotm
if [[ -n "$ORIGIN_IP" ]]; then
  summary_line human_origin
  summary_line adsbot_origin
  summary_line adsbotm_origin
fi
echo

# robots.txt (AdsBot UA)
echo "---- robots.txt (AdsBot UA) ----"
curl -sSL -m 20 -A "$UA_ADSBOT" -D "$OUTDIR/robots.h" "https://${HOST}/robots.txt" -o "$OUTDIR/robots.txt" >/dev/null || true
echo "Status: $(status_of "$OUTDIR/robots.h" || echo 0)"
echo "Sample:"; sed -n '1,80p' "$OUTDIR/robots.txt" 2>/dev/null || echo "(no robots.txt)"
