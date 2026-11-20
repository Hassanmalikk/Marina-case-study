{#
  Grain: one row per vendor / captain (vendor_id), for work orders created on or before the as-of date.
  Numerators and denominators are published next to every ratio so the dashboard can re-aggregate correctly
  (sum(hours)/sum(jobs), never an average of per-vendor ratios).
#}

with work_orders as (

    select *
    from {{ ref('fct_work_orders') }}
    where created_at_utc < {{ kpi_as_of_end() }}

),

vendor_labels as (

    -- Display name = most recently used spelling for the resolved vendor
    select vendor_id, vendor_name, vendor_type
    from work_orders
    qualify row_number() over (partition by vendor_id order by created_at_utc desc, work_order_id desc) = 1

),

vendor_totals as (

    select
        vendor_id,
        count(*)                                                            as logged_jobs,
        sum(case when is_completed then 1 else 0 end)                       as completed_jobs,
        sum(case when status in ('open', 'in_progress') then 1 else 0 end)  as open_jobs,
        sum(case when is_emergency then 1 else 0 end)                       as emergency_jobs,
        sum(logged_hours)                                                   as logged_hours,
        sum(billable_hours)                                                 as billable_hours,
        sum(turnaround_seconds)                                             as total_turnaround_seconds,
        min(created_at_utc)                                                 as first_job_created_at_utc,
        max(created_at_utc)                                                 as last_job_created_at_utc
    from work_orders
    group by vendor_id

)

select
    {{ kpi_as_of_date() }}                                                              as as_of_date,
    vendor_totals.vendor_id,
    vendor_labels.vendor_name,
    vendor_labels.vendor_type,
    cast(vendor_totals.logged_jobs as bigint)                                           as logged_jobs,
    cast(vendor_totals.completed_jobs as bigint)                                        as completed_jobs,
    cast(vendor_totals.open_jobs as bigint)                                             as open_jobs,
    cast(vendor_totals.emergency_jobs as bigint)                                        as emergency_jobs,
    cast(vendor_totals.logged_hours as decimal(14, 2))                                  as logged_hours,
    cast(vendor_totals.billable_hours as decimal(14, 2))                                as billable_hours,
    -- KPI 2  Utilisation = billable service hours delivered / total logged jobs
    cast(vendor_totals.billable_hours / nullif(vendor_totals.logged_jobs, 0) as decimal(10, 2))
                                                                                        as billable_hours_per_logged_job,
    cast(vendor_totals.total_turnaround_seconds / 3600.0 as decimal(14, 2))             as total_turnaround_hours,
    -- KPI 3  Response time = avg(completed_at - created_at) over COMPLETED work orders only
    cast(vendor_totals.total_turnaround_seconds / 3600.0 / nullif(vendor_totals.completed_jobs, 0) as decimal(10, 2))
                                                                                        as avg_turnaround_hours,
    vendor_totals.first_job_created_at_utc,
    vendor_totals.last_job_created_at_utc
from vendor_totals
inner join vendor_labels
    on vendor_totals.vendor_id = vendor_labels.vendor_id
