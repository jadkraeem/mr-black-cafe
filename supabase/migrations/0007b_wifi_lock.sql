-- =============================================================
-- Mr Black — 0007: قفل شبكة الواي فاي
-- عند التفعيل: لا يرى الزبون المنيو ولا يستطيع الطلب إلا من شبكة الكافيه.
-- عنوان الزبون يُقرأ من ترويسة cf-connecting-ip التي تضعها Cloudflare
-- (تم اختبار أنها لا تُزوَّر؛ أما x-forwarded-for فقابلة للتزوير ولا تُستخدم).
-- =============================================================

alter table public.settings
  add column if not exists wifi_lock boolean not null default false,
  add column if not exists allowed_networks cidr[] not null default '{}'
    check (cardinality(allowed_networks) <= 10);

-- ---------- عنوان المتصل الحقيقي ----------
create or replace function private.client_ip()
returns inet
language plpgsql stable security definer set search_path = '' as $$
declare v text;
begin
  v := nullif(btrim(current_setting('request.headers', true)::json->>'cf-connecting-ip'), '');
  if v is null then return null; end if;
  return v::inet;
exception when others then
  return null;
end $$;

-- ---------- هل المتصل على شبكة مسموحة؟ (يُغلق عند الشك) ----------
create or replace function private.network_ok()
returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select (not s.wifi_lock)
        or exists (select 1 from unnest(s.allowed_networks) n where private.client_ip() <<= n)
      from public.settings s where s.id = 1), false)
$$;

revoke all on function private.client_ip(), private.network_ok() from public;
grant execute on function private.client_ip(), private.network_ok() to anon, authenticated;

-- ---------- قراءة المنيو للزبون: فقط من الشبكة المسموحة ----------
alter policy categories_public_read on public.categories
  using (active and private.network_ok());
alter policy menu_public_read on public.menu_items
  using (available and (not track_stock or stock_qty > 0) and private.category_active(category_id) and private.network_ok());
alter policy offers_public_read on public.offers
  using (active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now()) and private.network_ok());

-- ---------- معلومات صفحة الزبون (+ حالة الشبكة) ----------
create or replace function public.menu_context(p_table int)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'cafe_name',       s.cafe_name,
    'currency',        s.currency,
    'tax_percent',     s.tax_percent,
    'service_percent', s.service_percent,
    'network_ok',      private.network_ok(),
    'table_valid',     exists (select 1 from public.cafe_tables t where t.number = p_table and t.active))
  from public.settings s where s.id = 1
$$;

-- ---------- معاينة السعر ----------
create or replace function public.quote_order(p_items jsonb)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lines jsonb;
begin
  if not private.network_ok() then
    raise exception 'الطلب متاح فقط من شبكة واي فاي الكافيه. اتصل بالشبكة ثم أعد المحاولة.';
  end if;
  v_lines := private.price_lines(p_items);
  return jsonb_build_object('lines', v_lines) || private.order_totals(v_lines);
end $$;

