-- =============================================================
-- Mr Black — 0003: دوال الطلبات والمخزون (كل الحسابات على السيرفر)
-- =============================================================

-- ---------- خصم الوحدة: أفضل عرض فعّال يطبَّق على الصنف ----------
create or replace function private.item_unit_discount(p_item_id bigint, p_category_id bigint, p_price bigint)
returns bigint
language sql stable security definer set search_path = '' as $$
  select coalesce(max(least(p_price,
           case when o.discount_type = 'percent'
                then round(p_price * o.discount_value / 100)::bigint
                else round(o.discount_value)::bigint end)), 0)
  from public.offers o
  where o.active
    and (o.starts_at is null or o.starts_at <= now())
    and (o.ends_at   is null or o.ends_at   >  now())
    and (o.item_id = p_item_id
         or o.category_id = p_category_id
         or (o.item_id is null and o.category_id is null))
$$;

-- ---------- التحقق من السلة وتسعيرها من قاعدة البيانات ----------
-- المدخل: [{"item_id":1,"qty":2,"note":"بدون سكر"}, ...]
-- أي سعر يرسله المتصفح يُتجاهل تماماً.
create or replace function private.price_lines(p_items jsonb)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_line jsonb;
  v_out  jsonb := '[]'::jsonb;
  v_id   bigint;
  v_qty  int;
  v_note text;
  v_disc bigint;
  r      record;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'بيانات السلة غير صالحة.';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'السلة فارغة. أضف صنفاً واحداً على الأقل.';
  end if;
  if jsonb_array_length(p_items) > 30 then
    raise exception 'عدد الأسطر في الطلب كبير جداً (الحد الأقصى 30).';
  end if;

  for v_line in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(v_line) <> 'object'
       or coalesce(v_line->>'item_id', '') !~ '^[0-9]{1,15}$'
       or coalesce(v_line->>'qty', '')     !~ '^[0-9]{1,3}$' then
      raise exception 'بيانات السلة غير صالحة.';
    end if;
    if v_line ? 'note' and jsonb_typeof(v_line->'note') not in ('string', 'null') then
      raise exception 'بيانات السلة غير صالحة.';
    end if;

    v_id   := (v_line->>'item_id')::bigint;
    v_qty  := (v_line->>'qty')::int;
    v_note := nullif(btrim(v_line->>'note'), '');

    if v_qty < 1 or v_qty > 50 then
      raise exception 'الكمية يجب أن تكون بين 1 و 50.';
    end if;
    if v_note is not null and char_length(v_note) > 200 then
      raise exception 'الملاحظة طويلة جداً (الحد الأقصى 200 حرف).';
    end if;

    select mi.id, mi.name, mi.price, mi.available, mi.category_id,
           c.name as category_name, c.active as category_active
      into r
      from public.menu_items mi
      join public.categories c on c.id = mi.category_id
     where mi.id = v_id;

    if not found then
      raise exception 'أحد الأصناف في سلتك لم يعد موجوداً في المنيو. حدّث الصفحة.';
    end if;
    if not r.available or not r.category_active then
      raise exception 'الصنف "%" غير متوفر حالياً.', r.name;
    end if;

    v_disc := private.item_unit_discount(r.id, r.category_id, r.price);

    v_out := v_out || jsonb_build_object(
      'item_id',       r.id,
      'item_name',     r.name,
      'category_name', r.category_name,
      'unit_price',    r.price,
      'unit_discount', v_disc,
      'qty',           v_qty,
      'note',          v_note,
      'line_total',    (r.price - v_disc) * v_qty
    );
  end loop;

  -- التحقق من المخزون (مجموع الكمية لكل صنف عبر كل الأسطر)
  select mi.name into r
    from (select (l->>'item_id')::bigint as id, sum((l->>'qty')::int) as q
            from jsonb_array_elements(v_out) l group by 1) s
    join public.menu_items mi on mi.id = s.id
   where mi.track_stock and mi.stock_qty < s.q
   limit 1;
  if found then
    raise exception 'الكمية المطلوبة من "%" غير متوفرة في المخزون حالياً.', r.name;
  end if;

  return v_out;
