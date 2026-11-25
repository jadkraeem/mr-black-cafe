-- =============================================================
-- Mr Black — 0008: صلاحيات صريحة للموظفين المسجّلين (authenticated)
-- مشاريع Supabase الجديدة لا تمنح صلاحيات الجداول تلقائياً.
-- الصلاحية هنا تسمح بنوع العملية فقط؛ سياسات RLS تحدد من يرى ماذا.
-- =============================================================

-- قراءة: كل الجداول (RLS: الموظف الفعّال فقط، والمخزون والموظفون للمدير)
grant select on public.settings, public.profiles, public.categories, public.menu_items,
               public.cafe_tables, public.offers, public.orders, public.order_items,
               public.stock_movements to authenticated;

-- الإعدادات: المدير يعدّل الحقول العامة (قفل الواي فاي عبر set_wifi_lock فقط)
grant update (cafe_name, currency, tax_percent, service_percent, late_minutes)
  on public.settings to authenticated;

-- الموظفون: المدير يعدّل الاسم والدور ويحذف (الإضافة والتعطيل عبر Edge Function)
grant update (full_name, role), delete on public.profiles to authenticated;

-- المنيو والطاولات والعروض: إدارة المدير
grant insert, update, delete on public.categories, public.cafe_tables, public.offers to authenticated;

-- الأصناف: بدون stock_qty (المخزون عبر adjust_stock فقط)
grant insert (category_id, name, description, price, image_url, available, track_stock, low_stock_threshold, sort),
      update (category_id, name, description, price, image_url, available, track_stock, low_stock_threshold, sort),
      delete
  on public.menu_items to authenticated;

-- orders / order_items / stock_movements: قراءة فقط؛ الكتابة عبر دوال RPC
