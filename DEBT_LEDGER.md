# Debt Ledger — observability

Known problems, ordered by severity. Burn items down; never add silently.

- [High] The stack has not been verified end-to-end on this machine: the local Docker daemon is broken (DNS egress denied at the snap/AppArmor layer — new containers cannot pull or publish). All configs parse (YAML/JSON validated, schemas cross-checked against the platform's migrations and Micrometer naming), but dashboards rendering, alerts emailing and the seeder running are UNTESTED locally. Confirmation path: `sudo snap restart docker`, then `docker compose up -d`, `bash scripts/seed-data.sh`, `bash scripts/simulate-traffic.sh --burst`, watch MailHog for the failed-login alert.
- [Medium] Grafana alert-rule provisioning is written against the unified-alerting schema of Grafana 11/12 from documentation, and the compose pins `grafana:latest` — a future major-version schema change would break provisioning at startup. Fix on first boot: pin the image tag once verified.
- [Medium] demo-data.sql writes plaintext email/address fields for historical rows. Deliberate trade-off (recorded, not overlooked): the app's encryption converter passes non-`enc:v1:` values through on read, dashboards never display them, and API-created rows stay encrypted. Revisit if the review requires historical rows to be ciphertext too.
- [Low] prometheus/rules.yml duplicates the Grafana alert rules without an Alertmanager — Prometheus's copy is only visible in its own UI Alerts tab and never emails. Kept intentionally for that UI; Grafana does the real alerting.
- [Low] docker-compose.yml carries the obsolete `version:` key (Compose v2 warns).
- [Low] The product-customer "Payments by provider" panel mixes an instant query with a range query in one timeseries panel — the instant series renders as a single point.
