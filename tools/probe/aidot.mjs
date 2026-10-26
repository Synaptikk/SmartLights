#!/usr/bin/env node
// AiDot / Linkind probe. Port of python-aidot 0.3.59 (MIT, AiDot-Development-Team):
//   login_const.py, const.py, client.py, discover.py, device_client.py, aes_utils.py,
//   models/discover_model.py, models/device_client_model.py.
// See research/research_aidot.md §2.
//
//   node aidot.mjs login                   env AIDOT_COUNTRY (ISO code, e.g. US), AIDOT_USER, AIDOT_PASS or interactive prompt
//   node aidot.mjs devices                 GET /houses, /devices?houseId=, /products/<ids>
//   node aidot.mjs discover [secs]         UDP 6666 AES-256-ECB broadcast (devDiscoveryReq)
//   node aidot.mjs state <devId> [ip]      TCP 10000 loginReq + getDevAttrReq
//   node aidot.mjs set <devId> '<json>' [ip]   setDevAttrReq (only when TEST_DEVICE == devId or MAC)
//   node aidot.mjs verify-key              compare the embedded RSA key with upstream login_const.py
//
// Secrets (tokens, device aesKey/password) are written only to out/aidot.json and never printed.

import crypto from 'node:crypto';
import dgram from 'node:dgram';
import net from 'node:net';
import https from 'node:https';
import { ipv4Interfaces, saveOut, loadOut, logOut, writeAllowed, refuseWrite, die, redact, prompt, normMac } from './lib/common.mjs';

// ---------- constants (login_const.py / const.py) ----------

