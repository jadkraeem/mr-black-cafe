-- =============================================================
-- Mr Black — 0010: النظام المحاسبي
--   نقطة بيع (طاولة/سفري) + التحصيل والدفع + الورديات والصندوق
--   + المصاريف + تقرير الأرباح + تحديث فوري لصفحة المنيو
-- =============================================================

-- ---------- الورديات ----------
create table if not exists public.shifts (
  id            bigint generated always as identity primary key,
  status        text not null default 'open' check (status in ('open', 'closed')),
  opened_by     uuid default auth.uid() references auth.users(id) on delete set null,
  opened_at     timestamptz not null default now(),
  opening_cash  bigint not null check (opening_cash between 0 and 1000000000000),
  closed_by     uuid references auth.users(id) on delete set null,
  closed_at     timestamptz,
  expected_cash bigint,
  counted_cash  bigint check (counted_cash is null or counted_cash between 0 and 1000000000000),
  difference    bigint,
  note          text check (note is null or char_length(note) <= 300)
);
create unique index if not exists shifts_one_open on public.shifts ((true)) where status = 'open';
create index if not exists shifts_opened_idx on public.shifts (opened_at desc);
create index if not exists shifts_opened_by_idx on public.shifts (opened_by);
create index if not exists shifts_closed_by_idx on public.shifts (closed_by);

-- ---------- الطلبات: النوع + الدفع ----------
alter table public.orders
  add column if not exists order_type text not null default 'table' check (order_type in ('table', 'takeaway')),
  add column if not exists created_by uuid references auth.users(id) on delete set null,
  add column if not exists paid_at timestamptz,
  add column if not exists payment_method text check (payment_method in ('cash', 'card')),
  add column if not exists amount_received bigint check (amount_received >= 0),
  add column if not exists change_due bigint check (change_due >= 0),
  add column if not exists paid_by uuid references auth.users(id) on delete set null,
  add column if not exists shift_id bigint references public.shifts(id) on delete set null;
-- الطلب السفري بلا طاولة (لا يحذف أي بيانات)
alter table public.orders alter column table_id drop not null;
alter table public.orders alter column table_number drop not null;
alter table public.orders add constraint orders_table_required check (order_type = 'takeaway' or table_id is not null);
create index if not exists orders_paid_idx on public.orders (paid_at);
create index if not exists orders_unpaid_idx on public.orders (status) where paid_at is null;
create index if not exists orders_shift_idx on public.orders (shift_id);
create index if not exists orders_created_by_idx on public.orders (created_by);
create index if not exists orders_paid_by_idx on public.orders (paid_by);

