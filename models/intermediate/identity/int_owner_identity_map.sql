{#
  Grain: one row per SOURCE CUSTOMER RECORD (a PMS booking or a Stripe subscription) -> its resolved owner_id.
  This is the identity crosswalk: every downstream model that needs an owner joins through it.

  Algorithm: deterministic graph-based entity resolution
    1. Nodes  = source customer records.
    2. Keys   = normalised identifiers each record carries ("match keys"):
                  email          exact canonical email
                  phone          exact E.164 phone
                  boat_and_name  same hull AND same last name AND same first initial
                                 (links 'John Doe' [phone only] to 'J. Doe' [email only]: they share no
                                  contact point, only the boat. The surname guard stops a boat RESALE from
                                  merging buyer and seller.)
    3. Edges  = records sharing a match key (star-linked to the key's smallest record: O(n) edges, not O(n^2)).
    4. Owner  = connected component (transitive: A~B by email, B~C by boat => A,B,C are one owner).
    5. owner_id = hash of the component's anchor (smallest record_key) -> deterministic across runs.
#}

with recursive

pms_records as (

    select
        'marina_pms'            as source_system,
        booking_id              as source_record_id,
        customer_full_name      as full_name,
        contact_email           as email,
        contact_phone_e164      as phone_e164,
        hull_id
    from {{ ref('stg_marina_pms') }}

),

stripe_records as (

    -- One identity record per subscription, using its most recent billing email.
    select
        'stripe'                as source_system,
        subscription_id         as source_record_id,
        cast(null as varchar)   as full_name,
        customer_email          as email,
        cast(null as varchar)   as phone_e164,
        cast(null as varchar)   as hull_id
    from {{ ref('stg_stripe_subscriptions') }}
    qualify row_number() over (partition by subscription_id order by event_at_utc desc, subscription_event_id) = 1

),

records as (

    select
        source_system || ':' || source_record_id as record_key,
        unioned.*,
        -- Name normalised for matching only: 'J. Doe' -> 'j doe', 'Mary-Ann O''Neil Jr.' -> 'mary-ann oneil'
        nullif(trim(regexp_replace(regexp_replace(regexp_replace(
            lower(full_name), '[''.]', '', 'g'),          -- drop apostrophes / periods (O'Neil -> oneil)
            '[^a-z\- ]+', ' ', 'g'),                       -- anything else becomes a separator
            '\s+(jr|sr|ii|iii|iv)\s*$', '')), '')          -- generational suffixes are not part of the surname
            as name_key
    from (
        select * from pms_records
        union all
        select * from stripe_records
    ) as unioned

),

match_keys as (

    select record_key, 'email' as match_type, email as match_value
    from records
    where email is not null

    union all

    select record_key, 'phone' as match_type, phone_e164 as match_value
    from records
    where phone_e164 is not null

    union all

    select
        record_key,
        'boat_and_name' as match_type,
        hull_id || '|' || regexp_extract(name_key, '(\S+)$', 1) || '|' || left(name_key, 1) as match_value
    from records
    where hull_id is not null
      and name_key like '% %'   -- need at least a first token and a surname

),

usable_match_keys as (

    -- Guard against placeholder identifiers ('noemail@marina.com', '+10000000000') that would chain thousands of
    -- unrelated people into one giant component. Keys shared by more records than the threshold are ignored.
    select *
    from match_keys
    qualify count(*) over (partition by match_type, match_value) <= {{ var('identity_max_records_per_key') }}

),

edges as (

    -- Star topology: link each record to the smallest record sharing the same key.
    select
        record_key                                                          as from_record,
        min(record_key) over (partition by match_type, match_value)         as to_record
    from usable_match_keys

),

undirected_edges as (

    select from_record, to_record from edges where from_record <> to_record
    union
    select to_record, from_record from edges where from_record <> to_record

),

reachable (record_key, reachable_record) as (

    -- Transitive closure. UNION (not UNION ALL) de-duplicates, so recursion terminates even on cycles.
    select record_key, record_key from records
    union
    select reachable.record_key, undirected_edges.to_record
    from reachable
    inner join undirected_edges
        on reachable.reachable_record = undirected_edges.from_record

),

components as (

    select
        record_key,
        min(reachable_record) as anchor_record_key
    from reachable
    group by record_key

),

match_evidence as (

    -- Audit trail: which identifier types actually linked this record to at least one other record.
    select
        record_key,
        string_agg(distinct match_type, ',' order by match_type) as matched_on
    from (
        select
            record_key,
            match_type,
            count(*) over (partition by match_type, match_value) as records_sharing_key
        from usable_match_keys
    ) as keyed
    where records_sharing_key > 1
    group by record_key

)

select
    {{ dbt_utils.generate_surrogate_key(['components.anchor_record_key']) }}  as owner_id,
    records.record_key,
    records.source_system,
    records.source_record_id,
    records.full_name,
    records.email,
    records.phone_e164,
    records.hull_id,
    components.anchor_record_key,
    coalesce(match_evidence.matched_on, 'unmatched')                         as matched_on
from records
inner join components
    on records.record_key = components.record_key
left join match_evidence
    on records.record_key = match_evidence.record_key