end $$;

-- ---------- الإجماليات ----------
-- الخدمة والضريبة تُحسبان على المبلغ بعد الخصم
create or replace function private.order_totals(p_lines jsonb)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  s      public.settings;
  v_sub  bigint;
  v_disc bigint;
  v_net  bigint;
  v_srv  bigint;
  v_tax  bigint;
begin
  select * into s from public.settings where id = 1;
  select coalesce(sum((l->>'unit_price')::bigint * (l->>'qty')::int), 0),
         coalesce(sum((l->>'unit_discount')::bigint * (l->>'qty')::int), 0)
    into v_sub, v_disc
    from jsonb_array_elements(p_lines) l;
  v_net := v_sub - v_disc;
  v_srv := round(v_net * s.service_percent / 100);
  v_tax := round(v_net * s.tax_percent / 100);
  return jsonb_build_object(
    'subtotal', v_sub, 'discount', v_disc,
    'service', v_srv, 'service_percent', s.service_percent,
    'tax', v_tax, 'tax_percent', s.tax_percent,
    'total', v_net + v_srv + v_tax,
    'currency', s.currency);
end $$;

revoke all on function private.item_unit_discount(bigint, bigint, bigint),
                       private.price_lines(jsonb),
                       private.order_totals(jsonb) from public, anon, authenticated;

-- =============================================================
-- دوال عامة (RPC)
-- =============================================================

-- ---------- معلومات صفحة الزبون ----------
create or replace function public.menu_context(p_table int)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'cafe_name',       s.cafe_name,
    'currency',        s.currency,
    'tax_percent',     s.tax_percent,
    'service_percent', s.service_percent,
    'table_valid',     exists (select 1 from public.cafe_tables t where t.number = p_table and t.active))
  from public.settings s where s.id = 1
$$;

-- ---------- معاينة السعر قبل الإرسال ----------
create or replace function public.quote_order(p_items jsonb)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lines jsonb;
begin
  v_lines := private.price_lines(p_items);
  return jsonb_build_object('lines', v_lines) || private.order_totals(v_lines);
end $$;

-- ---------- إرسال الطلب ----------
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
  select * into v_table from public.cafe_tables where number = p_table and active;
  if not found then
    raise exception 'رقم الطاولة غير صالح. امسح رمز QR الموجود على طاولتك مرة أخرى.';
  end if;

  -- حدود منع الإغراق
  if (select count(*) from public.orders
       where table_id = v_table.id and created_at > now() - interval '1 minute') >= 3 then
    raise exception 'تم إرسال طلبات كثيرة من هذه الطاولة خلال دقيقة. انتظر قليلاً ثم أعد المحاولة.';
  end if;
  if (select count(*) from public.orders where created_at > now() - interval '1 minute') >= 60 then
    raise exception 'النظام مشغول حالياً. أعد المحاولة بعد دقيقة.';
  end if;

  -- تحقق أولي ثم قفل صفوف الأصناف لمنع تعارض المخزون ثم إعادة التسعير
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

  -- خصم المخزون للأصناف المتتبَّعة
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

-- ---------- تغيير حالة الطلب ----------
create or replace function public.set_order_status(p_order_id bigint, p_status public.order_status)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_role public.staff_role := private.staff_role();
  v_cur  public.order_status;
