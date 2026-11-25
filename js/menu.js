// =========================================================
// Mr Black — منيو الزبون
// الأسعار المعروضة هنا للعرض فقط؛ السعر النهائي يُحسب على السيرفر.
// =========================================================
import {
  sb, html, setHTML, raw, $, $$, money, setCurrency, errMsg, toast, toastError,
  openModal, withBusy, safeUrl, fmtDateTime,
} from './common.js';

const app = $('#app');
const params = new URLSearchParams(location.search);
const tableParam = params.get('table') ?? '';
const TABLE = /^[0-9]{1,3}$/.test(tableParam) ? Number(tableParam) : null;
const CART_KEY = `mrblack-cart-${TABLE}`;
const INVOICES_KEY = `mrblack-invoices-${TABLE}`;
const MAX_NOTE = 200;

const state = {
  ctx: null,
  categories: [],
  items: new Map(),     // id -> item
  offers: [],
  cart: [],             // [{key, item_id, qty, note}]
  sending: false,
};

// ---------- السلة (محفوظة في المتصفح) ----------
function loadCart() {
  try {
    const c = JSON.parse(localStorage.getItem(CART_KEY) || '[]');
    state.cart = Array.isArray(c) ? c.filter((l) => Number.isInteger(l.item_id) && Number.isInteger(l.qty)) : [];
  } catch { state.cart = []; }
}
function saveCart() {
  localStorage.setItem(CART_KEY, JSON.stringify(state.cart));
  renderCartBar();
}
const newKey = () => Math.random().toString(36).slice(2, 10);
const cartCount = () => state.cart.reduce((s, l) => s + l.qty, 0);
const qtyOfItem = (id) => state.cart.filter((l) => l.item_id === id).reduce((s, l) => s + l.qty, 0);

/** تقدير الخصم للعرض فقط (نفس منطق السيرفر) */
function unitDiscount(item) {
  let best = 0;
  for (const o of state.offers) {
    const applies = o.item_id === item.id || o.category_id === item.category_id || (o.item_id == null && o.category_id == null);
    if (!applies) continue;
    const d = o.discount_type === 'percent'
      ? Math.round(item.price * Number(o.discount_value) / 100)
      : Math.round(Number(o.discount_value));
    best = Math.max(best, Math.min(d, item.price));
  }
  return best;
}
const unitPrice = (item) => item.price - unitDiscount(item);

function estimateTotal() {
  const net = state.cart.reduce((s, l) => {
    const it = state.items.get(l.item_id);
    return it ? s + unitPrice(it) * l.qty : s;
  }, 0);
  const { tax_percent = 0, service_percent = 0 } = state.ctx || {};
  return net + Math.round(net * service_percent / 100) + Math.round(net * tax_percent / 100);
}

function addItem(id) {
  const line = state.cart.find((l) => l.item_id === id && !l.note);
  if (qtyOfItem(id) >= 50) { toast('الحد الأقصى 50 من الصنف الواحد.', 'error'); return; }
  if (line) line.qty += 1; else state.cart.push({ key: newKey(), item_id: id, qty: 1, note: '' });
  saveCart();
  updateStepper(id);
}
function removeOne(id) {
  // ننقص من آخر سطر لهذا الصنف
  const lines = state.cart.filter((l) => l.item_id === id);
  const line = lines.find((l) => !l.note) || lines[lines.length - 1];
  if (!line) return;
  line.qty -= 1;
  if (line.qty <= 0) state.cart = state.cart.filter((l) => l !== line);
  saveCart();
  updateStepper(id);
}

// ---------- العرض ----------
function stepperTpl(id) {
  const q = qtyOfItem(id);
  if (!q) return html`<button class="btn btn-gold btn-icon" data-add="${id}" aria-label="إضافة">+</button>`;
  return html`<div class="stepper">
    <button class="btn" data-dec="${id}" aria-label="إنقاص">−</button>
    <span class="qty num">${q}</span>
    <button class="btn btn-gold" data-add="${id}" aria-label="إضافة">+</button></div>`;
}
function updateStepper(id) {
  const box = app.querySelector(`[data-stepper="${id}"]`);
  if (box) setHTML(box, stepperTpl(id));
}

function itemTpl(it) {
  const disc = unitDiscount(it);
  const img = safeUrl(it.image_url);
  return html`
    <article class="item">
      ${img
        ? html`<img class="item-img" src="${img}" alt="" loading="lazy" referrerpolicy="no-referrer">`
        : html`<div class="item-img item-ph" aria-hidden="true">${it.name.trim().charAt(0)}</div>`}
      <div class="item-info">
        <b>${it.name}</b>
        ${it.description ? html`<p>${it.description}</p>` : ''}
        <div class="price num">${money(it.price - disc)}${disc ? html`<s>${money(it.price)}</s>` : ''}</div>
      </div>
      <div data-stepper="${it.id}">${stepperTpl(it.id)}</div>
    </article>`;
}

