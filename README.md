# Marina Analytics: dbt Case Study (Data Engineer)

A modern warehouse layer (**dbt + SQL on DuckDB**) that unifies three raw systems (the Legacy Marina PMS, vendor work-order
logs and Stripe billing). It resolves owner and boat identities, standardises unstructured vendor data and powers an
executive KPI mart (**MRR, ARR, vendor utilisation, vendor response time**). The whole project is reproducible from a clean
laptop with two commands.

![Architecture](docs/architecture.svg)

## Results (actual output of `make kpis` on the case data)

| KPI | Value | How it is derived |
|---|---|---|
| **Active MRR** | **$3,700.00** | SUB-001 $1,200 + SUB-002 $2,500 (latest event per subscription, none churned) |
| **ARR** | **$44,400.00** | MRR × 12 |
| Active subscriptions / subscribers | 2 / 2 | After identity resolution, each subscription belongs to a distinct owner |
| **Vendor utilisation** | **3.17 billable h per logged job** | 9.50 billable h (completed jobs) / 3 logged jobs |
| **Avg vendor turnaround** | **4.75 h** | (6.5 h + 3.0 h) / 2 completed work orders |
| Owners / boats under management | 2 / 2 | **5 source records → 2 owners**, 3 bookings → 2 boats |

| Vendor | Type | Logged jobs | Completed | Billable h | Utilisation (h/job) | Avg turnaround (h) |
|---|---|---|---|---|---|---|
| Marine Tech LLC | vendor | 1 | 1 | 6.50 | 6.50 | 6.50 |
| Capt. Bob | captain | 1 | 1 | 3.00 | 3.00 | 3.00 |
| FastDock Inc | vendor | 1 | 0 | 0.00 | 0.00 | n/a (in progress) |

Build status: `dbt build --full-refresh` gives **PASS=107, WARN=0, ERROR=0** (90 data tests, 5 unit tests, 2 enforced contracts).

## Quickstart

