// =========================================================
// Mr Black — لوحة الكاشير والإدارة (الإطار العام والتبويبات)
// =========================================================
import {
  sb, html, setHTML, $, staffGate, signOut, setCurrency, unlockAudio, audioReady, beep,
  toast, toastError, ROLE_LABELS,
} from '../common.js';
import { startOrdersFeed } from '../orders-feed.js';
import { mountAssistant } from '../assistant.js';
import * as ordersTab from './orders.js';
import * as menuTab from './menu-admin.js';
import * as inventoryTab from './inventory.js';
import * as tablesTab from './tables.js';
import * as offersTab from './offers.js';
import * as reportsTab from './reports.js';
import * as stocktakeTab from './stocktake.js';
import * as staffTab from './staff.js';
import * as settingsTab from './settings.js';
import * as wifiTab from './wifi.js';

const TABS = [
  { key: 'orders', label: 'الطلبات', mod: ordersTab, roles: ['manager', 'cashier'] },
  { key: 'menu', label: 'المنيو', mod: menuTab, roles: ['manager', 'cashier'] },
  { key: 'inventory', label: 'المخزون', mod: inventoryTab, roles: ['manager'] },
  { key: 'tables', label: 'الطاولات و QR', mod: tablesTab, roles: ['manager'] },
  { key: 'offers', label: 'العروض', mod: offersTab, roles: ['manager'] },
  { key: 'reports', label: 'التقارير', mod: reportsTab, roles: ['manager'] },
  { key: 'stocktake', label: 'الجرد', mod: stocktakeTab, roles: ['manager'] },
  { key: 'wifi', label: 'الشبكة', mod: wifiTab, roles: ['manager', 'cashier'] },
  { key: 'staff', label: 'الموظفون', mod: staffTab, roles: ['manager'] },
  { key: 'settings', label: 'الإعدادات', mod: settingsTab, roles: ['manager'] },
];

const root = $('#app');

staffGate({
  root,
  allowed: ['manager', 'cashier'],
  title: 'لوحة الكاشير والإدارة — سجّل الدخول',
  onReady: async (profile) => {
    const ctx = {
      profile,
      isManager: profile.role === 'manager',
      settings: null,
      orders: [],
      ordersListeners: new Set(),
      async loadSettings() {
        const { data, error } = await sb.from('settings').select('*').maybeSingle();
        if (error) throw error;
        ctx.settings = data;
        setCurrency(data.currency);
        return data;
      },
    };
    try { await ctx.loadSettings(); } catch (e) { toastError(e); ctx.settings = { late_minutes: 15, currency: 'ل.س' }; }

    const tabs = TABS.filter((t) => t.roles.includes(profile.role));
    setHTML(root, html`
      <header class="topbar no-print">
        <div class="topbar-in">
          <span class="brand">Mr Black</span>
          <span class="conn" id="conn" title="الاتصال اللحظي بالطلبات"></span>
          <span class="spacer"></span>
          <button class="btn btn-sm" id="sound-btn" type="button">🔔 تفعيل الصوت</button>
          <a class="btn btn-sm" href="kitchen.html">شاشة المطبخ</a>
          <span class="user-chip">${profile.full_name} · ${ROLE_LABELS[profile.role]}</span>
          <button class="btn btn-sm btn-ghost" id="logout" type="button">خروج</button>
        </div>
        <nav class="tabs" role="tablist">${tabs.map((t) => html`
          <button class="tab" role="tab" data-tab="${t.key}" type="button">${t.label}${t.key === 'orders' ? html`<span class="count hidden" id="new-count">0</span>` : ''}</button>`)}
        </nav>
      </header>
      <main class="page" id="tab-root"></main>`);

    $('#logout').onclick = () => signOut();
    const soundBtn = $('#sound-btn');
    soundBtn.onclick = () => {
      unlockAudio();
      setTimeout(() => {
        if (audioReady()) { soundBtn.textContent = '🔔 الصوت مفعّل'; soundBtn.classList.add('btn-gold'); beep(1); }
        else toast('تعذّر تفعيل الصوت في هذا المتصفح.', 'error');
      }, 100);
    };

    // ---------- التبويبات ----------
    const tabRoot = $('#tab-root');
    let current = null;
    function show(key) {
      const tab = tabs.find((t) => t.key === key) || tabs[0];
      if (current?.unmount) current.unmount();
      document.querySelectorAll('.tab').forEach((b) => {
        const on = b.dataset.tab === tab.key;
        b.classList.toggle('on', on);
        b.setAttribute('aria-selected', on);
      });
      // عنصر جديد لكل تبويب حتى لا تتراكم مستمعات الأحداث
      const host = document.createElement('div');
      tabRoot.replaceChildren(host);
      current = { key: tab.key, unmount: tab.mod.mount(host, ctx) };
      if (location.hash !== `#${tab.key}`) history.replaceState(null, '', `#${tab.key}`);
    }
    document.querySelector('.tabs').addEventListener('click', (e) => {
      const b = e.target.closest('[data-tab]');
      if (b) show(b.dataset.tab);
    });
    window.addEventListener('hashchange', () => show(location.hash.slice(1)));

    // ---------- الطلبات اللحظية (تعمل في كل التبويبات) ----------
    ctx.feed = startOrdersFeed({
      statuses: ['new', 'preparing', 'ready'],
      onChange: (list, { newIds }) => {
        ctx.orders = list;
        const n = list.filter((o) => o.status === 'new').length;
        const badge = $('#new-count');
        badge.textContent = n;
        badge.classList.toggle('hidden', n === 0);
        document.title = n ? `(${n}) Mr Black — الكاشير` : 'Mr Black — الكاشير والإدارة';
        if (newIds.length) {
          beep(3);
          const t = list.find((o) => o.id === newIds[0]);
          toast(newIds.length > 1 ? `${newIds.length} طلبات جديدة` : `طلب جديد #${newIds[0]} — طاولة ${t?.table_number ?? ''}`);
          if (!audioReady()) toast('فعّل الصوت من الزر أعلى الشاشة لسماع التنبيهات.', 'error');
        }
        ctx.ordersListeners.forEach((fn) => fn(list, newIds));
      },
      onConn: (s) => { const c = $('#conn'); if (c) c.className = `conn ${s}`; },
      onError: toastError,
    });

    show(location.hash.slice(1) || 'orders');
    mountAssistant(profile);
  },
});