begin
  if v_role is null then
    raise exception 'غير مصرّح. سجّل الدخول بحساب موظف فعّال.' using errcode = '42501';
  end if;

  select status into v_cur from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'الطلب غير موجود.';
  end if;
  if v_cur in ('served', 'cancelled') then
    raise exception 'لا يمكن تعديل طلب مُسلَّم أو ملغى.';
  end if;
  if p_status = 'new' or p_status <= v_cur then
    raise exception 'لا يمكن إرجاع الطلب إلى حالة سابقة.';
  end if;
  if v_role = 'kitchen' and p_status not in ('preparing', 'ready') then
    raise exception 'حساب المطبخ يمكنه فقط بدء التحضير أو تحديد الطلب كجاهز.' using errcode = '42501';
  end if;

  update public.orders set
    status       = p_status,
    started_at   = case when p_status = 'preparing' then now() else started_at end,
    ready_at     = case when p_status = 'ready'     then now() else ready_at end,
    served_at    = case when p_status = 'served'    then now() else served_at end,
    cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
    updated_by   = auth.uid()
  where id = p_order_id;

  -- عند الإلغاء: إرجاع ما خُصم من المخزون بالضبط
  if p_status = 'cancelled' then
    with sold as (
      select item_id, -sum(change) as q
        from public.stock_movements
       where order_id = p_order_id and reason = 'sale'
       group by item_id
    ), upd as (
      update public.menu_items mi set stock_qty = mi.stock_qty + sold.q
        from sold where mi.id = sold.item_id
      returning mi.id, sold.q
    )
    insert into public.stock_movements (item_id, change, reason, order_id, created_by)
    select upd.id, upd.q, 'cancel', p_order_id, auth.uid() from upd;
  end if;
end $$;

-- ---------- تعديل المخزون (المدير) ----------
create or replace function public.adjust_stock(p_item_id bigint, p_change int, p_reason public.stock_reason, p_note text default null)
returns int
language plpgsql volatile security definer set search_path = '' as $$
declare v_new int;
begin
  if not private.is_manager() then
    raise exception 'هذه العملية للمدير فقط.' using errcode = '42501';
  end if;
  if p_reason not in ('restock', 'waste', 'adjust') then
    raise exception 'سبب الحركة غير صالح.';
  end if;
  if p_change is null or p_change = 0 or abs(p_change) > 100000 then
    raise exception 'الكمية غير صالحة.';
  end if;
  if p_reason = 'restock' and p_change < 0 then
    raise exception 'التوريد يجب أن يكون بكمية موجبة.';
  end if;
  if p_reason = 'waste' and p_change > 0 then
    raise exception 'التالف يجب أن يكون بكمية سالبة.';
  end if;
  if p_note is not null and char_length(p_note) > 200 then
    raise exception 'الملاحظة طويلة جداً.';
  end if;

  update public.menu_items set stock_qty = stock_qty + p_change
   where id = p_item_id
  returning stock_qty into v_new;
  if not found then
    raise exception 'الصنف غير موجود.';
  end if;

  insert into public.stock_movements (item_id, change, reason, note, created_by)
  values (p_item_id, p_change, p_reason, nullif(btrim(p_note), ''), auth.uid());
  return v_new;
exception
  when check_violation then
    raise exception 'لا يمكن أن يصبح المخزون أقل من صفر.';
end $$;

-- ---------- توفر الصنف (كل الموظفين: مثلاً عند نفاد صنف) ----------
create or replace function public.set_item_available(p_item_id bigint, p_available boolean)
returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not private.is_staff() then
    raise exception 'غير مصرّح.' using errcode = '42501';
  end if;
  update public.menu_items set available = coalesce(p_available, false) where id = p_item_id;
  if not found then
    raise exception 'الصنف غير موجود.';
  end if;
end $$;

-- ---------- الصلاحيات على الدوال ----------
revoke all on function public.menu_context(int), public.quote_order(jsonb), public.place_order(int, jsonb),
                       public.set_order_status(bigint, public.order_status),
                       public.adjust_stock(bigint, int, public.stock_reason, text),
                       public.set_item_available(bigint, boolean) from public, anon, authenticated;

grant execute on function public.menu_context(int), public.quote_order(jsonb), public.place_order(int, jsonb)
  to anon, authenticated;
grant execute on function public.set_order_status(bigint, public.order_status),
                          public.adjust_stock(bigint, int, public.stock_reason, text),
                          public.set_item_available(bigint, boolean)
  to authenticated;