**Prerequisites:** macOS/Linux, internet access for the first install only, and **either** Python 3.13
(`python3.13 --version`) **or** [uv](https://docs.astral.sh/uv/) (`uv --version`), which downloads Python 3.13 for you.
Run every command from the repository root.

```bash
# 1. Environment (creates .venv, installs pinned dbt-core 1.12.7 / dbt-duckdb 1.11.1 / duckdb 2.0.0, dbt_utils)

# Option A: no Python 3.13 installed? Use uv (fetches Python 3.13 automatically)
uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python -r requirements-lock.txt
.venv/bin/dbt deps

# Option B: Python 3.13 already installed
python3.13 -m venv .venv
.venv/bin/pip install -r requirements-lock.txt
.venv/bin/dbt deps

# 2. Build everything from scratch: load raw CSVs, seed, models, then all tests and unit tests
.venv/bin/dbt build --full-refresh

# 3. Look at the KPIs
.venv/bin/dbt show -s mrt_executive_kpis
.venv/bin/dbt show -s mrt_vendor_performance
```

Or with Make: `make setup && make build && make kpis` (needs Python 3.13 on the PATH; otherwise use Option A above, then `make build && make kpis`). Optionally `source .venv/bin/activate` to type `dbt` instead of `.venv/bin/dbt`.

> **Moved or renamed the project folder?** A Python venv stores absolute paths, so it breaks when the folder moves
> (`.venv/bin/dbt: ... No such file or directory`). Delete `.venv` and `target/` and redo step 1:
> `rm -rf .venv target`. A stale `target/partial_parse.msgpack` also keeps the old seed path, so remove `target/` as well.

| Task | Command |
|---|---|
| Run only tests (data + unit) | `dbt test` |
| Run only unit tests | `dbt test --select test_type:unit` |
| Rebuild one model and everything downstream | `dbt build -s stg_vendor_orders+` |
| Everything feeding the dashboard | `dbt build -s +exposure:executive_kpi_dashboard` |
| KPIs as of a past date (point-in-time) | `dbt build -s fct_subscriptions+ mrt_vendor_performance --vars '{kpi_as_of_date: 2026-01-15}'` (MRR 1,200) |
| Change the vendor source timezone | `--vars '{vendor_source_timezone: America/New_York}'` |
| Source freshness SLA | `dbt source freshness` (reports WARN by design: the sample data is from Q1 2026) |
| Lineage graph and docs site | `dbt docs generate && dbt docs serve`, then open http://localhost:8080 |
| Query the warehouse directly | `duckdb marina.duckdb` (if the DuckDB CLI is installed), schemas `main_staging`, `main_intermediate`, `main_marts` |
| Reset | `make clean` |

> Local only: the `on-run-start` hook [`load_local_raw_sources`](macros/load_local_raw_sources.sql) loads `data/raw/*.csv`
> into `raw.*` tables (all VARCHAR) before every run, standing in for Fivetran/Airbyte. It is a no-op on non-DuckDB targets.

## Requirements traceability (PDF → implementation)

| Requirement | Where |
|---|---|
| **Part 1**: currency strings → `DECIMAL(10,2)` | [`parse_currency`](macros/cleaning.sql) used in [`stg_marina_pms`](models/staging/marina_pms/stg_marina_pms.sql), [`stg_stripe_subscriptions`](models/staging/stripe/stg_stripe_subscriptions.sql) |
| **Part 1**: all timestamps in UTC | [`to_utc`](macros/cleaning.sql) (DST-aware, honours offsets; source tz via vars) → `*_utc` columns |
| **Part 1**: vendor service standardisation | seed [`service_category_rules.csv`](seeds/service_category_rules.csv) (regex + priority) applied in [`stg_vendor_orders`](models/staging/vendor_ops/stg_vendor_orders.sql) → Engine Maintenance / Hull Service / Dockage / Electrical |
| **Part 2**: `Owner_ID` (John Doe ≡ J. Doe) | [`int_owner_identity_map`](models/intermediate/identity/int_owner_identity_map.sql) (graph entity resolution) → [`int_owners`](models/intermediate/identity/int_owners.sql) (golden record) |
| **Part 2**: `Boat_ID` via standardised hull_id | [`int_boats`](models/intermediate/identity/int_boats.sql) |
| **Part 3**: MRR and ARR = MRR × 12 | [`fct_subscriptions`](models/marts/core/fct_subscriptions.sql) → [`mrt_executive_kpis`](models/marts/executive/mrt_executive_kpis.sql) |
| **Part 3**: captain/vendor utilisation | [`fct_work_orders`](models/marts/core/fct_work_orders.sql) → [`mrt_vendor_performance`](models/marts/executive/mrt_vendor_performance.sql) + `mrt_executive_kpis` |
| **Part 3**: vendor response time | `turnaround_seconds` in `fct_work_orders` → `avg_turnaround_hours` |
| **Deliverable 1**: dbt project with the 6 named models | all present with the exact names (plus 4 supporting models) |
| **Deliverable 2**: architecture diagram | [`docs/architecture.svg`](docs/architecture.svg) + Mermaid in [`docs/architecture.md`](docs/architecture.md) |
| **Presentation 1**: identity resolution | [decision_log ADR-07..10](docs/decision_log.md#adr-07--owner-identity-resolution-deterministic-graph-matching) |
| **Presentation 2**: data quality and testing | [`docs/testing_strategy.md`](docs/testing_strategy.md) |
| **Presentation 3**: scaling to 100M rows | [`docs/scaling_performance.md`](docs/scaling_performance.md) |
| **Presentation 4**: PII security and governance | [`docs/security_governance.md`](docs/security_governance.md) |

## Project structure

```
├── data/raw/                     # the 3 raw sources exactly as given in the PDF (dirty on purpose)
├── seeds/                        # service_category_rules.csv (analyst-owned regex rules) + tests
├── macros/
│   ├── cleaning.sql              # clean_string, parse_currency, normalize_email/phone/identifier/text_key, to_utc
│   ├── kpi_dates.sql             # kpi_as_of_date, kpi_as_of_end, utc_now
│   └── load_local_raw_sources.sql# local-only EL stand-in (on-run-start hook)
├── models/
│   ├── staging/{marina_pms,vendor_ops,stripe}/   # sources + stg_* views + YAML tests + unit tests
│   ├── intermediate/identity/                    # int_owner_identity_map, int_owners, int_boats
│   └── marts/{core,executive}/                   # fct_* and contract-enforced mrt_* + exposure
├── tests/
│   ├── generic/test_expected_columns.sql         # schema-drift test for sources
│   └── singular/                                 # identity integrity, KPI reconciliation, no-PII-in-marts
├── docs/                         # architecture, decision log, testing, scaling, security, interview guide
├── dbt_project.yml · profiles.yml (repo-local) · packages.yml · package-lock.yml
├── requirements.txt · requirements-lock.txt · Makefile
└── PROJECT_STATE.md              # build log / session checkpoint
```

## Key design decisions (full reasoning in [docs/decision_log.md](docs/decision_log.md))

1. **DuckDB + dbt-duckdb**: zero infrastructure, columnar, Snowflake/BigQuery-like SQL. Dialect-specific SQL is isolated in macros.
2. **Raw data = dbt sources in a `raw` schema (all VARCHAR)**, not seeds. This keeps the production contract, and the casting is provably done by staging.
3. **Staging → intermediate → marts**, with every grain stated in a header comment and tested (`unique` + `not_null`).
4. **Fail-soft parsing, loud tests**: parsers return NULL on garbage and error-severity tests block downstream KPIs.
5. **Naive UTC timestamps** with DST-aware conversion from configurable source timezones.
6. **Regex-rules seed** for free-text services, evaluated per *distinct* string. Unknown phrasing becomes `Unclassified` plus a warning.
7. **Graph entity resolution**: the Doe records share *no* contact point, only the boat. So match keys are email, E.164 phone and hull+surname+initial, owners are **connected components**, and there are guards against resale and placeholder merges.
8. **Deterministic hash surrogate keys** (`owner_id` = hash of the component anchor), with their stability limits documented.
9. **Event-sourced, point-in-time MRR** (as-of var). Unknown Stripe events are an error.
10. **Ratio-of-sums KPIs** with numerators and denominators published; turnaround stored in seconds.
11. **Incremental `fct_work_orders`** (upsert + 30-day look-back, because rows are mutable and there is no `updated_at`), with BigQuery/Snowflake partition and cluster configs.
12. **PII confined to restricted layers**: marts carry only `owner_id`, enforced by a test.

## Assumptions & known limitations

| # | Assumption / limitation | Impact | Mitigation |
|---|---|---|---|
| 1 | `mrr_amount` is trusted as monthly, including on the **Annual** plan (1,200) | If 1,200 is really the annual price: MRR 2,600 / ARR 31,200 | `billing_interval` is exposed; this is a **question for Finance** (ADR-11) |
| 2 | Vendor timestamps have no timezone. Assumed **UTC** | Turnaround is unaffected unless a job spans DST; absolute times would shift | `vendor_source_timezone` var; ask vendors for ISO-8601 with offset |
| 3 | Billable hours = hours on **completed** jobs; utilisation denominator = **all** logged jobs | Other definitions give 4.50 or 4.75 h/job | All components are published, so the definition can be agreed with Ops (ADR-12) |
| 4 | Work orders have no `updated_at`, hull or marina key | Incremental model relies on a 30-day look-back; service work can't be attributed to boats or owners | Use the EL sync column; capture hull_id at work-order intake |
| 5 | `hull_id` values look like **state registration numbers**, not 12-char HINs | Registration can change on interstate moves, which matters for national expansion | Capture the HIN as the primary key, registration as an alternate key (ADR-10) |
| 6 | The PMS has no booking date; the numeric booking-id suffix is the recency proxy | Survivorship "latest" depends on ids being sequential | Add the booking date to the extract |
| 7 | Deterministic matching favours precision; a typo in an email won't merge, and spouses sharing surname + initial + boat would | Small recall loss / household merge | Splink probabilistic matching feeds the same graph step (ADR-07) |
| 8 | `owner_id` can change when a new record bridges two owners | Historical joins must go through the crosswalk | Persisted identity map + merge history in production (ADR-08) |
| 9 | Vendor KPIs reflect the *current* status of work orders (no status history) | A back-dated run uses today's status for old jobs | dbt snapshot (SCD2) on work orders |

## Documentation

| Doc | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Pipeline flow, model inventory, ERD, identity graph, schemas |
| [docs/decision_log.md](docs/decision_log.md) | 16 ADRs: why, alternatives, trade-offs, scale, how to defend |
| [docs/testing_strategy.md](docs/testing_strategy.md) | Test pyramid, unit tests, severity policy, negative-test evidence, schema drift |
| [docs/scaling_performance.md](docs/scaling_performance.md) | 1k → 100M rows on BigQuery/Snowflake |
| [docs/security_governance.md](docs/security_governance.md) | PII inventory, layered access, masking, erasure |
| [docs/interview_guide.md](docs/interview_guide.md) | 20-minute talk track, live demo script, Q&A bank |
