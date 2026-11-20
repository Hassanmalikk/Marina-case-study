{#
  Grain: one row per subscription, state AS OF kpi_as_of_date (point-in-time correct).
  Current state = latest event on or before the as-of date (event-sourced; history is never overwritten upstream,
  so any past date can be recomputed exactly, e.g. `--vars '{kpi_as_of_date: 2026-01-15}'`).
  churn => status 'churned' and MRR 0 regardless of the amount on the churn row.
#}

with events as (

    select *
    from {{ ref('stg_stripe_subscriptions') }}
    where event_at_utc < {{ kpi_as_of_end() }}

),

latest_event as (

    select *
    from events
    qualify row_number() over (
        partition by subscription_id
        -- same-timestamp tie: churn wins (end of lifecycle), then a stable key for determinism
        order by event_at_utc desc, case when event_type = 'churn' then 0 else 1 end, subscription_event_id
    ) = 1

),

lifecycle as (

    select
        subscription_id,
        min(event_at_utc) as started_at_utc,
        cast(count(*) as bigint) as event_count
    from events
    group by subscription_id

),

owners as (

    select source_record_id as subscription_id, owner_id
    from {{ ref('int_owner_identity_map') }}
    where source_system = 'stripe'

)

select
    latest_event.subscription_id,
    owners.owner_id,
    latest_event.plan_name,
    latest_event.billing_interval,
    lifecycle.started_at_utc,
    lifecycle.event_count,
    latest_event.event_type                                                     as last_event_type,
    latest_event.event_at_utc                                                   as last_event_at_utc,
    case when latest_event.event_type = 'churn' then 'churned' else 'active' end as subscription_status,
    latest_event.event_type <> 'churn'                                          as is_active,
    cast(
        case when latest_event.event_type = 'churn' then 0 else latest_event.mrr_amount_usd end
        as decimal(12, 2)
    )                                                                           as current_mrr_usd,
    {{ kpi_as_of_date() }}                                                      as as_of_date
from latest_event
inner join lifecycle
    on latest_event.subscription_id = lifecycle.subscription_id
left join owners
    on latest_event.subscription_id = owners.subscription_id
