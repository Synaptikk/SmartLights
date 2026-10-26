#!/usr/bin/env node
// WiZ local UDP probe (port 38899). See research/research_wiz.md §1.
//
//   node wiz.mjs discover                 broadcast registration(register:false)+getPilot, listen 5 s
//   node wiz.mjs sweep [a.b.c]            unicast getPilot to every host of the local /24 (no broadcast)
//   node wiz.mjs info  <ip>              getSystemConfig, getModelConfig, getUserConfig (+ getPilot)
//   node wiz.mjs state <ip>               getPilot
//   node wiz.mjs set   <ip> '<json>'      setPilot (only when TEST_DEVICE == ip or MAC)
//
// Env: WIZ_SIGNING_KEY=<32 hex>  -> sign setPilot (HMAC-SHA256 over compact params JSON incl. sigTs)
//      TEST_DEVICE=<ip|mac>       -> required for `set`

import dgram from 'node:dgram';
import crypto from 'node:crypto';
import { ipv4Interfaces, saveOut, loadOut, logOut, writeAllowed, refuseWrite, die, normMac } from './lib/common.mjs';

const PORT = 38899;
const RETRY_MS = [0, 750, 1500, 3000]; // subset of pywizlight's 0.75/1.5/3/3/3 schedule

// ---------- transport ----------

/** Send one request to ip:38899, retry on schedule, resolve with the first reply whose method matches. */
function request(ip, msg, { timeoutMs = 6000, retries = RETRY_MS } = {}) {
  return new Promise((resolve) => {
    const sock = dgram.createSocket('udp4');
    const payload = Buffer.from(JSON.stringify(msg));
    const timers = [];
    let done = false;
    const finish = (val) => {
      if (done) return;
      done = true;
      timers.forEach(clearTimeout);
      try { sock.close(); } catch { /* already closed */ }
      resolve(val);
    };
    sock.on('message', (buf, rinfo) => {
      let json;
      try { json = JSON.parse(buf.toString('utf8')); } catch { json = { _raw: buf.toString('utf8') }; }
      if (json.method && json.method !== msg.method) return; // late reply to another request
      finish({ from: rinfo.address, raw: buf.toString('utf8'), json });
    });
    sock.on('error', (e) => finish({ error: e.message }));
    sock.bind(0, () => {
      for (const t of retries) timers.push(setTimeout(() => !done && sock.send(payload, PORT, ip), t));
      timers.push(setTimeout(() => finish({ timeout: true }), timeoutMs));
    });
  });
}

// ---------- signing ----------

function signParams(params, hexKey) {
  if (!/^[0-9a-fA-F]{32}$/.test(hexKey)) die('WIZ_SIGNING_KEY must be 32 hex characters (16 bytes).');
  const signed = { ...params, sigTs: Math.floor(Date.now() / 1000) };
  const compact = JSON.stringify(signed); // compact, no spaces
  const hmac = crypto.createHmac('sha256', Buffer.from(hexKey, 'hex')).update(compact).digest('base64');
  return { params: signed, hmac };
}

/** Facts about signing that can be inferred from a *read* reply (no writes sent). */
function signingHints(json) {
  if (!json || typeof json !== 'object') return {};
  const body = json.result ?? json.error ?? {};
  return {
    replyHasHmac: 'hmac' in json,
    replyHasSigTs: body && typeof body === 'object' && 'sigTs' in body,
    errorCode: json.error?.code,
  };
}

// ---------- commands ----------

