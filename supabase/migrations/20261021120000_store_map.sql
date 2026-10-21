-- Store map: the stores that matter for each category. Every hunt searches a rotating slice of them directly
-- (least recently searched first, the scout's favorite brands' own sites first), so no store goes unchecked for long.
-- Shopify stores are also read directly from their public catalogs between hunts (no AI, no search). Stores people
-- like or buy from, and stores scouts keep finding things at, join the map on their own. Non-store sites are blocked.
create table if not exists public.stores (
  domain           text not null check (domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
  category         text not null,
  name             text not null default '',
  kind             text not null default 'retailer',
  source           text not null default 'seed' check (source in ('seed', 'learned')),
  -- Shopify catalog: null until checked, then true (readable, in US dollars) or false.
  shopify          boolean,
  last_searched_at timestamptz,
  last_feed_at     timestamptz,
  feed_products    int,
  added_at         timestamptz not null default now(),
  primary key (domain, category)
);
create index if not exists stores_rotation on public.stores (category, last_searched_at nulls first);
alter table public.stores enable row level security;
revoke all on public.stores from anon, authenticated;
grant all on public.stores to service_role;

-- Sites that aren't stores (news, droplists, release calendars, encyclopedias): fine to read while hunting, never a find.
create table if not exists public.source_blocks (
  domain text primary key,
  reason text not null default ''
);
alter table public.source_blocks enable row level security;
revoke all on public.source_blocks from anon, authenticated;
grant all on public.source_blocks to service_role;
insert into public.source_blocks (domain, reason) values
  ('supremecommunity.com', 'droplists'), ('soleretriever.com', 'release calendar'), ('sneakernews.com', 'news'),
  ('nicekicks.com', 'news'), ('hypebeast.com', 'news'), ('complex.com', 'news'), ('sneakerbardetroit.com', 'news'),
  ('fragrantica.com', 'encyclopedia'), ('basenotes.com', 'encyclopedia'), ('parfumo.com', 'encyclopedia'),
  ('wikipedia.org', 'encyclopedia'), ('youtube.com', 'video'),
  ('instagram.com', 'social'), ('tiktok.com', 'social'), ('pinterest.com', 'social'), ('x.com', 'social'), ('twitter.com', 'social')
on conflict do nothing;

create or replace function public.host_of(url text) returns text language sql immutable as $$
  select lower(regexp_replace(substring(url from '://([^/:?#]+)'), '^www\.', ''))
$$;

-- The next stores for a hunt in this category: the scout's favorite brands' own stores first, then whichever have
-- waited longest. Marks them searched.
create or replace function public.claim_stores(p_category text, p_n int, p_prefer text[] default '{}')
returns table (domain text, name text) language plpgsql security definer set search_path = public as $$
begin
  return query
  with pick as (
    select s.domain, s.category from public.stores s
     where s.category = p_category
     order by (exists (select 1 from unnest(p_prefer) x where length(x) > 2 and (lower(s.name) = lower(x) or s.domain like replace(lower(x), ' ', '') || '.%'))
               and coalesce(s.last_searched_at, 'epoch') < now() - interval '30 minutes') desc,
              s.last_searched_at nulls first, random()
     limit greatest(0, least(p_n, 10))
     for update skip locked
  )
  update public.stores s set last_searched_at = now()
    from pick where s.domain = pick.domain and s.category = pick.category
  returning s.domain, s.name;
end $$;

-- Shopify catalogs due for a read (every 3 hours each), one row per store with all its categories.
create or replace function public.claim_feeds(p_n int)
returns table (domain text, categories text[], shopify boolean) language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select s.domain from public.stores s
     where s.shopify is distinct from false
     group by s.domain
    having coalesce(max(s.last_feed_at), 'epoch') < now() - interval '3 hours'
     order by max(s.last_feed_at) nulls first, random()
     limit greatest(0, least(p_n, 20))
  ), mark as (
    update public.stores s set last_feed_at = now() from due where s.domain = due.domain returning s.domain, s.category, s.shopify
  )
  select m.domain, array_agg(distinct m.category), bool_or(m.shopify) from mark m group by m.domain;
end $$;

-- Scouts that read a category's catalogs: every scout that's on and within its plan's scout count.
create or replace function public.feed_scouts(p_categories text[])
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'display_name', p.display_name, 'pro', public.is_pro(p.id))
    from public.agents a join public.profiles p on p.id = a.user_id
   where not a.paused and a.mission_category = any(p_categories)
     and (select count(*) from public.agents x where x.user_id = a.user_id and not x.paused and x.created_at < a.created_at) < public.scout_limit(p.id)
