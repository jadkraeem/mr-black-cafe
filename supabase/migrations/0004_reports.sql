-- =============================================================
-- Mr Black — 0004: التقارير والجرد (المدير فقط)
-- =============================================================

create or replace function private.check_range(p_from timestamptz, p_to timestamptz)
returns void language plpgsql immutable set search_path = '' as $$
begin
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'نطاق التاريخ غير صالح.';
  end if;
  if p_to - p_from > interval '400 days' then
    raise exception 'نطاق التقرير طويل جداً (الحد الأقصى 400 يوم).';
  end if;
end $$;
revoke all on function private.check_range(timestamptz, timestamptz) from public, anon, authenticated;

-- ---------- تقرير المبيعات ----------
create or replace function public.report_sales(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_tz text;
  v_result jsonb;
begin
  if not private.is_manager() then
    raise exception 'التقارير متاحة للمدير فقط.' using errcode = '42501';
  end if;
  perform private.check_range(p_from, p_to);
  select timezone into v_tz from public.settings where id = 1;

  with o as (
    select * from public.orders where created_at >= p_from and created_at < p_to
  ), ok as (
    select * from o where status <> 'cancelled'
  ), li as (
    select oi.* from public.order_items oi join ok on ok.id = oi.order_id
  )
  select jsonb_build_object(
    'summary', (select jsonb_build_object(
        'orders',         count(*),
        'subtotal',       coalesce(sum(subtotal), 0),
        'discount',       coalesce(sum(discount), 0),
        'service',        coalesce(sum(service), 0),
        'tax',            coalesce(sum(tax), 0),
        'revenue',        coalesce(sum(total), 0),
        'avg_order',      coalesce(round(avg(total)), 0),
        'items_sold',     (select coalesce(sum(qty), 0) from li),
        'cancelled',      (select count(*) from o where status = 'cancelled'),
        'avg_prep_min',   round((extract(epoch from avg(ready_at - created_at)) / 60)::numeric, 1)
      ) from ok),
    'by_day', (select coalesce(jsonb_agg(d order by d.day), '[]') from (
        select (created_at at time zone v_tz)::date as day, count(*) as orders, sum(total) as revenue
          from ok group by 1) d),
    'by_hour', (select coalesce(jsonb_agg(h order by h.hour), '[]') from (
        select extract(hour from created_at at time zone v_tz)::int as hour, count(*) as orders, sum(total) as revenue
          from ok group by 1) h),
    'top_items', (select coalesce(jsonb_agg(t order by t.qty desc), '[]') from (
        select item_name, sum(qty) as qty, sum(line_total) as revenue
          from li group by item_name order by sum(qty) desc limit 15) t),
    'by_category', (select coalesce(jsonb_agg(c order by c.revenue desc), '[]') from (
        select coalesce(category_name, '—') as category, sum(qty) as qty, sum(line_total) as revenue
          from li group by 1) c),
    'by_table', (select coalesce(jsonb_agg(t order by t.table_number), '[]') from (
        select table_number, count(*) as orders, sum(total) as revenue
          from ok group by 1) t)
  ) into v_result;

  return v_result;
end $$;

-- ---------- تقرير الجرد ----------
-- رصيد البداية = الرصيد الحالي - كل الحركات منذ بداية الفترة
-- رصيد النهاية = الرصيد الحالي - كل الحركات بعد نهاية الفترة
create or replace function public.report_inventory(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_manager() then
    raise exception 'الجرد متاح للمدير فقط.' using errcode = '42501';
  end if;
  perform private.check_range(p_from, p_to);

  return (
    select coalesce(jsonb_agg(r order by r.category, r.name), '[]')
    from (
      select mi.id, mi.name, c.name as category, mi.track_stock,
             mi.stock_qty as current_qty, mi.low_stock_threshold,
             mi.stock_qty - coalesce((select sum(change) from public.stock_movements m
                                       where m.item_id = mi.id and m.created_at >= p_from), 0) as opening_qty,
             mi.stock_qty - coalesce((select sum(change) from public.stock_movements m
                                       where m.item_id = mi.id and m.created_at >= p_to), 0)   as closing_qty,
             coalesce(sum(m.change) filter (where m.reason = 'restock'), 0)  as restocked,
             coalesce(-sum(m.change) filter (where m.reason = 'waste'), 0)   as wasted,
             coalesce(sum(m.change) filter (where m.reason = 'adjust'), 0)   as adjusted,
             coalesce(sum(m.change) filter (where m.reason = 'cancel'), 0)   as returned,
             (select coalesce(sum(oi.qty), 0) from public.order_items oi
                join public.orders o on o.id = oi.order_id
               where oi.item_id = mi.id and o.status <> 'cancelled'
                 and o.created_at >= p_from and o.created_at < p_to) as sold_qty
        from public.menu_items mi
        join public.categories c on c.id = mi.category_id
        left join public.stock_movements m
               on m.item_id = mi.id and m.created_at >= p_from and m.created_at < p_to
       group by mi.id, c.name
    ) r
  );
end $$;

revoke all on function public.report_sales(timestamptz, timestamptz),
                       public.report_inventory(timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.report_sales(timestamptz, timestamptz),
                          public.report_inventory(timestamptz, timestamptz) to authenticated;
