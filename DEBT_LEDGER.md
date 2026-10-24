# Debt Ledger — observability

Known problems, ordered by severity. Burn items down; never add silently.

- [RESOLVED] The stack is now verified END-TO-END on this machine (daemon repaired): all 4 dashboards provisioned, 3 datasources healthy, 4 alert rules provisioned, the failed-login alert FIRED on a simulated burst and delivered alert emails from alerts@iloveshopping.local to ops@iloveshopping.local through MailHog, the seed loaded 120 historical orders idempotently, the traffic simulator produced live counters (orders placed, payment failures via the STK watchdog, auth failures, rate-limit hits, suggestions), and Loki ingests container logs queryable through Grafana. Receipts: this session's curl checks against :9190/:3300/:3100/:8025 APIs.
- [Medium] Grafana alert-rule provisioning is written against the unified-alerting schema of Grafana 11/12 from documentation, and the compose pins `grafana:latest` — a future major-version schema change would break provisioning at startup. Fix on first boot: pin the image tag once verified.
- [Medium] demo-data.sql writes plaintext email/address fields for historical rows. Deliberate trade-off (recorded, not overlooked): the app's encryption converter passes non-`enc:v1:` values through on read, dashboards never display them, and API-created rows stay encrypted. Revisit if the review requires historical rows to be ciphertext too.
- [Low] prometheus/rules.yml duplicates the Grafana alert rules without an Alertmanager — Prometheus's copy is only visible in its own UI Alerts tab and never emails. Kept intentionally for that UI; Grafana does the real alerting.
- [Low] docker-compose.yml carries the obsolete `version:` key (Compose v2 warns).
- [Low] Traces pillar deferred (recorded trade-off): modular monolith keeps request paths in-process; the OTel-agent + Tempo wiring is the documented extension point if the platform splits into services.
- [Low] The product-customer "Payments by provider" panel mixes an instant query with a range query in one timeseries panel — the instant series renders as a single point.