$$;

-- New stores join the map: where people liked or bought something, and where scouts found 3+ products in 30 days.
create or replace function public.learn_stores()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with cand as (
    select public.host_of(l.url) d, l.category c, min(l.source) nm
      from public.finds f join public.listings l on l.id = f.listing_id
     where f.status in ('liked', 'acquired') and l.url is not null
     group by 1, 2
    union
    select public.host_of(l.url), l.category, min(l.source)
      from public.listings l
     where l.first_seen_at > now() - interval '30 days' and l.url is not null and l.category <> 'other'
     group by 1, 2 having count(*) >= 3
  ), ins as (
    insert into public.stores (domain, category, name, kind, source)
    select d, c, left(coalesce(nm, d), 80), 'learned', 'learned' from cand
     where d ~ '^[a-z0-9.-]+\.[a-z]{2,}$' and c is not null
       and not exists (select 1 from public.source_blocks b where d = b.domain or d like '%.' || b.domain)
    on conflict do nothing
    returning 1
  )
  select count(*) into n from ins;
  return n;
end $$;

-- How well each category is covered: stores on the map, searched this week, never searched, catalogs read.
create or replace function public.store_coverage()
returns setof jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('category', s.category, 'stores', count(*),
           'learned', count(*) filter (where s.source = 'learned'),
           'searched_7d', count(*) filter (where s.last_searched_at > now() - interval '7 days'),
           'never_searched', count(*) filter (where s.last_searched_at is null),
           'shopify', count(*) filter (where s.shopify),
           'finds_14d', (select count(*) from public.listings l where l.category = s.category and l.first_seen_at > now() - interval '14 days'),
           'sites_14d', (select count(distinct public.host_of(l.url)) from public.listings l where l.category = s.category and l.first_seen_at > now() - interval '14 days'))
    from public.stores s group by s.category order by count(*) desc
$$;

revoke all on function public.claim_stores(text, int, text[]) from public, anon, authenticated;
revoke all on function public.claim_feeds(int) from public, anon, authenticated;
revoke all on function public.feed_scouts(text[]) from public, anon, authenticated;
revoke all on function public.learn_stores() from public, anon, authenticated;
revoke all on function public.store_coverage() from public, anon, authenticated;
grant execute on function public.claim_stores(text, int, text[]), public.claim_feeds(int), public.feed_scouts(text[]),
  public.learn_stores(), public.store_coverage() to service_role;

-- Open finds that were never products (droplists, calendars, encyclopedia pages, dealer search pages) leave Finds.
update public.finds f set status = 'removed'
  from public.listings l
 where l.id = f.listing_id and f.status = 'open'
   and (exists (select 1 from public.source_blocks b where public.host_of(l.url) = b.domain or public.host_of(l.url) like '%.' || b.domain)
        or (public.host_of(l.url) = 'edmunds.com' and l.url !~ '/inventory/')
        or (public.host_of(l.url) = 'kbb.com' and l.url !~ '/cars-for-sale/vehicle/'));

