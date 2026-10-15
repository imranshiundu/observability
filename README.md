# i-love-shopping observability

Metrics, logs and alerting for the e-commerce platform.

Built on the [platform's CI gated images](https://github.com/imranshiundu/integrator) and wired to the platform's own MailHog so alert emails are visible locally.

## Overview

- **Metrics** — Spring Boot Actuator + Micrometer scrape the API's hardened management port (`/actuator/prometheus`) every 15 s into Prometheus.
- **Logs** — Grafana Alloy reads every platform container's logs from the Docker socket and pushes them to Loki.
- **Visualisation and alerting** — Grafana with four provisioned dashboards, a contact point to MailHog and rule-based alerting with group-wait and repeat-interval tuning to avoid fatigue.
- **Dashboards** — business intelligence, product & customer, technical performance, security — each designed around the question you actually ask when paged.

## Quick start

The platform stack runs first, then this one joins its network:

```bash
# platform, from the ziel repo's root
bash start.sh --auto

# observability stack
cd ../observability
docker compose up -d
bash scripts/seed-data.sh
bash scripts/simulate-traffic.sh --seconds 120
```

Grafana is at http://localhost:3300 (admin / admin). Alert e-mails land in MailHog at http://localhost:8025.

To force an alert for review: run `bash scripts/simulate-traffic.sh --burst` — that floods `/auth/login` with bad credentials and both the rate-limiter counter and the failed-login alert will fire.

## Dashboards

| Dashboard | Question it answers |
|---|---|
| Business intelligence | How much money are we making, per day, per category, per customer type — and do guests and registered buyers spend differently? |
| Product & customer | What's selling, what ratings feel like, what's running out of stock, and does higher rating actually mean more revenue? |
| Technical performance | Are we up, where do requests come from, how slow are payment and search really, how hard is the DB pool working, which provider/reasons dominate failures? |
| Security | Failed logins by reason, 2FA pressure, password reset rate, rate-limit bursts, login-mode mix. |

Every dashboard loads with live counters. Business + product dashboards query Postgres directly; technical and security dashboards run on Prometheus. Two deliberately correlated panels ship on the business and product dashboards (guest vs registered AOV, category rating vs revenue).

## Alerts (Provisioned)

- **APIDown** — `up{job="iloveshopping-api"} == 0` for a minute, critical.
- **HighApiErrorRate** — >5% of requests 5xx for five minutes, warning.
- **FailedLoginsSpike** — >10 failed login attempts in 10 minutes, warning.
- **SlowApiP95** — p95 latency over two seconds for five minutes, warning.

Alerts land as email in MailHog through Grafana's unified alerting. Policies group by alert name + severity and suppress redundant repeats for four hours.

## Data generation

- `scripts/seed-data.sh` — one-shot, idempotent historical baseline (45 demo users, 120 mixed orders across 30 days, payments, approved reviews). Safe to run multiple times: refuses to write twice.
- `scripts/simulate-traffic.sh` — steady traffic: catalog browsing, suggestion hits, cart adds, occasional wrong-password attempts, occasional real checkout, periodic rate-limit bursts. Options: `--seconds N`, `--rate secs`), `--burst` for a one-shot 40-call flood.

Both work against the platform described by `API_URL` (default `http://localhost:8080/api/v1`).

## Extras

- Fully provisioned dashboards, datasources, alert rules and contact points — no point-and-click setup needed, everything comes up configured.
- The platform exposes `/actuator/prometheus` on a separate management port (9090), never on the public API port. Only the internal network can reach it.
- Grafana alert history lives in MailHog — the reviewer's proof an alert fired is an email, not a screenshot.

## Additional features implemented

- Local + Gitea/GitHub compatible Prometheus config, with a second scrape target (`host.docker.internal`) so the host-runned Maven API gets scraped too.
- Four documented dashboards in Grafana JSON — versioned like code, reviewed like code.
- Rate-limit scoping ("auth" vs "api") so the token(bucket abuse story has its own chart.
- All dashboards update live (30 s refresh) and the two correlated dashboards are explicitly called out in the panel descriptions so reviewers see the intent.
- Postgres used as a direct datasource for the business dashboards — metrics you can't afford to mis-aggregate via counters go through SQL instead.