const APP_ID = '1383974540041977857';
const API_URL_TEMPLATE = (region) => `https://prod-${region}-api.arnoo.com/v35`;
// Copied verbatim from python-aidot aidot/login_const.py (main, 2026-10-26).
const PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCtQAnPCi8ksPnS1Du6z96PsKfN
p2Gp/f/bHwlrAdplbX3p7/TnGpnbJGkLq8uRxf6cw+vOthTsZjkPCF7CatRvRnTj
c9fcy7yE0oXa5TloYyXD6GkxgftBbN/movkJJGQCc7gFavuYoAdTRBOyQoXBtm0m
kXMSjXOldI/290b9BQIDAQAB
-----END PUBLIC KEY-----
`;
const LOGIN_CONST_URL = 'https://raw.githubusercontent.com/AiDot-Development-Team/python-AiDot/main/aidot/login_const.py';

// Country -> region, generated from SUPPORTED_COUNTRYS in python-aidot const.py (130 entries). ISO: [name, region]
const COUNTRIES = {
  AL: ['Albania', 'eu'], AG: ['Antigua and Barbuda', 'us'], AR: ['Argentina', 'us'], AT: ['Austria', 'eu'],
  AI: ['Anguilla', 'us'], AF: ['Afghanistan', 'jp'], AM: ['Armenia', 'jp'], AZ: ['Azerbaijan', 'jp'],
  AU: ['Australia', 'jp'], BO: ['Bolivia', 'us'], BR: ['Brazil', 'us'], BG: ['Bulgaria', 'eu'],
  BS: ['Bahamas', 'us'], BE: ['Belgium', 'eu'], BZ: ['Belize', 'us'], BB: ['Barbados', 'us'],
  BM: ['Bermuda', 'us'], BN: ['Brunei', 'jp'], BH: ['Bahrain', 'jp'], BD: ['Bangladesh', 'jp'],
  BT: ['Bhutan', 'jp'], CA: ['Canada', 'us'], CL: ['Chile', 'us'], CO: ['Colombia', 'us'],
  CR: ['Costa Rica', 'us'], CU: ['Cuba', 'us'], CZ: ['Czech Republic', 'eu'], HR: ['Croatia', 'eu'],
  KY: ['Cayman Islands', 'us'], KH: ['Cambodia', 'jp'], CY: ['Cyprus', 'jp'], DK: ['Denmark', 'eu'],
  DO: ['Dominican Republic', 'us'], EC: ['Ecuador', 'us'], SV: ['El Salvador', 'us'], EE: ['Estonia', 'eu'],
  FI: ['Finland', 'eu'], FR: ['France', 'eu'], GF: ['French Guiana', 'us'], GR: ['Greece', 'eu'],
  GT: ['Guatemala', 'us'], GY: ['Guyana', 'us'], DE: ['Germany', 'eu'], GD: ['Grenada', 'us'],
  GE: ['Georgia', 'jp'], HT: ['Haiti', 'us'], HN: ['Honduras', 'us'], HU: ['Hungary', 'eu'],
  IS: ['Iceland', 'eu'], IE: ['Ireland', 'eu'], IT: ['Italy', 'eu'], IN: ['India', 'jp'],
  ID: ['Indonesia', 'jp'], IR: ['Iran', 'jp'], IQ: ['Iraq', 'jp'], IL: ['Israel', 'eu'],
  JM: ['Jamaica', 'us'], JP: ['Japan', 'jp'], JO: ['Jordan', 'jp'], KZ: ['Kazakhstan', 'jp'],
  KR: ['Korea', 'jp'], KW: ['Kuwait', 'jp'], KG: ['Kyrgyzstan', 'jp'], LV: ['Latvia', 'eu'],
  LT: ['Lithuania', 'eu'], LU: ['Luxembourg', 'eu'], LI: ['Liechtenstein', 'eu'], LA: ['Laos', 'jp'],
  LB: ['Lebanon', 'jp'], MT: ['Malta', 'eu'], MX: ['Mexico', 'us'], MD: ['Moldova', 'eu'],
  MC: ['Monaco', 'eu'], MS: ['Montserrat', 'us'], ME: ['Montenegro', 'eu'], MY: ['Malaysia', 'jp'],
  MV: ['Maldives', 'jp'], MN: ['Mongolia', 'jp'], MM: ['Myanmar', 'jp'], NL: ['Netherlands', 'eu'],
  NI: ['Nicaragua', 'us'], NO: ['Norway', 'eu'], MK: ['North Macedonia', 'eu'], NZ: ['New Zealand', 'jp'],
  NP: ['Nepal', 'jp'], KP: ['North Korea', 'jp'], OM: ['Oman', 'jp'], PA: ['Panama', 'us'],
  PY: ['Paraguay', 'us'], PE: ['Peru', 'us'], PT: ['Portugal', 'eu'], PK: ['Pakistan', 'jp'],
  PS: ['Palestine', 'jp'], PH: ['Philippines', 'jp'], PL: ['Poland', 'eu'], QA: ['Qatar', 'jp'],
  RO: ['Romania', 'eu'], RU: ['Russia', 'eu'], SM: ['San Marino', 'eu'], SI: ['Slovenia', 'eu'],
  ES: ['Spain', 'eu'], LC: ['St.Lucia', 'us'], SR: ['Suriname', 'us'], SE: ['Sweden', 'eu'],
  SK: ['Slovakia', 'eu'], RS: ['Serbia', 'eu'], KN: ['St.Kitts and Nevis', 'us'], VC: ['St.Vincent and the Grenadines', 'us'],
  SA: ['Saudi Arabia', 'jp'], SG: ['Singapore', 'jp'], LK: ['Sri Lanka', 'jp'], SY: ['Syria', 'jp'],
  CH: ['Switzerland', 'eu'], TT: ['Trinidad and Tobago', 'us'], TC: ['Turks & Caicos', 'us'], TJ: ['Tajikistan', 'jp'],
  TH: ['Thailand', 'jp'], TG: ['Togo', 'jp'], TR: ['Turkey', 'eu'], TM: ['Turkmenistan', 'jp'],
  UA: ['Ukraine', 'eu'], GB: ['United Kingdom', 'eu'], US: ['United States', 'us'], UY: ['Uruguay', 'us'],
  AE: ['United Arab Emirates', 'jp'], UZ: ['Uzbekistan', 'jp'], VE: ['Venezuela', 'us'], VG: ['Virgin Islands', 'us'],
  VN: ['Vietnam', 'jp'], YE: ['Yemen', 'jp'],
};

// ---------- Python-compatible json.dumps (default separators ", " / ": ", ensure_ascii=True) ----------

function pyStr(s) {
  return JSON.stringify(s).replace(/[\u007f-￿]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
}
export function pyDumps(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'string') return pyStr(v);
  if (typeof v === 'number' || typeof v === 'boolean') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(pyDumps).join(', ') + ']';
  return '{' + Object.entries(v).map(([k, x]) => `${pyStr(k)}: ${pyDumps(x)}`).join(', ') + '}';
}

// ---------- crypto (aes_utils.py, client.rsa_password_encrypt) ----------

function aesEncrypt(plain, key) {
  const c = crypto.createCipheriv(`aes-${key.length * 8}-ecb`, key, null); // PKCS7 padding is Node's default
  return Buffer.concat([c.update(plain), c.final()]);
}
function aesDecrypt(cipher, key) {
  const d = crypto.createDecipheriv(`aes-${key.length * 8}-ecb`, key, null);
  return Buffer.concat([d.update(cipher), d.final()]).toString('utf8');
}
export function rsaPasswordEncrypt(message) {
  return crypto.publicEncrypt({ key: PUBLIC_KEY_PEM, padding: crypto.constants.RSA_PKCS1_PADDING }, Buffer.from(message, 'utf8')).toString('base64');
}
/** discover.py: b"T54uednca587".ljust(32, b"\x00") -> AES-256. */
const DISCOVER_KEY = Buffer.concat([Buffer.from('T54uednca587'), Buffer.alloc(20)]);
/** device_client.py: bytearray(16); aes_key[:len(key_bytes)] = key_bytes (longer keys extend the array). */
export function deviceKey(keyString) {
  const kb = Buffer.from(keyString, 'utf8');
  return kb.length >= 16 ? kb : Buffer.concat([kb, Buffer.alloc(16 - kb.length)]);
}

// ---------- HTTP (client.py) ----------

function httpJson(method, url, { headers = {}, body } = {}) {
  return new Promise((resolve) => {
    const data = body === undefined ? undefined : JSON.stringify(body);
    const r = https.request(url, {
      method,
      headers: { ...(data ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } : {}), ...headers },
      timeout: 15000,
    }, (res) => {
      let buf = '';
      res.setEncoding('utf8');
      res.on('data', (c) => (buf += c));
      res.on('end', () => {
        let json;
        try { json = JSON.parse(buf); } catch { /* not json */ }
        resolve({ status: res.statusCode, json, text: buf });
      });
    });
    r.on('timeout', () => r.destroy(new Error('timeout')));
    r.on('error', (e) => resolve({ error: e.message }));
    if (data) r.write(data);
    r.end();
  });
}

function terminalId(state) {
  // client.get_terminal_id(): md5 of a persisted machine id. We persist a random UUID in out/aidot.json.
  state.rawTerminalId ??= crypto.randomUUID();
  return crypto.createHash('md5').update(state.rawTerminalId).digest('hex');
}

function loadState() {
  return loadOut('aidot.json', {});
}
function saveState(s) {
  return saveOut('aidot.json', s, { secret: true });
}

async function login() {
  const state = loadState();
  const cc = (process.env.AIDOT_COUNTRY || (await prompt('Country ISO code [US]: ')) || 'US').toUpperCase();
  const country = COUNTRIES[cc];
  if (!country) die(`Unknown/unsupported country code ${cc}. Known: ${Object.keys(COUNTRIES).filter((k) => COUNTRIES[k]).join(' ')}`);
  const [countryName, region] = country;
  const username = process.env.AIDOT_USER || (await prompt('AiDot e-mail: '));
  const password = process.env.AIDOT_PASS || (await prompt('AiDot password (hidden): ', { mute: true }));
  if (!username || !password) die('username and password required');

  const body = {
    countryKey: `region:${countryName.trim()}`,
    username,
    password: rsaPasswordEncrypt(password),
    terminalId: terminalId(state),
    webVersion: '0.5.0',
    area: 'Asia/Shanghai',
    UTC: 'UTC+8',
  };
  const url = `${API_URL_TEMPLATE(region)}/users/loginWithFreeVerification`;
  console.log(`POST ${url} (country "${countryName}", region ${region})`);
  const r = await httpJson('POST', url, { headers: { Appid: APP_ID, Terminal: 'app' }, body });
  if (r.status !== 200 || !r.json?.accessToken) {
    const code = r.json?.code;
    console.log(`Login failed: HTTP ${r.status ?? r.error} code=${code ?? '-'} ${code === 560080 ? '(USER_PWD_INCORRECT)' : ''}`);
    console.log(JSON.stringify(redact(r.json ?? r.text ?? r.error), null, 2));
    process.exitCode = 1;
    return;
  }
  // Note: python-aidot stores the plaintext password in login_info for re-login. We do NOT persist it.
  state.login = { ...r.json, region, country: countryName, countryCode: cc, loggedInAt: new Date().toISOString() };
  const file = saveState(state);
  console.log(`Logged in. userId=${r.json.id}. Tokens saved to ${file} (not printed).`);
  console.log('Response fields: ' + Object.keys(r.json).join(', '));
  console.log('NOTE: a second login with the same account may invalidate this token (cbrightly README).');
}

async function apiGet(state, path) {
  const base = API_URL_TEMPLATE(state.login.region);
  const headers = () => ({ Terminal: 'app', Token: state.login.accessToken, Appid: APP_ID });
  let r = await httpJson('GET', base + path, { headers: headers() });
  if (r.json?.code === 21026) { // TOKEN_EXPIRED -> refresh once (client.async_refresh_token)
    console.log('token expired, refreshing ...');
    const rr = await httpJson('POST', `${base}/users/refreshToken`, { headers: { Appid: APP_ID, Terminal: 'app' }, body: { refreshToken: state.login.refreshToken } });
    if (rr.status !== 200 || !rr.json?.accessToken) die(`refresh failed: HTTP ${rr.status} code=${rr.json?.code} -> run login again`);
    state.login.accessToken = rr.json.accessToken;
    if (rr.json.refreshToken) state.login.refreshToken = rr.json.refreshToken;
    saveState(state);
    r = await httpJson('GET', base + path, { headers: headers() });
  }
  if (r.status !== 200) die(`GET ${path} -> HTTP ${r.status ?? r.error} code=${r.json?.code ?? '-'} ${r.json?.desc ?? r.json?.message ?? ''}`);
  return r.json;
}

function needLogin() {
  const s = loadState();
  if (!s.login?.accessToken) die('Not logged in. Run: node aidot.mjs login');
  return s;
}

async function devices() {
  const state = needLogin();
  const houses = await apiGet(state, '/houses');
  const all = [];
  for (const h of houses) {
    console.log(`house ${h.id} "${h.name}" isOwner=${h.isOwner}${h.isOwner === false ? '  (skipped, as python-aidot does)' : ''}`);
    if (h.isOwner === false) continue;
    const list = await apiGet(state, `/devices?houseId=${h.id}`);
    if (Array.isArray(list)) all.push(...list);
  }
  if (all.length) {
    const ids = [...new Set(all.map((d) => d.productId))].join(',');
    const products = await apiGet(state, `/products/${ids}`);
    for (const p of products ?? []) for (const d of all) if (d.productId === p.id) d.product = p;
  }
  state.houses = houses;
  state.devices = all;
  state.devicesAt = new Date().toISOString();
  const file = saveState(state);

  console.log(`\n${all.length} device(s):`);
  for (const d of all) {
    const p = d.properties ?? {};
    const caps = (d.product?.serviceModules ?? []).map((s) => s.identity).join(',');
    console.log(`- ${d.id}  "${d.name}"  type=${d.type} modelId=${d.modelId} mac=${d.mac} online=${d.online}`);
    console.log(`    fw=${d.firmwareVersion} hw=${d.hardwareVersion} proto=${d.protocolVersion} ip=${p.ipAddress ?? '-'} ssid=${p.ssidName ?? '-'} simpleVersion=${d.simpleVersion ?? '-'}`);
    console.log(`    hasAesKey=${Array.isArray(d.aesKey) && d.aesKey[0] != null} hasPassword=${!!d.password} isDirectDevice=${d.product?.isDirectDevice} services=${caps}`);
    const attrs = Object.fromEntries(Object.entries(p).filter(([k]) => /^(OnOff|Dimming|CCT|RGBW|EffectMode)$/.test(k)));
    console.log(`    attrs=${JSON.stringify(attrs)}`);
  }
  console.log(`\nFull records (incl. aesKey/password) saved to ${file}. Console output above is redacted.`);
}

// ---------- discover.py ----------

function discoverRequest(userId) {
  const ms = Date.now();
  return { protocolVer: '2.0.0', service: 'device', method: 'devDiscoveryReq', seq: String(ms + 1).slice(-9), srcAddr: `0.${userId}`, tst: ms, payload: { extends: {}, localCtrFlag: 1, timestamp: String(ms) } };
}

async function discover(secs = 8) {
  const state = loadState();
  const userId = state.login?.id ?? '0';
  if (!state.login) console.log('(not logged in; using srcAddr "0.0" - devices may still answer)');
  const found = new Map();
  const sockets = [];
  for (const iface of ipv4Interfaces()) {
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    sockets.push(sock);
    sock.on('error', (e) => console.error(`[${iface.name}] ${e.message}`));
    sock.on('message', (buf, rinfo) => {
      let json;
      try { json = JSON.parse(aesDecrypt(buf, DISCOVER_KEY)); } catch { return; } // also drops our own looped-back request
      if (json.method === 'devDiscoveryReq' && !json.ack) return;
      const p = json.payload ?? {};
      const key = p.devId ?? rinfo.address;
      if (!found.has(key)) console.log(`${rinfo.address}  devId=${p.devId} mac=${p.mac} model=${p.productModel} bind=${p.bindFlag} lanMode=${p.lanMode} conMode=${p.conMode} wifiBand=${p.wifiBand} version=${p.version} srvHost=${p.extends?.srvHost ?? '-'}`);
      found.set(key, { from: rinfo.address, ...json });
    });
    await new Promise((res) => sock.bind(0, iface.address, res));
    sock.setBroadcast(true);
    const send = () => {
      const data = aesEncrypt(Buffer.from(pyDumps(discoverRequest(userId))), DISCOVER_KEY);
      for (const t of new Set(['255.255.255.255', iface.broadcast])) sock.send(data, 6666, t);
    };
    console.log(`[${iface.name}] ${iface.address} -> 255.255.255.255,${iface.broadcast}:6666`);
    send();
    setTimeout(send, 2000);
    setTimeout(send, 4000);
  }
  await new Promise((r) => setTimeout(r, secs * 1000));
  sockets.forEach((s) => s.close());
  console.log(`${found.size} device(s) answered.`);
  saveOut('aidot-discover.json', { at: new Date().toISOString(), devices: [...found.values()] });
}

// ---------- device_client.py ----------

function frame(bodyBuf, msgtype, key) {
  const enc = key ? aesEncrypt(bodyBuf, key) : bodyBuf;
  const h = Buffer.alloc(8);
  h.writeUInt16BE(0x1eed, 0);
  h.writeInt16BE(msgtype, 2);
  h.writeInt32BE(enc.length, 4);
  return Buffer.concat([h, enc]);
}

/** Minimal framed reader: yields decrypted JSON messages. */
function frameReader(sock, key, onMsg) {
  let buf = Buffer.alloc(0);
  sock.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 8) {
      const magic = buf.readUInt16BE(0);
      const msgtype = buf.readUInt16BE(2);
      const size = buf.readUInt32BE(4);
      if (buf.length < 8 + size) break;
      const body = buf.subarray(8, 8 + size);
      buf = buf.subarray(8 + size);
      let json;
      try { json = JSON.parse(aesDecrypt(body, key)); } catch (e) { json = { _decryptError: e.message, magic, len: size }; }
      onMsg({ magic, msgtype, json });
    }
  });
}

function pyTimestamp(d = new Date()) {
  // datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f") (local time, microseconds)
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds() * 1000, 6)}`;
}

