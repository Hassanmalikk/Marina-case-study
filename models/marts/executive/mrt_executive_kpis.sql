{#
  Grain: exactly ONE row per as-of date: the executive KPI tiles.
  Every KPI is computed from the conformed facts (single source of truth). Counts/sums are coalesced to 0 so an
  empty period reads 0, not NULL (bug caught by the reconciliation test on a back-dated run). Ratios are ratio-of-sums,
  and their numerators/denominators are published alongside. Reconciled by tests/singular/assert_executive_kpis_reconcile.sql.

  KPI 1  Active MRR = sum(current MRR of active subscriptions as of date);  ARR = MRR x 12
  KPI 2  Utilisation = billable hours (completed work) / total logged jobs
  KPI 3  Avg turnaround = avg(completed_at - created_at) in hours, completed work orders only
#}

with subscriptions as (

    select * from {{ ref('fct_subscriptions') }}

),

work_orders as (

    select *
    from {{ ref('fct_work_orders') }}
    where created_at_utc < {{ kpi_as_of_end() }}

),

revenue as (

    select
        coalesce(sum(case when is_active then 1 else 0 end), 0)         as active_subscriptions,
        count(distinct case when is_active then owner_id end)          as active_subscribers,
        coalesce(sum(case when is_active then current_mrr_usd end), 0)  as active_mrr_usd
    from subscriptions

),

operations as (

    select
        count(*)                                                        as logged_jobs,
        coalesce(sum(case when is_completed then 1 else 0 end), 0)      as completed_jobs,
        coalesce(sum(case when status in ('open', 'in_progress') then 1 else 0 end), 0) as open_jobs,
        count(distinct vendor_id)                                       as active_vendors,
        coalesce(sum(billable_hours), 0)                                as billable_hours,
        sum(turnaround_seconds)                                         as total_turnaround_seconds
    from work_orders

),

entities as (

    select
        (select count(*) from {{ ref('int_owners') }})                  as total_owners,
        (select count(*) from {{ ref('int_boats') }})                   as total_boats

)

select
    {{ kpi_as_of_date() }}                                                                   as as_of_date,
    -- Revenue
    cast(revenue.active_subscriptions as bigint)                                             as active_subscriptions,
    cast(revenue.active_subscribers as bigint)                                               as active_subscribers,
    cast(revenue.active_mrr_usd as decimal(14, 2))                                           as active_mrr_usd,
    cast(revenue.active_mrr_usd * 12 as decimal(14, 2))                                      as arr_usd,
    -- Vendor operations
    cast(operations.logged_jobs as bigint)                                                   as logged_jobs,
    cast(operations.completed_jobs as bigint)                                                as completed_jobs,
    cast(operations.open_jobs as bigint)                                                     as open_jobs,
    cast(operations.active_vendors as bigint)                                                as active_vendors,
    cast(operations.billable_hours as decimal(14, 2))                                        as billable_hours,
    cast(operations.billable_hours / nullif(operations.logged_jobs, 0) as decimal(10, 2))    as billable_hours_per_logged_job,
    cast(operations.total_turnaround_seconds / 3600.0 / nullif(operations.completed_jobs, 0) as decimal(10, 2))
                                                                                             as avg_turnaround_hours,
    -- Entities under management (post entity-resolution)
    cast(entities.total_owners as bigint)                                                    as total_owners,
    cast(entities.total_boats as bigint)                                                     as total_boats,
    {{ utc_now() }}                                                                          as kpis_generated_at_utc
from revenue
cross join operations
cross join entities
