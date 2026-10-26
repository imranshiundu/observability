#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# simulate-traffic.sh — steady stream of realistic traffic (good and bad),
# designed to live INSIDE the platform's rate limits while still triggering
# them on purpose.
#
# Generates:
#   - normal browsing/catalog traffic        (search, product views, suggestions)
#   - one authenticated session              (register once, login, JWT refresh)
#   - checkout waves with the cached token   (cart add, checkout, M-Pesa STK
#     push to the sandbox number — the watchdog expires it, and the
#     payment-failure counter ticks with a real reason)
#   - failed logins                         (wrong-password attempts)
#   - occasional garbage refresh tokens     (invalid_token failures)
#   - deliberate rate-limit bursts          (the Security dashboard's counter)
#
# Rate budget (the platform limits: 10 auth req/min + burst 20, 100 api/min):
#   browsing       2 calls / 1.5s  ~80 api/min
#   failed logins  every ~10.5s     ~5.7 auth/min
#   refreshes      every ~25s      ~2.4 auth/min (plus occasional garbage)
#   checkouts      every ~30s      ~6 api/min (cart+checkout+STK)
#   bursts          every ~2.5m    mostly 429s on purpose
# Everything stays inside the buckets except the deliberate bursts.
#
# Usage:
#   API_URL=http://localhost:8080/api/v1 ./simulate-traffic.sh [--seconds 300]
#   ./simulate-traffic.sh --burst    # one 40-call auth flood, then exit
# ─────────────────────────────────────────────────────────────────────────────
set -u

API="${API_URL:-http://localhost:8080/api/v1}"
SECONDS_TO_RUN=300
WAVE_RATE="1.5"
DO_BURST=false
EMAIL="traffic-sim@demo.iloveshopping.ke"
PASSWORD="demo-traffic-123!"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) SECONDS_TO_RUN="$2"; shift ;;
    --rate) WAVE_RATE="$2"; shift ;;
    --burst) DO_BURST=true ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
  shift
done

# ── one authenticated session for the whole run ─────────────────────────────
TOKEN=""
REFRESH=""

