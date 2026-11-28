-- Open finds kept only for "Shares your <style> details" where the product doesn't really have that style: the old
-- matcher let a record's genre "pop" count as a Funko scout's "bitty pop". The matcher now needs every word of the
-- scout's style in the product's; this clears open finds whose only reason no longer holds. Watched finds stay.
with c as (
  select f.id, l.traits, regexp_replace(f.why[1], '^Shares your (.*) details$', '\1') as lst
    from finds f join listings l on l.id = f.listing_id
   where f.status = 'open' and not coalesce(f.watching, false)
     and array_length(f.why, 1) = 1 and f.why[1] ~ '^Shares your .* details$'
)
delete from finds f
using c
where f.id = c.id
  and not exists (
    select 1 from unnest(string_to_array(c.lst, ', ')) p
     where array_to_string(c.traits, ' | ') ~* ('\m' || regexp_replace(p, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M'));
