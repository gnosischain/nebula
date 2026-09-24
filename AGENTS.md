# AGENTS.md — nebula

Build wrapper, not an application: a `Dockerfile` that clones upstream `dennis-tra/nebula` at a pinned commit, and a workflow that publishes it as `ghcr.io/<owner>/gc-nebula`. Four files; no source, config, Makefile or tests.
Data flow: DHT peers → `nebula crawl` (one crawler per network) → ClickHouse `nebula` (consensus, discv5) and `nebula_discv4` (execution, discv4) → dbt-cerebro `models/p2p/` (26 of its 27 models read nebula; `stg_crawlers_data__ipinfo` does not; none reads `crawls`) and the ip-crawler.
The one rule: the private deployment stack decides what runs; this repo only chooses WHICH upstream commit is built. No subcommand, flag or env var is defined here, so never assume one exists.

## Where this runs (production)

GKE Autopilot, deployed by Terraform from the private repository gnosisdevops/infrastructure-gnosis-analytics (its `nebula` stack under `google/deployments/`). Both crawlers run `ghcr.io/gnosischain/gc-nebula` tag `53d3058`, pinned by digest (stack `locals.tf:17-19`), never `latest`.

| Role | What it runs | Schedule | Writes |
|---|---|---|---|
| Consensus crawler (discv5), 1 replica | `nebula crawl`, `NEBULA_CRAWL_NETWORK=GNOSIS`, `NEBULA_DATABASE_NAME=nebula`, `NEBULA_DATABASE_APPLY_MIGRATIONS=false` (`locals.tf:42-62`) | Continuous: a sweep ends, the process exits, the container restarts in place (`deployments.tf:14-16`); watchdog kills it past 3000 s, counted from the first probe at +300 s (`locals.tf:92`, `configmap.tf:37-53`, `deployments.tf:202-210`) | `nebula.visits`, `crawls`, `neighbors`, `discovery_id_prefixes_x_peer_ids`, `schema_migrations` (dbt-cerebro `p2p_sources.yml:15-105`) |
| Execution crawler (discv4), 1 replica | `nebula crawl`, `NEBULA_CRAWL_NETWORK=ETHEREUM_EXECUTION`, `NEBULA_DATABASE_NAME=nebula_discv4`, migrations flag unset (`locals.tf:64-79`) | Same; watchdog 10800 s (`locals.tf:93`) | same tables in `nebula_discv4` (`p2p_sources.yml:119-210`) |
| Metrics Service per crawler + PodMonitor | port 9090 `metrics` (`deployments.tf:228-252`, `podmonitor.tf:5-30`) | Continuous | nothing; feeds Prometheus and the nebula dashboard (`podmonitor.tf:1-4`) |
| Credentials sync | warehouse credentials from the cloud secret manager (`secrets.tf:3-17`) | every 3 min | `NEBULA_DATABASE_HOST/PORT/USER/PASSWORD` (`locals.tf:97-102`) |

