// Собирает сценарий n8n этапа М2: GET страница мини-приложения (тот же адрес, что у М1) и POST API записи.
// Один адрес API с белым списком операций (api.js) вместо четырех вебхуков: проще прокси и одна проверка initData.
// Использование: node build.js <выходной файл .json>
'use strict';
const fs = require('fs');
const path = require('path');
const out = process.argv[2];
if (!out) { console.error('нужен выходной файл'); process.exit(2); }
const page = fs.readFileSync(path.join(__dirname, 'page.html'), 'utf8');
const code = fs.readFileSync(path.join(__dirname, 'api.js'), 'utf8');
const PG = { postgres: { id: 'demo-pg', name: 'DEMO n8n_runtime' } };

const wf = [{
  name: 'DEMO - miniapp',
  // id М1 сохранен: n8n держит адрес страницы за этим сценарием (webhook_entity), снятие публикации из CLI его не освобождает
  id: 'demoMiniappM1',
  nodes: [
    { id: 'm2-page-hook', name: 'Page webhook', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 0], webhookId: 'demo-miniapp-page',
      parameters: { httpMethod: 'GET', path: 'demo-miniapp', responseMode: 'responseNode', options: {} } },
    { id: 'm2-page-resp', name: 'Respond page', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [240, 0],
      parameters: { respondWith: 'text', responseBody: page,
        options: { responseHeaders: { entries: [
          { name: 'Content-Type', value: 'text/html; charset=utf-8' },
          { name: 'Cache-Control', value: 'no-store' }] } } } },
    { id: 'm2-api-hook', name: 'API webhook', type: 'n8n-nodes-base.webhook', typeVersion: 2, position: [0, 240], webhookId: 'demo-miniapp-api',
      parameters: { httpMethod: 'POST', path: 'demo-miniapp-api', responseMode: 'responseNode', options: {} } },
    { id: 'm2-api-code', name: 'Check and route', type: 'n8n-nodes-base.code', typeVersion: 2, position: [240, 240],
      parameters: { jsCode: code } },
    { id: 'm2-api-exec', name: 'Exec', type: 'n8n-nodes-base.postgres', typeVersion: 2.5, position: [480, 240], credentials: PG,
      parameters: { operation: 'executeQuery', query: '={{ $json.sql }}', options: { queryReplacement: '={{ $json.params }}' } } },
    { id: 'm2-api-resp', name: 'Respond API', type: 'n8n-nodes-base.respondToWebhook', typeVersion: 1.1, position: [720, 240],
      parameters: { respondWith: 'json', responseBody: '={{ JSON.stringify($json.r ?? null) }}',
        options: { responseHeaders: { entries: [{ name: 'Cache-Control', value: 'no-store' }] } } } }
  ],
  connections: {
    'Page webhook': { main: [[{ node: 'Respond page', type: 'main', index: 0 }]] },
    'API webhook': { main: [[{ node: 'Check and route', type: 'main', index: 0 }]] },
    'Check and route': { main: [[{ node: 'Exec', type: 'main', index: 0 }]] },
    'Exec': { main: [[{ node: 'Respond API', type: 'main', index: 0 }]] }
  },
  settings: { executionOrder: 'v1', saveDataSuccessExecution: 'all', saveDataErrorExecution: 'all' }
}];
fs.writeFileSync(out, JSON.stringify(wf), 'utf8');
console.log('OK ' + out);
