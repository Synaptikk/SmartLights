#!/usr/bin/env node
// Philips Hue bridge probe (CLIP v2). See research/research_hue.md §1.
//
//   node hue.mjs discover [ip]          mDNS _hue._tcp + discovery.meethue.com + optional manual IP, then GET /api/config
//   node hue.mjs cert <ip>              dump the TLS chain (self-signed vs Signify CA)
//   node hue.mjs pair <ip>              POST /api {generateclientkey:true}; press the link button first. Saves out/hue.json
//   node hue.mjs list <ip>              GET /clip/v2/resource/{light,device,room,scene}
//   node hue.mjs events <ip> [secs]     tail the SSE eventstream (default 60 s)
//   node hue.mjs set <ip> <lightId> '<json>'   PUT /clip/v2/resource/light/<id> (only when TEST_DEVICE == lightId)

import https from 'node:https';
import http from 'node:http';
import tls from 'node:tls';
import crypto from 'node:crypto';
import { mdnsQuery } from './lib/mdns.mjs';
import { saveOut, loadOut, logOut, writeAllowed, refuseWrite, die, redact, sleep } from './lib/common.mjs';

const insecure = new https.Agent({ rejectUnauthorized: false, keepAlive: false });
const SIGNIFY_ROOT_URL = 'https://raw.githubusercontent.com/jdmg94/Hue-Sync/master/signify.pem';

function req(url, { method = 'GET', headers = {}, body, timeoutMs = 8000 } = {}) {
  return new Promise((resolve) => {
    const u = new URL(url);
    const mod = u.protocol === 'https:' ? https : http;
    const data = body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body);
    const r = mod.request(u, {
      method,
      agent: u.protocol === 'https:' && /^\d+\.\d+\.\d+\.\d+$/.test(u.hostname) ? insecure : undefined,
      headers: { ...(data ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) } : {}), ...headers },
      timeout: timeoutMs,
    }, (res) => {
      let buf = '';
      res.setEncoding('utf8');
      res.on('data', (c) => (buf += c));
      res.on('end', () => {
        let json;
        try { json = JSON.parse(buf); } catch { /* not json */ }
        resolve({ status: res.statusCode, headers: res.headers, text: buf, json });
      });
    });
    r.on('timeout', () => r.destroy(new Error('timeout')));
    r.on('error', (e) => resolve({ error: e.message }));
    if (data) r.write(data);
    r.end();
  });
}

function creds(ip) {
  const all = loadOut('hue.json', {});
  const c = all[ip] ?? Object.values(all).find((x) => x?.ip === ip);
  if (!c?.username) die(`No stored application key for ${ip}. Run: node hue.mjs pair ${ip}`);
  return c;
}

// ---------- discover ----------

async function apiConfig(ip) {
  // Unauthenticated; try HTTPS first (HTTP may be blocked on newer firmware).
  for (const proto of ['https', 'http']) {
    const r = await req(`${proto}://${ip}/api/config`, { timeoutMs: 5000 });
    if (r.json?.bridgeid) return { proto, ...r.json };
  }
  return null;
}

async function discover(manualIp) {
  const candidates = new Map(); // ip -> sources[]
  const add = (ip, src, extra = {}) => {
    const c = candidates.get(ip) ?? { ip, sources: [] };
    c.sources.push(src);
    Object.assign(c, extra);
    candidates.set(ip, c);
  };

  console.log('mDNS _hue._tcp.local ...');
  const replies = await mdnsQuery('_hue._tcp.local', 3000);
  for (const rep of replies) {
    const txt = rep.records.find((r) => r.type === 'TXT')?.data ?? {};
    const a = rep.records.find((r) => r.type === 'A')?.data;
    if (rep.records.some((r) => /_hue\._tcp/.test(r.name))) add(a ?? rep.from, 'mdns', { mdnsTxt: txt });
  }
  console.log(`  ${replies.length} mDNS reply packet(s)`);

  console.log('GET https://discovery.meethue.com/ ...');
  const cloud = await req('https://discovery.meethue.com/');
  if (Array.isArray(cloud.json)) {
    for (const b of cloud.json) add(b.internalipaddress, 'discovery.meethue.com', { cloudId: b.id, port: b.port });
    console.log(`  ${cloud.json.length} bridge(s) registered from this public IP`);
  } else {
    console.log(`  failed: ${cloud.error ?? `HTTP ${cloud.status} ${cloud.text?.slice(0, 120)}`}`);
  }

  if (manualIp) add(manualIp, 'manual');

  const out = [];
  for (const c of candidates.values()) {
    const cfg = await apiConfig(c.ip);
    const rec = { ...c, config: cfg };
    out.push(rec);
    if (cfg) {
      console.log(`${c.ip}  bridgeid=${cfg.bridgeid} modelid=${cfg.modelid} swversion=${cfg.swversion} apiversion=${cfg.apiversion} name="${cfg.name}" via ${cfg.proto} [${c.sources.join(',')}]`);
      const v2 = await req(`https://${c.ip}/clip/v2/resource`, { timeoutMs: 5000 });
      rec.clipV2Probe = v2.status ?? v2.error;
      console.log(`    GET /clip/v2/resource (no key) -> ${v2.status ?? v2.error} (403 = v2 API present, 404 = no v2)`);
    } else {
      console.log(`${c.ip}  no /api/config answer [${c.sources.join(',')}]`);
    }
  }
  if (!out.length) console.log('No Hue bridge found. Pass the IP manually: node hue.mjs discover <ip>');
  const file = saveOut('hue-discover.json', { at: new Date().toISOString(), bridges: out });
  console.log(`Saved ${file}`);
}

