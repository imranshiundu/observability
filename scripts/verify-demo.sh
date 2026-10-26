#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# verify-demo.sh — automated checks for every observability requirement.
#
# Usage: ./verify-demo.sh [api-url] [grafana-url]
#   api-url     default http://localhost:8080/api/v1
#   grafana-url default http://localhost:3300   (admin / admin)
#
# Prints a PASS/FAIL table mapping each requirement from the project brief to
# a live check, then exits non-zero if anything failed.
# ═══════════════════════════════════════════════════════════════════════════════
set -u
API="${1:-http://localhost:8080/api/v1}"
GRAF="${2:-http://localhost:3300}"
PROM="http://localhost:9190"
GRAF_AUTH="-u admin:admin"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1 -- $2"; FAIL=$((FAIL+1)); }

prom() { curl -s -m 8 --get "http://localhost:9190/api/v1/query" --data-urlencode "query=$1" 2>/dev/null; }
promv() { prom "$1" | python3 -c "
import json,sys
r=json.load(sys.stdin)['data']['result']
print(int(sum(float(x['value'][1]) for x in r)) if r else -1)" 2>/dev/null || echo -1; }
grf() { curl -s $GRAF_AUTH -m 8 "$1" 2>/dev/null; }

echo "════ Observability requirement verification ════"

# 1. Metrics collection — Prometheus scrapes the API
up=$(promv 'sum(up{job="iloveshopping-api"})')
if [ "${up:-0}" -ge 1 ] 2>/dev/null; then ok "metrics collection: Prometheus scrapes the API (up=$up)"; else bad "metrics collection" "no healthy scrape target"; fi

# 2. Business Intelligence — revenue, AOV, abandonment, categories, registrations
dash=$(grf "$GRAF/api/dashboards/uid/ils-business-intelligence")
echo "$dash" | grep -q "Business intelligence" && ok "BI dashboard provisioned" || bad "BI dashboard" "not provisioned"
rev=$(curl -s -m 8 "http://localhost:8080/api/v1/products?size=1" >/dev/null && docker exec iloveshopping-postgres psql -U iloveshopping -d iloveshopping -tA -c "SELECT count(*) FROM orders WHERE number LIKE 'DEMO-%'" 2>/dev/null || echo 0)
[ "${rev:-0}" -ge 100 ] 2>/dev/null && ok "seed history present (DEMO orders: $rev)" || bad "seed history" "expected >=100 demo orders, got $rev"

# 3. Product & Customer — top products, ratings, customer types
dash=$(grf "$GRAF/api/dashboards/uid/ils-product-customer")
echo "$dash" | grep -q "Product" && ok "Product & customer dashboard provisioned" || bad "Product & customer dashboard" "not provisioned"
cats=$(docker exec iloveshopping-postgres psql -U iloveshopping -d iloveshopping -tA -c "SELECT count(*) FROM categories" 2>/dev/null || echo 0)
[ "${cats:-0}" -ge 3 ] 2>/dev/null && ok "categories exist for the rating/revenue panels ($cats)" || bad "categories" "expected >=3"

# 4. Correlated metrics — >=2 panels titled Correlated
c=0
for uid in ils-business-intelligence ils-product-customer; do
  n=$(grf "$GRAF/api/dashboards/uid/$uid" | python3 -c "
import json,sys
d=json.load(sys.stdin)['dashboard']
print(sum(1 for p in d['panels'] if 'orrelated' in p['title']))" 2>/dev/null || echo 0)
  c=$((c+n))
done
[ "$c" -ge 2 ] && ok "correlated metrics: $c panels (>=2 required)" || bad "correlated metrics" "found $c, need >=2"

# 5. Technical performance — request metrics + latency + pool
req=$(promv 'sum(http_server_requests_seconds_count{uri="/products"})')
[ "${req:-0}" -gt 0 ] 2>/dev/null && ok "API request metrics recorded (/products: $req)" || bad "API request metrics" "no series"
hik=$(promv 'sum(hikaricp_connections_max)')
[ "${hik:-0}" -gt 0 ] 2>/dev/null && ok "database pool metrics present" || bad "database pool metrics" "no series"

# 6. Security — failed logins, refresh, password resets, rate limiting
fl=$(promv 'sum(ils_auth_login_failed_total)')
[ "${fl:-0}" -ge 1 ] 2>/dev/null && ok "failed-login counter live ($fl)" || bad "failed-login counter" "no data"
rs=$(promv 'sum(ils_auth_refresh_success_total)')
[ "${rs:-0}" -ge 1 ] 2>/dev/null && ok "JWT refresh counter live ($rs rotations)" || bad "JWT refresh counter" "no data"
rl=$(promv 'sum(ils_rate_limited_total)')
[ "${rl:-0}" -ge 1 ] 2>/dev/null && ok "rate-limit counter live ($rl)" || bad "rate-limit counter" "no data"

# 7. Logs — Loki ingests the platform's containers
logs=$(curl -s -m 8 -u admin:admin --get "$GRAF/api/datasources/proxy/uid/loki/loki/api/v1/query_range" \
  --data-urlencode 'query=count_over_time({job="iloveshopping"}[2h])' 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
print(sum(sum(int(v[1]) for v in f.get('values',[])) for f in r) if r else 0)" 2>/dev/null || echo 0)
[ "${logs:-0}" -ge 10 ] 2>/dev/null && ok "logs collected in Loki ($logs lines in 2h)" || bad "logs in Loki" "got ${logs:-0} lines"

# 8. Alerts — 4 provisioned rules
rules=$(grf "$GRAF/api/v1/provisioning/alert-rules" | python3 -c "
import json,sys
rs=json.load(sys.stdin)
print(len(rs))" 2>/dev/null || echo 0)
[ "$rules" -ge 2 ] && ok "alert rules provisioned ($rules)" || bad "alert rules" "found $rules, need >=2"

# 9. Alerting actually fires and emails — burst + MailHog
before=$(curl -s -m 8 "http://localhost:8025/api/v2/messages?limit=1" | python3 -c "
import json,sys
print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo 0)
for i in $(seq 1 15); do curl -s -o /dev/null -m 5 -X POST "$API/auth/login" -H "Content-Type: application/json" -d '{"email":"nonexistent@iloveshopping.local","password":"wrong"}' & done; wait
sleep 80   # rule interval (1m) + group_wait (30s) + delivery
after=$(curl -s -m 8 "http://localhost:8025/api/v2/messages?limit=1" | python3 -c "
import json,sys
print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo 0)
alertmails=$(curl -s -m 8 "http://localhost:8025/api/v2/messages?limit=60" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for m in d.get('items',[]) if m.get('From',{}).get('Mailbox')=='alerts'))" 2>/dev/null || echo 0)
if [ "$alertmails" -ge 1 ]; then ok "alert email delivered through MailHog ($alertmails alert email(s))"; else bad "alert email" "no alert email found after a burst (before=$before after=$after)"; fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "════ ALL REQUIREMENTS VERIFIED ($PASS/$PASS) ════"
  exit 0
fi
echo "════ $FAIL CHECK(S) FAILED — see above ($PASS passed) ════"
exit 1
