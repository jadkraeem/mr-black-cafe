-- =============================================================
-- Mr Black — اختبار صلاحيات الأدوار (مدير / كاشير / مطبخ / بلا دور)
-- ينشئ حسابات تجريبية مؤقتة ثم rollback: لا يترك أي بيانات.
-- شغّله من SQL Editor بعد أي تعديل على الصلاحيات.
-- غيّر MANAGER_ID إلى معرّف حساب المدير.
-- =============================================================
begin;
create temp table _r(who text, t text, v text) on commit drop;
grant all on _r to authenticated, anon;
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000c1', 't-cashier@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c2', 't-kitchen@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c3', 't-nobody@test.local',  'authenticated', 'authenticated');
insert into public.profiles (id, full_name, role) values
  ('00000000-0000-0000-0000-0000000000c1', 'كاشير تجريبي', 'cashier'),
  ('00000000-0000-0000-0000-0000000000c2', 'مطبخ تجريبي', 'kitchen');

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
insert into _r select 'anon', 'place_order', (public.place_order(
  (select number from public.cafe_tables where active limit 1),
  (select jsonb_build_array(jsonb_build_object('item_id', id, 'qty', 1)) from public.menu_items where available and not track_stock limit 1)))->>'total';
reset role;

create or replace function pg_temp.t(who text, uid text) returns void language plpgsql as $f$
declare oid bigint; iid bigint;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  select max(id) into oid from public.orders;
  select id into iid from public.menu_items order by track_stock desc limit 1;
  begin insert into _r select who, 'read profiles', count(*)::text from public.profiles; exception when others then insert into _r values (who, 'read profiles', 'ERR '||sqlerrm); end;
  begin insert into _r select who, 'read orders', count(*)::text from public.orders; exception when others then insert into _r values (who, 'read orders', 'ERR '||sqlerrm); end;
  begin insert into _r select who, 'read stock log', count(*)::text from public.stock_movements; exception when others then insert into _r values (who, 'read stock log', 'ERR '||sqlerrm); end;
  begin insert into public.categories(name) values ('اختبار'); insert into _r values (who, 'add category', 'OK');
    exception when others then insert into _r values (who, 'add category', 'ERR '||sqlerrm); end;
  begin update public.menu_items set stock_qty = 999 where id = iid; insert into _r values (who, 'edit stock directly', 'OK!');
    exception when others then insert into _r values (who, 'edit stock directly', 'ERR '||sqlerrm); end;
  begin perform public.set_order_status(oid, 'preparing'); insert into _r values (who, 'status->preparing', 'OK');
    exception when others then insert into _r values (who, 'status->preparing', 'ERR '||sqlerrm); end;
  begin perform public.set_order_status(oid, 'served'); insert into _r values (who, 'status->served', 'OK');
    exception when others then insert into _r values (who, 'status->served', 'ERR '||sqlerrm); end;
  begin perform public.report_sales(now() - interval '1 day', now() + interval '1 minute'); insert into _r values (who, 'report_sales', 'OK');
    exception when others then insert into _r values (who, 'report_sales', 'ERR '||sqlerrm); end;
  begin perform public.set_wifi_lock(false, '{}'); insert into _r values (who, 'set_wifi_lock', 'OK');
    exception when others then insert into _r values (who, 'set_wifi_lock', 'ERR '||sqlerrm); end;
end $f$;
grant execute on function pg_temp.t(text, text) to authenticated;

set local role authenticated;
select pg_temp.t('1-kitchen', '00000000-0000-0000-0000-0000000000c2');
select pg_temp.t('2-cashier', '00000000-0000-0000-0000-0000000000c1');
select pg_temp.t('3-nobody',  '00000000-0000-0000-0000-0000000000c3');
select pg_temp.t('4-manager', (select id::text from public.profiles where role = 'manager' and active limit 1));
reset role;
select who, t, left(v, 90) v from _r order by who, t;
rollback;