// ---------- cert ----------

function certSummary(c) {
  return {
    subjectCN: c.subject?.CN,
    subject: c.subject,
    issuerCN: c.issuer?.CN,
    issuer: c.issuer,
    validFrom: c.valid_from,
    validTo: c.valid_to,
    serialNumber: c.serialNumber,
    sha256: c.fingerprint256,
    keyType: c.asn1Curve ? `EC ${c.asn1Curve}` : c.bits ? `RSA ${c.bits}` : undefined,
    selfSigned: c.issuerCertificate === c || (c.subject?.CN === c.issuer?.CN && JSON.stringify(c.subject) === JSON.stringify(c.issuer)),
  };
}

function tlsConnect(ip, opts = {}) {
  return new Promise((resolve) => {
    const s = tls.connect({ host: ip, port: 443, rejectUnauthorized: false, servername: undefined, timeout: 8000, ...opts }, () => {
      const chain = [];
      let c = s.getPeerCertificate(true);
      const seen = new Set();
      while (c && c.fingerprint256 && !seen.has(c.fingerprint256)) {
        seen.add(c.fingerprint256);
        chain.push(certSummary(c));
        c = c.issuerCertificate;
      }
      resolve({ authorized: s.authorized, authorizationError: s.authorizationError, protocol: s.getProtocol(), cipher: s.getCipher()?.name, chain });
      s.end();
    });
    s.on('timeout', () => { s.destroy(); resolve({ error: 'timeout' }); });
    s.on('error', (e) => resolve({ error: e.message }));
  });
}

async function cert(ip) {
  const r = await tlsConnect(ip);
  if (r.error) die(`TLS connect failed: ${r.error}`);
  console.log(`TLS ${r.protocol} ${r.cipher}`);
  r.chain.forEach((c, i) => {
    console.log(`[${i}] subject CN=${c.subjectCN}  O=${c.subject?.O ?? '-'}  C=${c.subject?.C ?? '-'}`);
    console.log(`    issuer  CN=${c.issuerCN}  O=${c.issuer?.O ?? '-'}`);
    console.log(`    valid   ${c.validFrom} -> ${c.validTo}   key ${c.keyType ?? '?'}  serial ${c.serialNumber}`);
    console.log(`    sha256  ${c.sha256}`);
  });

  const cfg = await apiConfig(ip);
  const leaf = r.chain[0];
  const bridgeid = cfg?.bridgeid?.toLowerCase();
  const verdict = {
    bridgeid: cfg?.bridgeid,
    leafCNMatchesBridgeId: !!bridgeid && leaf?.subjectCN?.toLowerCase() === bridgeid,
    issuerIsBridgeItself: !!bridgeid && leaf?.issuerCN?.toLowerCase() === bridgeid,
    issuerIsSignifyRoot: leaf?.issuerCN === 'root-bridge' || r.chain.some((c) => c.subjectCN === 'root-bridge'),
  };

  // Verify against the Signify Hue root (fetched once and cached in out/).
  let rootPem = loadOut('signify-root.json')?.pem;
  if (!rootPem) {
    const g = await req(SIGNIFY_ROOT_URL);
    if (g.status === 200 && g.text.includes('BEGIN CERTIFICATE')) {
      rootPem = g.text;
      saveOut('signify-root.json', { source: SIGNIFY_ROOT_URL, pem: rootPem });
    }
  }
  if (rootPem) {
    const root = new crypto.X509Certificate(rootPem);
    verdict.signifyRoot = { subject: root.subject.replace(/\n/g, ', '), sha256: root.fingerprint256 };
    const v = await tlsConnect(ip, { ca: rootPem, rejectUnauthorized: false, checkServerIdentity: () => undefined });
    verdict.chainVerifiesAgainstSignifyRoot = v.authorized === true;
    verdict.verifyError = v.authorizationError ?? null;
  }
  verdict.classification = verdict.chainVerifiesAgainstSignifyRoot || verdict.issuerIsSignifyRoot
    ? 'Signify-CA-signed (validate with Signify root + CN == bridgeid)'
    : verdict.issuerIsBridgeItself || leaf?.selfSigned
      ? 'self-signed (needs TOFU pinning)'
      : 'unknown issuer';
  console.log('\n' + JSON.stringify(verdict, null, 2));

  const all = loadOut('hue-cert.json', {});
  all[ip] = { at: new Date().toISOString(), ...r, verdict };
  console.log(`Saved ${saveOut('hue-cert.json', all)}`);
}