function renderMenu() {
  const byCat = new Map(state.categories.map((c) => [c.id, []]));
  for (const it of state.items.values()) byCat.get(it.category_id)?.push(it);
  const cats = state.categories.filter((c) => byCat.get(c.id).length);

  if (!cats.length) {
    setHTML(app, html`<div class="state"><h3>المنيو فارغ حالياً</h3><p>لا توجد أصناف متاحة الآن. يرجى سؤال الكاشير.</p></div>`);
    setHTML($('#chips'), '');
    return;
  }

  setHTML($('#chips'), html`${cats.map((c, i) =>
    html`<button class="chip ${i === 0 ? 'on' : ''}" data-cat="${c.id}" type="button">${c.name}</button>`)}`);

  const offers = state.offers.length ? html`<section class="offers" aria-label="العروض">
    ${state.offers.map((o) => html`<div class="offer"><b>${o.title}</b>
      <small>${o.discount_type === 'percent' ? `خصم ${Number(o.discount_value)}%` : `خصم ${money(o.discount_value)}`}
      ${o.description ? ` — ${o.description}` : ''}</small></div>`)}
  </section>` : '';

  setHTML(app, html`${offers}${cats.map((c) => html`
    <section class="cat-section" id="cat-${c.id}">
      <h2>${c.name}</h2>
      <div class="items">${byCat.get(c.id).sort((a, b) => a.sort - b.sort || a.id - b.id).map(itemTpl)}</div>
    </section>`)}`);

  setupChipSpy();
}

