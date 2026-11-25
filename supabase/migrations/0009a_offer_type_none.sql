-- Mr Black — 0009a: نوع عرض بدون خصم (يجب أن يكون في migration منفصل عن استخدامه)
alter type public.discount_type add value if not exists 'none';
