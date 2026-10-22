#!/usr/bin/env bash
set -euo pipefail

CONFIG="${OPENAI_CONFIG:-/etc/sing-box/config.json}"
BACKUP_DIR="${OPENAI_BACKUP_DIR:-/root/bak-singbox}"
SERVICE="${OPENAI_SERVICE:-sing-box}"
TAG="openai-v6"
RULESET_TAG="openai"
SRS_NAME="geosite-openai.srs"
SRS_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
PROBE="2001:4860:4860::8888"
OPENAI_DOMAINS="chatgpt.com api.openai.com platform.openai.com"
MODE="${1:-apply}"
ARG_IPV6="${2:-}"

log() { echo "[openai-v6-patch] $*"; }
die() { echo "[openai-v6-patch] ERROR: $*" >&2; exit 1; }

usage() {
    echo "usage: $0 [apply|remove|status|test] [IPv6]"
    echo "  apply [IPv6] - add or refresh gemini-via-IPv6 patch in ${CONFIG} (default)"
    echo "  remove       - drop outbound/rules added by this patch"
    echo "  status       - show current patch state"
    echo "  test  [IPv6] - check IPv6 connectivity to OpenAI/ChatGPT (no config changes)"
    echo
    echo "IPv6 selection (apply/test), in priority order:"
    echo "  1) argument:    $0 apply 2001:db8::1"
    echo "  2) env var:     OPENAI_IPV6=2001:db8::1 $0 apply"
    echo "  3) interactive prompt (asks for the IPv6 of this server)"
    echo "  4) auto-detection (ip -6 route get $PROBE) as a last resort"
    echo
    echo "apply runs the same connectivity tests at the end (skip: OPENAI_SKIP_TEST=1)"
}

# Normalizes and validates an IPv6 address -> prints compressed form.
# Accepts optional /prefix or %zone suffix. Fails on non-global addresses.
normalize_ipv6() {
    python3 -c '
import ipaddress, sys
raw = sys.argv[1].strip().split("/")[0].split("%")[0]
try:
    a = ipaddress.ip_address(raw)
except ValueError:
    sys.exit("invalid IP address: %s" % raw)
if a.version != 6:
    sys.exit("not an IPv6 address: %s" % raw)
if not a.is_global:
    sys.exit("not a global IPv6: %s" % raw)
print(a.compressed)
' "$1"
}

# Auto-detected default (may be empty or wrong on multi-address hosts).
auto_detect_ipv6() {
    local ip=""
    ip="$(ip -6 route get "$PROBE" 2>/dev/null | sed -n 's/.*src \([0-9a-fA-F:]*\).*/\1/p' | head -1 || true)"
    if [[ -z "$ip" ]]; then
        ip="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
    fi
    [[ -n "$ip" ]] || return 0
    normalize_ipv6 "$ip" 2>/dev/null || true
}

# All global IPv6 addresses of the server (deduplicated, validated).
list_ipv6_candidates() {
    {
        ip -6 route get "$PROBE" 2>/dev/null | sed -n 's/.*src \([0-9a-fA-F:]*\).*/\1/p' | head -1
        ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    } | awk 'NF && !seen[$0]++' | while read -r a; do
        normalize_ipv6 "$a" 2>/dev/null || true
    done
}