function setupChipSpy() {
  const chips = $$('.chip');
  chips.forEach((ch) => ch.addEventListener('click', () => {
    document.getElementById(`cat-${ch.dataset.cat}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }));
  const obs = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      const id = e.target.id.replace('cat-', '');
      chips.forEach((c) => c.classList.toggle('on', c.dataset.cat === id));
      chips.find((c) => c.dataset.cat === id)?.scrollIntoView({ inline: 'center', block: 'nearest' });
    });
  }, { rootMargin: '-140px 0px -60% 0px' });
  $$('.cat-section').forEach((s) => obs.observe(s));
}

function renderCartBar() {
  const n = cartCount();
  $('#cart-bar').classList.toggle('hidden', n === 0);
  $('#cart-count').textContent = n;
  $('#cart-total').textContent = n ? `≈ ${money(estimateTotal())}` : '';
}

// ---------- السلة ----------
let cartModal = null;
let quoteSeq = 0;

function payloadItems() {
  return state.cart.map((l) => ({ item_id: l.item_id, qty: l.qty, note: l.note.trim() || null }));
}

function totalsTpl(q) {
  return html`<div class="totals">
    <div><span>المجموع</span><span class="num">${money(q.subtotal)}</span></div>
    ${q.discount ? html`<div><span>الخصم</span><span class="num">− ${money(q.discount)}</span></div>` : ''}
    ${Number(q.service_percent) ? html`<div><span>رسوم الخدمة (${Number(q.service_percent)}%)</span><span class="num">${money(q.service)}</span></div>` : ''}
    ${Number(q.tax_percent) ? html`<div><span>الضريبة (${Number(q.tax_percent)}%)</span><span class="num">${money(q.tax)}</span></div>` : ''}
    <div class="grand"><span>الإجمالي</span><span class="num">${money(q.total)}</span></div>
  </div>`;
}

async function refreshQuote() {
  if (!cartModal) return;
  const box = cartModal.body.querySelector('[data-totals]');
  const sendBtn = cartModal.body.querySelector('[data-send]');
  if (!box || !sendBtn || !state.cart.length) return;
  const seq = ++quoteSeq;
  box.style.opacity = '.5';
  const { data, error } = await sb.rpc('quote_order', { p_items: payloadItems() });
  if (seq !== quoteSeq || !cartModal) return;
  box.style.opacity = '1';
  if (error) {
    setHTML(box, html`<p class="form-error" style="margin-top:12px">${errMsg(error)}</p>`);
    sendBtn.disabled = true;
    return;
  }
  sendBtn.disabled = false;
  setHTML(box, totalsTpl(data));
}
let quoteTimer;
const refreshQuoteSoon = () => { clearTimeout(quoteTimer); quoteTimer = setTimeout(refreshQuote, 350); };

function renderCartBody() {
  if (!cartModal) return;
  const linesBox = cartModal.body.querySelector('[data-lines]');
  if (!state.cart.length) {
    setHTML(cartModal.body, html`<div class="state"><h3>السلة فارغة</h3><p>أضف أصنافاً من المنيو.</p>
      <button class="btn btn-gold" data-close>العودة للمنيو</button></div>`);
    return;
  }
  setHTML(linesBox, html`${state.cart.map((l) => {
    const it = state.items.get(l.item_id);
    return html`<div class="cart-line" data-key="${l.key}">
      <div class="cart-line-top">
        <div><b>${it?.name ?? 'صنف'}</b><div class="muted num" style="font-size:13px">${it ? money(unitPrice(it)) : ''}</div></div>
        <div class="stepper">
          <button class="btn" data-line-dec aria-label="إنقاص">−</button>
          <span class="qty num">${l.qty}</span>
          <button class="btn btn-gold" data-line-inc aria-label="زيادة">+</button>
        </div>
      </div>
      <input class="input" data-note maxlength="${MAX_NOTE}" placeholder="ملاحظة (اختياري): مثلاً بدون سكر" value="${l.note}">
    </div>`;
  })}`);
}

function openCart() {
  cartModal = openModal('سلتك', html`
    <div data-lines></div>
    <div data-totals></div>
    <p class="form-error" data-err style="margin-top:10px"></p>
    <button class="btn btn-gold" data-send style="width:100%;margin-top:6px;min-height:50px">إرسال الطلب — طاولة ${TABLE}</button>
    <p class="muted" style="font-size:12px;text-align:center;margin-top:8px">السعر النهائي يُحسب من النظام عند الإرسال.</p>`);
  const m = cartModal;
  renderCartBody();
  refreshQuote();

  m.body.addEventListener('click', (e) => {
    const lineEl = e.target.closest('[data-key]');
    if (lineEl) {
      const line = state.cart.find((l) => l.key === lineEl.dataset.key);
      if (!line) return;
      if (e.target.closest('[data-line-inc]')) {
        if (qtyOfItem(line.item_id) >= 50) { toast('الحد الأقصى 50 من الصنف الواحد.', 'error'); return; }
        line.qty += 1;
      } else if (e.target.closest('[data-line-dec]')) {
        line.qty -= 1;
        if (line.qty <= 0) state.cart = state.cart.filter((x) => x !== line);
      } else return;
      saveCart();
      updateStepper(line.item_id);
      renderCartBody();
      refreshQuoteSoon();
    }
    if (e.target.closest('[data-send]')) sendOrder(e.target.closest('[data-send]'));
  });
  m.body.addEventListener('input', (e) => {
    if (!e.target.matches('[data-note]')) return;
    const line = state.cart.find((l) => l.key === e.target.closest('[data-key]').dataset.key);
    if (line) { line.note = e.target.value.slice(0, MAX_NOTE); saveCart(); }
  });
  new MutationObserver((_, obs) => {
    if (!m.root.isConnected) { obs.disconnect(); if (cartModal === m) cartModal = null; }
  }).observe(document.body, { childList: true });
}

async function sendOrder(btn) {
  if (state.sending || !state.cart.length) return;
  const errBox = cartModal.body.querySelector('[data-err]');
  errBox.textContent = '';
  state.sending = true;
  try {
    await withBusy(btn, async () => {
      const { data, error } = await sb.rpc('place_order', { p_table: TABLE, p_items: payloadItems() });
      if (error) { errBox.textContent = errMsg(error); return; }
      state.cart = [];
      saveCart();
      storeInvoice(data);
      cartModal?.close();
      $$('[data-stepper]').forEach((el) => updateStepper(Number(el.dataset.stepper)));
      showInvoice(data, true);
    });
  } finally {
    state.sending = false;
  }
}

// ---------- الفاتورة ----------
function storeInvoice(inv) {
  const list = getInvoices();
  list.unshift(inv);
  sessionStorage.setItem(INVOICES_KEY, JSON.stringify(list.slice(0, 10)));
  $('#my-orders-btn').classList.remove('hidden');
}
function getInvoices() {
  try { return JSON.parse(sessionStorage.getItem(INVOICES_KEY) || '[]'); } catch { return []; }
}

function invoiceTpl(inv, fresh) {
  return html`<div class="invoice">
    ${fresh ? html`<div class="invoice-head"><div class="ok-icon" aria-hidden="true">✓</div>
      <h3>تم إرسال طلبك</h3><p class="muted">سيبدأ تحضيره الآن. شكراً لاختيارك Mr Black</p></div>` : ''}
    <div class="card">
      <div class="row" style="justify-content:space-between;margin-bottom:8px">
        <b>فاتورة رقم <span class="num">#${inv.order_id}</span></b>
        <span class="muted num" style="font-size:13px">طاولة ${inv.table_number} · ${fmtDateTime(inv.created_at)}</span>
      </div>
      <div class="invoice-lines">${inv.lines.map((l) => html`<div>
        <span><span class="num">${l.qty}×</span> ${l.item_name}${l.note ? html`<em>${l.note}</em>` : ''}</span>
        <span class="num">${money(l.line_total)}</span></div>`)}</div>
      ${totalsTpl(inv)}
    </div>
  </div>`;
}

function showInvoice(inv, fresh = false) {
  const m = openModal(fresh ? 'الفاتورة' : `فاتورة #${inv.order_id}`, html`
    ${invoiceTpl(inv, fresh)}
    <button class="btn btn-gold" data-close style="width:100%;margin-top:12px">${fresh ? 'متابعة التصفح' : 'إغلاق'}</button>`);
  return m;
}

function showInvoicesList() {
  const list = getInvoices();
  if (!list.length) return;
  const m = openModal('فواتيري', html`${list.map((inv, i) => html`
    <button class="btn" data-i="${i}" style="width:100%;justify-content:space-between;margin-bottom:8px">
      <span>فاتورة #${inv.order_id}</span><span class="num">${money(inv.total)}</span></button>`)}`);
  m.body.addEventListener('click', (e) => {
    const b = e.target.closest('[data-i]');
    if (b) { m.close(); showInvoice(list[Number(b.dataset.i)]); }
  });
}

// ---------- التشغيل ----------
async function load() {
  if (TABLE === null) {
    setHTML(app, html`<div class="state">
      <h3>أهلاً بك في Mr Black</h3>
      <p>للطلب: امسح رمز QR الموجود على طاولتك.</p>
      <div style="display:flex;flex-direction:column;gap:10px;max-width:300px;margin:26px auto 0">
        <p class="muted" style="font-size:13px">للموظفين:</p>
        <a class="btn btn-gold" href="casher.html">لوحة الكاشير والإدارة</a>
        <a class="btn" href="kitchen.html">شاشة المطبخ</a>
      </div></div>`);
    return;
  }
  setHTML(app, html`<div class="items">${raw('<div class="skeleton" style="height:92px"></div>'.repeat(6))}</div>`);

  try {
    const [ctxRes, catRes, itemRes, offRes] = await Promise.all([
      sb.rpc('menu_context', { p_table: TABLE }),
      sb.from('categories').select('id, name, sort').order('sort').order('id'),
      sb.from('menu_items').select('id, category_id, name, description, price, image_url, sort'),
      sb.from('offers').select('id, title, description, discount_type, discount_value, item_id, category_id, ends_at'),
    ]);
    for (const r of [ctxRes, catRes, itemRes, offRes]) if (r.error) throw r.error;

    state.ctx = ctxRes.data;
    setCurrency(state.ctx.currency);
    $('#cafe-name').textContent = state.ctx.cafe_name;
    document.title = `${state.ctx.cafe_name} — المنيو`;

    if (!state.ctx.network_ok) {
      setHTML(app, html`<div class="state"><h3>اتصل بشبكة واي فاي الكافيه</h3>
        <p>المنيو والطلب متاحان فقط من داخل ${state.ctx.cafe_name}.<br>اتصل بشبكة الواي فاي (وأوقف بيانات الجوال إن لزم) ثم أعد المحاولة.</p>
        <button class="btn btn-gold" data-retry>إعادة المحاولة</button></div>`);
      return;
    }
    if (!state.ctx.table_valid) {
      setHTML(app, html`<div class="state"><h3>رقم الطاولة غير صالح</h3>
        <p>امسح رمز QR الموجود على طاولتك مرة أخرى، أو اطلب المساعدة من الكاشير.</p></div>`);
      return;
    }
    $('#table-label').textContent = `طاولة رقم ${TABLE}`;

    state.categories = catRes.data;
    state.items = new Map(itemRes.data.map((i) => [i.id, i]));
    state.offers = offRes.data;

    loadCart();
    const before = state.cart.length;
    state.cart = state.cart.filter((l) => state.items.has(l.item_id));
    if (state.cart.length < before) toast('تمت إزالة أصناف لم تعد متوفرة من سلتك.');
    saveCart();
    if (getInvoices().length) $('#my-orders-btn').classList.remove('hidden');

    renderMenu();
  } catch (e) {
    setHTML(app, html`<div class="state"><h3>تعذّر تحميل المنيو</h3><p>${errMsg(e)}</p>
      <button class="btn btn-gold" data-retry>إعادة المحاولة</button></div>`);
  }
}

app.addEventListener('click', (e) => {
  const add = e.target.closest('[data-add]');
  if (add) { addItem(Number(add.dataset.add)); return; }
  const dec = e.target.closest('[data-dec]');
  if (dec) { removeOne(Number(dec.dataset.dec)); return; }
  if (e.target.closest('[data-retry]')) load();
});
$('#cart-btn').addEventListener('click', openCart);
$('#my-orders-btn').addEventListener('click', showInvoicesList);
window.addEventListener('online', () => toast('عاد الاتصال بالإنترنت.', 'success'));
window.addEventListener('offline', () => toast('انقطع الاتصال بالإنترنت.', 'error'));

load().catch(toastError);
