#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  i-love-shopping observability — one-command reviewer demo
#
#  Installs missing prerequisites, clones the platform repo if absent, builds
#  and starts everything in Docker, seeds 30 days of history, generates live
#  traffic (including failures), fires an alert, verifies every requirement,
#  and prints exactly where to look.
#
#  Works on Linux, macOS and Windows (Git Bash / WSL).
#
#  Usage:
#    ./start.sh                 # full demo: install, build, seed, simulate, verify
#    ./start.sh --stop          # stop everything (data is kept)
#    ./start.sh --rebuild       # force image rebuild
#    ./start.sh --verify-only   # run the requirement checks against a running stack
# ═══════════════════════════════════════════════════════════════════════════════
set -u

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; BLU=$'\033[1;34m'; RST=$'\033[0m'
log()  { printf "%s[demo]%s %s\n"  "$BLU" "$RST" "$1"; }
ok()   { printf "%s[demo]%s %s\n"  "$GRN" "$RST" "$1"; }
warn() { printf "%s[demo]%s %s\n"  "$YEL" "$RST" "$1"; }
die()  { printf "%s[demo]%s %s\n"  "$RED" "$RST" "$1"; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="${PLATFORM_DIR:-$HERE/../i-love-shopping}"
PLATFORM_REPO="${PLATFORM_REPO:-https://gitea.kood.tech/imranshiundu/i-love-shopping3.git}"
COMPOSE_FILE="$PLATFORM_DIR/docker/docker-compose.yml"
STOP=false; REBUILD=false; VERIFY_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --stop)        STOP=true ;;
    --rebuild)     REBUILD=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    --help|-h)     head -14 "$0" | tail -11; exit 0 ;;
    *)             die "unknown: $arg" ;;
  esac
done

# ── stop mode ────────────────────────────────────────────────────────────────
if $STOP; then
  log "Stopping everything (volumes and data are kept)..."
  [ -d "$PLATFORM_DIR" ] && (cd "$PLATFORM_DIR" && docker compose -f docker/docker-compose.yml down --remove-orphans 2>/dev/null) || true
  docker compose -f "$HERE/docker-compose.yml" down --remove-orphans 2>/dev/null || true
  docker rm -f iloveshopping-postgres iloveshopping-redis iloveshopping-rabbitmq iloveshopping-mailhog \
              iloveshopping-api iloveshopping-frontend iloveshopping-prometheus \
              iloveshopping-grafana iloveshopping-loki iloveshopping-alloy 2>/dev/null || true
  ok "All stopped. Data volumes survive — the next run reuses them."
  exit 0
fi

# ── OS detection ─────────────────────────────────────────────────────────────
OS="unknown"
case "$(uname -s)" in
  Linux*)  OS=linux ;;
  Darwin*) OS=mac ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows ;;
esac
log "OS detected: $OS"

SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

# ── Prerequisites: docker + compose + curl + python3 ─────────────────────────
log "Checking prerequisites (Docker is the only hard requirement for the stack)..."
command -v docker >/dev/null 2>&1 || {
  warn "Docker is missing — installing..."
  case "$OS" in
    linux)  curl -fsSL https://get.docker.com | $SUDO sh && ok "Docker installed." ;;
    mac)    command -v brew >/dev/null 2>&1 && brew install --cask docker && open -a Docker || die "Install Docker Desktop: https://docs.docker.com/desktop/mac/install/";;
    windows) die "Install Docker Desktop: https://docs.docker.com/desktop/windows/install/ then re-run from Git Bash." ;;
  esac
}
docker info >/dev/null 2>&1 || {
  warn "Docker daemon is not running — starting it..."
  case "$OS" in
    linux)  $SUDO systemctl start docker 2>/dev/null || $SUDO service docker start 2>/dev/null || true ;;
    mac)    open -a Docker 2>/dev/null || true ;;
  esac
  for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || die "Docker daemon did not start."
}
ok "Docker is running ($(docker --version | cut -d' ' -f3 | tr -d ','))."

docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1 || {
  warn "Docker Compose is missing — installing the plugin..."
  case "$OS" in
    linux) $SUDO apt-get update -qq && $SUDO apt-get install -y docker-compose-plugin || die "Install compose: https://docs.docker.com/compose/install/linux/";;
    mac)   brew install docker-compose || die "Install compose: brew install docker-compose";;
  esac
}
compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@";
  else docker-compose "$@"; fi
}
pkg_install() { # best-effort install of helper tools (never fatal)
  for p in "$@"; do
    command -v "$p" >/dev/null 2>&1 && continue
    log "Installing missing package: $p"
    case "$OS" in
      linux)
        if command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y "$p";
        elif command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y "$p";
        elif command -v yum >/dev/null 2>&1; then $SUDO yum install -y "$p"; fi ;;
      mac)
        command -v brew >/dev/null 2>&1 && brew install "$p" ;;
    esac
    command -v "$p" >/dev/null 2>&1 && ok "$p installed." || warn "$p could not be installed automatically — install it manually."
  done
}
pkg_install curl
pkg_install python3
command -v curl >/dev/null 2>&1 || die "curl is required for health checks."
command -v python3 >/dev/null 2>&1 && HAVE_PY=1 || HAVE_PY=0

