// تبويب الطلبات: لحظية + سجل
import {
  sb, html, setHTML, $, money, elapsed, minutesSince, fmtTime, fmtDateTime, toast, toastError,
  withBusy, confirmDialog, openModal, todayYMD, dayStart, addDays, STATUS_LABELS, STATUS_BADGE,
} from '../common.js';
import { changeStatus } from '../orders-feed.js';
import { loadingTpl, errorTpl, emptyTpl, printTpl } from './util.js';

const NEXT = {
  new: [{ to: 'preparing', label: 'بدء التحضير', cls: 'btn-gold' }],
  preparing: [{ to: 'ready', label: 'جاهز', cls: 'btn-ok' }],
  ready: [{ to: 'served', label: 'تم التسليم', cls: 'btn-gold' }],
};

function receiptTpl(o, settings) {
  return html`<div class="receipt">
    <h2>${settings.cafe_name || 'Mr Black'}</h2>
    <div class="r-line"><span>فاتورة #${o.id}</span><span>طاولة ${o.table_number}</span></div>
    <div class="r-line"><span>${fmtDateTime(o.created_at)}</span></div>
    <hr>
    ${(o.order_items || []).map((l) => html`<div class="r-line"><span>${l.qty}× ${l.item_name}</span><span>${money(l.line_total)}</span></div>
      ${l.note ? html`<div style="font-size:11px">  ✎ ${l.note}</div>` : ''}`)}
    <hr>
    <div class="r-line"><span>المجموع</span><span>${money(o.subtotal)}</span></div>
    ${o.discount ? html`<div class="r-line"><span>الخصم</span><span>− ${money(o.discount)}</span></div>` : ''}
    ${o.service ? html`<div class="r-line"><span>الخدمة</span><span>${money(o.service)}</span></div>` : ''}
    ${o.tax ? html`<div class="r-line"><span>الضريبة</span><span>${money(o.tax)}</span></div>` : ''}
    <hr>
    <div class="r-line" style="font-size:15px;font-weight:bold"><span>الإجمالي</span><span>${money(o.total)}</span></div>
    <p style="text-align:center;margin-top:8px">شكراً لزيارتكم</p>
  </div>`;
}

