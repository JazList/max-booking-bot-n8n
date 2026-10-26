// n8n Code node, mode: Run Once for All Items. API мини-приложения М2: проверка initData (как m1/check.js, KB-06B §2.4)
// и выбор одного SQL из белого списка; значения идут только параметрами. user_id — только из проверенных данных.
// Выход: { sql, params } для узла Exec; при отказе — SQL-заглушка, которая возвращает { error_code }.
const crypto = require('crypto');
const SC = 'demo_booking';
const MSK = "(now() at time zone 'Europe/Moscow')::date";
const Q = {
  ctx: `select jsonb_build_object(
    'consent', ${SC}.bot_context($1::bigint, null)->'consent',
    'services', (select coalesce(jsonb_agg(jsonb_build_object('id',s.service_id,'title',s.title,'min',s.duration_minutes,'price',s.price_minor) order by s.n),'[]'::jsonb)
                 from ${SC}.list_services() with ordinality as s(service_id,code,title,duration_minutes,price_minor,n)),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('svc',s.service_id,'id',t.staff_id,'name',t.display_name)),'[]'::jsonb)
              from ${SC}.list_services() as s cross join lateral ${SC}.list_staff(s.service_id) as t),
    'my', ${SC}.bot_my_appointments($1::bigint)) as r`,
  slots: `select coalesce(jsonb_agg(jsonb_build_object('id',slot_id,'d',to_char((starts_at at time zone 'Europe/Moscow')::date,'YYYY-MM-DD'),
    't',to_char(starts_at at time zone 'Europe/Moscow','HH24:MI'),'staff',staff_name) order by starts_at, staff_name),'[]'::jsonb) as r
    from ${SC}.free_slots($1::uuid, nullif($2,'any')::uuid, ${MSK}, ${MSK} + 13)`,
  book: `with g as (select case when $8::boolean then ${SC}.bot_grant_consent($1::bigint) end as x)
    select ${SC}.bot_create_appointment($1::bigint,$2::uuid,$3::uuid,$4::uuid,$5::uuid,$6,$7) as r from g`,
  my: `select ${SC}.bot_my_appointments($1::bigint) as r`,
  cancel: `select ${SC}.bot_cancel_appointment($1::bigint,$2::uuid) as r`
};
const fail = (code) => [{ json: { sql: 'select jsonb_build_object(\'error_code\', $1::text) as r', params: [code] } }];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const body = ($input.first().json || {}).body || {};
const keyHex = $env.DEMO_WEBAPP_KEY || '';
if (!/^[0-9a-f]{64}$/.test(keyHex)) return fail('server_key_missing');

// ---- проверка подписи initData ----
const dec = (s) => { try { return decodeURIComponent(String(s).replace(/\+/g, '%20')); } catch (e) { return null; } };
let raw = typeof body.initData === 'string' ? body.initData : '';
if (!raw && typeof body.fragment === 'string') raw = body.fragment.replace(/^#/, '');
if (!raw || raw.length > 8192) return fail('no_init_data');
if (raw.startsWith('WebAppData=')) raw = dec(raw.slice('WebAppData='.length).split('&')[0]) || '';
const pairs = [];
for (const part of raw.split('&')) {
  if (!part) continue;
  const i = part.indexOf('=');
  if (i < 1) return fail('bad_pair');
  pairs.push([part.slice(0, i), part.slice(i + 1)]);
}
const hashes = pairs.filter(([k]) => k === 'hash');
if (hashes.length !== 1 || !/^[0-9a-f]{64}$/i.test(hashes[0][1])) return fail('bad_hash');
const given = Buffer.from(hashes[0][1].toLowerCase(), 'hex');
const rest = pairs.filter(([k]) => k !== 'hash');
const secret = Buffer.from(keyHex, 'hex');
const sign = (s) => crypto.createHmac('sha256', secret).update(s, 'utf8').digest();
const build = (decode) => rest.map(([k, v]) => [k, decode ? dec(v) : v]).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([k, v]) => k + '=' + v).join('\n');
let okSig = false;
for (const decode of [true, false]) {
  const s = build(decode);
  if (s.includes('=null')) continue;
  if (crypto.timingSafeEqual(sign(s), given)) { okSig = true; break; }
}
if (!okSig) return fail('signature_mismatch');
const get = (k) => { const p = rest.find(([x]) => x === k); return p ? dec(p[1]) : null; };
let user = {};
try { user = JSON.parse(get('user') || '{}'); } catch (e) { user = {}; }
let authDate = Number(get('auth_date'));
if (authDate > 1e12) authDate = Math.floor(authDate / 1000);
const age = Math.floor(Date.now() / 1000) - authDate;
if (!Number.isFinite(age) || age > 86400 || age < -300) return fail('stale_auth_date');
const uid = Number(user.id);
if (!Number.isSafeInteger(uid) || uid <= 0) return fail('no_user');

// ---- операция ----
const a = body.args && typeof body.args === 'object' ? body.args : {};
const str = (v, max) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const uuidFrom = (s) => {
  const h = crypto.createHash('sha256').update(s).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const go = (op, params) => [{ json: { sql: Q[op], params } }];
switch (body.op) {
  case 'ctx': return go('ctx', [uid]);
  case 'my': return go('my', [uid]);
  case 'slots':
    if (!UUID.test(a.svc || '') || (a.staff !== 'any' && !UUID.test(a.staff || ''))) return fail('bad_args');
    return go('slots', [a.svc, a.staff]);
  case 'book': {
    const name = str(a.name, 60), phone = str(a.phone, 24), n = str(a.n, 40);
    if (!UUID.test(a.svc || '') || !UUID.test(a.slot || '') || !name || !phone || !/^[A-Za-z0-9-]{8,40}$/.test(n)) return fail('bad_args');
    // повтор того же нажатия (тот же n) дает тот же uuid записи — дубля не будет
    return go('book', [uid, uuidFrom(`m|${uid}|${a.slot}|${n}`), uuidFrom(`mc|${uid}|${n}`), a.svc, a.slot, name, phone, a.consent === true]);
  }
  case 'cancel':
    if (!UUID.test(a.appt || '')) return fail('bad_args');
    return go('cancel', [uid, a.appt]);
}
return fail('bad_op');
