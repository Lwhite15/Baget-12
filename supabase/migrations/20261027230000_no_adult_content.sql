-- Baget never hunts porn or other adult content. The server checks every mission and listing (_shared/adult.ts);
-- this is the database's backstop with the same word list: no scout can be set up for it, and no adult listing can
-- become a find, whichever way it's written.

create or replace function public.is_adult(t text) returns boolean language sql immutable as $$
  select coalesce(t, '') ~* ('\y(' ||
    'porn\w*|xxx(?!-?\s?l)|nsfw|onlyfans|only fans|fansly|hentai|sex ?toys?|sex ?dolls?|sex ?tapes?|sex ?shops?|' ||
    'adult ?toys?|adult ?videos?|adult ?films?|adult ?entertainment|adult ?content|dildos?|vibrators?|fleshlights?|butt ?plugs?|cock ?rings?|' ||
    'bdsm|bondage|erotica?|camgirls?|cam ?girls?|cam ?sites?|webcam ?models?|strip ?clubs?|lap ?dances?|escort ?services?|nudes|' ||
    'masturbat\w*|orgasm\w*|playboy ?magazine|penthouse ?magazine|hustler ?magazine' || ')\y')
$$;

create or replace function public.is_adult_host(url text) returns boolean language sql immutable as $$
  select coalesce(substring(url from '^https?://([^/?#]+)'), '') ~*
    '(porn|xxx|xvideos|xnxx|xhamster|hentai|onlyfans|fansly|chaturbate|stripchat|bongacams|livejasmin|myfreecams|camsoda|brazzers|redtube|spankbang|adultempire|adameve|lovehoney|fleshlight|bellesa|manyvids|clips4sale)'
$$;

-- Scouts: refuse a mission, name or taste list that's adult content.
create or replace function public.agents_no_adult() returns trigger language plpgsql as $$
begin
  if public.is_adult(concat_ws(' ', new.name, new.mission_custom, array_to_string(new.keywords, ' '), array_to_string(new.traits, ' '),
                               array_to_string(new.makers, ' '), array_to_string(new.creators, ' '))) then
    raise exception 'Baget doesn''t hunt adult content. Try something else you''re into.' using errcode = '23514';
  end if;
  return new;
end $$;
drop trigger if exists agents_no_adult on public.agents;
create trigger agents_no_adult before insert or update of name, mission_custom, keywords, traits, makers, creators on public.agents
  for each row execute function public.agents_no_adult();

-- Finds: an adult listing is quietly dropped instead of saved.
create or replace function public.finds_no_adult() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.listings l where l.id = new.listing_id
               and (public.is_adult(concat_ws(' ', l.title, l.brand, l.source, array_to_string(l.traits, ' '))) or public.is_adult_host(l.url))) then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists finds_no_adult on public.finds;
create trigger finds_no_adult before insert on public.finds for each row execute function public.finds_no_adult();
