# i-love-shopping observability

Metrics, logs and alerting for the e-commerce platform.

Built on the [platform's CI gated images](https://github.com/imranshiundu/integrator) and wired to the platform's own MailHog so alert emails are visible locally.

## Overview

- **Metrics** — Spring Boot Actuator + Micrometer scrape the API's hardened management port (`/actuator/prometheus`) every 15 s into Prometheus.
- **Logs** — Grafana Alloy reads every platform container's logs from the Docker socket and pushes them to Loki.
- **Visualisation and alerting** — Grafana with four provisioned dashboards, a contact point to MailHog and rule-based alerting with group-wait and repeat-interval tuning to avoid fatigue.
- **Dashboards** — business intelligence, product & customer, technical performance, security — each designed around the question you actually ask when paged.

## Quick start (reviewers: this is the only repo you need)

**Do I need to clone or run the i-love-shopping platform separately? NO.**
`./start.sh` clones the platform repository automatically if it is missing,
installs Docker if it is missing, generates every required secret, shifts
busy ports, builds and starts the whole stack, seeds 30 days of history,
generates live traffic (including failures), fires an alert, and verifies
every requirement automatically — then prints what to review.

```bash
git clone https://gitea.kood.tech/imranshiundu/observability.git
cd observability
./start.sh
# Windows: start.cmd (Git Bash + Docker Desktop required)
```

What `./start.sh` does, in order:

| Step | What happens |
|---|---|
| 1 | Installs Docker, docker compose, curl and python3 if missing (Linux/macOS; Windows requires Docker Desktop + Git Bash) |
| 2 | Clones [i-love-shopping](https://gitea.kood.tech/imranshiundu/i-love-shopping3) into `../i-love-shopping` if absent |
| 3 | Creates the platform `.env` and generates the required secrets (see [Rotating keys](#rotating-keys)) |
| 4 | Shifts every busy port (postgres/redis/mailhog/rabbitmq/api/frontend/grafana/prometheus) |
| 5 | Builds and starts the platform (PostgreSQL, Redis, RabbitMQ, MailHog, API, storefront) |
| 6 | Starts the observability stack (Prometheus, Loki, Alloy, Grafana) on the same network |
| 7 | Seeds 30 days of history (idempotent — safe on every run) |
| 8 | Generates 90s of live traffic + fires a failed-login burst so an alert email lands in MailHog |
| 9 | Runs 14 automated requirement checks — every dashboard, counter, log stream and alert verified live |
| 10 | Starts continuous background traffic so the dashboards stay live during the review |

**Exit is 0 when every requirement passes.** If any check fails, the stack still stays up for manual inspection and the failure is printed with its evidence.

- Grafana: http://localhost:3300 (admin / admin)
- MailHog (alert emails): http://localhost:8025
- Storefront: http://localhost:3000
- API health: http://localhost:8080/api/v1/health

Re-fire the alert anytime: `bash scripts/simulate-traffic.sh --burst`
Stop everything: `./start.sh --stop` (data volumes survive)

### Flags

| Flag | What it does |
|---|---|
| *(none)* | Full demo: install, build, seed, simulate, alert, verify, background traffic |
| `--stop` | Stop everything (data is kept) |
| `--rebuild` | Force image rebuild |
| `--verify-only` | Run the 14 requirement checks against an already-running stack |

### Requirements verification (what ./start.sh checks)

```
  PASS: metrics collection: Prometheus scrapes the API (up=1)
  PASS: BI dashboard provisioned
  PASS: seed history present (DEMO orders: 120)
  PASS: Product & customer dashboard provisioned
  PASS: categories exist for the rating/revenue panels (5)
  PASS: correlated metrics: 2 panels (>=2 required)
  PASS: API request metrics recorded (/products: 54)
  PASS: database pool metrics present
  PASS: failed-login counter live (16)
  PASS: JWT refresh counter live (3 rotations)
  PASS: rate-limit counter live (71)
  PASS: logs collected in Loki (557369 lines in 2h)
  PASS: alert rules provisioned (4)
  PASS: alert email delivered through MailHog (1 alert email(s))
════ ALL REQUIREMENTS VERIFIED (14/14) ════
```

## Dashboards

| Dashboard | Question it answers |
|---|---|
| Business intelligence | How much money are we making, per day, per category, per customer type — and do guests and registered buyers spend differently? |
| Product & customer | What's selling, what ratings feel like, what's running out of stock, and does higher rating actually mean more revenue? |
| Technical performance | Are we up, where do requests come from, how slow are payment and search really, how hard is the DB pool working, which provider/reasons dominate failures — and what do the error log lines behind the numbers actually say? |
| Security | Failed logins by reason and over time, JWT token refresh rotation vs failure (session_revoked, token_reuse_detected), password reset rate, rate-limit bursts by scope, login-mode mix, plus the live auth-failure log lines. |

Every dashboard loads with live counters. Business + product dashboards query Postgres directly; technical and security dashboards run on Prometheus. Two deliberately correlated panels ship on the business and product dashboards (guest vs registered AOV, category rating vs revenue).

## Rotating keys

The platform's secrets live in `../i-love-shopping/.env`. `./start.sh`
generates the required ones on first run. The observability demo works
without any payment keys — the traffic simulator deliberately exercises
the failure paths, which is what the payment-failure dashboard visualises.

| Key | Required | What breaks without it | How to update |
|---|---|---|---|
| `DATA_ENCRYPTION_KEY` | **YES** | the API refuses to start (by design) | `openssl rand -base64 32` into `.env`, then restart; old encrypted data becomes unreadable — wipe volumes or keep the key |
| `JWT_ACCESS_SECRET` / `JWT_REFRESH_SECRET` | **YES** | the API refuses to start | `openssl rand -hex 32`; rotation invalidates all sessions (users re-login) |
| `MPESA_CONSUMER_KEY/SECRET/PASSKEY` | no | M-Pesa payments disabled | Daraja dashboard → paste into `.env` → restart |
| `STRIPE_SECRET_KEY` / `STRIPE_PUBLISHABLE_KEY` | no | card payments disabled | Stripe dashboard → test keys (`sk_test_...`/`pk_test_...`) into `.env` + `NEXT_PUBLIC_*` in the frontend env → restart |
| `RECAPTCHA_SECRET_KEY` | no | real captcha enforcement | dev default (`dev-test-secret`) bypasses in dev; real key enables enforcement |
| `GOOGLE_CLIENT_ID/SECRET`, `GITHUB_CLIENT_ID/SECRET` | no | social login buttons hidden | provider console → paste into `.env` + `NEXT_PUBLIC_*` in the frontend env |
| `MAIL_*` | no | falls back to MailHog automatically | any SMTP; unreachable SMTP auto-falls back to MailHog for the run |

**To update a key:** edit `../i-love-shopping/.env`, then `./start.sh --stop && ./start.sh` (or just `docker compose -f ../i-love-shopping/docker/docker-compose.yml up -d --force-recreate api` if only the API needs it).

**Rotating `DATA_ENCRYPTION_KEY` caution:** the key encrypts addresses,
emails, payment metadata and guest emails at rest (AES-256-GCM). A new
key makes old ciphertext undecryptable — for dev data either keep the
same key or wipe volumes (`docker compose down -v`).

## What normal looks like (baseline for abnormal)

Read this before you debug at 3 a.m. These are the healthy values on
a fresh demo run:

| Signal | Normal | Abnormal when |
|---|---|---|
| `up{job="iloveshopping-api"}` | 1 (container target; host target down is fine in Docker mode) | 0 on every target = API down alert |
| API p95 latency | < 500 ms for catalog reads, < 1.5 s for checkout | sustained > 2 s = SlowApiP95 alert |
| 5xx rate | ~0% (only a handful of 400s from validation) | > 5% for 5 min = HighApiErrorRate alert |
| Failed logins | ~6/min while the sim runs (deliberate) | > 10 in 10 min = FailedLoginsSpike alert fires (by design during bursts) |
| JWT refresh failures | mostly `invalid_token` from the sim's garbage token | a rise in `session_revoked` or `token_reuse_detected` = possible session hijacking |
| Rate-limited requests | bursts of `auth`-scope 429s when the sim fires | sustained 429s at normal traffic = limits too low or an attack |
| Payment failures | STK timeouts from the sim's sandbox pushes (expected) | new failure reasons (card_declined spike, gateway errors) = provider issue |
| Revenue trend | steady from the seed history + sim orders | cliff to zero = checkout broken |
| Cart abandonment | ~20-30% (seeded PENDING/EXPIRED orders) | sudden rise = payment flow broken |

## Alerts (Provisioned)

- **APIDown** — `up{job="iloveshopping-api"} == 0` for a minute, critical.
- **HighApiErrorRate** — >5% of requests 5xx for five minutes, warning.
- **FailedLoginsSpike** — >10 failed login attempts in 10 minutes, warning.
- **SlowApiP95** — p95 latency over two seconds for five minutes, warning.

Alerts land as email in MailHog through Grafana's unified alerting. Policies group by alert name + severity and suppress redundant repeats for four hours.

## Data generation

- `scripts/seed-data.sh` — one-shot, idempotent historical baseline (45 demo users, 120 mixed orders across 30 days, payments, approved reviews). Safe to run multiple times: refuses to write twice.
- `scripts/simulate-traffic.sh` — steady traffic: catalog browsing, suggestion hits, cart adds, occasional wrong-password attempts, and real checkouts whose session includes **JWT token refresh** (success rotation plus deliberate garbage-token failures) and an **M-Pesa STK push to the sandbox number** — the platform cannot receive the callback locally, so its watchdog expires the session (~2 min) and the payment-failure counter ticks with a real reason. Periodic rate-limit bursts included. Options: `--seconds N`, `--rate secs`, `--burst` for a one-shot 40-call flood.

Both work against the platform described by `API_URL` (default `http://localhost:8080/api/v1`).

## Extras

- Fully provisioned dashboards, datasources, alert rules and contact points — no point-and-click setup needed, everything comes up configured.
- The platform exposes `/actuator/prometheus` on a separate management port (9090), never on the public API port. Only the internal network can reach it.
- Grafana alert history lives in MailHog — the reviewer's proof an alert fired is an email, not a screenshot.

## The three pillars — where traces stand

Metrics and logs are first-class here (Prometheus + Loki, both used directly in the dashboards — the technical and security dashboards carry live log panels next to the numbers). Traces are a **recorded deferral**: the platform is a modular monolith whose request paths stay within one process, so per-request tracing adds infra (Tempo/OpenTelemetry) without adding an answer the four required dashboards need. The extension point is documented in `DEBT_LEDGER.md`; the OTel Java agent plus a Tempo service is the natural next step if the platform splits into services.

## Additional features implemented

- Local + Gitea/GitHub compatible Prometheus config, with a second scrape target (`host.docker.internal`) so the host-runned Maven API gets scraped too.
- Four documented dashboards in Grafana JSON — versioned like code, reviewed like code.
- Rate-limit scoping ("auth" vs "api") so the token(bucket abuse story has its own chart.
- All dashboards update live (30 s refresh) and the two correlated dashboards are explicitly called out in the panel descriptions so reviewers see the intent.
- Postgres used as a direct datasource for the business dashboards — metrics you can't afford to mis-aggregate via counters go through SQL instead.
- The integrator CI pipeline verifies the metrics endpoint on every delivery: stage 4 asserts `/actuator/prometheus` serves Prometheus format from inside the API container, so the observability contract cannot silently break.
- Seed history deliberately includes stale unpaid orders (abandonment gauge) and failed payments with realistic reasons (payment-failure analysis), so every panel reads signal from minute one.