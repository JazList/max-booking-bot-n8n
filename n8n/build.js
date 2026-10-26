'use strict';
// Собирает сценарии n8n-max-booking из code/*.js.txt.
//   node build.js                      -> booking-dialog.json, booking-reminders.json (с плейсхолдерами, для склада)
//   node build.js --render <папка> --client demo --screen answer
//                                      -> подставленные файлы для импорта на стенд (фиксированные id)
// Секретов в выходных файлах нет: credential подключаются по id-плейсхолдерам.
const fs = require('fs');
const path = require('path');
const here = __dirname;
const code = (n) => fs.readFileSync(path.join(here, 'code', n), 'utf8');

const PG = { postgres: { id: '{{CRED_ID:pg}}', name: '{{CLIENT_CODE_UPPER}} n8n_runtime' } };
const HDR = { httpHeaderAuth: { id: '{{CRED_ID:max}}', name: '{{CLIENT_CODE_UPPER}} MAX bot token' } };
let pos = 0;
const node = (name, type, typeVersion, parameters, extra) => {
  pos += 1;
  return Object.assign({ parameters, id: `n${String(pos).padStart(2, '0')}-${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`,
    name, type, typeVersion, position: [pos * 220, 300] }, extra || {});
};
const codeNode = (name, file, mode) => node(name, 'n8n-nodes-base.code', 2,
  Object.assign({ jsCode: code(file) }, mode ? { mode } : {}));
const pgNode = (name, query, repl, extra) => node(name, 'n8n-nodes-base.postgres', 2.5,
  { operation: 'executeQuery', query, options: { queryReplacement: repl } }, Object.assign({ credentials: PG }, extra || {}));
const link = (conns, from, to, out) => {
  conns[from] = conns[from] || { main: [] };
  const o = out || 0;
  while (conns[from].main.length <= o) conns[from].main.push([]);
  conns[from].main[o].push({ node: to, type: 'main', index: 0 });
};
const httpSend = (name) => node(name, 'n8n-nodes-base.httpRequest', 4.2, {
  method: '={{ $json.method }}',
  url: '={{ $json.url }}',
  authentication: 'genericCredentialType',
  genericAuthType: 'httpHeaderAuth',
  sendBody: true,
  specifyBody: 'json',
  jsonBody: '={{ JSON.stringify($json.body) }}',
  options: { batching: { batch: { batchSize: 1, batchInterval: 600 } }, response: { response: { fullResponse: true, neverError: true } } }
}, { credentials: HDR, onError: 'continueRegularOutput' });
const SC = '{{CLIENT_CODE}}_booking';
const settings = { executionOrder: 'v1', saveDataSuccessExecution: 'all', saveDataErrorExecution: 'all' };

function dialog() {
  pos = 0;
  const nodes = [];
  const c = {};
  const add = (n) => { nodes.push(n); return n.name; };
  const wh = add(node('Webhook', 'n8n-nodes-base.webhook', 2, {
    httpMethod: 'POST', path: '{{CLIENT_CODE}}-booking-max', responseMode: 'responseNode', options: {}
  }, { webhookId: '{{CLIENT_CODE}}-booking-max-webhook' }));
  const guard = add(codeNode('Guard', 'booking-guard.js.txt'));
  const iff = add(node('Accepted', 'n8n-nodes-base.if', 2.2, {
    conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' },
      conditions: [{ id: 'accepted-true', leftValue: '={{ $json.accepted }}', rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }],
      combinator: 'and' },
    options: {}
  }));
  const reject = add(node('Respond reject', 'n8n-nodes-base.respondToWebhook', 1.1, {
    respondWith: 'json', responseBody: '={{ { ok: false, error: $json.error_code } }}', options: { responseCode: '={{ $json.status_code }}' }
  }));
  const ctxn = add(pgNode('Ctx', `select ${SC}.bot_context($1::bigint, $2) as ctx`, '={{ [$json.user_id, $json.event_id] }}'));
  const route = add(codeNode('Route', 'booking-route.js.txt'));
  const exec = add(pgNode('Exec', '={{ $json.sql }}', '={{ $json.params }}', { onError: 'continueRegularOutput', alwaysOutputData: true }));
  const render = add(codeNode('Render', 'booking-render.js.txt'));
  const save = add(pgNode('Save state',
    `select count(*) as saved from (select ${SC}.bot_state_set($1::bigint, nullif($3, ''), $4::jsonb) where $2::boolean) x`,
    '={{ [$json.user_id, $json.state_set, $json.state_step, $json.state_data] }}'));
  const respond = add(node('Respond ok', 'n8n-nodes-base.respondToWebhook', 1.1, {
    respondWith: 'json',
    responseBody: "={{ { ok: true, handler: $('Render').first().json.handler, actions: $('Render').first().json.dry ? $('Render').first().json.actions : undefined } }}",
    options: { responseCode: 200 }
  }));
  const explode = add(node('Explode', 'n8n-nodes-base.code', 2, { jsCode:
    "const r = $('Render').first().json;\nif (r.dry) return [];\nreturn (r.actions || []).map((a) => ({ json: a }));" }));
  const send = add(httpSend('Send'));
  const log = add(node('Delivery log', 'n8n-nodes-base.code', 2, { mode: 'runOnceForEachItem', jsCode:
    "const src = $('Explode').item.json;\nreturn { json: { op: src.op, http_status: Number($json.statusCode) || 0, error: $json.error ? true : false } };" }));
  link(c, wh, guard); link(c, guard, iff);
  link(c, iff, ctxn, 0); link(c, iff, reject, 1);
  link(c, ctxn, route); link(c, route, exec); link(c, exec, render); link(c, render, save);
  link(c, save, respond); link(c, respond, explode); link(c, explode, send); link(c, send, log);
  return { name: '{{CLIENT_CODE_UPPER}} - booking-dialog-max', id: '{{N8N_WF_ID:booking-dialog-max}}', nodes, connections: c, settings };
}

