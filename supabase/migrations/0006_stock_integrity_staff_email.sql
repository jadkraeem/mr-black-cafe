-- =============================================================
-- Mr Black — 0006: سلامة المخزون + بريد الموظف
-- =============================================================

-- المخزون لا يتغيّر إلا عبر الدوال المسجِّلة للحركة (adjust_stock / place_order / set_order_status)
revoke insert, update on public.menu_items from authenticated;
grant insert (category_id, name, description, price, image_url, available, track_stock, low_stock_threshold, sort)
  on public.menu_items to authenticated;
grant update (category_id, name, description, price, image_url, available, track_stock, low_stock_threshold, sort)
  on public.menu_items to authenticated;

-- بريد الموظف للعرض في لوحة المدير
alter table public.profiles add column if not exists email text
  check (email is null or char_length(email) <= 254);
update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is null;

-- من المتصفح: المدير يعدّل الاسم والدور فقط.
-- التفعيل/التعطيل والبريد عبر Edge Function (لأنها تحظر الحساب في Auth أيضاً).
revoke update on public.profiles from authenticated;
grant update (full_name, role) on public.profiles to authenticated;
