{#
  Reusable cleaning primitives used by the staging layer.

  Design notes
  - All dialect-specific SQL (regex, timezone functions) is isolated here. Porting to Snowflake/BigQuery
    means wrapping these in adapter.dispatch() with a snowflake__/bigquery__ implementation; models do not change.
  - Every parser is "fail-soft": it returns NULL for unparseable input instead of aborting the query
    (try_cast, regex validation). NULLs are then caught LOUDLY by not_null / accepted_values tests,
    so one malformed row fails the build (and blocks downstream models) without hiding which row it was.
  - Regex patterns live in template text (not Jinja string literals) so backslashes are not escape-processed.
#}


{# Blank strings and textual null tokens ('NULL', 'N/A', ...) exported by legacy systems -> SQL NULL. #}
{% macro clean_string(col) -%}
    case
        when upper(trim({{ col }})) in ('', 'NULL', 'NONE', 'N/A', 'NA', 'NAN') then null
        else trim({{ col }})
    end
{%- endmacro %}


{# "$1,200.00" / "1200" / "(1,200.00)" -> DECIMAL. Accounting parentheses mean negative. #}
{% macro parse_currency(col, precision=10, scale=2) -%}
    (
        case when {{ clean_string(col) }} like '(%)' then -1 else 1 end
        * try_cast(
            nullif(regexp_replace({{ clean_string(col) }}, '[^0-9.\-]', '', 'g'), '')
            as decimal({{ precision }}, {{ scale }})
        )
    )::decimal({{ precision }}, {{ scale }})
{%- endmacro %}


{# Pragmatic RFC-5322 subset; good enough for matching, not for deliverability validation. #}
{% macro email_regex() -%}
[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}
{%- endmacro %}


{# Extract + canonicalise an email from free text: lower-case, trimmed, NULL if none present. #}
{% macro normalize_email(col) -%}
    nullif(regexp_extract(lower({{ clean_string(col) }}), '{{ email_regex() }}', 0), '')
{%- endmacro %}


{#
  Free-text phone -> E.164 ('+15550192834').
  Default region is NANP (+1): 10 digits get '+1'; 11 digits starting with 1 get '+'.
  Anything else must already carry a leading '+' and 8-15 digits (E.164 bounds), otherwise NULL.
  Any email address in the text is removed first so its digits ('jdoe_99') are never read as a phone.
  Production upgrade path: libphonenumber in a dbt Python model / UDF for full international parsing.
#}
{% macro normalize_phone(col) -%}
    {%- set text -%}{{ clean_string(col) }}{%- endset -%}
    {%- set digits -%}
        regexp_replace(regexp_replace(lower({{ text }}), '{{ email_regex() }}', '', 'g'), '[^0-9]', '', 'g')
    {%- endset -%}
    case
        when length({{ digits }}) = 10 then '+1' || {{ digits }}
        when length({{ digits }}) = 11 and {{ digits }} like '1%' then '+' || {{ digits }}
        when {{ text }} like '+%' and length({{ digits }}) between 8 and 15 then '+' || {{ digits }}
        else null
    end
{%- endmacro %}


{# Identifier canonicalisation: 'fl-8812 ab ' -> 'FL8812AB'. Used for hull ids / registration numbers. #}
{% macro normalize_identifier(col) -%}
    nullif(upper(regexp_replace({{ clean_string(col) }}, '[^A-Za-z0-9]', '', 'g')), '')
{%- endmacro %}


{# Free text -> lower-case alphanumeric tokens separated by single spaces ('Hull Cleaning & Paint' -> 'hull cleaning paint'). #}
{% macro normalize_text_key(col) -%}
    nullif(trim(regexp_replace(lower({{ clean_string(col) }}), '[^a-z0-9]+', ' ', 'g')), '')
{%- endmacro %}


{#
  String timestamp -> naive TIMESTAMP in UTC.
  - If the string carries an explicit offset or 'Z', that offset is honoured.
  - Otherwise it is interpreted in `source_tz` (IANA name, e.g. 'America/New_York'), which handles DST correctly
    (a naive local-time subtraction would be off by 1h for jobs spanning a DST switch).
  Output is stored as TIMESTAMP (no tz) with an `_utc` suffix: unambiguous and identical across warehouses.
#}
{% macro to_utc(col, source_tz) -%}
    case
        when regexp_matches({{ clean_string(col) }}, '(Z|[+-][0-9]{2}:?[0-9]{2})$')
            then timezone('UTC', try_cast({{ clean_string(col) }} as timestamptz))
        else timezone('UTC', timezone('{{ source_tz }}', try_cast({{ clean_string(col) }} as timestamp)))
    end
{%- endmacro %}
