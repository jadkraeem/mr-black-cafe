-- دالة Supabase التي تفعّل RLS تلقائياً على الجداول الجديدة (event trigger).
-- لا حاجة لأن يستدعيها أحد عبر الـ API؛ التريغر يعمل بدون صلاحية EXECUTE.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
