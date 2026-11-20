# One-command workflows. Run from the repository root.
PY ?= python3.13
DBT = .venv/bin/dbt

.PHONY: setup build test kpis docs freshness clean

setup:            ## Create venv, install pinned deps, install dbt packages
	$(PY) -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements-lock.txt
	$(DBT) deps

build:            ## Load raw (local hook) + seeds + models + all tests, from scratch
	@[ -d dbt_packages/dbt_utils ] || $(DBT) deps
	$(DBT) build --full-refresh

test:             ## Data tests + unit tests only
	$(DBT) test

kpis:             ## Print the executive KPI tiles and the vendor drill-down
	$(DBT) show -s mrt_executive_kpis
	$(DBT) show -s mrt_vendor_performance

docs:             ## Generate and serve the dbt docs site (lineage graph) on http://localhost:8080
	$(DBT) docs generate && $(DBT) docs serve

freshness:        ## Source freshness SLA check (sample data is from Q1 2026, so it reports WARN by design)
	$(DBT) source freshness

clean:
	$(DBT) clean && rm -f marina.duckdb marina.duckdb.wal
