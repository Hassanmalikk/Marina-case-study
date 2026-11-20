{#
  Grain: one row per work order. The large, fast-growing fact (1k -> 100M+ rows), so it is INCREMENTAL.

  Incremental design
  - Work orders are MUTABLE (status/completed_at change after creation) and the source has no updated_at, so each
    run re-processes a trailing window (var work_order_lookback_days) and replaces those rows by work_order_id
    (delete+insert = idempotent upsert; re-running a day never duplicates rows).
  - Production: switch the predicate to the EL tool's sync column (e.g. _fivetran_synced) to catch late updates of
    any age, and use BigQuery partitioning / Snowflake clustering (configured below, inert on DuckDB).
  - on_schema_change='fail': adding a column forces a deliberate --full-refresh instead of silently leaving the
    column NULL for historical rows.
#}
{{
    config(
        materialized = 'incremental',
        unique_key = 'work_order_id',
        incremental_strategy = 'merge' if target.type == 'bigquery' else 'delete+insert',
        on_schema_change = 'fail',
        partition_by = ({'field': 'created_date', 'data_type': 'date', 'granularity': 'day'} if target.type == 'bigquery' else none),
        cluster_by = (['vendor_id', 'service_category'] if target.type in ['bigquery', 'snowflake'] else none)
    )
}}

with work_orders as (

    select * from {{ ref('stg_vendor_orders') }}

    {% if is_incremental() %}
    where created_at_utc >= (
        select {{ dbt.dateadd('day', -1 * var('work_order_lookback_days'), 'max(created_at_utc)') }}
        from {{ this }}
    )
    {% endif %}

)

select
    work_order_id,
    vendor_id,
    vendor_name,
    vendor_type,
    service_type_raw,
    service_category,
    is_emergency,
    status,
    status = 'completed'                                                    as is_completed,
    hours_spent                                                             as logged_hours,
    -- Billable = hours on DELIVERED (completed) work. In-progress hours are not yet invoiceable.
    cast(case when status = 'completed' then hours_spent else 0 end as decimal(10, 2)) as billable_hours,
    created_at_utc,
    cast(created_at_utc as date)                                            as created_date,
    completed_at_utc,
    -- Exact base unit (seconds) is stored; averages are computed from it and rounded only at presentation.
    case
        when status = 'completed'
            then {{ dbt.datediff('created_at_utc', 'completed_at_utc', 'second') }}
    end                                                                     as turnaround_seconds,
    case
        when status = 'completed'
            then cast({{ dbt.datediff('created_at_utc', 'completed_at_utc', 'second') }} / 3600.0 as decimal(10, 2))
    end                                                                     as turnaround_hours
from work_orders
