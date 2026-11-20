{#
  Grain: one row per subscription EVENT (new / upgrade / downgrade / renewal / reactivation / churn).
  Stripe data is event-sourced: current state is derived downstream (fct_subscriptions), never overwritten here.
#}

with source as (

    select * from {{ source('stripe', 'raw_stripe_subscriptions') }}

),

cleaned as (

    select
        {{ clean_string('sub_id') }}                                      as subscription_id,
        {{ normalize_email('customer_email') }}                           as customer_email,
        {{ clean_string('plan_name') }}                                   as plan_name,
        {{ parse_currency('mrr_amount') }}                                as mrr_amount_usd,
        {{ normalize_text_key('event_type') }}                            as event_type_key,
        {{ to_utc('event_timestamp', var('stripe_source_timezone')) }}    as event_at_utc
    from source

)

select
    {{ dbt_utils.generate_surrogate_key(['subscription_id', 'event_type_key', 'event_at_utc']) }} as subscription_event_id,
    subscription_id,
    customer_email,
    plan_name,
    -- Billing cadence inferred from the plan name (no interval field in the extract). Informational only:
    -- MRR is taken from mrr_amount as provided (see decision log: "Annual plan MRR ambiguity").
    case
        when lower(plan_name) like '%annual%' or lower(plan_name) like '%year%' then 'annual'
        when lower(plan_name) like '%month%' then 'monthly'
        else 'unknown'
    end                                                                   as billing_interval,
    mrr_amount_usd,
    -- Canonical lifecycle vocabulary; cancellation synonyms collapse to 'churn'.
    case
        when event_type_key in ('cancel', 'canceled', 'cancelled', 'cancellation', 'deleted') then 'churn'
        else replace(event_type_key, ' ', '_')
    end                                                                   as event_type,
    event_at_utc
from cleaned
