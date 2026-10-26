// Shared helpers for the SmartLights hardware probes.
// Node built-ins only. Outputs go to tools/probe/out/ (gitignored).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

export const PROBE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const OUT_DIR = path.join(PROBE_DIR, 'out');

export function ensureOutDir() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
}

/** Write JSON into out/. `secret` files get mode 0600 (best effort; on Windows NTFS ACLs of the user profile apply). */
export function saveOut(name, data, { secret = false } = {}) {
  ensureOutDir();
  const file = path.join(OUT_DIR, name);
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', { mode: secret ? 0o600 : 0o644 });
  if (secret) {
    try { fs.chmodSync(file, 0o600); } catch { /* ignore on Windows */ }
  }
  return file;
}

export function loadOut(name, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(path.join(OUT_DIR, name), 'utf8'));
  } catch {
    return fallback;
  }
}

/** Append a timestamped record to out/<name>.log.jsonl for later write-up. */
export function logOut(name, record) {
  ensureOutDir();
  fs.appendFileSync(path.join(OUT_DIR, `${name}.log.jsonl`), JSON.stringify({ ts: new Date().toISOString(), ...record }) + '\n');
}

/** Non-internal IPv4 interfaces with their directed broadcast address. */
export function ipv4Interfaces() {
  const res = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family !== 'IPv4' || a.internal) continue;
      if (a.netmask === '255.255.255.255') continue; // point-to-point (e.g. Tailscale)
      const ip = a.address.split('.').map(Number);
      const mask = a.netmask.split('.').map(Number);
      const bcast = ip.map((o, i) => (o & mask[i]) | (~mask[i] & 255)).join('.');
      res.push({ name, address: a.address, netmask: a.netmask, broadcast: bcast, mac: a.mac });
    }
  }
  return res;
}

const SECRET_KEYS = /^(password|passwd|aeskey|accesstoken|refreshtoken|token|clientkey|username|hmac|key|signingkey|udp_signing_key)$/i;

/** Deep-copy with secret-looking fields replaced. Used for console output only. */
export function redact(value) {
  if (Array.isArray(value)) return value.map(redact);
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (SECRET_KEYS.test(k) && v !== null && v !== undefined && v !== '') {
        out[k] = Array.isArray(v) ? v.map(() => '<redacted>') : '<redacted>';
      } else {
        out[k] = redact(v);
      }
    }
    return out;
  }
  return value;
}

export function normMac(s) {
  return String(s ?? '').toLowerCase().replace(/[^0-9a-f]/g, '');
}

/**
 * Write guard. Returns true only when env TEST_DEVICE names one of the given ids
 * (compared case-insensitively; MAC-like ids compared without separators).
 */
export function writeAllowed(...ids) {
  const td = process.env.TEST_DEVICE;
  if (!td) return false;
  const want = td.trim().toLowerCase();
  return ids.filter(Boolean).some((id) => {
    const s = String(id).toLowerCase();
    return s === want || (normMac(s).length === 12 && normMac(s) === normMac(want));
  });
}

export function refuseWrite(target) {
  console.error(`REFUSED: writes are only allowed to the device named in env TEST_DEVICE.`);
  console.error(`  target: ${target}`);
  console.error(`  TEST_DEVICE: ${process.env.TEST_DEVICE ?? '(unset)'}`);
  process.exitCode = 2;
}

export function prompt(question, { mute = false } = {}) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    if (mute) {
      rl._writeToOutput = (s) => {
        if (s.includes(question)) rl.output.write(s);
        else if (s === '\r\n' || s === '\n') rl.output.write(s);
      };
    }
    rl.question(question, (answer) => {
      rl.close();
      if (mute) process.stdout.write('\n');
      resolve(answer);
    });
  });
}

export function die(msg, code = 1) {
  console.error(msg);
  process.exit(code);
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