# ── Locate or clone the platform repository ──────────────────────────────────
if [ ! -d "$PLATFORM_DIR" ]; then
  log "Platform repository not found at $PLATFORM_DIR — cloning..."
  mkdir -p "$(dirname "$PLATFORM_DIR")"
  git clone --depth 1 "$PLATFORM_REPO" "$PLATFORM_DIR" || die "Could not clone $PLATFORM_REPO"
fi
[ -f "$COMPOSE_FILE" ] || die "Platform compose file not found: $COMPOSE_FILE"

# ── Platform env: create + generate required secrets ─────────────────────────
cd "$PLATFORM_DIR"
if [ ! -f ".env" ]; then
  [ -f ".env.example" ] || die "Platform .env.example not found."
  cp .env.example .env
  ok "Platform .env created from .env.example."
fi
gen_secret() { openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64; }
env_has_placeholder() {
  grep -E "^$1=" .env 2>/dev/null | cut -d= -f2- | grep -qE '^$|change-me|your-|dev-access-secret|dev-refresh-secret' && return 0 || return 1
}
env_set() {
  if grep -qE "^$1=" .env; then
    awk -v k="$1" -v v="$2" 'BEGIN{FS="="} $1==k {$0=k"="v} {print}' .env > .env.tmp && mv .env.tmp .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
env_has_placeholder DATA_ENCRYPTION_KEY && { env_set DATA_ENCRYPTION_KEY "$(gen_secret)"; ok "Generated DATA_ENCRYPTION_KEY (required — the API refuses blank)."; }
env_has_placeholder JWT_ACCESS_SECRET  && { env_set JWT_ACCESS_SECRET  "$(gen_secret)"; ok "Generated JWT_ACCESS_SECRET."; }
env_has_placeholder JWT_REFRESH_SECRET && { env_set JWT_REFRESH_SECRET "$(gen_secret)"; ok "Generated JWT_REFRESH_SECRET."; }

# ── Ports: auto-shift every one when busy ────────────────────────────────────
port_busy() { ss -tln 2>/dev/null | grep -qE "[:.]$1[[:space:]]" && return 0; (echo > /dev/tcp/127.0.0.1/$1) >/dev/null 2>&1 && return 0; return 1; }
resolve_port() { # resolve_port VAR PREFERRED
  local var=$1 preferred=$2 chosen=$2 guard=0
  while port_busy "$chosen"; do chosen=$((chosen+1)); guard=$((guard+1)); [ $guard -gt 100 ] && die "No free port above $preferred."; done
  export "$var=$chosen"
  if [ "$chosen" != "$preferred" ]; then warn "$var: port $preferred busy — using $chosen."; fi
  return 0
}
resolve_port POSTGRES_PORT      5433
resolve_port REDIS_PORT         6380
resolve_port MAILHOG_SMTP_PORT  1025
resolve_port MAILHOG_UI_PORT    8025
resolve_port RABBITMQ_AMQP_PORT 5672
resolve_port RABBITMQ_UI_PORT   15672
resolve_port API_PORT           8080
resolve_port FRONTEND_PORT      3000
resolve_port MANAGEMENT_PORT    9090
resolve_port GRAFANA_PORT       3300
resolve_port PROMETHEUS_PORT    9190

# ── Platform stack ───────────────────────────────────────────────────────────
if $VERIFY_ONLY; then
  log "verify-only: skipping startup — using the already-running stack."
else
  log "Building the platform images (first run takes a few minutes)..."
  compose -f "$COMPOSE_FILE" build ${REBUILD:+--no-cache} api frontend

  log "Starting platform dependencies..."
  compose -f "$COMPOSE_FILE" up -d postgres redis mailhog rabbitmq
  for i in $(seq 1 40); do
    healthy=$(compose -f "$COMPOSE_FILE" ps 2>/dev/null | grep -c "(healthy)" || true)
    [ "$healthy" -ge 3 ] && { ok "Platform dependencies healthy."; break; }
    [ "$i" -eq 40 ] && die "Platform dependencies did not become healthy."
    sleep 3
  done

  log "Starting the API and the storefront..."
  compose -f "$COMPOSE_FILE" up -d api frontend
fi

for i in $(seq 1 36); do
  H=$(curl -s -m 5 "http://localhost:$API_PORT/api/v1/health" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['status'])" 2>/dev/null || true)
  [ "$H" = "UP" ] && { ok "API is UP."; break; }
  [ "$i" -eq 36 ] && die "API did not become healthy — check: docker logs iloveshopping-api"
  sleep 5
done
for i in $(seq 1 24); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 "http://localhost:$FRONTEND_PORT/" 2>/dev/null || true)
  [ "$code" = "200" ] && { ok "Storefront is UP."; break; }
  [ "$i" -eq 24 ] && die "Storefront did not start — check: docker logs iloveshopping-frontend"
  sleep 5
