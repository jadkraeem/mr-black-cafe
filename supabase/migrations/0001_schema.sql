-- =============================================================
-- Mr Black — 0001: الجداول والأنواع
-- =============================================================

-- مخطط خاص للدوال المساعدة (لا يُعرض عبر الـ API)
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated;

-- ---------- الأنواع ----------
create type public.staff_role   as enum ('manager', 'cashier', 'kitchen');
create type public.order_status as enum ('new', 'preparing', 'ready', 'served', 'cancelled');
create type public.discount_type as enum ('percent', 'fixed');
create type public.stock_reason as enum ('restock', 'sale', 'waste', 'adjust', 'cancel');

-- ---------- الإعدادات (صف واحد فقط) ----------
create table public.settings (
  id               smallint primary key default 1 check (id = 1),
  cafe_name        text not null default 'Mr Black' check (char_length(cafe_name) between 1 and 60),
  currency         text not null default 'ل.س'      check (char_length(currency) between 1 and 10),
  tax_percent      numeric(5,2) not null default 0  check (tax_percent between 0 and 100),
  service_percent  numeric(5,2) not null default 0  check (service_percent between 0 and 100),
  late_minutes     int not null default 15          check (late_minutes between 1 and 240),
  timezone         text not null default 'Asia/Damascus',
  updated_at       timestamptz not null default now()
);
insert into public.settings default values;

-- ---------- الموظفون ----------
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null check (char_length(full_name) between 1 and 80),
  role        public.staff_role not null default 'cashier',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- الأقسام ----------
create table public.categories (
  id          bigint generated always as identity primary key,
  name        text not null check (char_length(name) between 1 and 60),
  sort        int not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- الأصناف ----------
create table public.menu_items (
  id                   bigint generated always as identity primary key,
  category_id          bigint not null references public.categories(id) on delete restrict,
  name                 text not null check (char_length(name) between 1 and 80),
  description          text check (description is null or char_length(description) <= 300),
  price                bigint not null check (price between 0 and 100000000),
  image_url            text check (image_url is null or (image_url ~ '^https://[^\s"''<>]+$' and char_length(image_url) <= 500)),
  available            boolean not null default true,
  track_stock          boolean not null default false,
  stock_qty            int not null default 0 check (stock_qty >= 0),
  low_stock_threshold  int not null default 5 check (low_stock_threshold >= 0),
  sort                 int not null default 0,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index menu_items_category_idx on public.menu_items(category_id);

-- ---------- الطاولات ----------
create table public.cafe_tables (
  id          bigint generated always as identity primary key,
  number      int not null unique check (number between 1 and 999),
  label       text check (label is null or char_length(label) <= 40),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- العروض ----------
create table public.offers (
  id              bigint generated always as identity primary key,
  title           text not null check (char_length(title) between 1 and 80),
  description     text check (description is null or char_length(description) <= 300),
  discount_type   public.discount_type not null,
  discount_value  numeric(12,2) not null check (discount_value > 0),
  item_id         bigint references public.menu_items(id) on delete cascade,
  category_id     bigint references public.categories(id) on delete cascade,
  starts_at       timestamptz,
  ends_at         timestamptz,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  constraint offers_single_target check (not (item_id is not null and category_id is not null)),
  constraint offers_percent_max  check (discount_type <> 'percent' or discount_value <= 100),
  constraint offers_dates        check (ends_at is null or starts_at is null or ends_at > starts_at)
);
create index offers_item_idx on public.offers(item_id);
create index offers_category_idx on public.offers(category_id);

-- ---------- الطلبات ----------
create table public.orders (
  id               bigint generated always as identity primary key,
  table_id         bigint not null references public.cafe_tables(id) on delete restrict,
  table_number     int not null,
  status           public.order_status not null default 'new',
  subtotal         bigint not null default 0,
  discount         bigint not null default 0,
  service          bigint not null default 0,
  tax              bigint not null default 0,
  total            bigint not null default 0,
  service_percent  numeric(5,2) not null default 0,
  tax_percent      numeric(5,2) not null default 0,
  created_at       timestamptz not null default now(),
  started_at       timestamptz,
  ready_at         timestamptz,
  served_at        timestamptz,
  cancelled_at     timestamptz,
  updated_by       uuid references auth.users(id) on delete set null
);
create index orders_created_idx on public.orders(created_at desc);
create index orders_status_idx  on public.orders(status);
create index orders_table_idx   on public.orders(table_id, created_at desc);
create index orders_updated_by_idx on public.orders(updated_by);

create table public.order_items (
  id             bigint generated always as identity primary key,
  order_id       bigint not null references public.orders(id) on delete cascade,
  item_id        bigint references public.menu_items(id) on delete set null,
  item_name      text not null,
  category_name  text,
  unit_price     bigint not null,
  unit_discount  bigint not null default 0,
  qty            int not null check (qty between 1 and 50),
  note           text check (note is null or char_length(note) <= 200),
  line_total     bigint not null
);
create index order_items_order_idx on public.order_items(order_id);
create index order_items_item_idx  on public.order_items(item_id);

-- ---------- حركات المخزون ----------
create table public.stock_movements (
  id          bigint generated always as identity primary key,
  item_id     bigint not null references public.menu_items(id) on delete cascade,
  change      int not null check (change <> 0),
  reason      public.stock_reason not null,
  note        text check (note is null or char_length(note) <= 200),
  order_id    bigint references public.orders(id) on delete set null,
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index stock_movements_item_idx    on public.stock_movements(item_id, created_at);
create index stock_movements_order_idx   on public.stock_movements(order_id);
create index stock_movements_created_by_idx on public.stock_movements(created_by);

-- ---------- updated_at تلقائي ----------
create or replace function private.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger menu_items_touch before update on public.menu_items
  for each row execute function private.touch_updated_at();
create trigger settings_touch before update on public.settings
  for each row execute function private.touch_updated_at();