function reminders() {
  pos = 0;
  const nodes = [];
  const c = {};
  const add = (n) => { nodes.push(n); return n.name; };
  const sch = add(node('Every 15 minutes', 'n8n-nodes-base.scheduleTrigger', 1.2, { rule: { interval: [{ field: 'minutes', minutesInterval: 15 }] } }));
  const due = add(pgNode('Due reminders', `select * from ${SC}.bot_due_reminders(now(), 50)`, '={{ [] }}'));
  const build = add(codeNode('Build reminders', 'reminder-build.js.txt'));
  const send = add(httpSend('Send reminder'));
  const cls = add(node('Classify', 'n8n-nodes-base.code', 2, { mode: 'runOnceForEachItem', jsCode: code('reminder-classify.js.txt') }));
  const mark = add(pgNode('Mark reminder', `select ${SC}.mark_reminder($1::uuid, $2, 'max') as marked`, '={{ [$json.reminder_id, $json.status] }}'));
  link(c, sch, due); link(c, due, build); link(c, build, send); link(c, send, cls); link(c, cls, mark);
  return { name: '{{CLIENT_CODE_UPPER}} - booking-reminders-max', id: '{{N8N_WF_ID:booking-reminders-max}}', nodes, connections: c, settings };
}

const flows = { 'booking-dialog.json': dialog(), 'booking-reminders.json': reminders() };
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const outDir = opt('--render', null);
if (!outDir) {
  for (const [f, w] of Object.entries(flows)) fs.writeFileSync(path.join(here, f), JSON.stringify(w, null, 2) + '\n');
  console.log('built', Object.keys(flows).join(', '));
} else {
  const client = opt('--client', 'demo');
  const screen = opt('--screen', 'answer');
  const ids = { 'booking-dialog-max': `${client}BookingDialog1`, 'booking-reminders-max': `${client}BookingRemind1` };
  const creds = { pg: `${client}-pg`, max: `${client}-max` };
  fs.mkdirSync(outDir, { recursive: true });
  for (const [f, w] of Object.entries(flows)) {
    let s = JSON.stringify(w);
    s = s.replace(/\{\{N8N_WF_ID:([a-z-]+)\}\}/g, (_, k) => ids[k])
      .replace(/\{\{CRED_ID:([a-z]+)\}\}/g, (_, k) => creds[k])
      .replace(/\{\{SCREEN_MODE\}\}/g, screen)
      .replace(/\{\{CLIENT_CODE_UPPER\}\}/g, client.toUpperCase())
      .replace(/\{\{CLIENT_CODE\}\}/g, client);
    if (/\{\{[A-Z_:a-z-]+\}\}/.test(s)) throw new Error('unrendered placeholder in ' + f);
    fs.writeFileSync(path.join(outDir, f), JSON.stringify([JSON.parse(s)]));
  }
  console.log('rendered to', outDir);
}