-- ---------- المصاريف ----------
create table if not exists public.expenses (
  id           bigint generated always as identity primary key,
  category     text not null check (category in ('supplies', 'salaries', 'rent', 'utilities', 'maintenance', 'marketing', 'other')),
  description  text check (description is null or char_length(description) <= 200),
  amount       bigint not null check (amount > 0 and amount <= 1000000000000),
  from_drawer  boolean not null default false,
  shift_id     bigint references public.shifts(id) on delete set null,
  spent_at     timestamptz not null default now(),
  created_by   uuid default auth.uid() references auth.users(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists expenses_spent_idx on public.expenses (spent_at desc);
create index if not exists expenses_shift_idx on public.expenses (shift_id);
create index if not exists expenses_created_by_idx on public.expenses (created_by);

-- ---------- RLS والصلاحيات ----------
alter table public.shifts enable row level security;
alter table public.expenses enable row level security;

create policy shifts_staff_read on public.shifts
  for select to authenticated using ((select private.staff_role()) in ('manager', 'cashier'));
create policy expenses_staff_read on public.expenses
  for select to authenticated using ((select private.staff_role()) in ('manager', 'cashier'));
create policy expenses_manager_update on public.expenses
  for update to authenticated using ((select private.is_manager())) with check ((select private.is_manager()));
create policy expenses_manager_delete on public.expenses
  for delete to authenticated using ((select private.is_manager()));

grant select on public.shifts, public.expenses to authenticated;
grant update (category, description, amount, spent_at), delete on public.expenses to authenticated;

-- ---------- أدوات داخلية ----------
create or replace function private.current_shift()
returns bigint language sql stable security definer set search_path = '' as $$
  select id from public.shifts where status = 'open' limit 1
$$;

create or replace function private.require_till_role()
returns public.staff_role language plpgsql stable security definer set search_path = '' as $$
declare v public.staff_role := private.staff_role();
begin
  if v is null or v not in ('manager', 'cashier') then
    raise exception 'هذه العملية للمدير أو الكاشير فقط.' using errcode = '42501';
  end if;
  return v;
end $$;

-- إدخال الطلب (مشترك بين طلب الزبون ونقطة البيع)
create or replace function private.insert_order(p_table_id bigint, p_table_number int, p_type text, p_items jsonb, p_created_by uuid)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_lines    jsonb;
  v_tot      jsonb;
  v_order_id bigint;
  v_created  timestamptz;
begin
  v_lines := private.price_lines(p_items);
  perform 1 from public.menu_items
   where id in (select (l->>'item_id')::bigint from jsonb_array_elements(v_lines) l)
   order by id for update;
  v_lines := private.price_lines(p_items);
  v_tot   := private.order_totals(v_lines);

  insert into public.orders (table_id, table_number, order_type, created_by, subtotal, discount, service, tax, total,
                             service_percent, tax_percent)
  values (p_table_id, p_table_number, p_type, p_created_by,
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
  select upd.id, -upd.q, 'sale', v_order_id, p_created_by from upd;

  return jsonb_build_object(
    'order_id', v_order_id, 'table_number', p_table_number, 'order_type', p_type,
    'created_at', v_created, 'lines', v_lines) || v_tot;
end $$;

revoke all on function private.current_shift(), private.require_till_role(),
  private.insert_order(bigint, int, text, jsonb, uuid) from public, anon, authenticated;

-- ---------- طلب الزبون (نفس التوقيع، يستخدم الإدخال المشترك) ----------
create or replace function public.place_order(p_table int, p_items jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_table public.cafe_tables;
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
  return private.insert_order(v_table.id, v_table.number, 'table', p_items, null);
end $$;

-- معاينة السعر: الموظف يتجاوز قفل الشبكة
create or replace function public.quote_order(p_items jsonb)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_lines jsonb;
begin
  if not (private.network_ok() or private.is_staff()) then
    raise exception 'الطلب متاح فقط من شبكة واي فاي الكافيه. اتصل بالشبكة ثم أعد المحاولة.';
  end if;
  v_lines := private.price_lines(p_items);
  return jsonb_build_object('lines', v_lines) || private.order_totals(v_lines);
end $$;

-- ---------- نقطة البيع ----------
create or replace function public.pos_create_order(p_type text, p_table int, p_items jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_table public.cafe_tables;
begin
  perform private.require_till_role();
  if p_type = 'takeaway' then
    return private.insert_order(null, null, 'takeaway', p_items, auth.uid());
  elsif p_type = 'table' then
    select * into v_table from public.cafe_tables where number = p_table and active;
    if not found then raise exception 'اختر طاولة صحيحة وفعّالة.'; end if;
    return private.insert_order(v_table.id, v_table.number, 'table', p_items, auth.uid());
  end if;
  raise exception 'نوع الطلب غير صالح.';
end $$;

-- ---------- التحصيل ----------
create or replace function public.pay_order(p_order_id bigint, p_method text, p_received bigint default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_shift bigint;
  o public.orders;
  v_recv bigint;
begin
  perform private.require_till_role();
  v_shift := private.current_shift();
  if v_shift is null then
    raise exception 'لا توجد وردية مفتوحة. افتح وردية من تبويب "الوردية والصندوق" قبل التحصيل.';
  end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'الطلب غير موجود.'; end if;
  if o.status = 'cancelled' then raise exception 'لا يمكن تحصيل طلب ملغى.'; end if;
  if o.paid_at is not null then raise exception 'هذا الطلب مدفوع مسبقاً.'; end if;
  if p_method not in ('cash', 'card') then raise exception 'طريقة الدفع غير صالحة.'; end if;

  if p_method = 'cash' then
    v_recv := coalesce(p_received, o.total);
    if v_recv < o.total then raise exception 'المبلغ المستلم أقل من الإجمالي.'; end if;
    if v_recv > 1000000000000 then raise exception 'المبلغ غير صالح.'; end if;
  else
    v_recv := o.total;
  end if;

  update public.orders set
    paid_at = now(), payment_method = p_method, amount_received = v_recv,
    change_due = v_recv - o.total, paid_by = auth.uid(), shift_id = v_shift
  where id = p_order_id;

  return jsonb_build_object('order_id', o.id, 'total', o.total, 'received', v_recv, 'change', v_recv - o.total, 'method', p_method);
end $$;

-- ---------- تغيير الحالة (+ منع إلغاء المدفوع) ----------
create or replace function public.set_order_status(p_order_id bigint, p_status public.order_status)
returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_role public.staff_role := private.staff_role();
  v_cur  public.order_status;
  v_paid timestamptz;
begin
  if v_role is null then
    raise exception 'غير مصرّح. سجّل الدخول بحساب موظف فعّال.' using errcode = '42501';
  end if;
  select status, paid_at into v_cur, v_paid from public.orders where id = p_order_id for update;
  if not found then raise exception 'الطلب غير موجود.'; end if;
  if v_cur in ('served', 'cancelled') then raise exception 'لا يمكن تعديل طلب مُسلَّم أو ملغى.'; end if;
  if p_status = 'new' or p_status <= v_cur then raise exception 'لا يمكن إرجاع الطلب إلى حالة سابقة.'; end if;
  if v_role = 'kitchen' and p_status not in ('preparing', 'ready') then
    raise exception 'حساب المطبخ يمكنه فقط بدء التحضير أو تحديد الطلب كجاهز.' using errcode = '42501';
  end if;
  if p_status = 'cancelled' and v_paid is not null then
    raise exception 'لا يمكن إلغاء طلب مدفوع.';
  end if;

  update public.orders set
    status       = p_status,
    started_at   = case when p_status = 'preparing' then now() else started_at end,
    ready_at     = case when p_status = 'ready'     then now() else ready_at end,
    served_at    = case when p_status = 'served'    then now() else served_at end,
    cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
    updated_by   = auth.uid()
  where id = p_order_id;

  if p_status = 'cancelled' then
    with sold as (
      select item_id, -sum(change) as q from public.stock_movements
       where order_id = p_order_id and reason = 'sale' group by item_id
    ), upd as (
      update public.menu_items mi set stock_qty = mi.stock_qty + sold.q
        from sold where mi.id = sold.item_id
      returning mi.id, sold.q
    )
    insert into public.stock_movements (item_id, change, reason, order_id, created_by)
    select upd.id, upd.q, 'cancel', p_order_id, auth.uid() from upd;
  end if;
end $$;

-- ---------- الورديات ----------
create or replace function public.shift_summary(p_shift_id bigint default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  s public.shifts;
  v_cash bigint; v_card bigint; v_cnt bigint; v_exp bigint;
begin
  perform private.require_till_role();
  select * into s from public.shifts where id = coalesce(p_shift_id, private.current_shift());
  if not found then return null; end if;
  select coalesce(sum(total) filter (where payment_method = 'cash'), 0),
         coalesce(sum(total) filter (where payment_method = 'card'), 0),
         count(*)
    into v_cash, v_card, v_cnt
    from public.orders where shift_id = s.id and paid_at is not null;
  select coalesce(sum(amount), 0) into v_exp from public.expenses where shift_id = s.id and from_drawer;
  return jsonb_build_object(
    'id', s.id, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opened_by', (select full_name from public.profiles where id = s.opened_by),
    'closed_by', (select full_name from public.profiles where id = s.closed_by),
    'opening_cash', s.opening_cash, 'cash_sales', v_cash, 'card_sales', v_card, 'paid_orders', v_cnt,
    'cash_expenses', v_exp, 'expected_cash', s.opening_cash + v_cash - v_exp,
    'counted_cash', s.counted_cash, 'difference', s.difference, 'note', s.note,
    'unpaid_open', (select count(*) from public.orders where paid_at is null and status <> 'cancelled'));
end $$;

create or replace function public.open_shift(p_opening_cash bigint)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.require_till_role();
  if p_opening_cash is null or p_opening_cash < 0 or p_opening_cash > 1000000000000 then
    raise exception 'مبلغ بداية الوردية غير صالح.';
  end if;
  if private.current_shift() is not null then
    raise exception 'يوجد وردية مفتوحة بالفعل.';
  end if;
  insert into public.shifts (opening_cash, opened_by) values (p_opening_cash, auth.uid());
  return public.shift_summary(null);
exception when unique_violation then
  raise exception 'يوجد وردية مفتوحة بالفعل.';
end $$;

create or replace function public.close_shift(p_counted_cash bigint, p_note text default null)
returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_id bigint; v_sum jsonb;
begin
  perform private.require_till_role();
  v_id := private.current_shift();
  if v_id is null then raise exception 'لا توجد وردية مفتوحة.'; end if;
  if p_counted_cash is null or p_counted_cash < 0 or p_counted_cash > 1000000000000 then
    raise exception 'المبلغ المعدود غير صالح.';
  end if;
  if p_note is not null and char_length(p_note) > 300 then raise exception 'الملاحظة طويلة جداً.'; end if;
  v_sum := public.shift_summary(v_id);
  update public.shifts set
    status = 'closed', closed_by = auth.uid(), closed_at = now(),
    expected_cash = (v_sum->>'expected_cash')::bigint, counted_cash = p_counted_cash,
    difference = p_counted_cash - (v_sum->>'expected_cash')::bigint,
    note = nullif(btrim(p_note), '')
  where id = v_id;
  return public.shift_summary(v_id);
end $$;

-- ---------- المصاريف ----------
create or replace function public.add_expense(p_category text, p_amount bigint, p_description text default null,
                                              p_from_drawer boolean default false, p_spent_at timestamptz default null)
returns bigint
language plpgsql volatile security definer set search_path = '' as $$
declare v_shift bigint; v_id bigint;
begin
  perform private.require_till_role();
  if coalesce(p_from_drawer, false) then
    v_shift := private.current_shift();
    if v_shift is null then raise exception 'لا توجد وردية مفتوحة للدفع من الصندوق.'; end if;
  end if;
  insert into public.expenses (category, amount, description, from_drawer, shift_id, spent_at, created_by)
  values (p_category, p_amount, nullif(btrim(p_description), ''), coalesce(p_from_drawer, false), v_shift,
          coalesce(p_spent_at, now()), auth.uid())
  returning id into v_id;
  return v_id;
exception when check_violation then
  raise exception 'بيانات المصروف غير صالحة (تأكد من النوع والمبلغ).';
end $$;

-- ---------- تقرير الأرباح والخسائر ----------
create or replace function public.report_pnl(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_manager() then
    raise exception 'التقارير متاحة للمدير فقط.' using errcode = '42501';
  end if;
  perform private.check_range(p_from, p_to);
  return (
    with paid as (
      select * from public.orders where paid_at >= p_from and paid_at < p_to and status <> 'cancelled'
    ), ex as (
      select * from public.expenses where spent_at >= p_from and spent_at < p_to
    )
    select jsonb_build_object(
      'revenue',     (select coalesce(sum(total), 0) from paid),
      'paid_orders', (select count(*) from paid),
      'cash',        (select coalesce(sum(total), 0) from paid where payment_method = 'cash'),
      'card',        (select coalesce(sum(total), 0) from paid where payment_method = 'card'),
      'discounts',   (select coalesce(sum(discount), 0) from paid),
      'service',     (select coalesce(sum(service), 0) from paid),
      'tax',         (select coalesce(sum(tax), 0) from paid),
      'expenses',    (select coalesce(sum(amount), 0) from ex),
      'expenses_by_category', (select coalesce(jsonb_agg(e order by e.total desc), '[]') from (
                       select category, sum(amount) as total, count(*) as count from ex group by category) e),
      'net_profit',  (select coalesce(sum(total), 0) from paid) - (select coalesce(sum(amount), 0) from ex),
      'unpaid_count', (select count(*) from public.orders where paid_at is null and status <> 'cancelled'
                         and created_at >= p_from and created_at < p_to),
      'unpaid_total', (select coalesce(sum(total), 0) from public.orders where paid_at is null and status <> 'cancelled'
                         and created_at >= p_from and created_at < p_to),
      'shifts', (select coalesce(jsonb_agg(x order by x.opened_at), '[]') from (
                   select id, opened_at, closed_at, opening_cash, expected_cash, counted_cash, difference
                     from public.shifts where opened_at >= p_from and opened_at < p_to) x)
    )
  );
end $$;

-- ---------- صلاحيات الدوال ----------
revoke all on function public.pos_create_order(text, int, jsonb), public.pay_order(bigint, text, bigint),
  public.shift_summary(bigint), public.open_shift(bigint), public.close_shift(bigint, text),
  public.add_expense(text, bigint, text, boolean, timestamptz), public.report_pnl(timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.pos_create_order(text, int, jsonb), public.pay_order(bigint, text, bigint),
  public.shift_summary(bigint), public.open_shift(bigint), public.close_shift(bigint, text),
  public.add_expense(text, bigint, text, boolean, timestamptz), public.report_pnl(timestamptz, timestamptz)
  to authenticated;

-- ---------- تحديث فوري لصفحة المنيو (إشارة عامة بلا بيانات حساسة) ----------
create or replace function private.notify_menu_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(jsonb_build_object('table', tg_table_name), 'changed', 'menu-updates', false);
  return null;
exception when others then
  return null;
end $$;
revoke all on function private.notify_menu_change() from public, anon, authenticated;

create trigger categories_notify after insert or update or delete on public.categories
  for each statement execute function private.notify_menu_change();
create trigger offers_notify after insert or update or delete on public.offers
  for each statement execute function private.notify_menu_change();
create trigger events_notify after insert or update or delete on public.events
  for each statement execute function private.notify_menu_change();
create trigger settings_notify after update on public.settings
  for each statement execute function private.notify_menu_change();
create trigger menu_items_notify_ins_del after insert or delete on public.menu_items
  for each statement execute function private.notify_menu_change();
-- عند البيع يتغيّر المخزون فقط؛ لا نرسل إشارة إلا إذا تغيّر ما يراه الزبون
create trigger menu_items_notify_upd after update on public.menu_items
  for each row when (
       old.sold_out    is distinct from new.sold_out
    or old.price       is distinct from new.price
    or old.name        is distinct from new.name
    or old.name_en     is distinct from new.name_en
    or old.description is distinct from new.description
    or old.image_url   is distinct from new.image_url
    or old.category_id is distinct from new.category_id
    or old.sort        is distinct from new.sort)
  execute function private.notify_menu_change();
