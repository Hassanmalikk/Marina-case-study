# PROJECT_STATE — Marina Analytics dbt Case Study

> Single source of truth for session continuity. A new session should read ONLY this file first,
> then inspect the specific files listed under "Exact next step".

## Stack (decided)
- Python 3.13 venv at `.venv/` · dbt-core + dbt-duckdb (local DuckDB file `marina.duckdb`)
- dbt project lives at repo root (`dbt_project.yml`), `profiles.yml` in repo root (no ~/.dbt needed)
- Package: dbt_utils (surrogate keys, generic tests)

## Milestones
| # | Phase | Status |
|---|-------|--------|
| 0 | Analyze PDF, inspect env, plan | DONE |
| 1 | Environment: venv, pinned requirements, dbt + duckdb verified | DONE |
| 2 | Project init: dbt_project.yml, profiles.yml, packages, folder layout, macros | DONE |
| 3 | Data ingestion: raw CSVs (exact PDF data) declared as dbt sources (on-run-start hook -> raw schema) | DONE |
| 4 | Staging: stg_marina_pms, stg_vendor_orders (+ seed service mapping), stg_stripe_subscriptions | DONE |
| 5 | Entity resolution: int_owner_identity_map, int_owners, int_boats | DONE |
| 6 | Marts: fct_work_orders (incremental), fct_subscriptions, mrt_vendor_performance, mrt_executive_kpis | DONE |
| 7 | Testing: generic + singular + unit tests + contracts; all green | DONE |
| 8 | Docs: README, architecture diagram, decision log, testing, scaling, security | DONE |
| 9 | Interview guide + final E2E verification + KPI outputs | DONE |

## Key decisions (details → docs/decision_log.md)
- DuckDB local warehouse (zero-infra, columnar, Snowflake/BigQuery-like SQL).
- Raw data = dbt **sources** in schema `raw` (not seeds). Locally loaded as all-VARCHAR tables by on-run-start hook
  `macros/load_local_raw_sources.sql` (simulates EL). Rejected dbt-duckdb `external_location`: unit tests can't introspect it.
- Seeds only for analyst-owned reference data (service-category regex rules).
- Owner identity = connected components over shared match keys (email, phone E.164, hull+surname+initial);
  owner_id = hash(anchor = min record_key). Placeholder-key guard var identity_max_records_per_key=50.
- KPI definitions: billable hours = hours on COMPLETED jobs; utilization = billable_hours / ALL logged jobs;
  turnaround over completed only (seconds base unit); MRR = latest event per sub as of kpi_as_of_date, churn -> 0.
- fct_work_orders incremental delete+insert, 30-day lookback on created_at (no updated_at in source).
- Marts contract-enforced; exposure executive_kpi_dashboard.

## Verified results (dbt build --full-refresh: PASS=107, WARN=0, ERROR=0; 5 unit tests)
MRR 3,700.00 · ARR 44,400.00 · 2 active subs · logged jobs 3 · completed 2 · billable hrs 9.50 ·
utilization 3.17 h/job · avg turnaround 4.75 h · owners 2 (from 5 source records) · boats 2.
Negative tests verified: unknown Stripe event -> ERROR + marts skipped; bad fee -> ERROR; unmapped service -> WARN;
dropped source column -> expected_columns FAIL.

## Known issues / open questions (documented as assumptions)
- Annual plan mrr_amount=1200 trusted as monthly (alt reading: MRR 2,600 / ARR 31,200).
- Vendor timestamp timezone unconfirmed (var, default UTC). Work orders lack updated_at / hull / marina keys.
- hull_ids look like state registration numbers, not 12-char USCG HINs.
- DuckDB 2.0 Python API: relations have no fetchone(); use `dbt show` for inspection.

## Versions verified
dbt-core 1.12.7 · dbt-duckdb 1.11.1 · duckdb 2.0.0 · dbt_utils 1.4.1 (package-lock.yml)

## Final status: COMPLETE (2026-11-19)
- Clean-room verified: fresh venv from requirements-lock.txt installs exact versions; `make clean && make build`
  gives PASS=107 WARN=0 ERROR=0; KPIs match README; interview live-demo script rehearsed and restored.
- All deliverables in README "Requirements traceability". Docs: docs/{architecture.md,.svg, decision_log, testing_strategy,
  scaling_performance, security_governance, interview_guide}.md

## Exact next step (optional enhancements, not required by the brief)
- agg_vendor_daily incremental aggregate; dbt snapshot on work orders; persisted identity map + merge history;
  mrt_executive_kpis as daily periodic snapshot; `git init` + first commit if the user wants version control.