# Sets global IPV6 (and logs its source). Interactive when run from a terminal.
choose_ipv6() {
    local input="" normalized="" auto="" src=""

    if [[ -n "$ARG_IPV6" ]]; then
        input="$ARG_IPV6"
        src="command-line argument"
    elif [[ -n "${OPENAI_IPV6:-}" ]]; then
        input="$OPENAI_IPV6"
        src="OPENAI_IPV6"
    fi

    if [[ -n "$input" ]]; then
        normalized="$(normalize_ipv6 "$input")" || die "invalid IPv6 ($src): $input"
        IPV6="$normalized"
        log "IPv6 ($src): $IPV6"
        return 0
    fi

    auto="$(auto_detect_ipv6 || true)"

    if [[ -t 0 ]]; then
        local -a candidates=()
        local line
        while IFS= read -r line; do
            [[ -n "$line" ]] && candidates+=("$line")
        done < <(list_ipv6_candidates)
        echo "Global IPv6 addresses found on this server:"
        local i
        for i in "${!candidates[@]}"; do
            if [[ "${candidates[$i]}" == "$auto" ]]; then
                printf '  %d) %s   <- auto-detected\n' "$((i + 1))" "${candidates[$i]}"
            else
                printf '  %d) %s\n' "$((i + 1))" "${candidates[$i]}"
            fi
        done
        [[ ${#candidates[@]} -eq 0 ]] && echo "  (none found)"
        local hint="${auto:-none}"
        while true; do
            input=""
            read -r -p "Enter the IPv6 of this server (number or full address) [default: $hint]: " input || true
            if [[ -z "$input" ]]; then
                input="$auto"
            elif [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#candidates[@]} )); then
                input="${candidates[$((input - 1))]}"
            fi
            if [[ -z "$input" ]]; then
                echo "nothing selected - type an IPv6 address (or Ctrl-C to abort)"
                continue
            fi
            if normalized="$(normalize_ipv6 "$input")"; then
                break
            fi
        done
    else
        [[ -n "$auto" ]] || die "no global IPv6 found (set OPENAI_IPV6=<ipv6> or run interactively)"
        normalized="$auto"
    fi

    IPV6="$normalized"
    log "IPv6 (${src:-manual input}): $IPV6"
}

# ---------- connectivity tests ----------

TESTS_OK=0
TESTS_FAILED=0
TESTS_SKIPPED=0

configured_ipv6() {
    python3 - <<'PY'
import json, os
try:
    cfg = json.load(open(os.environ["OPENAI_CONFIG"]))
except Exception:
    raise SystemExit(0)
for o in cfg.get("outbounds", []):
    if o.get("tag") == os.environ["OPENAI_TAG"] and o.get("inet6_bind_address"):
        print(o["inet6_bind_address"])
        break
PY
}

clash_api_info() {
    python3 - <<'PY'
import json, os
try:
    cfg = json.load(open(os.environ["OPENAI_CONFIG"]))
except Exception:
    raise SystemExit(0)
api = (cfg.get("experimental") or {}).get("clash_api") or {}
if api.get("external_controller"):
    print(api["external_controller"], api.get("secret", ""))
PY
}

# http_code <url> <source_ipv6|empty> -> prints HTTP code ("000" on failure)
http_code() {
    local url="$1" ip="${2:-}" out=""
    local args=(-6 -s -o /dev/null -w '%{http_code}' --max-time "${OPENAI_TEST_TIMEOUT:-15}")
    if [[ -n "$ip" ]]; then
        args+=(--interface "$ip")
    fi
    out="$(curl "${args[@]}" "$url" 2>/dev/null || true)"
    printf '%s' "${out:-000}"
}

run_tests() {
    local ip="$1"
    TESTS_OK=0
    TESTS_FAILED=0
    TESTS_SKIPPED=0
    _ok()   { TESTS_OK=$((TESTS_OK + 1));         printf '  [OK]   %s\n' "$1"; }
    _bad()  { TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  [FAIL] %s\n' "$1"; }
    _skip() { TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); printf '  [SKIP] %s\n' "$1"; }

    echo "=== connectivity tests to OpenAI/ChatGPT (source IPv6: $ip) ==="

    # 1. address must be assigned on the server
    if ip -6 addr show 2>/dev/null | grep -Fq "$ip"; then
        _ok "IPv6 $ip is assigned on this server"
    else
        _bad "IPv6 $ip is NOT assigned on this server - outbound bind will fail"
    fi

    # 2. DNS: chatgpt.com must have an AAAA record
    if python3 -c 'import socket, sys; socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET6)' chatgpt.com 2>/dev/null; then
        _ok "DNS: chatgpt.com resolves to IPv6 (AAAA)"
    else
        _bad "DNS: chatgpt.com has no IPv6 (AAAA) record"
    fi

    if ! command -v curl >/dev/null 2>&1; then
        _skip "HTTP tests (curl is not installed)"
    else
        local code

        # 3. ChatGPT web via bound IPv6
        code="$(http_code "https://chatgpt.com/cdn-cgi/trace" "$ip")"
        if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
            _ok "chatgpt.com (cdn-cgi/trace) via IPv6 -> HTTP $code (reachable)"
        else
            _bad "chatgpt.com (cdn-cgi/trace) via IPv6 -> HTTP $code (unreachable)"
        fi

        # 4. OpenAI API via bound IPv6
        code="$(http_code "https://api.openai.com/v1/models" "$ip")"
        if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
            _ok "api.openai.com/v1/models via IPv6 -> HTTP $code (reachable)"
        else
            _bad "api.openai.com/v1/models via IPv6 -> HTTP $code (unreachable)"
        fi

        # 5. control endpoint (openai.com)
        code="$(http_code "https://www.openai.com/" "$ip")"
        if [[ "$code" =~ ^[234][0-9][0-9]$ ]]; then
            _ok "www.openai.com via IPv6 -> HTTP $code (reachable)"
        else
            _bad "www.openai.com via IPv6 -> HTTP $code (unreachable)"
        fi

        # 6. outbound source address must be exactly our IPv6
        local seen=""
        seen="$(curl -6 -s --interface "$ip" --max-time "${OPENAI_TEST_TIMEOUT:-15}" https://api6.ipify.org 2>/dev/null || true)"
        if [[ -z "$seen" ]]; then
            seen="$(curl -6 -s --interface "$ip" --max-time "${OPENAI_TEST_TIMEOUT:-15}" https://ifconfig.me 2>/dev/null || true)"
        fi
        if [[ -n "$seen" ]]; then
            local seen_n
            seen_n="$(normalize_ipv6 "$seen" 2>/dev/null || echo "$seen")"
            if [[ "$seen_n" == "$ip" ]]; then
                _ok "outbound source address is $ip (no NAT)"
            else
                _bad "outbound source is $seen_n, expected $ip (NAT/masquerade?)"
            fi
        else
            _skip "outbound source address check (no response from api6.ipify.org)"
        fi

        # 7. end-to-end via sing-box outbound itself
        local ci="" ctrl="" secret="" resp="" delay="" msg=""
        ci="$(clash_api_info || true)"
        if [[ -z "$ci" ]]; then
            _skip "test via sing-box outbound $TAG (clash_api is not enabled in ${CONFIG})"
        else
            ctrl="${ci%% *}"
            secret="${ci#* }"
            [[ "$secret" == "$ctrl" ]] && secret=""
            local cargs=(-s --max-time 15)
            if [[ -n "$secret" ]]; then
                cargs+=(-H "Authorization: Bearer $secret")
            fi
            resp="$(curl "${cargs[@]}" "http://$ctrl/proxies/$TAG/delay?url=https%3A%2F%2Fchatgpt.com%2Fcdn-cgi%2Ftrace&timeout=10000" 2>/dev/null || true)"
            delay="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(0)
print(d.get("delay") or "")
' "$resp" 2>/dev/null || true)"
            if [[ -n "$delay" ]]; then
                _ok "sing-box outbound $TAG -> chatgpt.com works (delay ${delay} ms)"
            else
                msg="$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get("message") or d.get("error") or sys.argv[1][:150])
except Exception:
    print(sys.argv[1][:150] or "no response from clash_api")
' "$resp" 2>/dev/null || true)"
                _bad "sing-box outbound $TAG -> chatgpt.com failed: $msg"
            fi
        fi
    fi

    echo "--- tests: OK=$TESTS_OK FAIL=$TESTS_FAILED SKIP=$TESTS_SKIPPED"
}


backup_config() {
    mkdir -p "$BACKUP_DIR"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG" "$BACKUP_DIR/config.json.bak-$ts"
    ls -1t "$BACKUP_DIR"/config.json.bak-* 2>/dev/null | tail -n +11 | xargs -r rm -f --
    log "backup: $BACKUP_DIR/config.json.bak-$ts"
}

check_and_reload() {
    if ! sing-box check -c "$CONFIG"; then
        local last
        last="$(ls -1t "$BACKUP_DIR"/config.json.bak-* 2>/dev/null | head -1 || true)"
        if [[ -n "$last" ]]; then
            cp -a "$last" "$CONFIG"
            log "restored: $last"
        fi
        die "sing-box check failed, config reverted"
    fi
    log "sing-box check: OK"
    systemctl reload "$SERVICE" 2>/dev/null || systemctl restart "$SERVICE"
    sleep 1
    systemctl is-active --quiet "$SERVICE" || die "service $SERVICE is not active after reload"
    log "service $SERVICE reloaded"
}

case "$MODE" in
    -h|--help|help) usage; exit 0 ;;
    apply|remove|status|test) ;;
    *:*) ARG_IPV6="$MODE"; MODE="apply" ;;   # first argument is an IPv6 address
    *) usage; exit 1 ;;
