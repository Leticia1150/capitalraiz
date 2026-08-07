-- ============================================================
-- CAPITAL RAÍZ — Marketplace + Admin + Métricas
-- Ejecutar UNA VEZ en Supabase > SQL Editor.
-- No inserta publicaciones de ejemplo: el marketplace inicia vacío.
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1. ADMINISTRADORES
-- ------------------------------------------------------------
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

drop policy if exists "Admin can read own authorization" on public.admin_users;
create policy "Admin can read own authorization"
on public.admin_users
for select
to authenticated
using (auth.uid() = user_id);

grant select on public.admin_users to authenticated;

-- Usuario mostrado en la captura proporcionada.
insert into public.admin_users (user_id)
values ('331c6b51-5b9c-4a96-a65b-5a9338da25cf')
on conflict (user_id) do nothing;

create or replace function public.is_marketplace_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.user_id = auth.uid()
  );
$$;

revoke all on function public.is_marketplace_admin() from public;
grant execute on function public.is_marketplace_admin() to authenticated;

-- ------------------------------------------------------------
-- 2. PUBLICACIONES DEL MARKETPLACE
-- ------------------------------------------------------------
create table if not exists public.marketplace_items (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  category text,
  location text,
  status text,
  summary text,
  description text,

  min_investment numeric(14,2),
  term_months integer,
  projected_return numeric(8,2),
  total_investment numeric(14,2),
  projected_sale numeric(14,2),
  projected_profit numeric(14,2),
  projected_margin numeric(8,2),

  cta_label text,
  cta_url text,

  featured boolean not null default false,
  published boolean not null default false,
  display_order integer not null default 0,

  images text[] not null default '{}'::text[],
  image_paths text[] not null default '{}'::text[],

  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint marketplace_items_term_nonnegative check (term_months is null or term_months >= 0),
  constraint marketplace_items_min_nonnegative check (min_investment is null or min_investment >= 0),
  constraint marketplace_items_total_nonnegative check (total_investment is null or total_investment >= 0),
  constraint marketplace_items_sale_nonnegative check (projected_sale is null or projected_sale >= 0),
  constraint marketplace_items_image_count check (coalesce(array_length(images, 1), 0) <= 8),
  constraint marketplace_items_path_count check (coalesce(array_length(image_paths, 1), 0) <= 8)
);

create index if not exists idx_marketplace_items_public
  on public.marketplace_items (published, featured desc, display_order asc, created_at desc);

create or replace function public.set_marketplace_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_marketplace_items_updated_at on public.marketplace_items;
create trigger trg_marketplace_items_updated_at
before update on public.marketplace_items
for each row
execute function public.set_marketplace_updated_at();

alter table public.marketplace_items enable row level security;

drop policy if exists "Public can read published marketplace items" on public.marketplace_items;
create policy "Public can read published marketplace items"
on public.marketplace_items
for select
to anon, authenticated
using (published = true);

drop policy if exists "Admins can read all marketplace items" on public.marketplace_items;
create policy "Admins can read all marketplace items"
on public.marketplace_items
for select
to authenticated
using (public.is_marketplace_admin());

drop policy if exists "Admins can insert marketplace items" on public.marketplace_items;
create policy "Admins can insert marketplace items"
on public.marketplace_items
for insert
to authenticated
with check (public.is_marketplace_admin());

drop policy if exists "Admins can update marketplace items" on public.marketplace_items;
create policy "Admins can update marketplace items"
on public.marketplace_items
for update
to authenticated
using (public.is_marketplace_admin())
with check (public.is_marketplace_admin());

drop policy if exists "Admins can delete marketplace items" on public.marketplace_items;
create policy "Admins can delete marketplace items"
on public.marketplace_items
for delete
to authenticated
using (public.is_marketplace_admin());

grant select on public.marketplace_items to anon, authenticated;
grant insert, update, delete on public.marketplace_items to authenticated;

