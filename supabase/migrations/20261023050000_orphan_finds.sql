-- A scout that's deleted hands its finds to the person's best-fitting remaining scout (same category first, then
-- their oldest), so "Ask about this" and learning keep working. Finds of someone with no scouts left stay unassigned.
create or replace function public.rehome_finds()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- The whole account is being deleted: nothing to hand over.
  if not exists (select 1 from public.profiles p where p.id = old.user_id) then return old; end if;
  update public.finds f
     set agent_id = coalesce(
       (select a.id from public.agents a join public.listings l on l.id = f.listing_id
         where a.user_id = old.user_id and a.id <> old.id and a.mission_category = l.category
         order by a.created_at limit 1),
       (select a.id from public.agents a where a.user_id = old.user_id and a.id <> old.id order by a.created_at limit 1))
   where f.agent_id = old.id;
  return old;
end $$;
drop trigger if exists agents_rehome_finds on public.agents;
create trigger agents_rehome_finds before delete on public.agents for each row execute function public.rehome_finds();

-- Finds already left without a scout get one now.
update public.finds f
   set agent_id = coalesce(
     (select a.id from public.agents a join public.listings l on l.id = f.listing_id
       where a.user_id = f.user_id and a.mission_category = l.category order by a.created_at limit 1),
     (select a.id from public.agents a where a.user_id = f.user_id order by a.created_at limit 1))
 where f.agent_id is null and f.status in ('open', 'liked', 'acquired', 'passed')
   and exists (select 1 from public.agents a where a.user_id = f.user_id);
