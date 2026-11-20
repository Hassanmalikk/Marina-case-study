-- Governance guardrail: the BI-facing marts schema must never expose direct identifiers (email, phone, person name,
-- address). Marts carry owner_id, a pseudonymous surrogate key, instead. Checks the PHYSICAL columns, so it also
-- catches a `select *` that accidentally drags PII in. Any returned row = a PII leak.
-- depends_on: {{ ref('fct_work_orders') }} {{ ref('fct_subscriptions') }} {{ ref('mrt_vendor_performance') }}
{%- set marts = ref('mrt_executive_kpis') %}

select table_name, column_name
from information_schema.columns
where table_catalog = '{{ marts.database }}'
  and table_schema = '{{ marts.schema }}'
  and regexp_matches(
        lower(column_name),
        '(email|phone|full_name|first_name|last_name|owner_name|customer_name|address|raw_contact|ssn|birth)'
      )
