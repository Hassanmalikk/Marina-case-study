{#
  Grain: one row per vendor work order (work_order_id).
  Cleans types/timestamps and standardises free-text service types into the business taxonomy
  using the analyst-owned regex rules in seed `service_category_rules`.
#}

with source as (

    select * from {{ source('vendor_ops', 'raw_vendor_work_orders') }}

),

service_rules as (

    select * from {{ ref('service_category_rules') }}

),

cleaned as (

    select
        {{ clean_string('work_order_id') }}                                       as work_order_id,
        {{ clean_string('vendor_name') }}                                         as vendor_name,
        {{ clean_string('raw_service_type') }}                                    as service_type_raw,
        -- 'Engine_Overhaul_Emergency' -> 'engine overhaul emergency'
        {{ normalize_text_key('raw_service_type') }}                              as service_type_key,
        try_cast({{ clean_string('hours_spent') }} as decimal(10, 2))             as hours_spent,
        -- 'In Progress' -> 'in_progress'
        {{ normalize_text_key('status') }}                                        as status_key,
        {{ to_utc('created_at', var('vendor_source_timezone')) }}                 as created_at_utc,
        {{ to_utc('completed_at', var('vendor_source_timezone')) }}               as completed_at_utc
    from source

),

vendor_keyed as (

    select
        *,
        -- Vendor entity key: 'Capt. Bob' / 'Captain Bob' -> 'captain bob'; 'Marine Tech, LLC' -> 'marine tech'.
        trim(regexp_replace(
            regexp_replace(
                {{ normalize_text_key("replace(vendor_name, '&', ' and ')") }},
                '^capt(ain)?\b', 'captain'),
            '\s+(llc|inc|ltd|co|corp|corporation|company|incorporated|lp|llp)$', ''))   as vendor_key
    from cleaned

),

service_type_lookup as (

    -- Rules are evaluated once per DISTINCT service string (low cardinality: hundreds), not once per work order
    -- (100M+), then equi-joined back. This keeps the regex non-equi join off the large table.
    select
        keys.service_type_key,
        rules.service_category,
        rules.rule_priority
    from (select distinct service_type_key from vendor_keyed where service_type_key is not null) as keys
    inner join service_rules as rules
        on regexp_matches(keys.service_type_key, rules.match_pattern)
    qualify row_number() over (partition by keys.service_type_key order by rules.rule_priority) = 1

)

select
    vendor_keyed.work_order_id,
    {{ dbt_utils.generate_surrogate_key(['vendor_keyed.vendor_key']) }}            as vendor_id,
    vendor_keyed.vendor_name,
    case when vendor_keyed.vendor_key like 'captain %' then 'captain' else 'vendor' end as vendor_type,
    vendor_keyed.service_type_raw,
    coalesce(service_type_lookup.service_category, 'Unclassified')                as service_category,
    coalesce(regexp_matches(vendor_keyed.service_type_key, '\b(emergency|urgent|asap)\b'), false) as is_emergency,
    vendor_keyed.hours_spent,
    replace(vendor_keyed.status_key, ' ', '_')                                    as status,
    vendor_keyed.created_at_utc,
    vendor_keyed.completed_at_utc
from vendor_keyed
left join service_type_lookup
    on vendor_keyed.service_type_key = service_type_lookup.service_type_key