export function mount(el, ctx) {
  let mode = 'active';
  let histDate = todayYMD();
  let histStatus = 'all';
  let timer = null;

  setHTML(el, html`
    <div class="page-head">
      <h2>الطلبات</h2>
      <div class="filters" style="margin:0">
        <button class="btn btn-sm on" data-mode="active" type="button">النشطة</button>
        <button class="btn btn-sm" data-mode="history" type="button">السجل</button>
      </div>
    </div>
    <div id="o-body"></div>`);
  const body = $('#o-body', el);

  // ---------- النشطة ----------
  function cardTpl(o) {
    const late = ctx.settings.late_minutes || 15;
    const mins = minutesSince(o.created_at);
    const cls = o.status === 'ready' ? '' : mins >= late ? 'late' : mins >= late * 0.7 ? 'warn' : '';
    return html`<article class="order ${cls}" data-id="${o.id}">
      <div class="order-head">
        <b>طاولة ${o.table_number}</b>
        <span class="badge ${STATUS_BADGE[o.status]}">${STATUS_LABELS[o.status]}</span>
        <span class="timer" data-since="${o.status === 'ready' ? '' : o.created_at}">${o.status === 'ready' ? '✓' : elapsed(o.created_at)}</span>
      </div>
      <div class="order-body">
        <div class="muted num" style="font-size:12px;margin-bottom:4px">#${o.id} · ${fmtTime(o.created_at)}</div>
        ${(o.order_items || []).map((l) => html`<div class="order-line"><span class="q num">${l.qty}×</span>${l.item_name}
          ${l.note ? html`<span class="note">✎ ${l.note}</span>` : ''}</div>`)}
        <div class="row" style="justify-content:space-between;margin-top:8px;font-weight:800">
          <span>الإجمالي</span><span class="num" style="color:var(--gold-2)">${money(o.total)}</span></div>
      </div>
      <div class="order-foot">
        ${NEXT[o.status].map((a) => html`<button class="btn btn-sm ${a.cls}" data-to="${a.to}" type="button">${a.label}</button>`)}
        <button class="btn btn-sm btn-ghost" data-print type="button" title="طباعة">🖨</button>
        <button class="btn btn-sm btn-danger" data-to="cancelled" type="button">إلغاء</button>
      </div>
    </article>`;
  }

  function renderActive() {
    if (mode !== 'active') return;
    const list = ctx.orders;
    if (!list.length) { setHTML(body, emptyTpl('لا توجد طلبات نشطة', 'ستظهر الطلبات الجديدة هنا فوراً مع تنبيه صوتي.')); return; }
    const order = { new: 0, preparing: 1, ready: 2 };
    const sorted = [...list].sort((a, b) => order[a.status] - order[b.status] || new Date(a.created_at) - new Date(b.created_at));
    setHTML(body, html`<div class="orders-grid">${sorted.map(cardTpl)}</div>`);
  }

  function tick() {
    const late = ctx.settings.late_minutes || 15;
    el.querySelectorAll('.order [data-since]').forEach((t) => {
      if (!t.dataset.since) return;
      t.textContent = elapsed(t.dataset.since);
      const mins = minutesSince(t.dataset.since);
      const card = t.closest('.order');
      card.classList.toggle('late', mins >= late);
      card.classList.toggle('warn', mins < late && mins >= late * 0.7);
    });
  }

  // ---------- السجل ----------
  let histOrders = [];
  async function renderHistory() {
    setHTML(body, html`
      <div class="filters">
        <input class="input" type="date" id="h-date" value="${histDate}" max="${todayYMD()}">
        <select class="input" id="h-status" style="width:auto">
          <option value="all">كل الحالات</option>
          ${Object.entries(STATUS_LABELS).map(([k, v]) => html`<option value="${k}" ${histStatus === k ? html`selected` : ''}>${v}</option>`)}
        </select>
      </div>
      <div id="h-list">${loadingTpl()}</div>`);
    $('#h-date', body).onchange = (e) => { histDate = e.target.value || todayYMD(); renderHistory(); };
    $('#h-status', body).onchange = (e) => { histStatus = e.target.value; renderHistory(); };

    const from = dayStart(histDate);
    const to = dayStart(addDays(histDate, 1));
    let q = sb.from('orders')
      .select('id, table_number, status, subtotal, discount, service, tax, total, created_at, order_items(id, item_name, qty, note, line_total)')
      .gte('created_at', from.toISOString()).lt('created_at', to.toISOString())
      .order('created_at', { ascending: false }).limit(500);
    if (histStatus !== 'all') q = q.eq('status', histStatus);
    const { data, error } = await q;
    const box = $('#h-list', body);
    if (!box) return;
    if (error) { setHTML(box, errorTpl(error)); return; }
    histOrders = data;
    if (!data.length) { setHTML(box, emptyTpl('لا توجد طلبات في هذا اليوم')); return; }
    const sum = data.filter((o) => o.status !== 'cancelled').reduce((s, o) => s + Number(o.total), 0);
    setHTML(box, html`
      <p class="muted" style="margin-bottom:8px">${data.length} طلب · إجمالي غير الملغى: <b class="num" style="color:var(--gold-2)">${money(sum)}</b></p>
      <div class="table-wrap"><table class="data">
        <thead><tr><th>#</th><th>الوقت</th><th>الطاولة</th><th>الأصناف</th><th>الإجمالي</th><th>الحالة</th><th></th></tr></thead>
        <tbody>${data.map((o) => html`<tr data-id="${o.id}">
          <td class="num">${o.id}</td><td class="num">${fmtTime(o.created_at)}</td><td class="num">${o.table_number}</td>
          <td class="wrap">${o.order_items.map((l) => `${l.qty}× ${l.item_name}`).join('، ')}</td>
          <td class="num">${money(o.total)}</td>
          <td><span class="badge ${STATUS_BADGE[o.status]}">${STATUS_LABELS[o.status]}</span></td>
          <td><button class="btn btn-sm btn-ghost" data-print type="button">🖨 طباعة</button></td></tr>`)}
        </tbody></table></div>`);
  }

  function render() {
    el.querySelectorAll('[data-mode]').forEach((b) => b.classList.toggle('on', b.dataset.mode === mode));
    if (mode === 'active') renderActive(); else renderHistory();
  }

  // ---------- الأحداث ----------
  el.addEventListener('click', async (e) => {
    const m = e.target.closest('[data-mode]');
    if (m) { mode = m.dataset.mode; render(); return; }
    if (e.target.closest('[data-retry]')) { render(); return; }

    const host = e.target.closest('[data-id]');
    if (!host) return;
    const id = Number(host.dataset.id);
    const o = ctx.orders.find((x) => x.id === id) || histOrders.find((x) => x.id === id);

    if (e.target.closest('[data-print]') && o) { printTpl(receiptTpl(o, ctx.settings)); return; }

    const btn = e.target.closest('[data-to]');
    if (!btn) return;
    const to = btn.dataset.to;
    if (to === 'cancelled' && !(await confirmDialog(`إلغاء الطلب #${id}؟ سيتم إرجاع الكميات إلى المخزون.`, { okLabel: 'نعم، إلغاء الطلب', danger: true }))) return;
    await withBusy(btn, async () => {
      try {
        await changeStatus(id, to);
        ctx.feed.patch(id, { status: to });
        toast(`الطلب #${id}: ${STATUS_LABELS[to]}`, 'success');
      } catch (err) { toastError(err); }
    });
  });

  const onOrders = () => renderActive();
  ctx.ordersListeners.add(onOrders);
  timer = setInterval(tick, 1000);
  render();

  return () => { ctx.ordersListeners.delete(onOrders); clearInterval(timer); };
}

export { receiptTpl };