esac

[[ -s "$CONFIG" ]] || die "config not found: $CONFIG"

export OPENAI_MODE="$MODE" OPENAI_CONFIG="$CONFIG" OPENAI_TAG="$TAG" \
    OPENAI_RULESET_TAG="$RULESET_TAG" OPENAI_SRS_NAME="$SRS_NAME" OPENAI_SRS_URL="$SRS_URL" \
    OPENAI_DOMAINS="$OPENAI_DOMAINS"

if [[ "$MODE" == "status" ]]; then
    python3 - <<'PY'
import json, os
cfg = json.load(open(os.environ["OPENAI_CONFIG"]))
tag = os.environ["OPENAI_TAG"]
obs = [o for o in cfg.get("outbounds", []) if o.get("tag") == tag]
rules = [r for r in cfg.get("route", {}).get("rules", []) if r.get("outbound") == tag]
rss = [r for r in cfg.get("route", {}).get("rule_set", []) if r.get("tag") == os.environ["OPENAI_RULESET_TAG"]]
print("outbound:", json.dumps(obs[0], ensure_ascii=False) if obs else "NOT SET")
print("rules:", len(rules))
for r in rules:
    print("  ", json.dumps(r, ensure_ascii=False))
print("rule_set:", json.dumps(rss[0], ensure_ascii=False) if rss else "NOT SET")
PY
    systemctl is-active "$SERVICE" 2>/dev/null || true
    exit 0
