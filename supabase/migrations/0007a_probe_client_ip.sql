-- =============================================================
-- Mr Black — 0007a: دالة اختبار مؤقتة (استُبدلت في 0007b)
-- استُخدمت لمعرفة أي ترويسة IP موثوقة. النتيجة:
--   x-forwarded-for  ← قابلة للتزوير (العميل يضيف قيمة في أولها)
--   cf-connecting-ip ← تضعها Cloudflare، ومحاولة إرسالها من العميل تُرفض (خطأ 1000)
-- 0007b يعيد تعريف my_network_ip للموظفين فقط ويسحبها من anon.
-- =============================================================
create or replace function public.my_network_ip()
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'xff', current_setting('request.headers', true)::json->>'x-forwarded-for',
    'cf', current_setting('request.headers', true)::json->>'cf-connecting-ip',
    'xreal', current_setting('request.headers', true)::json->>'x-real-ip',
    'keys', (select jsonb_agg(k) from json_object_keys(current_setting('request.headers', true)::json) k))
$$;
grant execute on function public.my_network_ip() to anon;
