-- A hunt's store slice: at most half goes to the scout's favorite brands' own stores; the rest rotates through the
-- category (least recently searched first), so boutiques, retailers and resale sites all keep getting their turn.
create or replace function public.claim_stores(p_category text, p_n int, p_prefer text[] default '{}')
returns table (domain text, name text) language plpgsql security definer set search_path = public as $$
declare n int := greatest(0, least(p_n, 10));
begin
  return query
  with fav as (
    select s.domain, s.category from public.stores s
     where s.category = p_category
       and coalesce(s.last_searched_at, 'epoch') < now() - interval '30 minutes'
       and exists (select 1 from unnest(p_prefer) x where length(x) > 2
                    and (lower(s.name) = lower(x) or s.domain like replace(lower(x), ' ', '') || '.%'))
     order by s.last_searched_at nulls first
     limit ceil(n / 2.0)::int
  ), rest as (
    select s.domain, s.category from public.stores s
     where s.category = p_category and not exists (select 1 from fav f where f.domain = s.domain)
     order by s.last_searched_at nulls first, random()
     limit n - (select count(*) from fav)
  ), pick as (select * from fav union all select * from rest)
  update public.stores s set last_searched_at = now()
    from pick where s.domain = pick.domain and s.category = pick.category
  returning s.domain, s.name;
end $$;
revoke all on function public.claim_stores(text, int, text[]) from public, anon, authenticated;
grant execute on function public.claim_stores(text, int, text[]) to service_role;