async function discover() {
  const ifaces = ipv4Interfaces();
  if (!ifaces.length) die('No non-internal IPv4 interface found.');
  const found = new Map(); // mac -> record
  const sockets = [];

  for (const iface of ifaces) {
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    sockets.push(sock);
    sock.on('error', (e) => console.error(`[${iface.name}] socket error: ${e.message}`));
    sock.on('message', (buf, rinfo) => {
      let json;
      try { json = JSON.parse(buf.toString('utf8')); } catch { return; }
      const r = json.result ?? json.params ?? {};
      const mac = normMac(r.mac);
      if (!mac) return;
      const rec = found.get(mac) ?? { mac, ip: rinfo.address, iface: iface.name };
      rec.ip = rinfo.address;
      if (json.method === 'getPilot') rec.pilot = r;
      if (json.method === 'registration') rec.registration = r;
      Object.assign(rec, signingHints(json));
      found.set(mac, rec);
    });
    await new Promise((res) => sock.bind(0, iface.address, res));
    sock.setBroadcast(true);
    const reg = { method: 'registration', params: { phoneMac: 'AAAAAAAAAAAA', register: false, phoneIp: '1.2.3.4', id: '1' } };
    const pilot = { method: 'getPilot', params: {} };
    const targets = [...new Set([iface.broadcast, '255.255.255.255'])];
    console.log(`[${iface.name}] ${iface.address}/${iface.netmask} -> ${targets.join(', ')}:${PORT}`);
    const send = () => {
      for (const t of targets) {
        sock.send(JSON.stringify(reg), PORT, t);
        sock.send(JSON.stringify(pilot), PORT, t);
      }
    };
    send();
    // pywizlight re-sends every 1 s during the 5 s window
    for (let i = 1; i < 5; i++) setTimeout(send, i * 1000);
  }

  await new Promise((r) => setTimeout(r, 5000));
  sockets.forEach((s) => s.close());

  const list = [...found.values()].sort((a, b) => a.ip.localeCompare(b.ip, undefined, { numeric: true }));
  if (!list.length) {
    console.log('No WiZ devices replied. Check: same subnet/VLAN, bulbs powered, "Allow local communication" enabled in the WiZ app, Windows firewall for node.exe (UDP inbound).');
  }
  for (const d of list) {
    const p = d.pilot ?? {};
    const state = d.pilot
      ? `state=${p.state} dimming=${p.dimming ?? '-'} temp=${p.temp ?? '-'} rgb=${p.r ?? '-'},${p.g ?? '-'},${p.b ?? '-'} sceneId=${p.sceneId ?? '-'} rssi=${p.rssi ?? '-'}`
      : '(no getPilot reply)';
    console.log(`${d.mac}  ${d.ip.padEnd(15)}  ${state}${d.replyHasHmac ? '  [signed replies]' : ''}`);
  }
  const file = saveOut('wiz-discover.json', { at: new Date().toISOString(), devices: list });
  console.log(`\n${list.length} device(s). Saved ${file}`);
}

/** Unicast getPilot to every host of each local /24 (the iOS no-entitlement fallback, as Lumen does). */
async function sweep(prefixArg) {
  const prefixes = prefixArg
    ? [prefixArg.split('.').filter(Boolean).slice(0, 3).join('.')]
    : ipv4Interfaces().map((i) => i.address.split('.').slice(0, 3).join('.'));
  const sock = dgram.createSocket('udp4');
  const found = new Map();
  sock.on('error', (e) => console.error(`socket error: ${e.message}`));
  sock.on('message', (buf, rinfo) => {
    let json;
    try { json = JSON.parse(buf.toString('utf8')); } catch { return; }
    const r = json.result ?? {};
    const mac = normMac(r.mac);
    if (mac) found.set(mac, { mac, ip: rinfo.address, pilot: r, ...signingHints(json) });
  });
  await new Promise((res) => sock.bind(0, res));
  const msg = Buffer.from(JSON.stringify({ method: 'getPilot', params: {} }));
  for (let pass = 0; pass < 2; pass++) {
    for (const p of prefixes) {
      console.log(`pass ${pass + 1}: ${p}.1-254`);
      for (let i = 1; i < 255; i++) sock.send(msg, PORT, `${p}.${i}`);
    }
    await new Promise((r) => setTimeout(r, 1500));
  }
  await new Promise((r) => setTimeout(r, 1500));
  sock.close();
  const list = [...found.values()];
  for (const d of list) console.log(`${d.mac}  ${d.ip.padEnd(15)}  state=${d.pilot.state} dimming=${d.pilot.dimming ?? '-'}`);
  console.log(`${list.length} device(s) answered unicast getPilot.`);
  saveOut('wiz-sweep.json', { at: new Date().toISOString(), prefixes, devices: list });
}

