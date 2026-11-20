{# Point-in-time for "current" KPIs. var('kpi_as_of_date') (YYYY-MM-DD) makes runs reproducible and back-fillable. #}
{% macro kpi_as_of_date() -%}
    {%- if var('kpi_as_of_date', none) -%}
        cast('{{ var("kpi_as_of_date") }}' as date)
    {%- else -%}
        cast(timezone('UTC', current_timestamp) as date)
    {%- endif -%}
{%- endmacro %}


{# Exclusive upper bound for "on or before the as-of date": events strictly before as_of_date + 1 day. #}
{% macro kpi_as_of_end() -%}
    {{ dbt.dateadd('day', 1, kpi_as_of_date()) }}
{%- endmacro %}


{# Current wall-clock time as a naive UTC TIMESTAMP. #}
{% macro utc_now() -%}
    cast(timezone('UTC', current_timestamp) as timestamp)
{%- endmacro %}
