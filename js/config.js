// =========================================================
// Mr Black — الإعدادات العامة
// تنبيه: هذا الملف علني. لا تضع فيه أي مفتاح سري أبداً.
// المفتاح الموجود هنا هو "publishable" (عام) ومصمَّم ليكون في المتصفح؛
// الحماية الحقيقية تأتي من سياسات RLS في قاعدة البيانات.
// =========================================================
export const SUPABASE_URL = 'https://wsgpvqwapdpmpqsdjbks.supabase.co';
export const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_NRLTHP1jIdH_DYL7-jtOCw_XXe8s4Tf';

// رابط مساعد الذكاء الاصطناعي (Cloudflare Worker)
export const AI_WORKER_URL = 'https://mr-black-assistant.dailydosecafe.workers.dev';

// رابط دالة إدارة الموظفين
export const STAFF_FUNCTION_URL = `${SUPABASE_URL}/functions/v1/manage-staff`;