// ---------- pair ----------

async function pair(ip) {
  const cfg = await apiConfig(ip);
  if (!cfg) die(`${ip} does not answer /api/config - is it a Hue bridge?`);
  console.log(`Bridge ${cfg.bridgeid} (${cfg.modelid}, sw ${cfg.swversion}).`);
  console.log('>>> Press the round LINK BUTTON on the bridge now. Trying for 60 s ...');
  const body = { devicetype: 'SmartLights#probe', generateclientkey: true };
  for (let i = 0; i < 30; i++) {
    const r = await req(`https://${ip}/api`, { method: 'POST', body });
    const item = Array.isArray(r.json) ? r.json[0] : null;
    if (item?.success?.username) {
      const all = loadOut('hue.json', {});
      all[ip] = { ip, bridgeid: cfg.bridgeid, username: item.success.username, clientkey: item.success.clientkey, pairedAt: new Date().toISOString() };
      const file = saveOut('hue.json', all, { secret: true });
      console.log(`Paired. Application key + clientkey stored in ${file} (not printed).`);
      return;
    }
    const err = item?.error;
    if (err && err.type !== 101) die(`Unexpected error: ${JSON.stringify(err)}`);
    if (i === 0) console.log(`  waiting (error 101 "${err?.description ?? 'link button not pressed'}") ...`);
    await sleep(2000);
  }
  die('Gave up after 60 s - link button not pressed.');
}

// ---------- list ----------

async function list(ip) {
  const c = creds(ip);
  const H = { 'hue-application-key': c.username };
  const res = {};
  for (const type of ['light', 'device', 'room', 'scene', 'bridge', 'grouped_light', 'zone']) {
    const r = await req(`https://${ip}/clip/v2/resource/${type}`, { headers: H });
    if (r.status !== 200) {
      console.log(`${type}: HTTP ${r.status ?? r.error} ${r.text?.slice(0, 200) ?? ''}`);
      continue;
    }
    res[type] = r.json?.data ?? [];
    if (r.json?.errors?.length) console.log(`${type} errors: ${JSON.stringify(r.json.errors)}`);
  }
  const devById = Object.fromEntries((res.device ?? []).map((d) => [d.id, d]));
  console.log(`\nLights (${res.light?.length ?? 0}):`);
  for (const l of res.light ?? []) {
    const dev = devById[l.owner?.rid];
    const caps = [l.dimming && 'dim', l.color_temperature && `ct(${l.color_temperature.mirek_schema?.mirek_minimum}-${l.color_temperature.mirek_schema?.mirek_maximum})`, l.color && `color(gamut ${l.color.gamut_type})`, l.gradient && 'gradient', l.effects && 'effects'].filter(Boolean).join(' ');
    console.log(`  ${l.id}  "${l.metadata?.name}"  on=${l.on?.on} bri=${l.dimming?.brightness ?? '-'}  ${caps}`);
    if (dev) console.log(`      device ${dev.product_data?.model_id} "${dev.product_data?.product_name}" ${dev.product_data?.manufacturer_name} sw ${dev.product_data?.software_version}`);
  }
  console.log(`\nDevices (${res.device?.length ?? 0}):`);
  for (const d of res.device ?? []) console.log(`  ${d.id}  ${d.product_data?.model_id}  "${d.metadata?.name}"  ${d.product_data?.manufacturer_name} sw ${d.product_data?.software_version}`);
  console.log(`\nRooms (${res.room?.length ?? 0}):`);
  for (const r of res.room ?? []) console.log(`  ${r.id}  "${r.metadata?.name}"  children=${r.children?.length}`);
  console.log(`\nScenes (${res.scene?.length ?? 0}):`);
  for (const s of res.scene ?? []) console.log(`  ${s.id}  "${s.metadata?.name}"  group=${s.group?.rtype}:${s.group?.rid}`);
  console.log(`\nSaved ${saveOut('hue-list.json', { at: new Date().toISOString(), ip, ...res })}`);
}

