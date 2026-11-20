{#
  Cross-database shims. Models call these instead of dialect-specific functions.
  Only the DuckDB/default implementations ship (they are what the test suite exercises); the comments give the
  one-line equivalents to add as snowflake__ / bigquery__ implementations when porting.
#}


{#
  dbt-duckdb ships NO duckdb__safe_cast, so dbt.safe_cast() silently falls back to default__safe_cast = a plain CAST,
  which aborts the whole query on one bad value. This override restores fail-soft semantics on DuckDB.
  (dbt-snowflake -> TRY_CAST and dbt-bigquery -> SAFE_CAST already implement it correctly.)
#}
{% macro duckdb__safe_cast(field, type) -%}
    try_cast({{ field }} as {{ type }})
{%- endmacro %}


{#
  True if string_expr contains a match of pattern_expr (both are SQL expressions, e.g. a column holding a regex).
  Snowflake: regexp_instr(s, p) > 0    BigQuery: regexp_contains(s, p)
#}
{% macro regex_contains(string_expr, pattern_expr) -%}
    {{ return(adapter.dispatch('regex_contains', 'marina_analytics')(string_expr, pattern_expr)) }}
{%- endmacro %}

{% macro default__regex_contains(string_expr, pattern_expr) -%}
    regexp_matches({{ string_expr }}, {{ pattern_expr }})
{%- endmacro %}
