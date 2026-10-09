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
update public.agents set last_swept_at = now() - interval '5 hours';
select t.ok(t.n($$select * from public.sweep_candidates(20, 2, null, null) x where x ->> 'name' = 'Jumpman Scout'$$) = 0, 'sweeps spread to fit the daily cap');
select t.ok(t.n($$select * from public.sweep_candidates(20, 48, null, null) x where x ->> 'name' = 'Jumpman Scout'$$) = 1, 'roomy cap: due after the 3 hour default');
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

-- morning release and account deletion
set role service_role;
select t.ok(t.n('select * from public.release_held_notes()') >= 0, 'release runs');
reset role;
delete from auth.users where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select t.ok((select count(*) = 0 from public.agents where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 'deleting an account removes its agents');
select t.ok((select count(*) = 0 from public.friendships), 'and its friendships');
select t.ok((select count(*) = 0 from public.purchases), 'and its purchases');