// ---------- events ----------

async function events(ip, secs = 60) {
  const c = creds(ip);
  console.log(`Tailing https://${ip}/eventstream/clip/v2 for ${secs} s (change a light in the Hue app to see events) ...`);
  await new Promise((resolve) => {
    const r = https.request(`https://${ip}/eventstream/clip/v2`, {
      agent: insecure,
      headers: { 'hue-application-key': c.username, Accept: 'text/event-stream', 'Cache-Control': 'no-cache' },
    }, (res) => {
      console.log(`HTTP ${res.statusCode} ${res.headers['content-type'] ?? ''}`);
      let buf = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        buf += chunk;
        let idx;
        while ((idx = buf.indexOf('\n\n')) >= 0) {
          const block = buf.slice(0, idx);
          buf = buf.slice(idx + 2);
          const id = block.match(/^id: ?(.*)$/m)?.[1];
          const data = block.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim()).join('');
          if (!data) { if (block.trim()) console.log(`[${new Date().toISOString()}] ${block.trim()}`); continue; }
          let parsed;
          try { parsed = JSON.parse(data); } catch { parsed = data; }
          logOut('hue-events', { id, data: parsed });
          for (const ev of Array.isArray(parsed) ? parsed : [parsed]) {
            for (const d of ev.data ?? []) {
              console.log(`[${new Date().toISOString()}] id=${id} ${ev.type} ${d.type} ${d.id} ${JSON.stringify(redact({ ...d, id: undefined, id_v1: undefined, owner: undefined, type: undefined }))}`);
            }
          }
        }
      });
      res.on('end', resolve);
    });
    r.on('error', (e) => { console.log(`error: ${e.message}`); resolve(); });
    r.end();
    setTimeout(() => { r.destroy(); resolve(); }, secs * 1000);
  });
  console.log('Done. Raw events appended to out/hue-events.log.jsonl');
}

// ---------- set ----------

async function set(ip, lightId, json) {
  if (!lightId || !json) die('usage: hue.mjs set <ip> <lightId> \'{"on":{"on":true}}\'');
  if (!writeAllowed(lightId)) return refuseWrite(`light ${lightId}`);
  let body;
  try { body = JSON.parse(json); } catch (e) { die(`bad JSON: ${e.message}`); }
  const c = creds(ip);
  const r = await req(`https://${ip}/clip/v2/resource/light/${lightId}`, { method: 'PUT', headers: { 'hue-application-key': c.username }, body });
  logOut('hue', { ip, lightId, body, status: r.status, reply: r.text ?? r.error });
  console.log(`HTTP ${r.status ?? r.error}\n${r.text ?? ''}`);
}

// ---------- main ----------

const [cmd, ...args] = process.argv.slice(2);
const need = (n, usage) => { if (args.length < n) die(`usage: node hue.mjs ${usage}`); };
switch (cmd) {
  case 'discover': await discover(args[0]); break;
  case 'cert': need(1, 'cert <ip>'); await cert(args[0]); break;
  case 'pair': need(1, 'pair <ip>'); await pair(args[0]); break;
  case 'list': need(1, 'list <ip>'); await list(args[0]); break;
  case 'events': need(1, 'events <ip> [secs]'); await events(args[0], Number(args[1] ?? 60)); break;
  case 'set': await set(args[0], args[1], args[2]); break;
  default:
    console.log('usage: node hue.mjs discover [ip] | cert <ip> | pair <ip> | list <ip> | events <ip> [secs] | set <ip> <lightId> <json>');
    process.exitCode = cmd ? 1 : 0;
}
