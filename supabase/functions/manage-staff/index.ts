// Mr Black — إدارة الموظفين (للمدير فقط)
// المفتاح السري يأتي من بيئة Supabase تلقائياً ولا يُكتب في أي ملف.
import { createClient } from "npm:@supabase/supabase-js@2";

const ALLOWED_ORIGINS = ["https://jadkraeem.github.io"];
const ROLES = ["manager", "cashier", "kitchen"] as const;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function getServiceKey(): string | undefined {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    return keys.default ?? Object.values(keys)[0] as string | undefined;
  } catch {
    return undefined;
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin") ?? "";
  const allowed = ALLOWED_ORIGINS.includes(origin);
  const headers: Record<string, string> = {
    "Access-Control-Allow-Origin": allowed ? origin : ALLOWED_ORIGINS[0],
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
    "Content-Type": "application/json; charset=utf-8",
  };
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers });

  if (req.method === "OPTIONS") return new Response(null, { status: allowed ? 204 : 403, headers });
  if (!allowed) return json({ error: "مصدر الطلب غير مسموح." }, 403);
  if (req.method !== "POST") return json({ error: "الطريقة غير مسموحة." }, 405);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "يجب تسجيل الدخول." }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = getServiceKey();
  if (!url || !serviceKey) return json({ error: "إعدادات السيرفر غير مكتملة." }, 500);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // 1) التحقق من الجلسة
  const { data: userData, error: userErr } = await admin.auth.getUser(token);
  if (userErr || !userData?.user) return json({ error: "الجلسة منتهية. سجّل الدخول من جديد." }, 401);
  const callerId = userData.user.id;

  // 2) التحقق أن المستخدم مدير فعّال
  const { data: me } = await admin.from("profiles").select("role, active").eq("id", callerId).maybeSingle();
  if (!me || !me.active || me.role !== "manager") {
    return json({ error: "هذه العملية للمدير فقط." }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "بيانات الطلب غير صالحة." }, 400);
  }
  if (!body || typeof body !== "object") return json({ error: "بيانات الطلب غير صالحة." }, 400);

  const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
  const validPassword = (p: unknown) => typeof p === "string" && p.length >= 8 && p.length <= 72;
  const userId = str(body.user_id);

  try {
    switch (body.action) {
      case "create": {
        const email = str(body.email).toLowerCase();
        const fullName = str(body.full_name);
        const role = str(body.role);
        if (!EMAIL_RE.test(email) || email.length > 254) return json({ error: "البريد الإلكتروني غير صالح." }, 400);
        if (!validPassword(body.password)) return json({ error: "كلمة المرور يجب أن تكون بين 8 و 72 حرفاً." }, 400);
        if (fullName.length < 1 || fullName.length > 80) return json({ error: "الاسم مطلوب (حتى 80 حرفاً)." }, 400);
        if (!ROLES.includes(role as typeof ROLES[number])) return json({ error: "الدور غير صالح." }, 400);

        const { data, error } = await admin.auth.admin.createUser({
          email, password: body.password as string, email_confirm: true,
        });
        if (error || !data.user) {
          const exists = /already|registered|exists/i.test(error?.message ?? "");
          return json({ error: exists ? "هذا البريد مسجّل مسبقاً." : "تعذّر إنشاء الحساب." }, exists ? 409 : 400);
        }
        const { error: pErr } = await admin.from("profiles").insert({ id: data.user.id, full_name: fullName, role, email });
        if (pErr) {
          await admin.auth.admin.deleteUser(data.user.id);
          return json({ error: "تعذّر حفظ بيانات الموظف." }, 500);
        }
        return json({ ok: true, id: data.user.id });
      }

      case "set_password": {
        if (!UUID_RE.test(userId)) return json({ error: "معرّف الموظف غير صالح." }, 400);
        if (!validPassword(body.password)) return json({ error: "كلمة المرور يجب أن تكون بين 8 و 72 حرفاً." }, 400);
        const { data: target } = await admin.from("profiles").select("id").eq("id", userId).maybeSingle();
        if (!target) return json({ error: "الموظف غير موجود." }, 404);
        const { error } = await admin.auth.admin.updateUserById(userId, { password: body.password as string });
        if (error) return json({ error: "تعذّر تغيير كلمة المرور." }, 400);
        return json({ ok: true });
      }

      case "set_active": {
        if (!UUID_RE.test(userId)) return json({ error: "معرّف الموظف غير صالح." }, 400);
        if (userId === callerId) return json({ error: "لا يمكنك تعطيل حسابك بنفسك." }, 400);
        const active = body.active === true;
        const { error: pErr } = await admin.from("profiles").update({ active }).eq("id", userId);
        if (pErr) return json({ error: pErr.message.includes("آخر مدير") ? pErr.message : "تعذّر تحديث الحالة." }, 400);
        // الحظر يُنهي قدرة الحساب على تسجيل الدخول
        await admin.auth.admin.updateUserById(userId, { ban_duration: active ? "none" : "876000h" });
        return json({ ok: true });
      }

      case "delete": {
        if (!UUID_RE.test(userId)) return json({ error: "معرّف الموظف غير صالح." }, 400);
        if (userId === callerId) return json({ error: "لا يمكنك حذف حسابك بنفسك." }, 400);
        const { error: pErr } = await admin.from("profiles").delete().eq("id", userId);
        if (pErr) return json({ error: pErr.message.includes("آخر مدير") ? pErr.message : "تعذّر حذف الموظف." }, 400);
        const { error } = await admin.auth.admin.deleteUser(userId);
        if (error) return json({ error: "تم حذف الملف لكن تعذّر حذف الحساب." }, 500);
        return json({ ok: true });
      }

      default:
        return json({ error: "عملية غير معروفة." }, 400);
    }
  } catch (_e) {
    return json({ error: "حدث خطأ غير متوقع. حاول مرة أخرى." }, 500);
  }
});
