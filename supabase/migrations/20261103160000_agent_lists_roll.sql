-- A scout's taste lists roll over instead of overflowing: when liking something adds a trait or brand to a full list,
-- the oldest ones drop off (newest are at the end). Before, a full list (40 traits) made the update fail with a 400.
create or replace function public.agents_trim_lists() returns trigger
language plpgsql set search_path = public as $$
begin
  if cardinality(new.traits) > 40 then new.traits := new.traits[cardinality(new.traits) - 39 : cardinality(new.traits)]; end if;
  if cardinality(new.makers) > 20 then new.makers := new.makers[cardinality(new.makers) - 19 : cardinality(new.makers)]; end if;
  if cardinality(new.keywords) > 20 then new.keywords := new.keywords[cardinality(new.keywords) - 19 : cardinality(new.keywords)]; end if;
  if cardinality(new.creators) > 20 then new.creators := new.creators[cardinality(new.creators) - 19 : cardinality(new.creators)]; end if;
  return new;
end $$;
drop trigger if exists agents_trim_lists on public.agents;
create trigger agents_trim_lists before insert or update on public.agents for each row execute function public.agents_trim_lists();
