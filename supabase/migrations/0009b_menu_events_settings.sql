-- =============================================================
-- Mr Black — 0009: نفد حالياً + اسم إنكليزي + فعاليات + عروض بلا خصم + بيانات الغلاف
-- (0009a منفصل: alter type public.discount_type add value 'none')
-- =============================================================

-- ---------- الأصناف ----------
alter table public.menu_items
  add column if not exists name_en text check (name_en is null or char_length(name_en) <= 80);
alter table public.menu_items
  add column if not exists sold_out boolean generated always as (not available or (track_stock and stock_qty <= 0)) stored;

-- الزبون يرى كل أصناف الأقسام الفعّالة، والموقوف يظهر "نفد حالياً" (الطلب عليه يُرفض في place_order)
alter policy menu_public_read on public.menu_items
  using (private.category_active(category_id) and private.network_ok());
grant select (name_en, sold_out) on public.menu_items to anon;
grant select (name_en, sold_out) on public.menu_items to authenticated;
grant insert (name_en), update (name_en) on public.menu_items to authenticated;

-- ---------- العروض: نوع "none" = إعلان بدون خصم ----------
create or replace function private.item_unit_discount(p_item_id bigint, p_category_id bigint, p_price bigint)
returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce(max(least(p_price,
           case when o.discount_type = 'percent'
                then round(p_price * o.discount_value / 100)::bigint
                else round(o.discount_value)::bigint end)), 0)
  from public.offers o
  where o.active
    and o.discount_type <> 'none'
    and (o.starts_at is null or o.starts_at <= now())
    and (o.ends_at   is null or o.ends_at   >  now())
    and (o.item_id = p_item_id
         or o.category_id = p_category_id
         or (o.item_id is null and o.category_id is null))
$$;
revoke all on function private.item_unit_discount(bigint, bigint, bigint) from public, anon, authenticated;

-- ---------- الإعدادات: نصوص الغلاف والفوتر ----------
alter table public.settings
  add column if not exists tagline text not null default 'أكثر من مجرد قهوة..' check (char_length(tagline) <= 120),
  add column if not exists about text check (about is null or char_length(about) <= 300),
  add column if not exists address text check (address is null or char_length(address) <= 150),
  add column if not exists phone text check (phone is null or char_length(phone) <= 40),
  add column if not exists opening_hours text check (opening_hours is null or char_length(opening_hours) <= 80);
grant update (tagline, about, address, phone, opening_hours) on public.settings to authenticated;

create or replace function public.menu_context(p_table int)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'cafe_name',       s.cafe_name,
    'currency',        s.currency,
    'tax_percent',     s.tax_percent,
    'service_percent', s.service_percent,
    'tagline',         s.tagline,
    'about',           s.about,
    'address',         s.address,
    'phone',           s.phone,
    'opening_hours',   s.opening_hours,
    'network_ok',      private.network_ok(),
    'table_valid',     exists (select 1 from public.cafe_tables t where t.number = p_table and t.active))
  from public.settings s where s.id = 1
$$;

-- ---------- الفعاليات ----------
create table if not exists public.events (
  id           bigint generated always as identity primary key,
  title        text not null check (char_length(title) between 1 and 80),
  description  text check (description is null or char_length(description) <= 300),
  starts_at    timestamptz,
  ends_at      timestamptz,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  constraint events_dates check (ends_at is null or starts_at is null or ends_at > starts_at)
);
alter table public.events enable row level security;

create policy events_public_read on public.events
  for select to anon using (active and (ends_at is null or ends_at > now()) and private.network_ok());
create policy events_staff_read on public.events
  for select to authenticated using ((select private.is_staff()));
create policy events_staff_insert on public.events
  for insert to authenticated with check ((select private.staff_role()) in ('manager', 'cashier'));
create policy events_staff_update on public.events
  for update to authenticated using ((select private.staff_role()) in ('manager', 'cashier'))
  with check ((select private.staff_role()) in ('manager', 'cashier'));
create policy events_staff_delete on public.events
  for delete to authenticated using ((select private.staff_role()) in ('manager', 'cashier'));

revoke all on public.events from anon, authenticated;
grant select (id, title, description, starts_at, ends_at) on public.events to anon;
grant select, insert, update, delete on public.events to authenticated;
