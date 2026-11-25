-- Mr Black — منيو تجريبي (الأسعار تقريبية، عدّلها من لوحة المدير)
insert into public.categories (name, sort) values
  ('قهوة ساخنة', 1), ('مشروبات باردة', 2), ('حلويات', 3), ('مأكولات خفيفة', 4);

insert into public.menu_items (category_id, name, description, price, sort, track_stock, stock_qty)
select c.id, v.name, v.description, v.price, v.sort, v.track, v.qty
from (values
  ('قهوة ساخنة',    'إسبريسو',          'شوت مركّز من بن محمّص طازج',         15000, 1, false, 0),
  ('قهوة ساخنة',    'إسبريسو مزدوج',    'شوتين لمحبي القهوة القوية',          20000, 2, false, 0),
  ('قهوة ساخنة',    'أمريكانو',         'إسبريسو مع ماء ساخن',                18000, 3, false, 0),
  ('قهوة ساخنة',    'كابتشينو',         'إسبريسو وحليب مخفوق برغوة كثيفة',    25000, 4, false, 0),
  ('قهوة ساخنة',    'لاتيه',            'إسبريسو مع حليب ناعم',               25000, 5, false, 0),
  ('قهوة ساخنة',    'قهوة عربية',       'بالهيل، دلّة صغيرة',                 20000, 6, false, 0),
  ('مشروبات باردة', 'آيس لاتيه',        'إسبريسو وحليب بارد على الثلج',       28000, 1, false, 0),
  ('مشروبات باردة', 'آيس أمريكانو',     'منعش وخفيف',                         22000, 2, false, 0),
  ('مشروبات باردة', 'موهيتو ليمون',     'ليمون ونعنع وصودا',                  25000, 3, false, 0),
  ('مشروبات باردة', 'عصير برتقال',      'طبيعي معصور عند الطلب',              22000, 4, false, 0),
  ('حلويات',        'تشيز كيك',         'بصوص التوت الأحمر',                  35000, 1, true, 12),
  ('حلويات',        'براوني',           'شوكولا داكنة، يقدّم دافئاً',         30000, 2, true, 15),
  ('حلويات',        'كرواسون شوكولا',   'زبدة فرنسية وحشوة شوكولا',           20000, 3, true, 20),
  ('مأكولات خفيفة', 'ساندويش حلّومي',   'جبنة حلّومي مشوية وخضار',            35000, 1, true, 10),
  ('مأكولات خفيفة', 'ساندويش دجاج',     'صدر دجاج مشوي مع صوص خاص',          40000, 2, true, 10)
) as v(cat, name, description, price, sort, track, qty)
join public.categories c on c.name = v.cat;

-- رصيد افتتاحي في سجل المخزون للأصناف المتتبَّعة
insert into public.stock_movements (item_id, change, reason, note, created_by)
select id, stock_qty, 'restock', 'رصيد افتتاحي', null
from public.menu_items where track_stock and stock_qty > 0;

insert into public.cafe_tables (number) select generate_series(1, 10);
