-- =============================================================
-- Mr Black — اختبار الأمان (لا يترك أي بيانات: ينتهي بـ rollback)
-- شغّله من: Supabase Dashboard → SQL Editor → الصق → Run
-- النتيجة المتوقعة: كل سطر فيه blocked، ولا يوجد ALLOWED!
-- =============================================================
begin;
insert into public.categories(name) values ('قهوة');
insert into public.categories(name, active) values ('مخفي', false);
insert into public.menu_items(category_id, name, price, track_stock, stock_qty)
  select id, 'إسبريسو', 10000, true, 3 from public.categories where name='قهوة';
insert into public.menu_items(category_id, name, price, available)
  select id, 'غير متوفر', 5000, false from public.categories where name='قهوة';
insert into public.cafe_tables(number) values (4);
insert into public.offers(title, discount_type, discount_value) values ('خصم عام', 'percent', 10);
update public.settings set tax_percent = 5, service_percent = 10;

create temp table _r(t text, v text) on commit drop;
grant all on _r to anon;

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);

insert into _r select 'anon categories (expect: قهوة)', string_agg(name, ',') from public.categories;
insert into _r select 'anon items (expect: إسبريسو)', string_agg(name, ',') from public.menu_items;
insert into _r select 'anon offers (expect: 1)', count(*)::text from public.offers;
insert into _r select 'context', public.menu_context(4)::text;
insert into _r select 'context bad table (expect: false)', public.menu_context(99)->>'table_valid';
insert into _r select 'order with fake price 1 (expect total 20700)',
  public.place_order(4, (select jsonb_build_array(jsonb_build_object('item_id', id, 'qty', 2, 'note', 'بدون سكر', 'unit_price', 1))
                         from public.menu_items where name='إسبريسو'))::text;

do $$ begin
  begin perform * from public.orders; insert into _r values ('orders read', 'ALLOWED!');
  exception when others then insert into _r values ('orders read', 'blocked: ' || sqlerrm); end;
  begin perform * from public.cafe_tables; insert into _r values ('tables read', 'ALLOWED!');
  exception when others then insert into _r values ('tables read', 'blocked: ' || sqlerrm); end;
  begin perform * from public.settings; insert into _r values ('settings read', 'ALLOWED!');
  exception when others then insert into _r values ('settings read', 'blocked: ' || sqlerrm); end;
  begin perform stock_qty from public.menu_items; insert into _r values ('stock column read', 'ALLOWED!');
  exception when others then insert into _r values ('stock column read', 'blocked: ' || sqlerrm); end;
  begin insert into public.categories(name) values ('hack'); insert into _r values ('insert category', 'ALLOWED!');
  exception when others then insert into _r values ('insert category', 'blocked: ' || sqlerrm); end;
  begin perform public.set_order_status(1, 'served'); insert into _r values ('change order status', 'ALLOWED!');
  exception when others then insert into _r values ('change order status', 'blocked: ' || sqlerrm); end;
  begin perform public.report_sales(now() - interval '1 day', now()); insert into _r values ('sales report', 'ALLOWED!');
  exception when others then insert into _r values ('sales report', 'blocked: ' || sqlerrm); end;
  begin perform public.place_order(4, (select jsonb_build_array(jsonb_build_object('item_id', id, 'qty', 2))
                                        from public.menu_items where name='إسبريسو'));
    insert into _r values ('order more than stock', 'ALLOWED!');
  exception when others then insert into _r values ('order more than stock', 'blocked: ' || sqlerrm); end;
  begin perform public.place_order(4, '[{"item_id":"1; drop table x","qty":1}]'); insert into _r values ('malicious input', 'ALLOWED!');
  exception when others then insert into _r values ('malicious input', 'blocked: ' || sqlerrm); end;
end $$;

reset role;
insert into _r select 'stock after order (expect: 1)', stock_qty::text from public.menu_items where name='إسبريسو';
select * from _r;
rollback;
