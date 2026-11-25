// =========================================================
// Mr Black — تغذية الطلبات اللحظية (مشتركة بين الكاشير والمطبخ)
// =========================================================
import { sb } from './common.js';

const ORDER_SELECT = 'id, table_number, status, subtotal, discount, service, tax, total, created_at, started_at, ready_at, served_at, cancelled_at, order_items(id, item_name, qty, note, unit_price, unit_discount, line_total)';

/**
 * يحمّل الطلبات المفتوحة ويستمع للتغييرات.
 * statuses: الحالات المطلوب عرضها
 * onChange(ordersArray, {newIds}) يُستدعى عند كل تحديث
 * onConn(state) : 'on' | 'off' | 'connecting'
 */
export function startOrdersFeed({ statuses, onChange, onConn, onError }) {
  const orders = new Map();
  let firstLoad = true;
  let reloadTimer = null;

  const emit = (newIds = []) => {
    const list = [...orders.values()].sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    onChange(list, { newIds });
  };

  async function reloadAll() {
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const { data, error } = await sb.from('orders').select(ORDER_SELECT)
      .in('status', statuses).gte('created_at', since).order('created_at').limit(300);
    if (error) { onError?.(error); return; }
    const newIds = firstLoad ? [] : data.filter((o) => !orders.has(o.id) && o.status === 'new').map((o) => o.id);
    orders.clear();
    data.forEach((o) => orders.set(o.id, o));
    firstLoad = false;
    emit(newIds);
  }

  async function fetchOne(id) {
    const { data, error } = await sb.from('orders').select(ORDER_SELECT).eq('id', id).maybeSingle();
    if (error) { onError?.(error); return; }
    if (!data) return;
    const isNew = !orders.has(id) && data.status === 'new';
    if (statuses.includes(data.status)) orders.set(id, data); else orders.delete(id);
    emit(isNew ? [id] : []);
  }

  const channel = sb.channel('orders-feed')
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'orders' }, (p) => fetchOne(p.new.id))
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'orders' }, (p) => {
      const cur = orders.get(p.new.id);
      if (!statuses.includes(p.new.status)) {
        if (orders.delete(p.new.id)) emit();
      } else if (cur) {
        orders.set(p.new.id, { ...cur, ...p.new });
        emit();
      } else fetchOne(p.new.id);
    })
    .subscribe((status) => {
      if (status === 'SUBSCRIBED') { onConn?.('on'); reloadAll(); }
      else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') onConn?.('off');
    });

  onConn?.('connecting');
  reloadAll();
  // احتياط: إعادة مزامنة دورية في حال انقطع الاتصال اللحظي
  reloadTimer = setInterval(reloadAll, 45000);
  window.addEventListener('online', reloadAll);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) reloadAll(); });

  return {
    reload: reloadAll,
    /** تحديث محلي فوري بعد تغيير الحالة */
    patch(id, fields) {
      const cur = orders.get(id);
      if (!cur) return;
      const next = { ...cur, ...fields };
      if (statuses.includes(next.status)) orders.set(id, next); else orders.delete(id);
      emit();
    },
    stop() { clearInterval(reloadTimer); sb.removeChannel(channel); },
  };
}

export async function changeStatus(id, status) {
  const { error } = await sb.rpc('set_order_status', { p_order_id: id, p_status: status });
  if (error) throw error;
}