function findDevice(state, devId) {
  const d = (state.devices ?? []).find((x) => x.id === devId || normMac(x.mac) === normMac(devId));
  if (!d) die(`Device ${devId} not in out/aidot.json. Run: node aidot.mjs devices`);
  if (!d.aesKey?.[0]) die(`Device ${devId} has no aesKey (not a LAN-controllable Wi-Fi device?).`);
  return d;
}

function resolveIp(state, d, ipArg) {
  if (ipArg) return ipArg;
  const disc = loadOut('aidot-discover.json', {})?.devices?.find((x) => x.payload?.devId === d.id);
  return disc?.from ?? d.properties?.ipAddress ?? die(`No IP for ${d.id}; pass it: node aidot.mjs state ${d.id} <ip>`);
}

async function session(d, userId, ip, actions, { listenMs = 3000 } = {}) {
  const key = deviceKey(d.aesKey[0]);
  const sock = net.connect({ host: ip, port: 10000, noDelay: true });
  sock.setTimeout(8000);
  const msgs = [];
  let resolveLogin;
  const loginDone = new Promise((r) => (resolveLogin = r));
  frameReader(sock, key, (m) => {
    msgs.push(m);
    logOut('aidot-tcp', { devId: d.id, ip, msgtype: m.msgtype, json: redact(m.json) });
    // device_client.login(): the first frame after loginReq is the login response.
    if (msgs.length === 1) resolveLogin(m.json);
    else console.log(`<- msgtype=${m.msgtype} ${JSON.stringify(redact(m.json))}`);
  });
  await new Promise((res, rej) => { sock.once('connect', res); sock.once('error', rej); sock.once('timeout', () => rej(new Error('connect timeout'))); })
    .catch((e) => die(`TCP ${ip}:10000 failed: ${e.message}`));
  console.log(`connected ${ip}:10000`);

  const loginReq = {
    service: 'device', method: 'loginReq', seq: String(Date.now()).slice(-9), srcAddr: userId, deviceId: d.id,
    payload: { userId, password: d.password, timestamp: pyTimestamp(), ascNumber: 1 },
  };
  sock.write(frame(Buffer.from(pyDumps(loginReq)), 1, key));
  const login = await Promise.race([loginDone, new Promise((r) => setTimeout(() => r(null), 5000))]);
  if (!login) { sock.destroy(); die('no login response (0 bytes) - wrong key/IP, or device rejects this userId (only the owner account works)'); }
  console.log(`login ack: code=${login.ack?.code} ascNumber=${login.payload?.ascNumber}`);
  if (login.ack?.code !== 200) { sock.destroy(); die('login rejected'); }
  let ascNumber = (login.payload?.ascNumber ?? 0) + 1;
  let seqNum = 1;

  for (const { method, attr } of actions) {
    seqNum += 1;
    const seq = 'ha93' + String(seqNum).padStart(5, '0');
    // DeviceActionRequest.from_params: full payload only when the cloud record has simpleVersion.
    const req = d.simpleVersion != null
      ? { method, service: 'device', clientId: `ha-${userId}`, srcAddr: `0.${userId}`, seq, payload: { devId: d.id, parentId: d.id, userId, password: d.password, attr, channel: 'tcp', ascNumber }, tst: Date.now(), deviceId: d.id }
      : { method, service: 'device', clientId: '', srcAddr: `0.${userId}`, seq, payload: { devId: '', parentId: '', userId: '', password: '', attr, channel: 'tcp', ascNumber }, tst: Date.now(), deviceId: d.id };
    console.log(`-> ${method} ${JSON.stringify(attr)}`);
    sock.write(frame(Buffer.from(pyDumps(req)), 1, key));
  }
  await new Promise((r) => setTimeout(r, listenMs));
  sock.destroy();
  return msgs;
}

