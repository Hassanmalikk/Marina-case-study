{#
  Grain: one row per resolved owner (owner_id): the "golden record".
  Survivorship rules (deterministic and documented, so the golden record is explainable):
    name  : longest available name (a full first name beats an initial: 'John Doe' over 'J. Doe'), tie -> smallest record_key
    email : billing-verified Stripe email first (it receives invoices), else the most recent PMS booking's email
    phone : most recent PMS booking that has a phone
  PII (name/email/phone) lives here and in staging only; marts carry owner_id (a pseudonymous key) instead.
#}

with identity as (

    select
        identity_map.*,
        bookings.booking_sequence
    from {{ ref('int_owner_identity_map') }} as identity_map
    left join {{ ref('stg_marina_pms') }} as bookings
        on identity_map.source_system = 'marina_pms'
       and identity_map.source_record_id = bookings.booking_id

),

best_name as (

    select owner_id, full_name
    from identity
    where full_name is not null
    qualify row_number() over (partition by owner_id order by length(full_name) desc, record_key) = 1

),

best_email as (

    select owner_id, email
    from identity
    where email is not null
    qualify row_number() over (
        partition by owner_id
        order by case when source_system = 'stripe' then 0 else 1 end, booking_sequence desc nulls last, record_key
    ) = 1

),

best_phone as (

    select owner_id, phone_e164
    from identity
    where phone_e164 is not null
    qualify row_number() over (partition by owner_id order by booking_sequence desc nulls last, record_key) = 1

),

rollup as (

    select
        owner_id,
        min(anchor_record_key)                                              as anchor_record_key,
        count(*)                                                            as source_record_count,
        cast(sum(case when source_system = 'marina_pms' then 1 else 0 end) as bigint) as pms_booking_count,
        cast(sum(case when source_system = 'stripe' then 1 else 0 end) as bigint)     as stripe_subscription_count,
        count(distinct email)                                               as distinct_email_count,
        count(distinct phone_e164)                                          as distinct_phone_count,
        count(distinct hull_id)                                             as distinct_boat_count
    from identity
    group by owner_id

)

select
    rollup.owner_id,
    best_name.full_name                         as owner_full_name,
    best_email.email                            as primary_email,
    best_phone.phone_e164                       as primary_phone_e164,
    rollup.source_record_count,
    rollup.pms_booking_count,
    rollup.stripe_subscription_count,
    rollup.distinct_email_count,
    rollup.distinct_phone_count,
    rollup.distinct_boat_count,
    rollup.stripe_subscription_count > 0        as is_billing_customer,
    rollup.pms_booking_count > 0                as has_pms_booking,
    rollup.anchor_record_key
from rollup
left join best_name  on rollup.owner_id = best_name.owner_id
left join best_email on rollup.owner_id = best_email.owner_id
left join best_phone on rollup.owner_id = best_phone.owner_id
