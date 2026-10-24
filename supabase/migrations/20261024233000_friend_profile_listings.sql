-- Friend profiles return whole listings (so the app shows them like any other product).
create or replace function public.friend_profile(p_friend uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  fr public.friendships;
  them public.profiles;
  mine_p public.profiles;
  shares boolean;
  res jsonb;
begin
  if me is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into fr from public.friendships
   where status = 'accepted' and ((requester = me and addressee = p_friend) or (requester = p_friend and addressee = me));
  if not found then raise exception 'not_friends' using errcode = '42501'; end if;
  select * into them from public.profiles where id = p_friend;
  select * into mine_p from public.profiles where id = me;
  shares := coalesce(them.share_taste, false) and coalesce(mine_p.share_taste, false);
  res := jsonb_build_object('friend_id', them.id, 'handle', them.handle, 'name', them.display_name,
                            'since', fr.created_at, 'shares', shares, 'they_share', coalesce(them.share_taste, false));
  if not shares then return res; end if;

  with
  a as (select f, least(w, 6.0) as w from public.taste_features(me) where w > 0.5 and (f like 'b:%' or f like 't:%' or f like 'c:%')),
  b as (select f, least(w, 6.0) as w from public.taste_features(p_friend) where w > 0.5 and (f like 'b:%' or f like 't:%' or f like 'c:%')),
  j as (select coalesce(a.f, b.f) as f, coalesce(a.w, 0) as mw, coalesce(b.w, 0) as tw from a full join b on a.f = b.f),
  sim as (
    select case when sqrt(sum(mw * mw)) * sqrt(sum(tw * tw)) = 0 then 0
                else sum(mw * tw) / (sqrt(sum(mw * mw)) * sqrt(sum(tw * tw))) end as s
      from j where f not like 'c:%'
  ),
  cats as (select (select count(*) from j where f like 'c:%' and mw > 0 and tw > 0) as shared,
                  (select count(*) from j where f like 'c:%' and (mw > 0 or tw > 0)) as total),
  dna as (
    select f, mw, tw from j where f not like 'c:%' order by greatest(mw, tw) + least(mw, tw) desc limit 5
  ),
  grails as (
    select to_jsonb(l) as listing,
           case when f.status = 'acquired' then 'got' when f.watching then 'watching' else 'liked' end as tag
      from public.finds f join public.listings l on l.id = f.listing_id
     where f.user_id = p_friend and (f.watching or f.status in ('liked', 'acquired')) and l.image_url is not null
     order by f.created_at desc limit 6
  ),
  twins as (
    select to_jsonb(l) as listing
      from public.finds f1 join public.finds f2 on f2.listing_id = f1.listing_id and f2.user_id = p_friend
      join public.listings l on l.id = f1.listing_id
     where f1.user_id = me and l.image_url is not null and not (l.tags && array['intel', 'search'])
     order by greatest(f1.created_at, f2.created_at) desc limit 4
  ),
  -- Gift radar: store and house listings (never anyone else's scouts' finds) that fit their taste, $15-$150.
  gcand as (
    select l.id, l.brand, to_jsonb(l) as listing,
           (select coalesce(sum(b.w), 0) from b where b.f = any(array['b:' || lower(l.brand), 'c:' || l.category]
                                                         || coalesce(array(select 't:' || lower(x) from unnest(l.traits) x), '{}'))) as fit
      from public.listings l
     where l.image_url is not null and l.url is not null and l.price between 15 and 150
       and not (l.tags && array['intel', 'search'])
       and l.last_seen_at > now() - interval '60 days'
       and ('catalog' = any(l.tags) or l.id in (select listing_id from public.listing_seen where user_id in (me, '0a99e1e0-5eed-4d3e-8a00-00000000d3e0')))
       and l.category in (select substr(f, 3) from b where f like 'c:%')
       and not exists (select 1 from public.finds x where x.user_id = p_friend and x.listing_id = l.id)
       and not public.wrong_dept(l.title || ' ' || array_to_string(l.traits, ' '), them.settings ->> 'department', l.category)
  ),
  gifts as (
    select g.* from (select gc.*, row_number() over (partition by public.brand_key(gc.brand) order by gc.fit desc) as rb from gcand gc where gc.fit > 1) g
     where g.rb = 1 order by g.fit desc limit 6
  )
  select res || jsonb_build_object(
    'match', (select least(99, greatest(5, round(100 * (0.8 * sqrt(sim.s)
                       + 0.2 * case when cats.total = 0 then 0 else cats.shared::numeric / cats.total end))))::int
                from sim, cats),
    'dna', coalesce((select jsonb_agg(jsonb_build_object('label', public.feature_label(f),
                       'who', case when mw > 0 and tw > 0 and greatest(mw, tw) < 2.2 * least(mw, tw) then 'both' when tw > mw then 'them' else 'you' end,
                       'strength', round(least(1.0, greatest(mw, tw) / 6.0)::numeric, 2))) from dna), '[]'),
    'both_love', coalesce((select jsonb_agg(public.feature_label(f) order by least(mw, tw) desc)
                             from (select * from j where f not like 'c:%' and mw > 0.75 and tw > 0.75 order by least(mw, tw) desc limit 8) x), '[]'),
    'their_world', coalesce((select jsonb_agg(public.feature_label(f) order by tw desc)
                               from (select * from j where f not like 'c:%' and tw > 1.5 and mw <= 0.25 order by tw desc limit 6) x), '[]'),
    'hunts', coalesce((select jsonb_agg(distinct coalesce(ag.mission_category, ag.mission_custom)) from public.agents ag where ag.user_id = p_friend and not ag.paused), '[]'),
    'grails', coalesce((select jsonb_agg(jsonb_build_object('listing', g.listing, 'tag', g.tag)) from grails g), '[]'),
    'twins', coalesce((select jsonb_agg(t.listing) from twins t), '[]'),
    'gifts', coalesce((select jsonb_agg(g.listing) from gifts g), '[]'),
    'birthday', them.birthday,
    'card', case when them.taste_card is not null then them.taste_card || jsonb_build_object('number', public.card_number(them.id)) end,
    'my_card', case when mine_p.taste_card is not null then mine_p.taste_card || jsonb_build_object('number', public.card_number(me)) end
  ) into res;
  return res;
end $$;
revoke all on function public.friend_profile(uuid) from public, anon;
grant execute on function public.friend_profile(uuid) to authenticated;
