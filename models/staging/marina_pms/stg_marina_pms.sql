{#
  Grain: one row per PMS booking (booking_id).
  Purpose: type-cast and canonicalise the raw PMS extract. No joins, no business logic.
  Columns are selected explicitly (never select *) so upstream schema drift cannot leak downstream.
#}

with source as (

    select * from {{ source('marina_pms', 'raw_marina_pms') }}

),

cleaned as (

    select
        {{ clean_string('booking_id') }}                as booking_id,
        {{ clean_string('customer_full_name') }}        as customer_full_name,
        {{ clean_string('raw_contact') }}               as raw_contact,
        {{ clean_string('boat_name') }}                 as boat_name,
        {{ normalize_identifier('hull_id') }}           as hull_id,
        {{ parse_currency('slip_fee') }}                as slip_fee_usd,
        upper({{ clean_string('marina_code') }})        as marina_code
    from source

),

parsed as (

    select
        booking_id,
        -- PMS booking ids are sequential and the extract has no booking date,
        -- so the numeric suffix is the recency proxy used for "latest record wins" survivorship.
        try_cast(regexp_extract(booking_id, '([0-9]+)$', 1) as bigint) as booking_sequence,
        customer_full_name,
        -- raw_contact is a single free-text field holding EITHER an email OR a phone number.
        {{ normalize_email('raw_contact') }}            as contact_email,
        {{ normalize_phone('raw_contact') }}            as contact_phone_e164,
        boat_name,
        hull_id,
        slip_fee_usd,
        marina_code
    from cleaned

)

select
    booking_id,
    booking_sequence,
    customer_full_name,
    contact_email,
    contact_phone_e164,
    case
        when contact_email is not null then 'email'
        when contact_phone_e164 is not null then 'phone'
        else 'unparseable'
    end                                                 as contact_type,
    boat_name,
    hull_id,
    slip_fee_usd,
    marina_code
from parsed