acquire_session() {
  local login_json
  login_json=$(curl -s -m 10 -X POST "$API/auth/login" -H "Content-Type: application/json" \
    -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
  TOKEN=$(echo "$login_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['accessToken'])" 2>/dev/null || true)
  REFRESH=$(echo "$login_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['refreshToken'])" 2>/dev/null || true)

  if [ -z "$TOKEN" ]; then
    # first ever run: register the traffic user, then log in
    curl -s -m 10 -X POST "$API/auth/register" -H "Content-Type: application/json" \
      -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"Traffic Sim\",\"captchaToken\":\"dev-test-secret\"}" > /dev/null 2>&1 || true
    sleep 2
    login_json=$(curl -s -m 10 -X POST "$API/auth/login" -H "Content-Type: application/json" \
      -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
    TOKEN=$(echo "$login_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['accessToken'])" 2>/dev/null || true)
    REFRESH=$(echo "$login_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['refreshToken'])" 2>/dev/null || true)
  fi

  if [ -z "$TOKEN" ]; then
    echo "simulate: could not establish the session for $EMAIL (login/register failed)" >&2
    return 1
  fi
  return 0
}

burst() {
  local n="$1"
  for i in $(seq 1 "$n"); do
    curl -s -o /dev/null -m 5 -X POST "$API/auth/login" \
      -H "Content-Type: application/json" \
      -d '{"email":"nonexistent@iloveshopping.local","password":"wrong"}' &
  done
  wait
}

checkout_wave() {
  # api-scope only: uses the cached token
  local prod order_json order_id
  prod=$(curl -s -m 8 "$API/products?size=3" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['products'][0]['id'])" 2>/dev/null || true)
  [ -z "$prod" ] && return
  local add_status
  add_status=$(curl -s -o /dev/null -w '%{http_code}' -m 8 -X POST "$API/cart/items" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"productId\":\"$prod\",\"quantity\":$((RANDOM % 3 + 1))}")
  # a rate-limited add means an empty cart: checkout would only 400
  [ "$add_status" != "200" ] && return
  order_json=$(curl -s -m 12 -X POST "$API/orders/checkout" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d '{"shippingAddress":{"name":"Sim User","line1":"1 Sim Lane","city":"Nairobi","state":"Nairobi","postalCode":"00100","country":"KE","phone":"+254700000000"},"billingAddress":{"name":"Sim User","line1":"1 Sim Lane","city":"Nairobi","state":"Nairobi","postalCode":"00100","country":"KE","phone":"+254700000000"}}')
  order_id=$(echo "$order_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || true)
  # invalid-payment attempt: STK push to the sandbox number — the callback
  # cannot reach us, so the watchdog fails the payment after its timeout
  if [ -n "$order_id" ]; then
    curl -s -o /dev/null -m 8 -X POST "$API/orders/payments/mpesa/stk-push" \
      -H "Content-Type: application/json" \
      -d "{\"orderId\":\"$order_id\",\"phoneNumber\":\"254708374149\"}"
  fi
}

refresh_flow() {
  if [ -n "$REFRESH" ]; then
    # rotate (success path). BOTH tokens must be captured: rotation revokes
    # the old session and the JWT filter rejects access tokens bound to a
    # revoked session — keeping the old access token silently downgrades
    # every later request to anonymous (guest cart, empty-checkout 400s).
    local out new_refresh new_access
    out=$(curl -s -m 8 -X POST "$API/auth/refresh" -H "Content-Type: application/json" \
      -d "{\"refreshToken\":\"$REFRESH\"}" 2>/dev/null || true)
    new_refresh=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['refreshToken'])" 2>/dev/null || true)
    new_access=$(echo "$out" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['accessToken'])" 2>/dev/null || true)
    if [ -n "$new_refresh" ] && [ -n "$new_access" ]; then
      REFRESH="$new_refresh"
      TOKEN="$new_access"
    else
      # rotation failed (rate-limited or the token went stale) — the next
      # attempt would cascade into session_revoked; re-login instead
      acquire_session || true
    fi
    # every other refresh: a garbage token (invalid_token failure path)
    if [ $((RANDOM % 2)) -eq 0 ]; then
      curl -s -o /dev/null -m 8 -X POST "$API/auth/refresh" -H "Content-Type: application/json" \
        -d '{"refreshToken":"garbage.token.value"}'
    fi
  fi
}

if $DO_BURST; then
  echo "simulate: one-shot burst of 40 unauthorized logins"
  burst 40
  echo "simulate: done"
  exit 0
fi

if ! acquire_session; then
  exit 1
fi

echo "simulate: running for ${SECONDS_TO_RUN}s against $API (Ctrl+C to stop)"
END=$(( $(date +%s) + SECONDS_TO_RUN ))
N=0
while [ "$(date +%s)" -lt "$END" ]; do
  N=$((N + 1))

  # browsing wave (api scope, every 0.7s)
  curl -s -o /dev/null -m 6 "$API/products?size=8&page=$((RANDOM % 3))" &
  curl -s -o /dev/null -m 6 "$API/products/search/suggestions?query=ceram" &

  # failed login every ~10.5s (~5.7 auth/min, inside the 10/min bucket)
  [ $((N % 7)) -eq 0 ] && curl -s -o /dev/null -m 6 -X POST "$API/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"email":"soldi@iloveshopping.ke","password":"wrong-pass"}' &

  # JWT refresh every ~25s. FOREGROUND on purpose: refresh_flow rotates
  # TOKEN/REFRESH, and a background subshell cannot modify the parent
  # shell's variables — backgrounded, the parent would keep the revoked
  # token and every later request would silently downgrade to anonymous.
  [ $((N % 17)) -eq 0 ] && refresh_flow

  # checkout wave every ~30s (api scope with the cached token)
  [ $((N % 20)) -eq 0 ] && checkout_wave &

  # deliberate rate-limit burst every ~2.5m
  [ $((N % 100)) -eq 0 ] && burst 12 &

  wait
  sleep "$WAVE_RATE"
done

echo "simulate: done after $((N)) waves"
