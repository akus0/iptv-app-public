// Exercise the shipped form script without a browser, network or subscriber data.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const path = require('node:path');
const html = fs.readFileSync(path.join(__dirname, '../../assets/pair/pair.html'), 'utf8');

function page(hash = '') {
  const nodes = new Map();
  for (const match of html.matchAll(/id="([^"]+)"/g)) {
    nodes.set(match[1], { value: '', style: {}, hidden: false, attributes: {},
      setAttribute(k, v) { this.attributes[k] = v; },
      addEventListener(k, v) { this[k] = v; } });
  }
  const requests = [];
  const context = vm.createContext({
    document: { getElementById: id => { assert(nodes.has(id), id); return nodes.get(id); } },
    location: { hash, pathname: '/p/fixture' }, URL, TextEncoder, Uint8Array,
    atob, btoa, crypto: webcrypto, window: { crypto: webcrypto },
    fetch: async (url, options) => {
      requests.push({ url, ...options });
      return { ok: true, status: 204 };
    },
  });
  vm.runInContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], context);
  return { nodes, requests, set: (id, value) => { nodes.get(id).value = value; },
    mode: m => nodes.get('tab-' + m).onclick(),
    submit: () => nodes.get('form').submit({ preventDefault() {} }) };
}

(async () => {
  const form = page();
  form.mode('stalker');
  assert.equal(form.nodes.get('stalker-fields').hidden, false);
  assert.equal(form.nodes.get('xtream-fields').hidden, true);
  assert.equal(form.nodes.get('m3u-fields').hidden, true);
  form.set('portalUrl', 'https://portal.example.test/stalker_portal/c/');
  form.set('portalMac', 'invalid');
  await form.submit();
  assert.equal(form.requests.length, 0);
  form.set('portalMac', '00:1A:79:12:34:56');
  form.set('portalUrl', 'javascript:invalid');
  await form.submit();
  assert.equal(form.requests.length, 0);
  form.set('portalUrl', 'https://portal.example.test/stalker_portal/c/');
  form.set('portalPassword', ' spaces matter ');
  form.set('portalDeviceId', 'fixture-device');
  await form.submit();
  const data = JSON.parse(form.requests[0].body);
  assert.equal(data.mode, 'stalker');
  assert.equal(data.portalPassword, ' spaces matter ');
  assert.equal(data.portalDeviceId, 'fixture-device');
  assert.equal(data.server, undefined);
  assert.equal(data.m3u, undefined);

  for (const mode of ['m3u', 'xtream']) {
    const old = page();
    old.mode(mode);
    old.set('m3u', 'https://example.test/list');
    old.set('server', 'https://example.test');
    old.set('username', 'fixture');
    old.set('password', 'fixture');
    await old.submit();
    const payload = JSON.parse(old.requests[0].body);
    assert.equal(payload.mode, mode);
    assert.equal(payload.portalMac, undefined);
    assert.equal(old.nodes.get('stalker-fields').hidden, true);
  }

  const key = Buffer.alloc(32, 7);
  const relay = page('#fixture-session-12345.' + key.toString('base64url'));
  relay.mode('stalker');
  relay.set('portalUrl', 'https://portal.example.test/c/');
  relay.set('portalMac', '001a79123456');
  relay.set('portalSignature', 'fixture-signature');
  await relay.submit();
  const sent = relay.requests[0];
  assert.equal(sent.method, 'PUT');
  assert.equal(sent.body.includes('fixture-signature'), false);
  const encrypted = JSON.parse(sent.body);
  const aesKey = await webcrypto.subtle.importKey('raw', key, 'AES-GCM', false, ['decrypt']);
  const clear = await webcrypto.subtle.decrypt({ name: 'AES-GCM', iv: Buffer.from(encrypted.iv, 'base64') },
      aesKey, Buffer.from(encrypted.ct, 'base64'));
  assert.equal(JSON.parse(Buffer.from(clear).toString()).portalSignature, 'fixture-signature');

  const link = page('#link');
  link.set('link', 'https://example.test/manifest');
  await link.nodes.get('link-form').submit({ preventDefault() {} });
  assert.equal(JSON.parse(link.requests[0].body).mode, 'link');
  console.log('Pairing form: Stalker validation, LAN payload, encrypted relay, M3U, Xtream and link modes passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