fi

if [[ "$MODE" == "remove" ]]; then
    backup_config
    python3 - <<'PY'
import json, os
p = os.environ["OPENAI_CONFIG"]
tag = os.environ["OPENAI_TAG"]
rst = os.environ["OPENAI_RULESET_TAG"]
srs = os.environ["OPENAI_SRS_NAME"]
cfg = json.load(open(p))
cfg["outbounds"] = [o for o in cfg.get("outbounds", []) if o.get("tag") != tag]
cfg["route"]["rules"] = [r for r in cfg["route"].get("rules", []) if r.get("outbound") != tag]
# Leave rule_set entries untouched: the "openai"/"anthropic" rule_set is shared
# with other routing rules (e.g. ssb sends them to warp), deleting it here
# would break those rules. Only outbound and its rules are removed.

json.dump(cfg, open(p, "w"), indent=2, ensure_ascii=False)
print("patch removed")
PY
    check_and_reload
    exit 0
fi

if [[ "$MODE" == "test" ]]; then
    IPV6=""
    if [[ -z "$ARG_IPV6" && -z "${OPENAI_IPV6:-}" ]]; then
        CFG_IPV6="$(configured_ipv6 || true)"
        if [[ -n "$CFG_IPV6" ]]; then
            IPV6="$(normalize_ipv6 "$CFG_IPV6")" || die "invalid IPv6 in ${CONFIG}: $CFG_IPV6"
            log "IPv6 (from ${CONFIG}, outbound $TAG): $IPV6"
        fi
    fi
    if [[ -z "$IPV6" ]]; then
        choose_ipv6
    fi
    run_tests "$IPV6"
    [[ "$TESTS_FAILED" -eq 0 ]] || exit 1
    exit 0
