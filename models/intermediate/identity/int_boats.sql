{#
  Grain: one row per physical boat. boat_id = hash of the standardised hull_id (the cross-system natural key).
  Today only the PMS captures hull_id; any other system that starts capturing it (e.g. vendor work orders)
  is added to `boat_sightings` with a UNION ALL, and nothing downstream changes.
  Survivorship: the most recent booking supplies the current name, owner and home marina.
#}

with bookings as (

    select * from {{ ref('stg_marina_pms') }}

),

booking_owners as (

    select source_record_id as booking_id, owner_id
    from {{ ref('int_owner_identity_map') }}
    where source_system = 'marina_pms'

),

boat_sightings as (

    select
        bookings.hull_id,
        bookings.boat_name,
        -- 'Sea Breeze' and 'Seabreeze' share the key 'seabreeze': a spelling variant, not a different boat name
        regexp_replace(lower(bookings.boat_name), '[^a-z0-9]', '', 'g')  as boat_name_key,
        bookings.marina_code,
        bookings.booking_id,
        bookings.booking_sequence,
        booking_owners.owner_id
    from bookings
    inner join booking_owners
        on bookings.booking_id = booking_owners.booking_id
    where bookings.hull_id is not null

),

latest_sighting as (

    select *
    from boat_sightings
    qualify row_number() over (partition by hull_id order by booking_sequence desc, booking_id desc) = 1

),

rollup as (

    select
        hull_id,
        count(*)                        as booking_count,
        count(distinct owner_id)        as distinct_owner_count,
        count(distinct boat_name)       as boat_name_variant_count,
        count(distinct boat_name_key)   as distinct_boat_name_key_count
    from boat_sightings
    group by hull_id

)

select
    {{ dbt_utils.generate_surrogate_key(['latest_sighting.hull_id']) }}  as boat_id,
    latest_sighting.hull_id,
    latest_sighting.boat_name,
    latest_sighting.owner_id                                            as current_owner_id,
    latest_sighting.marina_code                                         as home_marina_code,
    rollup.booking_count,
    rollup.distinct_owner_count,
    rollup.boat_name_variant_count,
    rollup.distinct_boat_name_key_count > 1                             as has_conflicting_boat_names,
    rollup.distinct_owner_count > 1                                     as has_ownership_change
from latest_sighting
inner join rollup
    on latest_sighting.hull_id = rollup.hull_id
