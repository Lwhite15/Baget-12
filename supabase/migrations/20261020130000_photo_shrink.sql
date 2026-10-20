-- Existing product photos over 250 KB get a phone-sized copy written over them (same address, so nothing breaks).
create table if not exists public.photo_shrink_done (name text primary key, at timestamptz not null default now());
alter table public.photo_shrink_done enable row level security;
revoke all on public.photo_shrink_done from anon, authenticated;
grant select, insert on public.photo_shrink_done to service_role;

create or replace function public.large_photos(p_limit int default 10)
returns table (name text, mimetype text, size bigint) language plpgsql stable security definer set search_path = public, storage as $$
begin
  -- plpgsql so the storage tables are only looked up when this runs (the test database has none).
  return query
  select o.name::text, (o.metadata ->> 'mimetype')::text, (o.metadata ->> 'size')::bigint
    from storage.objects o
   where o.bucket_id = 'product-photos'
     and (o.metadata ->> 'size')::bigint > 250000
     and o.metadata ->> 'mimetype' in ('image/jpeg', 'image/png')
     and not exists (select 1 from public.photo_shrink_done d where d.name = o.name)
   order by (o.metadata ->> 'size')::bigint desc
   limit greatest(1, least(p_limit, 50));
end $$;
revoke all on function public.large_photos(int) from public, anon, authenticated;
grant execute on function public.large_photos(int) to service_role;