async function call(ip, method, params = {}) {
  const r = await request(ip, { id: 1, method, params });
  logOut('wiz', { ip, method, params, reply: r.raw ?? r });
  return r;
}

async function info(ip) {
  const out = { ip, at: new Date().toISOString() };
  for (const m of ['getSystemConfig', 'getModelConfig', 'getUserConfig', 'getPilot']) {
    const r = await call(ip, m);
    if (r.timeout) {
      console.log(`${m}: timeout`);
      out[m] = { timeout: true };
      continue;
    }
    if (r.json?.error?.code === -32601) {
      console.log(`${m}: -32601 Method not found (older firmware) - tolerated`);
    } else {
      console.log(`${m}: ${r.raw}`);
    }
    out[m] = r.json;
    out[`${m}_signing`] = signingHints(r.json);
  }
  const sys = out.getSystemConfig?.result ?? {};
  if (out.getSystemConfig?.timeout && out.getPilot?.timeout) die(`${ip}: no reply on UDP ${PORT} (not a WiZ device, offline, or local communication disabled).`);
  const all = loadOut('wiz-info.json', {});
  const key = normMac(sys.mac) || ip;
  all[key] = out;
  const file = saveOut('wiz-info.json', all);
  console.log(`\nmoduleName=${sys.moduleName ?? '?'} fwVersion=${sys.fwVersion ?? '?'} mac=${sys.mac ?? '?'}`);
  const anyHmac = Object.keys(out).some((k) => k.endsWith('_signing') && out[k].replyHasHmac);
  console.log(`signed replies (hmac on reads): ${anyHmac ? 'YES -> firmware has the 1.34+ signing feature' : 'no'}`);
  console.log(`Saved ${file}`);
}

async function state(ip) {
  const r = await call(ip, 'getPilot');
  if (r.timeout) die('timeout');
  console.log(r.raw);
}

async function set(ip, jsonParams) {
  if (!jsonParams) die('usage: wiz.mjs set <ip> \'{"state":true}\'');
  let params;
  try { params = JSON.parse(jsonParams); } catch (e) { die(`bad JSON params: ${e.message}`); }

  // Resolve the MAC so TEST_DEVICE may name either the IP or the MAC.
  const pilot = await request(ip, { method: 'getPilot', params: {} });
  const mac = normMac(pilot.json?.result?.mac);
  if (!writeAllowed(ip, mac)) return refuseWrite(`${ip} (mac ${mac || 'unknown'})`);

  const msg = { method: 'setPilot', params };
  const key = process.env.WIZ_SIGNING_KEY;
  if (key) {
    const s = signParams(params, key.trim());
    msg.env = 'pro';
    msg.params = s.params;
    msg.hmac = s.hmac;
    console.log(`signing with WIZ_SIGNING_KEY (sigTs=${s.params.sigTs})`);
  }
  const r = await request(ip, msg, { retries: [0, 750] }); // fewer retries for writes (avoid flicker)
  logOut('wiz', { ip, method: 'setPilot', params: msg.params, signed: !!key, reply: r.raw ?? r });
  if (r.timeout) die('timeout');
  console.log(r.raw);
  const code = r.json?.error?.code;
  if (code === -32602) console.log('-> -32602 Invalid params: this bulb requires signed writes (set WIZ_SIGNING_KEY) or "Allow all controls" in the WiZ app.');
  if (code === -32605) console.log('-> -32605 Security error: signature rejected (wrong key or stale sigTs).');
}

// ---------- main ----------

const [cmd, ...args] = process.argv.slice(2);
switch (cmd) {
  case 'discover': await discover(); break;
  case 'sweep': await sweep(args[0]); break;
  case 'info': if (!args[0]) die('usage: wiz.mjs info <ip>'); await info(args[0]); break;
  case 'state': if (!args[0]) die('usage: wiz.mjs state <ip>'); await state(args[0]); break;
  case 'set': await set(args[0], args[1]); break;
  default:
    console.log('usage: node wiz.mjs discover | sweep [a.b.c] | info <ip> | state <ip> | set <ip> <json-params>');
    process.exitCode = cmd ? 1 : 0;
}
