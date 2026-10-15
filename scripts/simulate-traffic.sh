#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# simulate-traffic.sh — steady stream of realistic traffic (good and bad).
#
# Generates:
#   - normal browsing/catalog traffic  (search, product views, cart adds, checkout)
#   - auth traffic                     (login success, wrong-password failures, 2FA bursts)
#   - payment outcomes                 (deliberately-cheap Stripe order, a bogus M-Pesa phone)
#   - rate-limit hits                  (short auth and burst floods, so the Security
#                                      dashboard and threshold alerts light up)
#
# Usage:
#   API_URL=http://localhost:8080/api/v1 ./simulate-traffic.sh [--seconds 300] [--rate 0.6]
#   ./simulate-traffic.sh --burst             # one big rate-limit burst, then exit
# ─────────────────────────────────────────────────────────────────────────────
set -u

API="${API_URL:-http://localhost:8080/api/v1}"
SECONDS_TO_RUN=300
RATE="0.6"      # seconds between waves
DO_BURST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) SECONDS_TO_RUN="$2"; shift ;;
    --rate) RATE="$2"; shift ;;
    --burst) DO_BURST=true ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
  shift
done

RANDOM_EMAIL()  { echo "traffic$((RANDOM % 400))@demo.iloveshopping.ke"; }
VALID_PHONE()   { printf "+2547%08d" $((RANDOM % 100000000)); }
seq() { eval "echo {1..$1}"; }   # portable seq

burst() {
  echo "simulate: burst of $1 unauthorized calls"
  for i in $(seq 1 "$1"); do
    curl -s -o /dev/null -w "%{http_code} " "$API/auth/login" \
      -X POST -H "Content-Type: application/json" \
      -d '{"email":"nonexistent@iloveshopping.local","password":"wrong"}' &
  done
  wait
  echo
  sleep 1
}

demo_checkout() {
  # A registered user's full flow: register if needed, login, refresh the
  # token (JWT refresh metrics), add to cart, checkout, then attempt an
  # M-Pesa STK push to the sandbox number - the platform's watchdog expires
  # the unanswered session after ~2 minutes and the payment-failure counter
  # ticks with a real reason (stk_timeout).
  local email="$1"; local password="demo-traffic-123!"
  local login_json
  login_json=$(curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" 2>/dev/null || true)
  local token refresh
  token=$(echo "$login_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['accessToken'])" 2>/dev/null || true)
  refresh=$(echo "$login_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['refreshToken'])" 2>/dev/null || true)
  if [ -z "$token" ]; then
    curl -s -X POST "$API/auth/register" -H "Content-Type: application/json" \
      -d "{\"email\":\"$email\",\"password\":\"$password\",\"name\":\"Demo Traffic\",\"captchaToken\":\"dev-test-secret\"}" > /dev/null
    login_json=$(curl -s -X POST "$API/auth/login" -H "Content-Type: application/json" \
      -d "{\"email\":\"$email\",\"password\":\"$password\"}")
    token=$(echo "$login_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['accessToken'])" 2>/dev/null || true)
    refresh=$(echo "$login_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['refreshToken'])" 2>/dev/null || true)
  fi
  if [ -z "$token" ]; then
    echo "simulate: could not log in $email"
    return
  fi

  # JWT refresh: rotate the fresh token (success path), and every third
  # wave present a garbage token too (invalid_token failure path)
  if [ -n "$refresh" ]; then
    curl -s -X POST "$API/auth/refresh" -H "Content-Type: application/json" \
      -d "{\"refreshToken\":\"$refresh\"}" > /dev/null
    if [ $((RANDOM % 3)) -eq 0 ]; then
      curl -s -o /dev/null -X POST "$API/auth/refresh" -H "Content-Type: application/json" \
        -d '{\"refreshToken\":\"garbage.token.value\"}'
    fi
  fi

  local prod
  prod=$(curl -s "$API/products?size=3" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['products'][0]['id'])" 2>/dev/null || true)
  [ -z "$prod" ] && return
  curl -s -X POST "$API/cart/items" -H "Authorization: Bearer $token" -H "Content-Type: application/json" -d "{\"productId\":\"$prod\",\"quantity\":$((RANDOM % 3 + 1))}" > /dev/null
  local order_json
  order_json=$(curl -s -X POST "$API/orders/checkout" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{"shippingAddress":{"name":"Demo User","line1":"1 Demo Lane","city":"Nairobi","state":"Nairobi","postalCode":"00100","country":"KE","phone":"+254700000000"},"billingAddress":{"name":"Demo User","line1":"1 Demo Lane","city":"Nairobi","state":"Nairobi","postalCode":"00100","country":"KE","phone":"+254700000000"}}')

  # invalid-payment attempt: real STK push to the sandbox number; the
  # platform cannot receive the callback locally, so the watchdog marks
  # it FAILED (reason: stk_timeout) after MPESA_STK_TIMEOUT_SECONDS
  local order_id
  order_id=$(echo "$order_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])" 2>/dev/null || true)
  if [ -n "$order_id" ]; then
    curl -s -o /dev/null -X POST "$API/orders/payments/mpesa/stk-push" \
      -H "Content-Type: application/json" \
      -d "{\"orderId\":\"$order_id\",\"phoneNumber\":\"254708374149\"}"
  fi
}

if $DO_BURST; then
  burst 40
  exit 0
fi

echo "simulate: running for ${SECONDS_TO_RUN}s against $API (every ${RATE}s a wave), Ctrl+C to stop"
END=$(( $(date +%s) + SECONDS_TO_RUN ))
while [ "$(date +%s)" -lt "$END" ]; do
  # casual browsing
  curl -s -o /dev/null "$API/products?page=$RANDOM%2&size=8" &
  curl -s -o /dev/null "$API/products/search/suggestions?query=ceram" &
  curl -s -o /dev/null "$API/categories" &
  curl -s -o /dev/null "$API/products/soy-candle-cedar-moss" &
  curl -s -o /dev/null "$API/products?onSaleOnly=true" &

  # one in four waves tries to log in badly on purpose
  if [ $((RANDOM % 4)) -eq 0 ]; then
    curl -s -o /dev/null -X POST "$API/auth/login" -H "Content-Type: application/json" \
      -d '{"email":"soldi@iloveshopping.ke","password":"wrong-pass"}' &
  fi

  # occasional happy shopper completes a checkout
  if [ $((RANDOM % 5)) -eq 0 ]; then
    demo_checkout "$(RANDOM_EMAIL)" &
  fi

  # occasionally trigger a rate-limited spike so that counter never sits at zero
  if [ $((RANDOM % 9)) -eq 0 ]; then
    burst 12 &
  fi

  wait
  sleep "$RATE"
done

echo "simulate: done"
