-- =============================================================
-- Mr Black — 0002: الصلاحيات و RLS
-- =============================================================

-- ---------- دوال معرفة الدور ----------
create or replace function private.staff_role()
returns public.staff_role
language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p where p.id = auth.uid() and p.active
$$;

create or replace function private.is_staff()
returns boolean
language sql stable security definer set search_path = '' as $$
  select private.staff_role() is not null
$$;

create or replace function private.is_manager()
returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.staff_role() = 'manager', false)
$$;

-- هل القسم فعّال؟ (حتى لا يحتاج الزبون صلاحية قراءة عمود active)
create or replace function private.category_active(p_id bigint)
returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select c.active from public.categories c where c.id = p_id), false)
$$;

revoke all on function private.staff_role(), private.is_staff(), private.is_manager(), private.category_active(bigint) from public;
grant execute on function private.staff_role(), private.is_staff(), private.is_manager(), private.category_active(bigint) to anon, authenticated;
revoke all on function private.touch_updated_at() from public;

-- ---------- حماية آخر مدير ----------
create or replace function private.protect_last_manager()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.role = 'manager' and old.active
     and (tg_op = 'DELETE' or new.role <> 'manager' or not new.active)
     and not exists (select 1 from public.profiles p
                     where p.role = 'manager' and p.active and p.id <> old.id) then
    raise exception 'لا يمكن إزالة أو تعطيل آخر مدير نشط في النظام.';
  end if;
  return coalesce(new, old);
end $$;
revoke all on function private.protect_last_manager() from public;

create trigger profiles_protect_last_manager
  before update or delete on public.profiles
  for each row execute function private.protect_last_manager();

-- ---------- الامتيازات الأساسية ----------
-- نسحب كل شيء من anon ثم نمنح أعمدة محددة فقط
revoke all on all tables in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- الطلبات والمخزون: لا كتابة مباشرة إطلاقاً (فقط عبر دوال RPC)
revoke insert, update, delete on public.orders, public.order_items, public.stock_movements from authenticated;
-- الإعدادات: لا إضافة ولا حذف
revoke insert, delete on public.settings from authenticated;
-- الموظفون: الإضافة عبر Edge Function فقط
revoke insert on public.profiles from authenticated;

-- ما يقرؤه الزبون (anon): أعمدة المنيو والعروض فقط
grant select (id, name, sort) on public.categories to anon;
grant select (id, category_id, name, description, price, image_url, sort) on public.menu_items to anon;
grant select (id, title, description, discount_type, discount_value, item_id, category_id, ends_at) on public.offers to anon;

-- ---------- تفعيل RLS على كل الجداول ----------
alter table public.settings        enable row level security;
alter table public.profiles        enable row level security;
alter table public.categories      enable row level security;
alter table public.menu_items      enable row level security;
alter table public.cafe_tables     enable row level security;
alter table public.offers          enable row level security;
alter table public.orders          enable row level security;
alter table public.order_items     enable row level security;
alter table public.stock_movements enable row level security;

-- settings
create policy settings_staff_read on public.settings
  for select to authenticated using ((select private.is_staff()));
create policy settings_manager_update on public.settings
  for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));

-- profiles
create policy profiles_read on public.profiles
  for select to authenticated using (id = (select auth.uid()) or (select private.is_manager()));
create policy profiles_manager_update on public.profiles
  for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));
create policy profiles_manager_delete on public.profiles
  for delete to authenticated using ((select private.is_manager()) and id <> (select auth.uid()));

-- categories
create policy categories_public_read on public.categories
  for select to anon using (active);
create policy categories_auth_read on public.categories
  for select to authenticated using (active or (select private.is_staff()));
create policy categories_manager_insert on public.categories
  for insert to authenticated with check ((select private.is_manager()));
create policy categories_manager_update on public.categories
  for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));
create policy categories_manager_delete on public.categories
  for delete to authenticated using ((select private.is_manager()));

-- menu_items: الزبون يرى المتوفر فقط (وغير النافد من المخزون) ضمن قسم فعّال
create policy menu_public_read on public.menu_items
  for select to anon using (
    available and (not track_stock or stock_qty > 0) and private.category_active(category_id));
create policy menu_staff_read on public.menu_items
  for select to authenticated using ((select private.is_staff()));
create policy menu_manager_insert on public.menu_items
  for insert to authenticated with check ((select private.is_manager()));
create policy menu_manager_update on public.menu_items
  for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));
create policy menu_manager_delete on public.menu_items
  for delete to authenticated using ((select private.is_manager()));

-- cafe_tables
create policy tables_staff_read on public.cafe_tables
  for select to authenticated using ((select private.is_staff()));
create policy tables_manager_insert on public.cafe_tables
  for insert to authenticated with check ((select private.is_manager()));
create policy tables_manager_update on public.cafe_tables
  for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));
create policy tables_manager_delete on public.cafe_tables
  for delete to authenticated using ((select private.is_manager()));

-- offers: الزبون يرى العروض الفعّالة حالياً فقط
create policy offers_public_read on public.offers
  for select to anon using (
    active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()));
create policy offers_staff_read on public.offers
  for select to authenticated using ((select private.is_staff()));
create policy offers_manager_insert on public.offers
  for insert to authenticated with check ((select private.is_manager()));
create policy offers_manager_update on public.offers
  for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));
create policy offers_manager_delete on public.offers
  for delete to authenticated using ((select private.is_manager()));

-- orders / order_items: قراءة للموظفين فقط، التعديل عبر RPC
create policy orders_staff_read on public.orders
  for select to authenticated using ((select private.is_staff()));
create policy order_items_staff_read on public.order_items
  for select to authenticated using ((select private.is_staff()));

-- stock_movements: المدير فقط
create policy stock_manager_read on public.stock_movements
  for select to authenticated using ((select private.is_manager()));

-- ---------- التحديث اللحظي ----------
alter publication supabase_realtime add table public.orders, public.order_items;