- Shared pod `env` (`locals.tf:46-53,60-61` and `:68-75,77-78`; port `locals.tf:31`): `NEBULA_DATABASE_ENGINE=clickhouse`, `NEBULA_DATABASE_SSL=true`, `NEBULA_CLICKHOUSE_MIGRATIONS_TABLE_ENGINE=MergeTree`, `NEBULA_CLICKHOUSE_REPLICATED_TABLE_ENGINES=true`, `NEBULA_CRAWL_NEIGHBORS=true`, `NEBULA_CRAWL_PEER_LIMIT=0`, `NEBULA_CRAWL_WORKER_COUNT=1000`, `NEBULA_UDP_BUFFER_SIZE=4194304`, `NEBULA_METRICS_HOST=0.0.0.0`, `NEBULA_METRICS_PORT=9090`. Container: `command=["nebula"] args=["crawl"]` (`deployments.tf:129-135`).
- Local-only artifacts: none (no Makefile, docker-compose or `.env`). Production runs only the image's `nebula` binary with `crawl`.
- Single writer per database, enforced only by the stack (`locals.tf:22` replicas = 1; `deployments.tf:53-59` Recreate, "tables that do not dedupe re-inserted rows"). Nothing in this repo or the stack prevents a second writer; upstream's locking at `7cf39ac8` is unverified (at the older upstream `77aa1796` a second crawl only logs "Another crawl is already running", `db/ch.go:352-353`), so check before relying on it.
- Not deployed: any subcommand but `crawl`; the Docker `HEALTHCHECK`; the old cluster's p2p NodePort Services (`deployments.tf:6-8`); any Job, CronJob or backfill (a missed sweep cannot be re-crawled). Public nodes, egress from an ephemeral node IP, not the shared NAT (`locals.tf:104-120`).
- No alert rule reads the metrics (runbook 27 line 3; the deployments repo's alerting `README.md:156-159`, "Not yet covered"). The `locals.tf:12-13` comment mentioning alert rules is stale.

## Modes and commands — the complete list

The CLI (subcommands, flags, env defaults) is upstream's: open `github.com/dennis-tra/nebula` at the pinned commit before claiming anything about it. Citations to upstream commit `77aa1796` (Feb 2025, older than the pin) are hints from an earlier tree, not facts about `7cf39ac8`.

| Invocation | What it does | Writes? | Safe beside the live writer? | Required args / env | Source |
|---|---|---|---|---|---|
| `docker build .` (local-only) | Clones upstream, checks out `7cf39ac8b5a172b226086ee05c14913ab25a22d3`, builds `./cmd/nebula` (CGO), copies it into Alpine as user `nebula` | Nothing | Yes | Docker, GitHub access | `Dockerfile:6-13,17-23` |
| `docker build --target builder .` (local-only) | Builds only the Go toolchain stage: upstream source at `/build` checked out at `7cf39ac8`, binary at `/build/nebula`; the way to read the pinned CLI (`cmd/nebula`) and ClickHouse migrations locally | Nothing | Yes | Docker, GitHub access | `Dockerfile:1-13` |
| `docker run [--env-file ⟨FILE⟩] <image> nebula ⟨subcommand⟩` (local-only) | Any upstream subcommand. `docker run <image> crawl` fails: no ENTRYPOINT, so `crawl` replaces CMD and is exec'd as a binary | Per subcommand; `crawl` writes `NEBULA_DATABASE_NAME` | NO with production `NEBULA_DATABASE_*` in the env (`crawl` is then a second writer, and may also migrate) | for `crawl`, a `NEBULA_DATABASE_NAME` other than `nebula`/`nebula_discv4`, non-production host | `Dockerfile:17-28` (final stage, no ENTRYPOINT; CMD at `:28`); stack `deployments.tf:129-133` |
| `nebula` (image CMD) | Upstream binary, no subcommand; unverified. Production never runs it | Unknown | Unknown; never with production credentials | none | `Dockerfile:28` |
| `nebula health` (Docker HEALTHCHECK: interval 15 s, timeout 5 s, start-period 10 s) | Run only by a Docker engine. At `77aa1796` a hidden subcommand that GETs `/health` on `NEBULA_METRICS_HOST:PORT` and fails unless 200; that it exists and does this at `7cf39ac8` is unverified, so open upstream `cmd/nebula` before relying on it | No at `77aa1796` (one HTTP GET) | Yes (local only) | none | `Dockerfile:25-26`; upstream `cmd/nebula/cmd_health.go:12-30` at `77aa1796` |
| `nebula crawl` (PRODUCTION) | One DHT sweep of `NEBULA_CRAWL_NETWORK` into `NEBULA_DATABASE_NAME`, then exits | Yes: `<NEBULA_DATABASE_NAME>.*` | NO: a second writer into tables that do not dedupe (stack `deployments.tf:55-56`; at `77aa1796` `visits` and `neighbors` are plain MergeTree, `db/migrations/ch/000003_create_visits_table.up.sql:65`, `000004_create_neighbors_table.up.sql:7`, and each writer mints its own crawl ids, `db/ch.go:358-365`) | `NEBULA_CRAWL_NETWORK`, `NEBULA_DATABASE_NAME`, `NEBULA_DATABASE_HOST/PORT/USER/PASSWORD`, shared env | `Dockerfile:13,23`; stack `deployments.tf:14-16,134-135`, `configmap.tf:5-6`, `locals.tf:22,42-79,97-102` |
| Push to `main` → "Build & Release GC nebula" | Two separate multi-arch buildx builds: `:latest` (`build-and-release.yml:43-47`) and `:<short-sha>` (`:49-53`). Base images unpinned (`Dockerfile:1` golang:1.23-alpine, `Dockerfile:17` alpine:latest), so the tags can differ in digest and rebuilds are not reproducible; pin the stack by the short-sha tag's digest. Runs cancel each other (`:8-10`) and `:latest` is pushed first, so a commit may have NO `:<short-sha>` tag: confirm it exists in GHCR before proposing it. No `paths:` filter (`:3-6`): any push to `main`, even README-only, republishes. No tests, PR build or dispatch | Registry only | Yes: nothing changes until a human updates the stack | `secrets.GITHUB_TOKEN` (`:41`); no `permissions:` block (default token permissions). Actions pinned by tag, not SHA (`:20,31,34,37`); the short-sha tag is the third-party `prompt/actions-commit-hash@v3` output (`:31,52`); owner is `github.repository_owner` (`:25`), i.e. `gnosischain` | `.github/workflows/build-and-release.yml:3-10,20-53` |

## What does not exist, or does not do what its name says

- The repo is not the crawler: `README.md:1-3` describes upstream, and behaviour is an unmodified clone (`Dockerfile:7-9`). The public page's "forked ... and customized" (`nebula.md:3`) is wrong.
- `.gitignore:1-3` ignores `.env`, `__pycache__`, `.DS_Store`; nothing here reads `.env` and there is no Python.
- `nebula health` is not liveness: Kubernetes ignores `HEALTHCHECK`. Liveness is an exec probe that FAILS on purpose past a max uptime (`configmap.tf:1-8`, `deployments.tf:199-210`).
- `:latest` is not production. Today `53d3058` is `main` HEAD (`.git/refs/heads/main`) and set the `7cf39ac8` pin (2026-04-23, last `.git/logs/HEAD` entry). After the next push, have a human compare `git log -1 -- Dockerfile` with the stack's tag.
- The migrations default the execution crawler inherits (`locals.tf:55-58`) is unverified at the pin. At the older upstream `77aa1796` it is `true` (`cmd/nebula/cmd.go:57`; flag `db-apply-migrations` / `NEBULA_DATABASE_APPLY_MIGRATIONS`, "apply the database migrations on startup", `:183-187`), so if the pin keeps it the execution crawler applies any pending upstream migration to `nebula_discv4` on every ~35 min restart; if `false`, no new upstream migration reaches `nebula_discv4`. Confirm in `cmd/nebula/cmd.go` at `7cf39ac8`. Ownership is unresolved (runbook 27, "nebula").
- Sweep length: ~35 min per the stack (`locals.tf:90-91`, `configmap.tf:5`); not re-measured on GKE in any repo file. An unrecorded 2026-09-09 observation put the first GKE sweep at 46 min; measure it with `median_sweep_s` from the completeness query below before relying on either number.
- Public page errors: `visit_started_at` (`nebula.md:59`) vs `visited_at` (`:108`); "All tables ... in the `nebula` database" (`:91`), though execution writes `nebula_discv4`; fork digests "configured as environment variables" (`:87`), none in the stack; "configurable schedule" (`:23`), but the loop is exit-and-restart (`configmap.tf:5-6`); `nebula.peers` (`:42-44,111-122`) has no consumer and is unverified; "16 dbt p2p models" (`:27`, runbook 27 line 8) is really 26; "three-file build wrapper" (`:50`, runbook 27 line 10) is four files (`Dockerfile`, `README.md`, `.gitignore`, the workflow); the visits schema table (`:93-109`, also `:39`) lists `id`, `session_id`, `listen_addrs`, `connect_error`, `created_at` and ORDER BY `visited_at`, none of which is in the dbt source (`p2p_sources.yml:42-71`; errors live in `crawl_error` / `dial_errors`). Run `DESCRIBE nebula.visits` first.

## Hazards

- Second writer: `nebula crawl` with `NEBULA_DATABASE_NAME` `nebula`/`nebula_discv4` against production (laptop, `docker run --env-file`, extra replica) duplicates rows. Safe: another database or a local ClickHouse. Enforcement: replicas = 1 and Recreate (runbook 27, "nebula"; `deployments.tf:53-59`).
- Migrations: enabling them, or flipping the consensus flag, lets upstream alter tables dbt reads. Safe: leave both flags as the stack has them.
- Watchdog vs sweep: consensus is killed ~56 min after start (3000 s counted from the first probe at 300 s, probes every 60 s); a slower sweep (fewer workers, bigger network) dies incomplete every time while `max(visit_started_at)` looks fresh. Safe: raise the stack's threshold; check sweep duration (`median_sweep_s` below, or the pod log).
- Image contract: binary `nebula` on PATH (`Dockerfile:23`, the stack's `command`); process name `nebula` (watchdog `pgrep`, `configmap.tf:32-35`, else a restart every probe); user `nebula`, uid 1000: `Dockerfile:19` creates it with no explicit uid, and 1000 was read from the built image (stack `locals.tf:81-86`, README:87-98); the stack forces uid 1000 (`locals.tf:86`, `deployments.tf:104-107`), overriding any other image user; writable `/tmp` (`configmap.tf:29`). Working directory `/home/nebula` is made by WORKDIR, not by `adduser -H` (`Dockerfile:19-21`); its owner is unverified on the pinned image and the stack mounts nothing there (root filesystem left writable, `deployments.tf:140-143`), so do not assume cwd is writable by uid 1000. A human can check with `docker run --rm <image> ls -ld /home/nebula`. An ENTRYPOINT is ignored (the stack sets `command`). Change these only with a stack change proposed to a human.

## Health and verification is a warehouse query

```sql
SELECT max(visit_started_at) FROM nebula.visits;          -- consensus
SELECT max(visit_started_at) FROM nebula_discv4.visits;   -- execution
```

- Healthy: minutes old. Over ~1 h (consensus) or ~3 h (execution) means down or stuck: the watchdog forces a new sweep past 3000 s / 10800 s. Visits land during a sweep (confirm upstream's batching before relying on sub-sweep freshness).
- Coverage: `SELECT toDate(visit_started_at) AS d, uniqExact(crawl_id) AS sweeps, count() AS visits FROM nebula.visits WHERE d >= today() - 7 GROUP BY d ORDER BY d`. Fewer sweeps than neighbouring days are missed samples; no gap repair exists.
- Completeness: each crawl writes a `started` row, then a final-state row with the same `id` (at `77aa1796`: `db/ch.go:380,433`, table `ReplacingMergeTree(updated_at)`, `db/migrations/ch/000001_create_crawls_table.up.sql:26-27`; the warehouse table's engine is in no repo). Dedupe per `id` by `updated_at` before counting states, or every sealed crawl also counts as `started` until a merge. Same for `nebula_discv4`:

```sql
SELECT st, count() AS crawls, max(fin) AS last_finished,
       median(dateDiff('second', created, fin)) AS median_sweep_s
FROM (SELECT id, argMax(state, updated_at) AS st, argMax(finished_at, updated_at) AS fin,
             min(created_at) AS created
      FROM nebula.crawls WHERE created_at >= now() - INTERVAL 1 DAY GROUP BY id)
GROUP BY st;  -- aliases differ from column names so WHERE still reads the raw column
```

- `succeeded` about every ~35 min; a run of `started`, `cancelled` or `failed` without `succeeded` means incomplete sweeps (enum per `p2p_sources.yml:22,126`; values are upstream's).
- Not a health signal: pod `Running`; restart count (thousands are by design; a LOW count after long uptime is suspicious); exit 0; scraped Prometheus counters; row counts; `nebula health`; dbt source freshness (warn 36 h / error 72 h, `p2p_sources.yml:8-10,112-114`), which passes for 36 h after a crawler stops. Nothing pages (runbook 27 line 3; alerting `README.md:159`).
- Logs: an unrecorded 2026-09-09 observation (in no repo file) found them absent from the cluster's Loki, with no collector on the public node; re-check with LogQL before relying on Loki. The cloud provider's logging is the fallback.
- cerebro-mcp reads `nebula_discv4` and `nebula` (verified 2026-09-23: `SELECT 1 FROM nebula_discv4.visits LIMIT 1` answers, and both databases served every check of that day's redeploy). Both are in its code allowlist (cerebro-mcp `src/cerebro_mcp/config.py`, `ALLOWED_DATABASES`) and the reader user is granted every analytics database (`WAREHOUSE-MIGRATION.md:195`, in the deployments repo's GKE deployments directory); the 2026-09-09 grant gap is closed. If a query ever fails with an access error, use another warehouse client and report the grant.
- Last resort: `nebula_*` Prometheus series show inserting, not rows landed. The name `nebula_insert_latency_count{success=...}` comes from an unrecorded 2026-09-09 observation; confirm it exists before querying.

## Rules for agents

- Derive from code: the Dockerfile pin and the stack's `locals.tf` are the facts; README, the public page and this file are hearsay. A CLI claim cites the upstream file at the pinned commit, opened.
- Local tooling is not production; production takes only the stack's `command`, `args` and `env`. Never run a writer with production `NEBULA_DATABASE_*` from a laptop.
- Never a second writer: never scale a crawler above one, never add a Deployment or Job with a production `NEBULA_DATABASE_NAME`.
- Never assume access to the cluster or the private deployments repository. Propose exact commands for a human to run. Never run a git write, a Terraform apply, a cluster-mutating command or an image push yourself; read-only plans and read-only cluster reads are fine where you already have access.
- Never "normalise" the migrations flag; never treat restarts in the thousands, `Running` or scraped metrics as health signals. Restarting a crawler is safe (runbook 27, "nebula").
- The only change here is the upstream pin: edit `Dockerfile:6-9`, let `main` publish a short-SHA tag, propose the stack's tag+digest change to a human. The pin must be the multi-arch index digest of the short-sha tag, not a per-architecture child (stack `locals.tf:17-19`; the stack sets no arch nodeSelector, `locals.tf:118-120`, and Autopilot injects an amd64 toleration, `deployments.tf:82-91`), while the old AWS pin was the arm64 child (`locals.tf:17-18`, README:46). Never `latest`.
- Lessons: no `.agents/` or `docs/lessons/` here; propose them into the private runbook.

## Where the full procedures live

- In-repo: `README.md` (upstream blurb), `Dockerfile` (the pin), `.github/workflows/build-and-release.yml` (the publish).
- Upstream, the only place the CLI is defined: https://github.com/dennis-tra/nebula at `7cf39ac8b5a172b226086ee05c14913ab25a22d3`.
- Private runbook (restart, watchdog, health query, migrations ownership, ip-crawler): https://github.com/gnosisdevops/infrastructure-gnosis-analytics/blob/main/runbooks/27-nebula-and-ip-crawler.md
- Public docs page: https://docs.analytics.gnosis.io/data-pipeline/crawlers/nebula/
- Public runbooks: downstream dbt after a crawler outage, https://docs.analytics.gnosis.io/operations/runbooks/dbt-reprocess/ (linked from the nebula page's "Then dbt", `nebula.md:72-74`). nebula has no one-shot Job, so https://docs.analytics.gnosis.io/operations/runbooks/one-shot-jobs/ does not cover it.
- Deployment stack: the `nebula` stack in the GKE deployments directory: `locals.tf` (pin, env, thresholds, public nodes), `deployments.tf` (command/args, Recreate, probe), `configmap.tf` (watchdog), `podmonitor.tf`, `secrets.tf`, `data.tf` (root remote state that supplies the namespace and secret store, `locals.tf:9-10`), `providers.tf`, `outputs.tf` (`:1-4` says `replicas` must be the inverse of the AWS twins'; stale: no AWS twin runs, the old cluster was torn down, deployments repo root `CLAUDE.md:9`), and `README.md`, stale on three points: `replicas = 0`/dormant (README:7, and the `locals.tf:21` comment), both crawlers writing `nebula` (README:3-4), and "restarts the pod" (README:78; the container restarts in place). `locals.tf:22,66` are the facts.

Verified 2026-09-23 against: Dockerfile:1-28, .github/workflows/build-and-release.yml:1-53, README.md:1-3, .gitignore:1-3, nebula .git/config (origin); deployment stack nebula/locals.tf:1-153, nebula/deployments.tf:1-252, nebula/configmap.tf:1-61, nebula/outputs.tf:1-13, nebula/podmonitor.tf:1-35, nebula/secrets.tf:1-17, nebula/data.tf:1-8, nebula/providers.tf:1-31, nebula/README.md:1-98; private repository slug per GitHub API full_name; deployments repo root CLAUDE.md:9; GKE deployments directory WAREHOUSE-MIGRATION.md:190-196,925-931; deployments repo alerting README.md:156-159; runbooks/27-nebula-and-ip-crawler.md:1-35; dbt-cerebro models/p2p/p2p_sources.yml:1-211 and the 27 `*.sql` files under models/p2p/; cerebro-docs docs/data-pipeline/crawlers/nebula.md:1-122; cerebro-mcp src/cerebro_mcp/config.py:469-481; nebula .git/refs/heads/main and the last entry of .git/logs/HEAD; cerebro-docs docs/operations/runbooks/dbt-reprocess.md:1-8 and one-shot-jobs.md:1-15; upstream dennis-tra/nebula at 77aa1796 (older than the pin): cmd/nebula/cmd.go:40-70,175-195, cmd/nebula/cmd_health.go:1-31, db/ch.go:340-447, db/migrations/ch/000001_create_crawls_table.up.sql:1-27, 000003_create_visits_table.up.sql:65-66, 000004_create_neighbors_table.up.sql:7-8
