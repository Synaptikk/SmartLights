// Minimal one-shot mDNS (RFC 6762) PTR query + response parser. Node built-ins only.

import dgram from 'node:dgram';
import { ipv4Interfaces } from './common.mjs';

const MDNS_ADDR = '224.0.0.251';
const MDNS_PORT = 5353;
const TYPES = { 1: 'A', 12: 'PTR', 16: 'TXT', 28: 'AAAA', 33: 'SRV' };

function encodeName(name) {
  const parts = name.replace(/\.$/, '').split('.');
  const bufs = parts.map((p) => {
    const b = Buffer.from(p, 'utf8');
    return Buffer.concat([Buffer.from([b.length]), b]);
  });
  return Buffer.concat([...bufs, Buffer.from([0])]);
}

function buildQuery(name, type = 12) {
  const header = Buffer.alloc(12); // id 0, flags 0, qdcount 1
  header.writeUInt16BE(1, 4);
  const q = Buffer.alloc(4);
  q.writeUInt16BE(type, 0);
  q.writeUInt16BE(0x8001, 2); // class IN + unicast-response bit (QU) so replies come straight back
  return Buffer.concat([header, encodeName(name), q]);
}

function readName(buf, off) {
  const labels = [];
  let jumped = false;
  let end = off;
  for (let guard = 0; guard < 128; guard++) {
    const len = buf[off];
    if (len === undefined) break;
    if (len === 0) { off += 1; break; }
    if ((len & 0xc0) === 0xc0) {
      const ptr = ((len & 0x3f) << 8) | buf[off + 1];
      if (!jumped) end = off + 2;
      jumped = true;
      off = ptr;
      continue;
    }
    labels.push(buf.toString('utf8', off + 1, off + 1 + len));
    off += 1 + len;
  }
  return { name: labels.join('.'), next: jumped ? end : off };
}

export function parsePacket(buf) {
  const qd = buf.readUInt16BE(4);
  const total = buf.readUInt16BE(6) + buf.readUInt16BE(8) + buf.readUInt16BE(10);
  let off = 12;
  for (let i = 0; i < qd; i++) off = readName(buf, off).next + 4;
  const records = [];
  for (let i = 0; i < total && off < buf.length; i++) {
    const { name, next } = readName(buf, off);
    off = next;
    const type = buf.readUInt16BE(off);
    const rdlen = buf.readUInt16BE(off + 8);
    const rd = off + 10;
    const rec = { name, type: TYPES[type] ?? type };
    if (type === 1) rec.data = [...buf.subarray(rd, rd + 4)].join('.');
    else if (type === 12) rec.data = readName(buf, rd).name;
    else if (type === 33) rec.data = { port: buf.readUInt16BE(rd + 4), target: readName(buf, rd + 6).name };
    else if (type === 16) {
      const txt = {};
      let p = rd;
      while (p < rd + rdlen) {
        const l = buf[p];
        const s = buf.toString('utf8', p + 1, p + 1 + l);
        const eq = s.indexOf('=');
        if (s) txt[eq < 0 ? s : s.slice(0, eq)] = eq < 0 ? true : s.slice(eq + 1);
        p += 1 + l;
      }
      rec.data = txt;
    }
    records.push(rec);
    off = rd + rdlen;
  }
  return records;
}

/**
 * Send a PTR query for `service` (e.g. "_hue._tcp.local") on every IPv4 interface and
 * collect answers for `waitMs`. Returns [{from, records}].
 */
export async function mdnsQuery(service, waitMs = 3000) {
  const replies = [];
  const sockets = [];
  const query = buildQuery(service);
  for (const iface of ipv4Interfaces()) {
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    sockets.push(sock);
    sock.on('error', () => {});
    sock.on('message', (buf, rinfo) => {
      try {
        const records = parsePacket(buf);
        if (records.length) replies.push({ from: rinfo.address, iface: iface.name, records });
      } catch { /* malformed */ }
    });
    try {
      // Bind to 5353 to also see multicast answers; fall back to an ephemeral port (unicast replies only).
      await new Promise((res, rej) => { sock.once('error', rej); sock.bind({ port: MDNS_PORT, exclusive: false }, () => { sock.off('error', rej); res(); }); });
      try { sock.addMembership(MDNS_ADDR, iface.address); } catch { /* ignore */ }
    } catch {
      await new Promise((res) => sock.bind(0, iface.address, res));
    }
    try { sock.setMulticastInterface(iface.address); } catch { /* ignore */ }
    sock.send(query, MDNS_PORT, MDNS_ADDR);
    setTimeout(() => { try { sock.send(query, MDNS_PORT, MDNS_ADDR); } catch { /* closed */ } }, 1000);
  }
  await new Promise((r) => setTimeout(r, waitMs));
  sockets.forEach((s) => { try { s.close(); } catch { /* ignore */ } });
  return replies;
}
