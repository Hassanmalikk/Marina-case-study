{#
  Schema-drift guard for sources: compares the columns that actually arrive with the agreed column contract.
  - missing columns    -> always a failure (staging would break or silently lose a field)
  - unexpected columns -> failure only if allow_extra_columns=false. New upstream columns are harmless
    because staging selects columns explicitly, but strict mode surfaces them so they can be adopted.
  Uses get_columns_in_query (works for tables, views and dbt-duckdb external CSV/parquet sources alike).
#}
{% test expected_columns(model, column_names, allow_extra_columns=true) %}
{%- set actual = (get_columns_in_query('select * from ' ~ model) | map('lower') | list) if execute else [] -%}
{%- set expected = column_names | map('lower') | list -%}
{%- set missing = expected | reject('in', actual) | list -%}
{%- set extra = actual | reject('in', expected) | list -%}
select cast(null as varchar) as column_name, cast(null as varchar) as drift_type where false
{%- for c in missing %}
union all select '{{ c }}', 'missing'
{%- endfor %}
{%- if not allow_extra_columns %}
{%- for c in extra %}
union all select '{{ c }}', 'unexpected'
{%- endfor %}
{%- endif %}
{% endtest %}