-- ------------------------------------------------------------
-- 3. ANALÍTICA DE TRÁFICO
-- ------------------------------------------------------------
create table if not exists public.analytics_events (
  id bigint generated by default as identity primary key,
  created_at timestamptz not null default now(),
  event_name text not null,
  path text,
  item_id uuid references public.marketplace_items(id) on delete set null,
  visitor_id text not null,
  session_id text not null,
  referrer text,
  user_agent text,
  metadata jsonb not null default '{}'::jsonb,

  constraint analytics_event_name_allowed
    check (event_name in ('page_view','item_view','cta_click','search','filter')),
  constraint analytics_visitor_length check (char_length(visitor_id) between 8 and 100),
  constraint analytics_session_length check (char_length(session_id) between 8 and 100)
);

create index if not exists idx_analytics_created_at
  on public.analytics_events (created_at desc);

create index if not exists idx_analytics_event_created
  on public.analytics_events (event_name, created_at desc);

create index if not exists idx_analytics_item_created
  on public.analytics_events (item_id, created_at desc)
  where item_id is not null;

alter table public.analytics_events enable row level security;

drop policy if exists "Public can insert analytics events" on public.analytics_events;
create policy "Public can insert analytics events"
on public.analytics_events
for insert
to anon, authenticated
with check (
  event_name in ('page_view','item_view','cta_click','search','filter')
  and char_length(visitor_id) between 8 and 100
  and char_length(session_id) between 8 and 100
);

drop policy if exists "Admins can read analytics events" on public.analytics_events;
create policy "Admins can read analytics events"
on public.analytics_events
for select
to authenticated
using (public.is_marketplace_admin());

grant insert on public.analytics_events to anon, authenticated;
grant select on public.analytics_events to authenticated;
grant usage, select on sequence public.analytics_events_id_seq to anon, authenticated;

-- ------------------------------------------------------------
-- 4. STORAGE DE IMÁGENES
-- ------------------------------------------------------------
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'marketplace-images',
  'marketplace-images',
  true,
  8388608,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public can read marketplace images" on storage.objects;
create policy "Public can read marketplace images"
on storage.objects
for select
to public
using (bucket_id = 'marketplace-images');

drop policy if exists "Admins can upload marketplace images" on storage.objects;
create policy "Admins can upload marketplace images"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'marketplace-images'
  and public.is_marketplace_admin()
);

drop policy if exists "Admins can update marketplace images" on storage.objects;
create policy "Admins can update marketplace images"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'marketplace-images'
  and public.is_marketplace_admin()
)
with check (
  bucket_id = 'marketplace-images'
  and public.is_marketplace_admin()
);

drop policy if exists "Admins can delete marketplace images" on storage.objects;
create policy "Admins can delete marketplace images"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'marketplace-images'
  and public.is_marketplace_admin()
);

-- ------------------------------------------------------------
-- 5. FUNCIONES DE MÉTRICAS
-- Las consultas agregadas se ejecutan solo para administradores.
-- ------------------------------------------------------------
create or replace function public.marketplace_metrics(p_days integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_since timestamptz;
  v_page_views bigint := 0;
  v_unique_visitors bigint := 0;
  v_sessions bigint := 0;
  v_item_views bigint := 0;
  v_cta_clicks bigint := 0;
  v_searches bigint := 0;
  v_published bigint := 0;
  v_conversion numeric := 0;
begin
  if not public.is_marketplace_admin() then
    raise exception 'Acceso no autorizado';
  end if;

  v_since := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));

  select
    count(*) filter (where event_name = 'page_view'),
    count(distinct visitor_id) filter (where event_name = 'page_view'),
    count(distinct session_id) filter (where event_name = 'page_view'),
    count(*) filter (where event_name = 'item_view'),
    count(*) filter (where event_name = 'cta_click'),
    count(*) filter (where event_name = 'search')
  into
    v_page_views,
    v_unique_visitors,
    v_sessions,
    v_item_views,
    v_cta_clicks,
    v_searches
  from public.analytics_events
  where created_at >= v_since;

  select count(*)
  into v_published
  from public.marketplace_items
  where published = true;

  if v_page_views > 0 then
    v_conversion := round((v_cta_clicks::numeric / v_page_views::numeric) * 100, 2);
  end if;

  return jsonb_build_object(
    'page_views', v_page_views,
    'unique_visitors', v_unique_visitors,
    'sessions', v_sessions,
    'item_views', v_item_views,
    'cta_clicks', v_cta_clicks,
    'searches', v_searches,
    'published_items', v_published,
    'conversion_rate', v_conversion
  );
