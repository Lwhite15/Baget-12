-- Exercises the Baget schema as real Supabase roles would. Run after supabase_stub.sql and the migrations.
-- Prints PASS/FAIL lines; any FAIL is a bug.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create schema t;
grant usage on schema t to anon, authenticated, service_role;
create function t.ok(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond then raise notice 'PASS %', label; else raise warning 'FAIL %', label; end if;
end $$;
create function t.err(q text, label text) returns void language plpgsql as $$
begin
  execute q;
  raise warning 'FAIL % (no error raised)', label;
exception when others then
  raise notice 'PASS % -> %', label, sqlerrm;
end $$;
create function t.n(q text) returns bigint language plpgsql as $$
declare c bigint; begin execute 'select count(*) from (' || q || ') x' into c; return c; end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- users (as the auth service would create them)
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'larry@example.com', '{"full_name":"Larry W"}'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'x1y2@privaterelay.appleid.com', '{}'),
  ('cccccccc-0000-0000-0000-000000000003', 'carol@example.com', '{"full_name":"Larry W"}');
select t.ok((select count(*) = 3 from public.profiles), 'profiles created for new users');
select t.ok((select handle = 'larryw' from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000001'), 'handle from name');
select t.ok((select handle <> 'larryw' and handle like 'larryw%' from public.profiles where id = 'cccccccc-0000-0000-0000-000000000003'), 'duplicate handle gets a suffix');

-- ── as Larry ──
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);

insert into public.agents (name, mission_category, keywords, traits, makers, size)
values ('Jumpman Scout', 'sneakers', '{aj1}', '{suede,"low top"}', '{Jordan}', 'US M 10.5');
select t.ok(t.n('select * from public.agents') = 1, 'larry sees his agent');
select t.err($$insert into public.agents (user_id, name, mission_category) values ('bbbbbbbb-0000-0000-0000-000000000002', 'x', 'cars')$$,
             'cannot create an agent for someone else');
select t.err($$insert into public.agents (name, mission_category, mission_custom) values ('x', 'cars', 'vinyl')$$, 'one mission only');
select t.err($$update public.agents set last_swept_at = now()$$, 'cannot fake sweep timestamps');
update public.agents set paused = true, alerts = 'quiet' where name = 'Jumpman Scout';
select t.ok(t.n($$select * from public.agents where paused and alerts = 'quiet'$$) = 1, 'owner can turn an agent off and quiet it');
select t.err($$update public.agents set alerts = 'loud'$$, 'alerts must be normal, quiet or off');
select t.err($$select * from public.device_tokens$$, 'device tokens not readable directly');
select public.register_device(repeat('ab', 32), 'sandbox');
update public.profiles set handle = 'larry.w', settings = '{"sweepMinutes":180}' where id = auth.uid();
select t.ok((select handle = 'larry.w' from public.profiles where id = auth.uid()), 'can change own handle');
select t.err($$update public.profiles set handle = 'BAD HANDLE!' where id = auth.uid()$$, 'handle format enforced');
update public.profiles set display_name = 'hacked' where id = 'bbbbbbbb-0000-0000-0000-000000000002';
select t.ok(t.n($$select * from public.profiles where display_name = 'hacked'$$) = 0, 'cannot edit another profile');
select t.ok(t.n('select * from public.profiles') = 1, 'strangers'' profiles are hidden');
select t.err($$insert into public.notes (kind, body) values ('release', 'fake drop')$$, 'app cannot forge sweep notifications');
insert into public.notes (kind, body) values ('learned', 'Noticed you like suede');
select t.ok(t.n('select * from public.notes') = 1, 'app can leave itself a learned note');
insert into storage.objects (bucket_id, name) values ('taste-photos', 'aaaaaaaa-0000-0000-0000-000000000001/p1.jpg');
select t.err($$insert into storage.objects (bucket_id, name) values ('taste-photos', 'bbbbbbbb-0000-0000-0000-000000000002/p1.jpg')$$,
             'cannot upload into someone else''s photo folder');
insert into public.taste_photos (agent_id, storage_path, tags)
  select id, 'aaaaaaaa-0000-0000-0000-000000000001/p1.jpg', '{suede}' from public.agents limit 1;
select t.err($$insert into public.taste_photos (agent_id, storage_path) select id, 'bbbbbbbb-0000-0000-0000-000000000002/x.jpg' from public.agents limit 1$$,
             'photo path must be in your own folder');

-- friend request by handle
select t.ok((public.request_friend('@nobody_here') ->> 'status') = 'not_found', 'unknown handle');
select t.ok((public.request_friend('larry.w') ->> 'status') = 'self', 'cannot friend yourself');
reset role;
select handle as bob_handle from public.profiles where id = 'bbbbbbbb-0000-0000-0000-000000000002' \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok((public.request_friend(:'bob_handle') ->> 'status') = 'requested', 'friend request sent');
select t.ok((public.request_friend(:'bob_handle') ->> 'status') = 'exists', 'no duplicate requests');
select t.ok(t.n('select * from public.profiles') = 2, 'pending friend profile visible to requester');

-- ── as Bob ──
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.ok(t.n($$select * from public.notes where kind = 'friend' and body like '%wants to be friends%'$$) = 1, 'bob notified of request');
select t.ok(t.n('select * from public.agents') = 0, 'bob cannot see larry''s agents');
select t.ok(t.n($$select * from public.my_friends() where direction = 'incoming'$$) = 1, 'bob sees incoming request');
select public.respond_friend((select friendship_id from public.my_friends() limit 1), true);
insert into public.agents (name, mission_category, traits) values ('Maya Nose', 'fragrance', '{oud,rose}');

-- ── as Larry again ──
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok(t.n($$select * from public.notes where body like '%accepted your friend request%'$$) = 1, 'larry notified of acceptance');
select t.ok(t.n($$select * from public.my_friends() where status = 'accepted' and 'fragrance' = any(hunts) and 'oud' = any(likes)$$) = 1,
            'friend taste visible when shared');

-- ── server: a sweep finds listings for Larry ──
reset role;
set role service_role;
select t.ok(t.n($$select * from public.sweep_candidates(20, 12, null, null)$$) = 1, 'an agent that is off is never swept');
update public.agents set paused = false, alerts = 'normal';
select t.ok(t.n($$select * from public.sweep_candidates(20, 12, null, null)$$) = 2, 'both new agents are due');
select * from public.upsert_listings('aaaaaaaa-0000-0000-0000-000000000001',
  '[{"fingerprint":"nike-snkrs|travis scott jordan 1 low","title":"Travis Scott x Jordan 1 Low OG","brand":"Jordan","category":"sneakers","price":150,"market":610,"source":"Nike SNKRS","url":"https://www.nike.com/launch","traits":["suede","low top"],"sizes_in_stock":["10.5","11"]},
    {"fingerprint":"les-senteurs|frederic malle the night","title":"Frederic Malle The Night 100ml","brand":"Frederic Malle","category":"fragrance","price":1650,"source":"Les Senteurs","sold_out":true,"traits":["oud"]}]'::jsonb);
select public.record_finds((select id from public.agents where name = 'Jumpman Scout'),
  jsonb_build_array(jsonb_build_object('listing_id', (select id from public.listings where fingerprint like 'nike%'), 'score', 85,
    'why', '["Matches your keywords: aj1"]'::jsonb, 'note', '{"kind":"release","body":"Yo! The Travis Scott x Jordan 1 Low drops this week.","held":true}'::jsonb)));
select t.ok((select last_swept_at is not null from public.agents where name = 'Jumpman Scout'), 'sweep time recorded');
select t.ok(t.n($$select * from public.sweep_candidates(20, 12, null, null) x where x ->> 'name' = 'Jumpman Scout'$$) = 0, 'swept agent not due again yet');
select t.ok(t.n($$select * from public.sweep_candidates(20, 12, 'aaaaaaaa-0000-0000-0000-000000000001', null)$$) = 0, 'manual sweep cooldown');
-- With a cap of 2 runs a day and 2 agents, each agent waits 24h; with a cap of 48 it can go after the 3h default.
-- (Around-the-clock spacing is the Pro schedule; Free hunts in its daily window, tested further down.)
reset role;
update public.profiles set plan = 'comp' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role service_role;
update public.agents set last_swept_at = now() - interval '5 hours';
select t.ok(t.n($$select * from public.sweep_candidates(20, 48, null, null) x where x ->> 'name' = 'Jumpman Scout'$$) = 0, 'Pro schedule: not due within 6 hours');
update public.agents set last_swept_at = now() - interval '7 hours';
select t.ok(t.n($$select * from public.sweep_candidates(20, 48, null, null) x where x ->> 'name' = 'Jumpman Scout'$$) = 1, 'due again after 6 hours');
insert into public.sweep_runs (user_id, trigger) select 'aaaaaaaa-0000-0000-0000-000000000001', 'scheduled' from generate_series(1, 2);
select t.ok(t.n($$select * from public.sweep_candidates(20, 2, null, null) x where x ->> 'name' = 'Jumpman Scout'$$) = 0, 'the daily cap stops hunts');
delete from public.sweep_runs where user_id = 'aaaaaaaa-0000-0000-0000-000000000001' and error is null and searches = 0;
-- Failed runs don't use up the daily cap.
insert into public.sweep_runs (user_id, trigger, error) select 'aaaaaaaa-0000-0000-0000-000000000001', 'scheduled', 'out of credit' from generate_series(1, 5);
update public.agents set last_swept_at = now() - interval '30 hours';
select t.ok(t.n($$select * from public.sweep_candidates(20, 5, null, null) x where x ->> 'name' = 'Jumpman Scout'$$) = 1, 'failed sweeps do not count toward the cap');
delete from public.sweep_runs where error = 'out of credit';
update public.agents set last_swept_at = now();
-- Listings without sizes (fragrance, furniture) arrive with JSON nulls; they must save, not error.
select * from public.upsert_listings('aaaaaaaa-0000-0000-0000-000000000001',
  '[{"fingerprint":"aesop|hwyl eau de parfum","title":"Aesop Hwyl Eau de Parfum","brand":"Aesop","category":"fragrance","price":195,"source":"Aesop","url":"https://www.aesop.com/hwyl","image_url":null,"drop_at":null,"creator":null,"traits":["smoky","woody"],"tags":[],"sizes_in_stock":null,"sold_out":false}]'::jsonb);
select t.ok((select sizes_in_stock is null and traits = '{smoky,woody}' from public.listings where fingerprint = 'aesop|hwyl eau de parfum'), 'listing with null sizes saves');
select * from public.upsert_listings('aaaaaaaa-0000-0000-0000-000000000001',
  '[{"fingerprint":"aesop|hwyl eau de parfum","title":"Aesop Hwyl Eau de Parfum","price":190,"traits":"smoky","sizes_in_stock":null}]'::jsonb);
select t.ok((select price = 190 and traits = '{smoky,woody}' from public.listings where fingerprint = 'aesop|hwyl eau de parfum'), 'update with scalar and null lists keeps what was there');
select t.ok((select about is null from public.listings where fingerprint = 'aesop|hwyl eau de parfum'), 'no description yet');
select * from public.upsert_listings('aaaaaaaa-0000-0000-0000-000000000001',
  '[{"fingerprint":"aesop|hwyl eau de parfum","title":"Aesop Hwyl Eau de Parfum","about":"Smoky and woody, like a forest after rain."}]'::jsonb);
select * from public.upsert_listings('aaaaaaaa-0000-0000-0000-000000000001',
  '[{"fingerprint":"aesop|hwyl eau de parfum","title":"Aesop Hwyl Eau de Parfum","about":"Something else"}]'::jsonb);
select t.ok((select about = 'Smoky and woody, like a forest after rain.' from public.listings where fingerprint = 'aesop|hwyl eau de parfum'), 'a description is saved once and kept');
select t.ok(public.record_finds((select id from public.agents where name = 'Jumpman Scout'),
  jsonb_build_array(jsonb_build_object('listing_id', (select id from public.listings where fingerprint = 'aesop|hwyl eau de parfum'), 'score', 70, 'why', null))) = 1,
  'find with null reasons saves');
delete from public.finds where listing_id = (select id from public.listings where fingerprint = 'aesop|hwyl eau de parfum');
delete from public.listings where fingerprint = 'aesop|hwyl eau de parfum';
reset role;

-- ── Larry acts on his finds ──
select id as bob_agent from public.agents where name = 'Maya Nose' \gset
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok(t.n('select * from public.finds') = 1, 'larry sees his find');
select t.ok(t.n('select * from public.listings') = 2, 'listings readable when signed in');
select t.ok((select count(*) from public.finds) = 1, 'larry has one find to react to');
update public.finds set status = 'liked';
select t.ok((select status from public.finds limit 1) = 'liked', 'a find can be liked');
select t.err($$update public.finds set status = 'loved'$$, 'only known find statuses');
update public.finds set watch_price = 199;
select t.ok((select watch_price from public.finds limit 1) = 199, 'watch price can be saved');
update public.finds set status = 'open';
select t.err($$update public.finds set score = 99$$, 'cannot inflate match scores');
update public.finds set status = 'acquired';
insert into public.purchases (title, amount, category, agent_name, listing_id, agent_id)
  select l.title, l.price, l.category, 'Jumpman Scout', l.id, a.id from public.listings l, public.agents a where l.fingerprint like 'nike%';
select t.ok(t.n('select * from public.purchases') = 1, 'purchase recorded');
select t.err(format($$insert into public.purchases (title, amount, category, agent_id) values ('x', 1, 'other', %L)$$, :'bob_agent'),
             'cannot charge a purchase to someone else''s agent');
-- watch the sold-out fragrance
insert into public.finds (listing_id, agent_id, watching) select l.id, null, true from public.listings l where l.fingerprint like 'les%';

-- share with Bob
select public.share_listing((select id from public.listings where fingerprint like 'les%'),
  array['bbbbbbbb-0000-0000-0000-000000000002'::uuid], 'Rose and oud. Your whole thing.', true);
select t.err($$select public.share_listing((select id from public.listings limit 1), array['cccccccc-0000-0000-0000-000000000003'::uuid], 'hi', false)$$,
             'can only share with friends');
select t.err($$select * from public.listings where false; insert into public.listings (fingerprint, title) values ('x','x')$$, 'app cannot write listings');

-- ── Bob responds to the suggestion ──
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.ok(t.n($$select * from public.suggestions where status = 'new'$$) = 1, 'bob got the suggestion');
select t.ok(t.n($$select * from public.notes where body like '%thinks you''d like%'$$) = 1, 'bob notified of suggestion');
update public.suggestions set status = 'sent';
insert into public.share_replies (share_id, body) select id, 'Okay obsessed.' from public.shares;
select t.ok(t.n('select * from public.purchases') = 0, 'bob cannot see larry''s purchases');

-- ── restock: the watched fragrance comes back ──
reset role;
set role service_role;
select * from public.upsert_listings('aaaaaaaa-0000-0000-0000-000000000001',
  '[{"fingerprint":"les-senteurs|frederic malle the night","title":"Frederic Malle The Night 100ml","price":1650,"sold_out":false}]'::jsonb);
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok(t.n($$select * from public.notes where kind = 'restock'$$) = 1, 'restock notification for watched item');
select t.ok(t.n($$select * from public.notes where body like '%Okay obsessed%'$$) = 1, 'larry notified of bob''s reply');
select t.ok(t.n($$select * from public.notes where held_for_morning$$) = 1, 'quiet-hours note held');

-- agent cap
insert into public.agents (name, mission_category) select 'Agent ' || g, 'cars' from generate_series(1, 11) g;
select t.err($$insert into public.agents (name, mission_category) values ('One too many', 'cars')$$, 'squad capped at 12 agents');

-- ── anonymous visitors ──
reset role;
set role anon;
select set_config('request.jwt.claim.sub', '', false);
select t.err($$select * from public.agents$$, 'anon cannot read agents');
select t.err($$select * from public.listings$$, 'anon cannot read listings');
select t.err($$select public.request_friend('larry.w')$$, 'anon cannot call friend functions');
select t.err($$select * from public.sweep_candidates()$$, 'anon cannot call server functions');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.err($$select * from public.sweep_candidates()$$, 'users cannot call server functions');
select t.err($$select public.configure_scheduler('https://x', 'y')$$, 'users cannot reconfigure the scheduler');
reset role;

-- owner stats: only admins
set role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.ok(not public.am_i_admin(), 'a regular user is not an admin');
select t.err($$select public.admin_stats()$$, 'a regular user cannot read the stats');
select t.err($$select public.road_to_100()$$, 'a regular user cannot read the road to 100');
select t.err($$select * from public.claude_usage$$, 'Claude usage is not readable');
select t.err($$insert into public.app_admins (user_id) values ('bbbbbbbb-0000-0000-0000-000000000002')$$, 'nobody can make themselves an admin');
reset role;
insert into public.app_admins (user_id) values ('aaaaaaaa-0000-0000-0000-000000000001');
insert into public.claude_usage (fn, model, input_tokens, output_tokens, cache_write_tokens, cache_read_tokens, searches)
  values ('chat', 'claude-sonnet-5-5', 1000, 500, 2000, 50000, 0), ('sweep', 'claude-sonnet-5-5', 0, 0, 0, 0, 6);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok(public.am_i_admin(), 'the owner is an admin');
select t.ok((public.admin_stats() -> 'users' ->> 'total')::int >= 2, 'the owner sees user counts');
select t.ok((public.admin_stats() -> 'claude' ->> 'today')::numeric > 0.06, 'spend includes tokens and searches');
select t.ok((public.admin_stats() -> 'claude' ->> 'cache_saved_week')::numeric > 0, 'cache savings are counted');
select t.ok(jsonb_array_length(public.admin_stats() -> 'daily') = 14, 'two weeks of daily numbers');
select t.ok((public.road_to_100() ->> 'goal')::int = 100 and (public.road_to_100() ->> 'users')::int >= 2, 'the owner sees progress to 100');
reset role;

-- For You: always something, ranked by taste, learns from reactions
insert into public.listings (fingerprint, title, brand, category, url, image_url, traits) values
  ('fy|jordan', 'Air Jordan 1 Low Mocha', 'Jordan', 'sneakers', 'https://nike.com/p/1', 'https://img.example/1.jpg', '{suede}'),
  ('fy|lamp', 'Arc Floor Lamp', 'Hay', 'furniture', 'https://hay.com/p/2', 'https://img.example/2.jpg', '{brass}'),
  ('fy|nophoto', 'Jordan 4 Mystery', 'Jordan', 'sneakers', 'https://nike.com/p/3', null, '{suede}'),
  ('fy|bobs', 'Bob Secret Grail Sneaker', 'Jordan', 'sneakers', 'https://nike.com/p/4', 'https://img.example/4.jpg', '{suede}'),
  ('fy|house', 'House Pick Fragrance', 'Le Labo', 'fragrance', 'https://lelabo.com/p/5', 'https://img.example/5.jpg', '{woody}');
-- Who saw what: Larry's scouts saw the first three, Bob's saw his grail, Baget's house account saw the house pick.
insert into auth.users (id, email) values ('0a99e1e0-5eed-4d3e-8a00-00000000d3e0', 'house@example.com') on conflict do nothing;
insert into public.listing_seen (user_id, listing_id)
  select 'aaaaaaaa-0000-0000-0000-000000000001'::uuid, id from public.listings where fingerprint in ('fy|jordan', 'fy|lamp', 'fy|nophoto')
  union all select 'bbbbbbbb-0000-0000-0000-000000000002'::uuid, id from public.listings where fingerprint = 'fy|bobs'
  union all select '0a99e1e0-5eed-4d3e-8a00-00000000d3e0'::uuid, id from public.listings where fingerprint = 'fy|house';
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok(t.n('select * from public.for_you(10)') >= 2, 'For You has picks');
select t.ok((select x ->> 'kind' = 'match' and x -> 'listing' ->> 'title' = 'Air Jordan 1 Low Mocha' from public.for_you(10) x limit 1), 'the best taste match comes first');
select t.ok(not exists (select 1 from public.for_you(10) x where x -> 'listing' ->> 'title' = 'Jordan 4 Mystery'), 'no photo, not shown');
select t.ok(exists (select 1 from public.for_you(10) x where x -> 'listing' ->> 'title' = 'Arc Floor Lamp' and x ->> 'kind' = 'explore'), 'something new to try is mixed in');
select t.ok(jsonb_array_length(public.taste_top(8)) > 0, 'taste profile is readable by its owner');
select t.ok(t.n($$select * from public.taste_quiz(array['sneakers'], 10)$$) >= 1, 'taste check has sneakers to rate');
select t.ok(not exists (select 1 from public.taste_quiz(array['sneakers'], 10) x where x ->> 'category' <> 'sneakers'), 'only the categories you picked');
select t.ok(not exists (select 1 from public.taste_quiz(array['sneakers'], 10) x where x ->> 'image_url' is null), 'only products with photos');
select t.err($$select * from public.buy_clicks$$, 'buy clicks are server-only');
insert into public.feed_reactions (listing_id, action) select id, 'dismiss' from public.listings where fingerprint = 'fy|lamp';
select t.ok(not exists (select 1 from public.for_you(10) x where x -> 'listing' ->> 'title' = 'Arc Floor Lamp'), '"not for me" removes it');
select t.ok(exists (select 1 from jsonb_array_elements(public.taste_top(20)) e where e ->> 'feature' = 'b:hay' and (e ->> 'weight')::numeric < 0), 'and teaches a dislike');
select t.err($$insert into public.feed_reactions (user_id, listing_id, action) select 'bbbbbbbb-0000-0000-0000-000000000002', id, 'like' from public.listings limit 1$$, 'cannot react for someone else');
select t.err($$select * from public.taste_features('bbbbbbbb-0000-0000-0000-000000000002')$$, 'cannot read anyone''s raw taste');
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
select t.ok(t.n('select * from public.feed_reactions') = 0, 'reactions are private');
select t.ok(t.n('select * from public.for_you(10)') >= 1, 'a brand-new user still gets a feed');
select t.ok(not exists (select 1 from public.for_you(20) x where x -> 'listing' ->> 'title' in ('Air Jordan 1 Low Mocha', 'Arc Floor Lamp')), 'never products another person''s scouts found');
select t.ok(exists (select 1 from public.for_you(20) x where x -> 'listing' ->> 'title' = 'House Pick Fragrance'), 'the house catalog fills a new feed');
select t.ok(t.n('select * from public.listing_seen') = 1, 'who saw what is private');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok(not exists (select 1 from public.for_you(20) x where x -> 'listing' ->> 'title' = 'Bob Secret Grail Sneaker'), 'Bob''s grail never shows on Larry''s screen');
select t.ok(not exists (select 1 from public.taste_quiz(array['sneakers'], 10) x where x ->> 'title' = 'Bob Secret Grail Sneaker'), 'nor in Larry''s taste check');
select t.ok(t.n($$select * from public.taste_quiz(array['fragrance'], 10)$$) >= 1, 'the taste check uses the house catalog');
reset role;

-- Free and Pro
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.err($$update public.profiles set plan = 'pro', pro_until = now() + interval '1 year' where id = auth.uid()$$, 'nobody can give themselves Pro');
select t.err($$select public.is_pro(auth.uid())$$, 'plan checks are server-only');
select t.ok((public.my_plan() ->> 'hours')::int = 4, 'the app can read its own plan');
reset role;
update public.profiles set plan = 'free', settings = settings || jsonb_build_object('huntStart', ((extract(hour from now() at time zone tz)::int + 12) % 24))
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
update public.agents set last_swept_at = now() - interval '21 hours', paused = false where user_id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role service_role;
select t.ok(not exists (select 1 from public.sweep_candidates(20, 50, null, null) c where c ->> 'user_id' = 'aaaaaaaa-0000-0000-0000-000000000001'), 'Free scouts rest outside their window');
reset role;
update public.profiles set settings = settings || jsonb_build_object('huntStart', extract(hour from now() at time zone tz)::int)
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role service_role;
select t.ok(exists (select 1 from public.sweep_candidates(20, 50, null, null) c where c ->> 'user_id' = 'aaaaaaaa-0000-0000-0000-000000000001'), 'and hunt inside it');
reset role;
update public.profiles set plan = 'pro', pro_until = now() + interval '30 days', settings = settings || jsonb_build_object('huntStart', ((extract(hour from now() at time zone tz)::int + 12) % 24))
 where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role service_role;
select t.ok(exists (select 1 from public.sweep_candidates(20, 50, null, null) c where c ->> 'user_id' = 'aaaaaaaa-0000-0000-0000-000000000001'), 'Pro hunts around the clock');
reset role;
update public.profiles set pro_until = now() - interval '1 day' where id = 'aaaaaaaa-0000-0000-0000-000000000001';
set role service_role;
select t.ok(not exists (select 1 from public.sweep_candidates(20, 50, null, null) c where c ->> 'user_id' = 'aaaaaaaa-0000-0000-0000-000000000001'), 'an expired Pro is Free again');
reset role;

-- Tester feedback
set role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
insert into public.feedback (kind, body, app_version) values ('bug', 'The Buy button did nothing', '1.0 (78)');
select t.ok(t.n('select * from public.feedback') = 1, 'a tester can send feedback and see their own');
select t.err($$insert into public.feedback (user_id, body) values ('aaaaaaaa-0000-0000-0000-000000000001', 'x')$$, 'not as someone else');
select t.err($$select public.admin_feedback(10)$$, 'only admins read all feedback');
select t.err($$update public.feedback set status = 'done'$$, 'testers cannot change status');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok(t.n('select * from public.feedback') = 0, 'feedback is private to the sender');
select t.ok(t.n('select * from public.admin_feedback(10)') = 1, 'the owner reads it');
select t.ok(t.n($$select * from public.notes where kind = 'feedback' and body like '%Buy button did nothing%'$$) = 1, 'and gets a text about it');
select public.admin_mark_feedback((select (x ->> 'id')::uuid from public.admin_feedback(1) x), 'done');
select t.ok((select x ->> 'status' = 'done' from public.admin_feedback(1) x), 'the owner can mark it done');
reset role;

-- Plan limits
reset role;
update public.profiles set plan = 'free', pro_until = null where id = 'bbbbbbbb-0000-0000-0000-000000000002';
delete from public.agents where user_id = 'bbbbbbbb-0000-0000-0000-000000000002';
set role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
insert into public.agents (name, mission_category) values ('One', 'cars'), ('Two', 'watches');
select t.err($$insert into public.agents (name, mission_category) values ('Three', 'fragrance')$$, 'Free includes 2 scouts');
select t.ok((public.my_plan() ->> 'scouts')::int = 2, 'the app knows the limit');
reset role;
update public.profiles set plan = 'pro', pro_until = now() + interval '30 days' where id = 'bbbbbbbb-0000-0000-0000-000000000002';
set role authenticated;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-0000-0000-0000-000000000002', false);
insert into public.agents (name, mission_category) values ('Three', 'fragrance'), ('Four', 'cars'), ('Five', 'furniture');
select t.err($$insert into public.agents (name, mission_category) values ('Six', 'apparel')$$, 'Pro includes 5 scouts');
reset role;
-- Pro: a scout that hunted 3 hours ago isn't due (every 6 hours); one from 7 hours ago is.
update public.agents set last_swept_at = now() - interval '3 hours' where user_id = 'bbbbbbbb-0000-0000-0000-000000000002';
update public.agents set last_swept_at = now() - interval '7 hours' where user_id = 'bbbbbbbb-0000-0000-0000-000000000002' and name = 'One';
set role service_role;
select t.ok(t.n($$select * from public.sweep_candidates(20, 30, null, null) c where c ->> 'user_id' = 'bbbbbbbb-0000-0000-0000-000000000002'$$) = 1, 'Pro hunts every 6 hours');
select t.ok((select (c ->> 'pro')::boolean from public.sweep_candidates(20, 30, null, null) c where c ->> 'user_id' = 'bbbbbbbb-0000-0000-0000-000000000002' limit 1), 'hunts know the plan');
reset role;
-- Back to Free with 5 scouts: only the first 2 hunt, once a day.
update public.profiles set plan = 'free', pro_until = null, settings = settings || jsonb_build_object('huntStart', extract(hour from now() at time zone tz)::int)
 where id = 'bbbbbbbb-0000-0000-0000-000000000002';
update public.agents set last_swept_at = now() - interval '21 hours' where user_id = 'bbbbbbbb-0000-0000-0000-000000000002';
set role service_role;
select t.ok(t.n($$select * from public.sweep_candidates(20, 30, null, null) c where c ->> 'user_id' = 'bbbbbbbb-0000-0000-0000-000000000002'$$) = 2, 'Free: only 2 scouts hunt');
select t.ok(t.n($$select * from public.sweep_candidates(20, 30, 'bbbbbbbb-0000-0000-0000-000000000002', null) c where c ->> 'name' = 'Three'$$) = 0, 'extra scouts on Free stay home, even on refresh');
reset role;
update public.agents set last_swept_at = now() - interval '5 hours' where user_id = 'bbbbbbbb-0000-0000-0000-000000000002';
set role service_role;
select t.ok(t.n($$select * from public.sweep_candidates(20, 30, 'bbbbbbbb-0000-0000-0000-000000000002', null)$$) = 0, 'Free: no extra hunts by refreshing the same day');
reset role;

-- morning release and account deletion
set role service_role;
select t.ok(t.n('select * from public.release_held_notes()') >= 0, 'release runs');
reset role;
delete from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select t.ok((select count(*) = 0 from public.agents where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 'deleting an account removes its agents');
select t.ok((select count(*) = 0 from public.friendships), 'and its friendships');
select t.ok((select count(*) = 0 from public.purchases), 'and its purchases');