async function state(devId, ipArg) {
  if (!devId) die('usage: aidot.mjs state <devId> [ip]');
  const s = needLogin();
  const d = findDevice(s, devId);
  const ip = resolveIp(s, d, ipArg);
  // python sends syncProperties ([] for current gen, full list for lk.WIFI-RGBWLight-D0006)
  const attr = d.modelId === 'lk.WIFI-RGBWLight-D0006' ? ['OnOff', 'Dimming', 'RGBW', 'CCT'] : [];
  const msgs = await session(d, String(s.login.id), ip, [{ method: 'getDevAttrReq', attr }]);
  const attrs = msgs.map((m) => m.json?.payload?.attr).filter(Boolean);
  console.log(`attrs: ${JSON.stringify(attrs.at(-1) ?? null)}`);
}

async function set(devId, json, ipArg) {
  if (!devId || !json) die('usage: aidot.mjs set <devId> \'{"OnOff":1}\' [ip]');
  const s = needLogin();
  const d = findDevice(s, devId);
  if (!writeAllowed(d.id, d.mac)) return refuseWrite(`${d.id} (mac ${d.mac})`);
  let attr;
  try { attr = JSON.parse(json); } catch (e) { die(`bad JSON: ${e.message}`); }
  const ip = resolveIp(s, d, ipArg);
  await session(d, String(s.login.id), ip, [{ method: 'setDevAttrReq', attr }]);
}

