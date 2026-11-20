-- Identity integrity: an email or phone number must never belong to two different owners.
-- A row here means entity resolution under-merged (a duplicate owner exists). The exception is a contact point
-- that is deliberately ignored as a placeholder (shared by more records than identity_max_records_per_key).
with contact_points as (

    select 'email' as contact_type, email as contact_value, owner_id
    from {{ ref('int_owner_identity_map') }}
    where email is not null

    union all

    select 'phone', phone_e164, owner_id
    from {{ ref('int_owner_identity_map') }}
    where phone_e164 is not null

)

select
    contact_type,
    contact_value,
    count(distinct owner_id) as owner_count
from contact_points
group by contact_type, contact_value
having count(distinct owner_id) > 1
   and count(*) <= {{ var('identity_max_records_per_key') }}