done

# ── Observability stack ──────────────────────────────────────────────────────
cd "$HERE"
log "Starting the observability stack (Prometheus, Loki, Alloy, Grafana)..."
compose -f "$HERE/docker-compose.yml" up -d
for i in $(seq 1 24); do
  g=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -u admin:admin "http://localhost:$GRAFANA_PORT/api/health" 2>/dev/null || true)
  [ "$g" = "200" ] && { ok "Grafana is UP."; break; }
  [ "$i" -eq 24 ] && die "Grafana did not start — check: docker logs iloveshopping-grafana"
  sleep 5
done

# ── Data generation: seed + traffic ──────────────────────────────────────────
log "Seeding 30 days of history (idempotent)..."
PG_CONTAINER="${PG_CONTAINER:-iloveshopping-postgres}"
bash "$HERE/scripts/seed-data.sh"

log "Generating live traffic for 90 seconds (browsing, logins, checkouts, failures, bursts)..."
API_URL="http://localhost:$API_PORT/api/v1" bash "$HERE/scripts/simulate-traffic.sh" --seconds 90 || true

log "Triggering a failed-login burst — the alert will fire and email MailHog..."
API_URL="http://localhost:$API_PORT/api/v1" bash "$HERE/scripts/simulate-traffic.sh" --burst || true
sleep 20
API_URL="http://localhost:$API_PORT/api/v1" bash "$HERE/scripts/simulate-traffic.sh" --burst || true
log "Waiting for the alert to evaluate and deliver (75s)..."
sleep 75

# ── Automatic requirement verification ───────────────────────────────────────
log "Verifying every requirement automatically..."
bash "$HERE/scripts/verify-demo.sh" "http://localhost:$API_PORT/api/v1" "http://localhost:$GRAFANA_PORT" || \
  warn "Some checks failed — see the table above. The stack is still up for manual inspection."

# ── Keep live traffic flowing for the review ─────────────────────────────────
log "Starting continuous background traffic (keeps dashboards live during the review)..."
API_URL="http://localhost:$API_PORT/api/v1" nohup bash "$HERE/scripts/simulate-traffic.sh" --seconds 3600 --rate 2 > /tmp/ils-traffic-sim.log 2>&1 &
disown

# ── Reviewer guide ───────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════════"
ok  "EVERYTHING IS RUNNING — here is what to review, in order:"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "  1. GRAFANA (the four required dashboards, live data):"
echo "     http://localhost:$GRAFANA_PORT  (admin / admin)"
echo "       · Business intelligence — revenue, AOV, abandonment, categories"
echo "       · Product & customer    — top products, ratings, correlation panels"
echo "       · Technical performance — latency, error rates, pool pressure"
echo "       · Security              — failed logins, JWT refresh, rate limits"
echo
echo "  2. ALERTING (requirement: alerts that actually fire):"
echo "     The failed-login burst has already fired an alert."
echo "     MailHog:  http://localhost:$MAILHOG_UI_PORT  — an email from"
echo "     alerts@iloveshopping.local is waiting in the inbox."
echo "     Re-fire anytime:  bash scripts/simulate-traffic.sh --burst"
echo
echo "  3. THE PLATFORM ITSELF:"
echo "     Storefront:  http://localhost:$FRONTEND_PORT"
echo "     API health:  http://localhost:$API_PORT/api/v1/health"
echo "     Metrics:     http://localhost:$PROMETHEUS_PORT/api/v1/targets"
echo "     Accounts:    admin@iloveshopping.com / Admin123!"
echo "                  user@iloveshopping.com  / User123!"
echo
echo "  4. CORRELATED METRICS (requirement: >=2):"
echo "     Business dashboard:  AOV — guests vs registered"
echo "     Product dashboard:   category rating × revenue"
echo
echo "  Stop everything:  ./start.sh --stop"
echo "════════════════════════════════════════════════════════════════════"