fi

IPV6=""
choose_ipv6
backup_config

OPENAI_IPV6="$IPV6" python3 - <<'PY'
import glob, json, os, shutil, urllib.request

p = os.environ["OPENAI_CONFIG"]
tag = os.environ["OPENAI_TAG"]
rst = os.environ["OPENAI_RULESET_TAG"]
srs_name = os.environ["OPENAI_SRS_NAME"]
srs_url = os.environ["OPENAI_SRS_URL"]
domains = os.environ["OPENAI_DOMAINS"].split()
ipv6 = os.environ["OPENAI_IPV6"]

cfg = json.load(open(p))
route = cfg.setdefault("route", {})
rules = route.setdefault("rules", [])
rule_sets = route.setdefault("rule_set", [])
outbounds = cfg.setdefault("outbounds", [])

dns_tag = None
for s in cfg.get("dns", {}).get("servers", []):
    if s.get("tag"):
        dns_tag = s["tag"]
        break
if not dns_tag:
    raise SystemExit("no tagged DNS server in config")

existing_rs = next((r for r in rule_sets if r.get("tag") == rst), None)
if existing_rs is None:
    ruleset_dir = None
    for r in rule_sets:
        path = r.get("path", "")
        if path.endswith(".srs") and os.path.isdir(os.path.dirname(path)):
            ruleset_dir = os.path.dirname(path)
            break
    if ruleset_dir is None:
        found = glob.glob("/var/www/*/" + srs_name)
        ruleset_dir = os.path.dirname(found[0]) if found else "/var/lib/sing-box"
    os.makedirs(ruleset_dir, exist_ok=True)
    srs_path = os.path.join(ruleset_dir, srs_name)
    if not os.path.isfile(srs_path):
        found = [f for f in glob.glob("/var/www/*/" + srs_name) + glob.glob("/var/lib/sing-box/" + srs_name) if f != srs_path]
        if found:
            shutil.copy2(found[0], srs_path)
            print("copied", srs_name, "from", found[0])
        else:
            urllib.request.urlretrieve(srs_url, srs_path)
            print("downloaded", srs_name, "from", srs_url)
    rule_sets.append({"tag": rst, "type": "local", "format": "binary", "path": srs_path})
    print("rule_set added:", rst, "->", srs_path)
else:
    print("rule_set exists:", rst, "->", existing_rs.get("path"))

outbounds[:] = [o for o in outbounds if o.get("tag") != tag]
outbounds.append({
    "type": "direct",
    "tag": tag,
    "inet6_bind_address": ipv6,
    "domain_resolver": {"server": dns_tag, "strategy": "ipv6_only"},
})
print("outbound added:", tag, "inet6_bind_address=" + ipv6, "dns=" + dns_tag)

rules[:] = [r for r in rules if r.get("outbound") != tag]
new_rules = [
    {"rule_set": [rst], "outbound": tag},
    {"domain": list(domains), "outbound": tag},
]
idx = next((i for i, r in enumerate(rules) if "outbound" in r), len(rules))
rules[idx:idx] = new_rules
print("rules added at", idx, ":", json.dumps(new_rules, ensure_ascii=False))

json.dump(cfg, open(p, "w"), indent=2, ensure_ascii=False)
print("config written:", p)
PY

check_and_reload
log "done: openai traffic -> $TAG -> IPv6"

if [[ "${OPENAI_SKIP_TEST:-0}" == "1" ]]; then
    log "connectivity tests skipped (OPENAI_SKIP_TEST=1)"
else
    run_tests "$IPV6"
    if [[ "$TESTS_FAILED" -ne 0 ]]; then
        die "connectivity tests FAILED ($TESTS_FAILED) - patch is applied, check IPv6/DNS/routing"
    fi
    log "all connectivity tests passed"
fi