async function verifyKey() {
  const r = await httpJson('GET', LOGIN_CONST_URL);
  const m = r.text?.match(/-----BEGIN PUBLIC KEY-----[\s\S]+?-----END PUBLIC KEY-----/);
  if (!m) die(`could not fetch/parse ${LOGIN_CONST_URL}`);
  const norm = (s) => s.replace(/\s+/g, '');
  const same = norm(m[0]) === norm(PUBLIC_KEY_PEM);
  const k = crypto.createPublicKey(PUBLIC_KEY_PEM);
  console.log(`upstream key ${same ? 'MATCHES' : 'DIFFERS FROM'} the embedded key (${k.asymmetricKeyType} ${k.asymmetricKeyDetails.modulusLength} bit).`);
  const ct = rsaPasswordEncrypt('probe-self-test');
  console.log(`self-test: PKCS#1 v1.5 ciphertext ${Buffer.from(ct, 'base64').length} bytes, base64 length ${ct.length} (expect 128 / 172).`);
  if (!same) process.exitCode = 1;
}

// ---------- main ----------

const [cmd, ...args] = process.argv.slice(2);
switch (cmd) {
  case 'login': await login(); break;
  case 'devices': await devices(); break;
  case 'discover': await discover(Number(args[0] ?? 8)); break;
  case 'state': await state(args[0], args[1]); break;
  case 'set': await set(args[0], args[1], args[2]); break;
  case 'verify-key': await verifyKey(); break;
  default:
    console.log('usage: node aidot.mjs login | devices | discover [secs] | state <devId> [ip] | set <devId> <json-attrs> [ip] | verify-key');
    process.exitCode = cmd ? 1 : 0;
}
