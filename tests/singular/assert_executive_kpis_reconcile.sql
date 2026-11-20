-- Cross-model reconciliation: the executive tiles must equal the sums of the facts / drill-down they summarise.
-- Catches fan-out joins, double counting, filter drift, and AS-OF DRIFT (a partial rebuild with a different
-- kpi_as_of_date var would otherwise mix points in time). Any returned row = a mismatch.
with kpis as (

    select * from {{ ref('mrt_executive_kpis') }}

),

subscriptions as (

    select
        coalesce(sum(case when is_active then current_mrr_usd end), 0)  as active_mrr_usd,
        coalesce(sum(case when is_active then 1 else 0 end), 0)        as active_subscriptions,
        max(as_of_date)                                                 as as_of_date
    from {{ ref('fct_subscriptions') }}

),

vendors as (

    select
        coalesce(sum(logged_jobs), 0)              as logged_jobs,
        coalesce(sum(completed_jobs), 0)           as completed_jobs,
        coalesce(sum(billable_hours), 0)           as billable_hours,
        sum(total_turnaround_hours)                as total_turnaround_hours,
        max(as_of_date)                            as as_of_date
    from {{ ref('mrt_vendor_performance') }}

)

select
    kpis.as_of_date,            subscriptions.as_of_date            as subscriptions_as_of_date,
    kpis.active_mrr_usd,        subscriptions.active_mrr_usd        as expected_active_mrr_usd,
    kpis.active_subscriptions,  subscriptions.active_subscriptions  as expected_active_subscriptions,
    kpis.logged_jobs,           vendors.logged_jobs                 as expected_logged_jobs,
    kpis.completed_jobs,        vendors.completed_jobs              as expected_completed_jobs,
    kpis.billable_hours,        vendors.billable_hours              as expected_billable_hours
from kpis
cross join subscriptions
cross join vendors
where (subscriptions.as_of_date is not null and subscriptions.as_of_date <> kpis.as_of_date)
   or (vendors.as_of_date is not null and vendors.as_of_date <> kpis.as_of_date)
   or kpis.active_mrr_usd       is distinct from subscriptions.active_mrr_usd
   or kpis.active_subscriptions is distinct from subscriptions.active_subscriptions
   or kpis.logged_jobs          is distinct from vendors.logged_jobs
   or kpis.completed_jobs       is distinct from vendors.completed_jobs
   or kpis.billable_hours       is distinct from vendors.billable_hours
   -- ratio-of-sums check (tolerance covers 2-dp rounding of the per-vendor totals)
   or abs(coalesce(kpis.avg_turnaround_hours, 0)
          - coalesce(vendors.total_turnaround_hours / nullif(vendors.completed_jobs, 0), 0)) > 0.01
