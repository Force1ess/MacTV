const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('src/browser-extension/popup.js', 'utf8');
async function run(provider, cookies) {
  let click, reads = [], sent = [];
  const elements = {provider: {value: provider}, status: {}, import: {addEventListener: (event, action) => { assert.equal(event, 'click'); click = action; }}};
  const context = {document: {getElementById: id => elements[id]}, chrome: {
    cookies: {getAll: async filter => { reads.push(filter); return cookies; }},
    runtime: {sendNativeMessage: async (host, payload) => { sent.push({host, payload}); return {ok: true}; }}
  }};
  vm.runInNewContext(source, context);
  assert.equal(reads.length, 0, 'Opening popup must not read cookies');
  assert.equal(sent.length, 0);
  await click();
  return {reads, sent, elements};
}
(async () => {
  for (const [provider, name, domain, url] of [
    ['mtv.quark', '__puus', '.quark.cn', 'https://drive.quark.cn/'],
    ['mtv.bilibili', 'SESSDATA', '.bilibili.com', 'https://api.bilibili.com/']
  ]) {
    const result = await run(provider, [{name, domain, value: 'OWNED-FAKE', path: '/', hostOnly: false},
      {name: 'unrelated', domain, value: 'DO-NOT-SEND', path: '/', hostOnly: false}]);
    assert.equal(result.reads[0].url, url);
    assert.equal(result.sent.length, 1);
    assert.equal(result.sent[0].payload.provider, provider);
    assert.equal(result.sent[0].payload.cookies.length, 1);
    assert.equal(result.sent[0].payload.cookies[0].name, name);
    assert.equal(result.elements.import.disabled, false);
    const missing = await run(provider, []);
    assert.equal(missing.sent.length, 0);
    assert.match(missing.elements.status.textContent, /没有/);
  }
  const unknown = await run('unknown', []);
  assert.equal(unknown.reads.length, 0);
  assert.equal(unknown.sent.length, 0);
  console.log(JSON.stringify({passed: true, scenarios: 5, realCookiesRead: false}));
})().catch(error => { console.error(error); process.exitCode = 1; });