insert into public.stores (domain, category, name, kind) values
('nike.com','sneakers','Nike','brand'),
('adidas.com','sneakers','adidas','brand'),
('newbalance.com','sneakers','New Balance','brand'),
('asics.com','sneakers','ASICS','brand'),
('puma.com','sneakers','Puma','brand'),
('reebok.com','sneakers','Reebok','brand'),
('converse.com','sneakers','Converse','brand'),
('vans.com','sneakers','Vans','brand'),
('salomon.com','sneakers','Salomon','brand'),
('hoka.com','sneakers','HOKA','brand'),
('on.com','sneakers','On','brand'),
('footlocker.com','sneakers','Foot Locker','retailer'),
('champssports.com','sneakers','Champs Sports','retailer'),
('finishline.com','sneakers','Finish Line','retailer'),
('jdsports.com','sneakers','JD Sports','retailer'),
('dtlr.com','sneakers','DTLR','retailer'),
('shoepalace.com','sneakers','Shoe Palace','retailer'),
('hibbett.com','sneakers','Hibbett','retailer'),
('nordstrom.com','sneakers','Nordstrom','retailer'),
('endclothing.com','sneakers','END.','retailer'),
('sneakersnstuff.com','sneakers','Sneakersnstuff','boutique'),
('kith.com','sneakers','Kith','boutique'),
('cncpts.com','sneakers','Concepts','boutique'),
('bdgastore.com','sneakers','Bodega','boutique'),
('extrabutterny.com','sneakers','Extra Butter','boutique'),
('undefeated.com','sneakers','Undefeated','boutique'),
('packershoes.com','sneakers','Packer Shoes','boutique'),
('a-ma-maniere.com','sneakers','A Ma Maniere','boutique'),
('socialstatuspgh.com','sneakers','Social Status','boutique'),
('feature.com','sneakers','Feature','boutique'),
('notre-shop.com','sneakers','Notre','boutique'),
('saintalfred.com','sneakers','Saint Alfred','boutique'),
('sneakerpolitics.com','sneakers','Sneaker Politics','boutique'),
('wishatl.com','sneakers','Wish ATL','boutique'),
('lapstoneandhammer.com','sneakers','Lapstone & Hammer','boutique'),
('onenessboutique.com','sneakers','Oneness','boutique'),
('atmosusa.com','sneakers','atmos USA','boutique'),
('shopnicekicks.com','sneakers','Nice Kicks','boutique'),
('trophyroomstore.com','sneakers','Trophy Room','boutique'),
('afew-store.com','sneakers','afew','boutique'),
('overkillshop.com','sneakers','Overkill','boutique'),
('solebox.com','sneakers','Solebox','boutique'),
('slamjam.com','sneakers','Slam Jam','boutique'),
('ssense.com','sneakers','SSENSE','retailer'),
('stockx.com','sneakers','StockX','resale'),
('goat.com','sneakers','GOAT','resale'),
('flightclub.com','sneakers','Flight Club','resale'),
('stadiumgoods.com','sneakers','Stadium Goods','resale'),
('kickscrew.com','sneakers','KicksCrew','resale'),
('grailed.com','sneakers','Grailed','resale'),
('ebay.com','sneakers','eBay','resale'),
('ssense.com','apparel','SSENSE','retailer'),
('endclothing.com','apparel','END.','retailer'),
('mrporter.com','apparel','Mr Porter','retailer'),
('farfetch.com','apparel','Farfetch','retailer'),
('mytheresa.com','apparel','Mytheresa','retailer'),
('nordstrom.com','apparel','Nordstrom','retailer'),
('saksfifthavenue.com','apparel','Saks Fifth Avenue','retailer'),
('neimanmarcus.com','apparel','Neiman Marcus','retailer'),
('bergdorfgoodman.com','apparel','Bergdorf Goodman','retailer'),
('hbx.com','apparel','HBX','retailer'),
('shop-us.doverstreetmarket.com','apparel','Dover Street Market','boutique'),
('kith.com','apparel','Kith','boutique'),
('bdgastore.com','apparel','Bodega','boutique'),
('unionlosangeles.com','apparel','Union Los Angeles','boutique'),
('havenshop.com','apparel','Haven','boutique'),
('nepenthesny.com','apparel','Nepenthes New York','boutique'),
('goodhoodstore.com','apparel','Goodhood','boutique'),
('bstn.com','apparel','BSTN','boutique'),
('slamjam.com','apparel','Slam Jam','boutique'),
('aimeleondore.com','apparel','Aimé Leon Dore','brand'),
('fearofgod.com','apparel','Fear of God','brand'),
('stussy.com','apparel','Stüssy','brand'),
('supreme.com','apparel','Supreme','brand'),
('noahny.com','apparel','Noah','brand'),
('shop-usa.palaceskateboards.com','apparel','Palace','brand'),
('jjjjound.com','apparel','JJJJound','brand'),
('us.bape.com','apparel','BAPE','brand'),
('carhartt-wip.com','apparel','Carhartt WIP','brand'),
('patagonia.com','apparel','Patagonia','brand'),
('arcteryx.com','apparel','Arc''teryx','brand'),
('thenorthface.com','apparel','The North Face','brand'),
('stoneisland.com','apparel','Stone Island','brand'),
('acnestudios.com','apparel','Acne Studios','brand'),
('ourlegacy.com','apparel','Our Legacy','brand'),
('kapital-webshop.jp','apparel','Kapital','brand'),
('grailed.com','apparel','Grailed','resale'),
('depop.com','apparel','Depop','resale'),
('vinted.com','apparel','Vinted','resale'),
('poshmark.com','apparel','Poshmark','resale'),
('therealreal.com','apparel','The RealReal','resale'),
('vestiairecollective.com','apparel','Vestiaire Collective','resale'),
('mercari.com','apparel','Mercari','resale'),
('2ndstreetusa.com','apparel','2nd Street','resale'),
('stockx.com','apparel','StockX','resale'),
('ebay.com','apparel','eBay','resale'),
('luckyscent.com','fragrance','Luckyscent','boutique'),
('twistedlily.com','fragrance','Twisted Lily','boutique'),
('aedes.com','fragrance','Aedes','boutique'),
('osswaldnyc.com','fragrance','Osswald NYC','boutique'),
('ministryofscent.com','fragrance','Ministry of Scent','boutique'),
('indigoperfumery.com','fragrance','Indigo Perfumery','boutique'),
('scentsplit.com','fragrance','Scent Split','decants'),
('surrendertochance.com','fragrance','Surrender to Chance','decants'),
('fragrancenet.com','fragrance','FragranceNet','discount'),
('fragrancex.com','fragrance','FragranceX','discount'),
('jomashop.com','fragrance','Jomashop','discount'),
('maxaroma.com','fragrance','MaxAroma','discount'),
('sephora.com','fragrance','Sephora','retailer'),
('ulta.com','fragrance','Ulta','retailer'),
('nordstrom.com','fragrance','Nordstrom','retailer'),
('saksfifthavenue.com','fragrance','Saks Fifth Avenue','retailer'),
('neimanmarcus.com','fragrance','Neiman Marcus','retailer'),
('bergdorfgoodman.com','fragrance','Bergdorf Goodman','retailer'),
('bloomingdales.com','fragrance','Bloomingdale''s','retailer'),
('harrods.com','fragrance','Harrods','retailer'),
('libertylondon.com','fragrance','Liberty London','retailer'),
('lelabofragrances.com','fragrance','Le Labo','brand'),
('byredo.com','fragrance','Byredo','brand'),
('diptyqueparis.com','fragrance','Diptyque','brand'),
('creedboutique.com','fragrance','Creed','brand'),
('parfums-de-marly.com','fragrance','Parfums de Marly','brand'),
('xerjoff.com','fragrance','Xerjoff','brand'),
('amouage.com','fragrance','Amouage','brand'),
('bykilian.com','fragrance','Kilian','brand'),
('tomfordbeauty.com','fragrance','Tom Ford','brand'),
('fredericmalle.com','fragrance','Frédéric Malle','brand'),
('maisonfranciskurkdjian.com','fragrance','Maison Francis Kurkdjian','brand'),
('initioparfums.com','fragrance','Initio','brand'),
('dsanddurga.com','fragrance','D.S. & Durga','brand'),
('imaginaryauthors.com','fragrance','Imaginary Authors','brand'),
('juliettehasagun.com','fragrance','Juliette Has a Gun','brand'),
('vilhelmparfumerie.com','fragrance','Vilhelm Parfumerie','brand'),
('ellisbrooklyn.com','fragrance','Ellis Brooklyn','brand'),
('beautyhabit.com','fragrance','Beautyhabit','boutique'),
('ebay.com','fragrance','eBay','resale'),
('mercari.com','fragrance','Mercari','resale'),
('chrono24.com','watches','Chrono24','marketplace'),
('bobswatches.com','watches','Bob''s Watches','dealer'),
('hodinkee.com','watches','Hodinkee Shop','retailer'),
('the1916company.com','watches','The 1916 Company','dealer'),
('crownandcaliber.com','watches','Crown & Caliber','dealer'),
('analogshift.com','watches','Analog/Shift','dealer'),
('europeanwatch.com','watches','European Watch Co.','dealer'),
('jomashop.com','watches','Jomashop','discount'),
('teddybaldassarre.com','watches','Teddy Baldassarre','retailer'),
('windupwatchshop.com','watches','Windup Watch Shop','retailer'),
('longislandwatch.com','watches','Long Island Watch','retailer'),
('weisswatchcompany.com','watches','Weiss','brand'),
('seikowatches.com','watches','Seiko','brand'),
('grand-seiko.com','watches','Grand Seiko','brand'),
('tudorwatch.com','watches','Tudor','brand'),
('omegawatches.com','watches','Omega','brand'),
('hamiltonwatch.com','watches','Hamilton','brand'),
('swatch.com','watches','Swatch','brand'),
('nomos-glashuette.com','watches','NOMOS','brand'),
('christopherward.com','watches','Christopher Ward','brand'),
('baltic-watches.com','watches','Baltic','brand'),
('farer.com','watches','Farer','brand'),
('vaerwatches.com','watches','Vaer','brand'),
('ebay.com','watches','eBay','resale'),
('bringatrailer.com','cars','Bring a Trailer','auction'),
('carsandbids.com','cars','Cars & Bids','auction'),
('pcarmarket.com','cars','PCARMARKET','auction'),
('collectingcars.com','cars','Collecting Cars','auction'),
('hemmings.com','cars','Hemmings','classifieds'),
('autotrader.com','cars','Autotrader','classifieds'),
('cars.com','cars','Cars.com','classifieds'),
('cargurus.com','cars','CarGurus','classifieds'),
('kbb.com','cars','Kelley Blue Book','classifieds'),
('truecar.com','cars','TrueCar','classifieds'),
('carmax.com','cars','CarMax','dealer'),
('carvana.com','cars','Carvana','dealer'),
('dupontregistry.com','cars','duPont REGISTRY','classifieds'),
('classiccars.com','cars','ClassicCars.com','classifieds'),
('hagerty.com','cars','Hagerty Marketplace','auction'),
('rmsothebys.com','cars','RM Sotheby''s','auction'),
('mecum.com','cars','Mecum','auction'),
('barrett-jackson.com','cars','Barrett-Jackson','auction'),
('finder.porsche.com','cars','Porsche Finder','dealer'),
('ebay.com','cars','eBay Motors','auction'),
('1stdibs.com','furniture','1stDibs','marketplace'),
('chairish.com','furniture','Chairish','marketplace'),
('kaiyo.com','furniture','Kaiyo','resale'),
('aptdeco.com','furniture','AptDeco','resale'),
('dwr.com','furniture','Design Within Reach','retailer'),
('hermanmiller.com','furniture','Herman Miller','brand'),
('knoll.com','furniture','Knoll','brand'),
('us.hay.com','furniture','HAY','brand'),
('muuto.com','furniture','Muuto','brand'),
('vitra.com','furniture','Vitra','brand'),
('hivemodern.com','furniture','Hive Modern','retailer'),
('finnishdesignshop.com','furniture','Finnish Design Shop','retailer'),
('lumens.com','furniture','Lumens','retailer'),
('rejuvenation.com','furniture','Rejuvenation','retailer'),
('article.com','furniture','Article','brand'),
('cb2.com','furniture','CB2','retailer'),
('rh.com','furniture','RH','retailer'),
('westelm.com','furniture','West Elm','retailer'),
('midcenturywarehouse.com','furniture','Mid Century Warehouse','dealer'),
('liveauctioneers.com','furniture','LiveAuctioneers','auction'),
('invaluable.com','furniture','Invaluable','auction'),
('etsy.com','furniture','Etsy','marketplace'),
('ebay.com','furniture','eBay','resale'),
('ssense.com','accessories','SSENSE','retailer'),
('mytheresa.com','accessories','Mytheresa','retailer'),
('farfetch.com','accessories','Farfetch','retailer'),
('mrporter.com','accessories','Mr Porter','retailer'),
('nordstrom.com','accessories','Nordstrom','retailer'),
('saksfifthavenue.com','accessories','Saks Fifth Avenue','retailer'),
('therealreal.com','accessories','The RealReal','resale'),
('fashionphile.com','accessories','Fashionphile','resale'),
('rebag.com','accessories','Rebag','resale'),
('vestiairecollective.com','accessories','Vestiaire Collective','resale'),
('grailed.com','accessories','Grailed','resale'),
('depop.com','accessories','Depop','resale'),
('ray-ban.com','accessories','Ray-Ban','brand'),
('oliverpeoples.com','accessories','Oliver Peoples','brand'),
('gentlemonster.com','accessories','Gentle Monster','brand'),
('moscot.com','accessories','MOSCOT','brand'),
('ebay.com','accessories','eBay','resale'),
('stockx.com','collectibles','StockX','resale'),
('ebay.com','collectibles','eBay','resale'),
('ha.com','collectibles','Heritage Auctions','auction'),
('goldin.com','collectibles','Goldin','auction'),
('whatnot.com','collectibles','Whatnot','marketplace'),
('mercari.com','collectibles','Mercari','resale'),
('etsy.com','collectibles','Etsy','marketplace'),
('lego.com','collectibles','LEGO','brand'),
('popmart.com','collectibles','POP MART','brand'),
('funko.com','collectibles','Funko','brand'),
('kidrobot.com','collectibles','Kidrobot','brand'),
('baitme.com','collectibles','BAIT','boutique'),
('sideshow.com','collectibles','Sideshow','retailer'),
('bigbadtoystore.com','collectibles','BigBadToyStore','retailer'),
('entertainmentearth.com','collectibles','Entertainment Earth','retailer'),
('hlj.com','collectibles','HobbyLink Japan','retailer')

on conflict do nothing;
