{#
  LOCAL-ONLY stand-in for the EL tool (Fivetran / Airbyte / Stripe Sigma export).

  Runs as an on-run-start hook. For every source whose YAML declares `meta.local_csv_dir`, it (re)creates the
  physical table <source schema>.<table> from <local_csv_dir>/<table>.csv with EVERY column typed VARCHAR,
  reproducing an untyped landing zone, so all casting/cleaning is provably done by the staging layer.

  Why physical tables instead of dbt-duckdb `external_location` (zero-copy) sources:
    - dbt unit tests must introspect the input relation to type their fixtures; external sources are not relations.
    - catalog/docs show source columns; staging views do not depend on the process working directory.
  In production this hook is inert (target.type != 'duckdb') and the sources point at the EL-loaded raw schema.
#}
{% macro load_local_raw_sources() %}
    {%- if execute and target.type == 'duckdb' -%}
        {%- for src in graph.sources.values() if src.source_meta.get('local_csv_dir') -%}
            {%- set csv_path = src.source_meta['local_csv_dir'] ~ '/' ~ src.identifier ~ '.csv' -%}
            {%- do run_query('create schema if not exists ' ~ src.schema) -%}
            {%- do run_query(
                'create or replace table ' ~ src.schema ~ '.' ~ src.identifier ~
                " as select * from read_csv('" ~ csv_path ~ "', header = true, all_varchar = true)"
            ) -%}
            {%- do log('Loaded local raw source ' ~ src.schema ~ '.' ~ src.identifier ~ ' <- ' ~ csv_path, info=true) -%}
        {%- endfor -%}
    {%- endif -%}
{% endmacro %}