end;
$$;

create or replace function public.marketplace_daily_traffic(p_days integer default 30)
returns table (
  day date,
  page_views bigint,
  unique_visitors bigint,
  item_views bigint,
  cta_clicks bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
begin
  if not public.is_marketplace_admin() then
    raise exception 'Acceso no autorizado';
  end if;

  return query
  with calendar as (
    select generate_series(
      current_date - (v_days - 1),
      current_date,
      interval '1 day'
    )::date as day
  ),
  stats as (
    select
      (e.created_at at time zone 'America/Guayaquil')::date as day,
      count(*) filter (where e.event_name = 'page_view')::bigint as page_views,
      count(distinct e.visitor_id) filter (where e.event_name = 'page_view')::bigint as unique_visitors,
      count(*) filter (where e.event_name = 'item_view')::bigint as item_views,
      count(*) filter (where e.event_name = 'cta_click')::bigint as cta_clicks
    from public.analytics_events e
    where e.created_at >= now() - make_interval(days => v_days)
    group by 1
  )
  select
    c.day,
    coalesce(s.page_views, 0)::bigint,
    coalesce(s.unique_visitors, 0)::bigint,
    coalesce(s.item_views, 0)::bigint,
    coalesce(s.cta_clicks, 0)::bigint
  from calendar c
  left join stats s on s.day = c.day
  order by c.day;
end;
$$;

create or replace function public.marketplace_top_items(
  p_days integer default 30,
  p_limit integer default 7
)
returns table (
  item_id uuid,
  title text,
  views bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_limit integer := greatest(1, least(coalesce(p_limit, 7), 25));
begin
  if not public.is_marketplace_admin() then
    raise exception 'Acceso no autorizado';
  end if;

  return query
  select
    i.id,
    i.title,
    count(e.id)::bigint as views
  from public.marketplace_items i
  left join public.analytics_events e
    on e.item_id = i.id
   and e.event_name = 'item_view'
   and e.created_at >= now() - make_interval(days => v_days)
  group by i.id, i.title
  order by count(e.id) desc, i.updated_at desc
  limit v_limit;
end;
$$;

create or replace function public.marketplace_sources(
  p_days integer default 30,
  p_limit integer default 7
)
returns table (
  source text,
  visits bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_limit integer := greatest(1, least(coalesce(p_limit, 7), 25));
begin
  if not public.is_marketplace_admin() then
    raise exception 'Acceso no autorizado';
  end if;

  return query
  select
    coalesce(nullif(e.metadata->>'source', ''), 'Directo') as source,
    count(*)::bigint as visits
  from public.analytics_events e
  where e.event_name = 'page_view'
    and e.created_at >= now() - make_interval(days => v_days)
  group by 1
  order by count(*) desc
  limit v_limit;
end;
$$;

create or replace function public.marketplace_devices(p_days integer default 30)
returns table (
  device text,
  visits bigint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
begin
  if not public.is_marketplace_admin() then
    raise exception 'Acceso no autorizado';
  end if;

  return query
  select
    coalesce(nullif(e.metadata->>'device', ''), 'Sin dato') as device,
    count(*)::bigint as visits
  from public.analytics_events e
  where e.event_name = 'page_view'
    and e.created_at >= now() - make_interval(days => v_days)
  group by 1
  order by count(*) desc;
end;
$$;

revoke all on function public.marketplace_metrics(integer) from public;
revoke all on function public.marketplace_daily_traffic(integer) from public;
revoke all on function public.marketplace_top_items(integer, integer) from public;
revoke all on function public.marketplace_sources(integer, integer) from public;
revoke all on function public.marketplace_devices(integer) from public;

grant execute on function public.marketplace_metrics(integer) to authenticated;
grant execute on function public.marketplace_daily_traffic(integer) to authenticated;
grant execute on function public.marketplace_top_items(integer, integer) to authenticated;
grant execute on function public.marketplace_sources(integer, integer) to authenticated;
grant execute on function public.marketplace_devices(integer) to authenticated;

-- FIN