-- ---------- إرسال الطلب (+ فحص الشبكة) ----------
create or replace function public.place_order(p_table int, p_items jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_table    public.cafe_tables;
  v_lines    jsonb;
  v_tot      jsonb;
  v_order_id bigint;
  v_created  timestamptz;
begin
  if not private.network_ok() then
    raise exception 'الطلب متاح فقط من شبكة واي فاي الكافيه. اتصل بالشبكة ثم أعد المحاولة.';
  end if;

  select * into v_table from public.cafe_tables where number = p_table and active;
  if not found then
    raise exception 'رقم الطاولة غير صالح. امسح رمز QR الموجود على طاولتك مرة أخرى.';
  end if;

  if (select count(*) from public.orders
       where table_id = v_table.id and created_at > now() - interval '1 minute') >= 3 then
    raise exception 'تم إرسال طلبات كثيرة من هذه الطاولة خلال دقيقة. انتظر قليلاً ثم أعد المحاولة.';
  end if;
  if (select count(*) from public.orders where created_at > now() - interval '1 minute') >= 60 then
    raise exception 'النظام مشغول حالياً. أعد المحاولة بعد دقيقة.';
  end if;

  v_lines := private.price_lines(p_items);
  perform 1 from public.menu_items
   where id in (select (l->>'item_id')::bigint from jsonb_array_elements(v_lines) l)
   order by id for update;
  v_lines := private.price_lines(p_items);
  v_tot   := private.order_totals(v_lines);

  insert into public.orders (table_id, table_number, subtotal, discount, service, tax, total,
                             service_percent, tax_percent)
  values (v_table.id, v_table.number,
          (v_tot->>'subtotal')::bigint, (v_tot->>'discount')::bigint,
          (v_tot->>'service')::bigint,  (v_tot->>'tax')::bigint,
          (v_tot->>'total')::bigint,
          (v_tot->>'service_percent')::numeric, (v_tot->>'tax_percent')::numeric)
  returning id, created_at into v_order_id, v_created;

  insert into public.order_items (order_id, item_id, item_name, category_name,
                                  unit_price, unit_discount, qty, note, line_total)
  select v_order_id, (l->>'item_id')::bigint, l->>'item_name', l->>'category_name',
         (l->>'unit_price')::bigint, (l->>'unit_discount')::bigint,
         (l->>'qty')::int, l->>'note', (l->>'line_total')::bigint
    from jsonb_array_elements(v_lines) l;

  with s as (
    select (l->>'item_id')::bigint as id, sum((l->>'qty')::int) as q
      from jsonb_array_elements(v_lines) l group by 1
  ), upd as (
    update public.menu_items mi set stock_qty = mi.stock_qty - s.q
      from s where mi.id = s.id and mi.track_stock
    returning mi.id, s.q
  )
  insert into public.stock_movements (item_id, change, reason, order_id, created_by)
  select upd.id, -upd.q, 'sale', v_order_id, null from upd;

  return jsonb_build_object(
    'order_id', v_order_id,
    'table_number', v_table.number,
    'created_at', v_created,
    'lines', v_lines) || v_tot;
end $$;

-- ---------- للموظفين: معرفة عنوان الشبكة الحالية ----------
create or replace function public.my_network_ip()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_ip inet := private.client_ip();
begin
  if not private.is_staff() then
    raise exception 'غير مصرّح.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'ip', host(v_ip),
    'suggested', case when v_ip is null then null
                      when family(v_ip) = 4 then host(v_ip) || '/32'
                      else network(set_masklen(v_ip, 64))::text end,
    'allowed_now', private.network_ok());
end $$;

-- ---------- للمدير والكاشير: تشغيل/إيقاف القفل وتحديد الشبكات ----------
create or replace function public.set_wifi_lock(p_enabled boolean, p_networks text[])
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_role public.staff_role := private.staff_role();
  v_nets cidr[] := '{}';
  v_txt  text;
begin
  if v_role is null or v_role not in ('manager', 'cashier') then
    raise exception 'هذه العملية للمدير أو الكاشير فقط.' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_networks), 0) > 10 then
    raise exception 'الحد الأقصى 10 عناوين.';
  end if;
  foreach v_txt in array coalesce(p_networks, '{}') loop
    v_txt := btrim(v_txt);
    continue when v_txt = '';
    begin
      v_nets := v_nets || network(v_txt::inet)::cidr;
    exception when others then
      raise exception 'العنوان "%" غير صالح. مثال صحيح: 185.12.34.56', v_txt;
    end;
  end loop;
  if p_enabled and cardinality(v_nets) = 0 then
    raise exception 'أضف عنوان شبكة واحد على الأقل قبل تفعيل القفل.';
  end if;

  update public.settings
     set wifi_lock = coalesce(p_enabled, false),
         allowed_networks = (select coalesce(array_agg(distinct n), '{}') from unnest(v_nets) n)
   where id = 1;

  return (select jsonb_build_object('wifi_lock', wifi_lock, 'allowed_networks', allowed_networks)
            from public.settings where id = 1);
end $$;

revoke all on function public.menu_context(int), public.quote_order(jsonb), public.place_order(int, jsonb),
                       public.my_network_ip(), public.set_wifi_lock(boolean, text[]) from public, anon, authenticated;
grant execute on function public.menu_context(int), public.quote_order(jsonb), public.place_order(int, jsonb)
  to anon, authenticated;
grant execute on function public.my_network_ip(), public.set_wifi_lock(boolean, text[]) to authenticated;
