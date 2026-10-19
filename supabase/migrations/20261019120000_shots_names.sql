-- Screenshot texts: the name is swapped wherever it appears, not only at the start.
create or replace function public.seed_shots(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  house uuid := '0a99e1e0-5eed-4d3e-8a00-00000000d3e0';
  cat text; src uuid; dst uuid; n int := 0;
begin
  if p_user = house then raise exception 'not the house account'; end if;
  update public.profiles set display_name = 'Maya', plan = 'pro', pro_until = now() + interval '1 year' where id = p_user;
  delete from public.notes where user_id = p_user;
  delete from public.finds where user_id = p_user;
  delete from public.agents where user_id = p_user;
  foreach cat in array array['sneakers', 'fragrance', 'watches'] loop
    select id into src from public.agents where user_id = house and mission_category = cat order by created_at limit 1;
    insert into public.agents (user_id, name, mission_category, keywords, traits, makers, creators, size, mode, voice, learned, icon, last_swept_at)
      select p_user, a.name, a.mission_category, a.keywords, a.traits, a.makers, a.creators, a.size, a.mode, a.voice, a.learned, a.icon, now()
        from public.agents a where a.id = src
      returning id into dst;
    -- The best real finds: photo, description and brand blurb, one per brand, freshest first.
    with best as (
      select distinct on (lower(l.brand)) f.*, l.brand
        from public.finds f join public.listings l on l.id = f.listing_id
       where f.agent_id = src and l.image_url is not null and l.about is not null and l.brand_about is not null and l.price is not null
       order by lower(l.brand), f.score desc, f.created_at desc)
    insert into public.finds (user_id, agent_id, listing_id, score, why, status, created_at)
      select p_user, dst, b.listing_id, b.score, b.why, 'open', now() - (row_number() over (order by b.score desc)) * interval '37 minutes'
        from (select * from best order by score desc limit 8) b;
    insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id, read, pushed_at, push_skipped)
      select p_user, dst, a.name, nt.kind, regexp_replace(nt.body, '\m(App|Alex)([,:])', 'Maya\2', 'g'), f2.id, false, now(), true
        from public.notes nt
        join public.finds f1 on f1.id = nt.find_id
        join public.finds f2 on f2.listing_id = f1.listing_id and f2.user_id = p_user
        join public.agents a on a.id = dst
       where nt.user_id = house and nt.agent_id = src
       order by nt.created_at desc limit 2;
  end loop;
  insert into public.listing_seen (user_id, listing_id, seen_at)
    select p_user, s.listing_id, now() from public.listing_seen s where s.user_id = house
  on conflict do nothing;
  select count(*) into n from public.finds where user_id = p_user;
  return jsonb_build_object('finds', n, 'agents', (select count(*) from public.agents where user_id = p_user),
                            'notes', (select count(*) from public.notes where user_id = p_user));
end $$;
revoke all on function public.seed_shots(uuid) from public, anon, authenticated;
grant execute on function public.seed_shots(uuid) to service_role;
