-- A deleted scout's finds only move to a scout that hunts the same kind of thing (or one with a custom mission);
-- otherwise they stay unassigned (the app asks your best-fitting scout about them). Undo yesterday's moves that put
-- a find with a scout of another category that didn't exist when it was found (e.g. a necklace under a boot scout).
create or replace function public.rehome_finds()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.profiles p where p.id = old.user_id) then return old; end if;
  update public.finds f
     set agent_id = (select a.id from public.agents a join public.listings l on l.id = f.listing_id
                      where a.user_id = old.user_id and a.id <> old.id
                        and (a.mission_category = l.category or a.mission_category is null)
                      order by (a.mission_category = l.category) desc nulls last, a.created_at limit 1)
   where f.agent_id = old.id;
  return old;
end $$;

update public.finds f set agent_id = null
  from public.agents a, public.listings l
 where a.id = f.agent_id and l.id = f.listing_id
   and a.mission_category is not null and a.mission_category <> l.category
   and f.created_at < a.created_at;
