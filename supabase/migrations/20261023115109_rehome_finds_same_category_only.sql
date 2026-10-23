-- Applied directly to the database on Oct 23 (outside the repo); kept here so the repo matches it.
-- Superseded by 20261023120000_rehome_same_kind.sql.
CREATE OR REPLACE FUNCTION public.rehome_finds()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- The whole account is being deleted: nothing to hand over.
  if not exists (select 1 from public.profiles p where p.id = old.user_id) then return old; end if;
  -- Hand finds only to another agent in the same category as the listing.
  -- With no same-category agent, leave them; ON DELETE SET NULL clears agent_id.
  update public.finds f
     set agent_id = a.id
    from public.listings l
    cross join lateral (
      select x.id from public.agents x
       where x.user_id = old.user_id and x.id <> old.id and x.mission_category = l.category
       order by x.created_at limit 1) a
   where f.agent_id = old.id and l.id = f.listing_id;
  return old;
end $function$;
