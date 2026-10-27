"""Generates TPLinkCodec test vectors by running python-kasa (GPL-3.0).

Only the *outputs* of python-kasa are recorded (hex strings); no python-kasa code is copied into
the Swift sources. Run:

    python3 -m venv /tmp/kasa && /tmp/kasa/bin/pip install python-kasa==0.12.0
    /tmp/kasa/bin/python -I gen_vectors.py > tplink_vectors.json

All inputs are fixed so the output is deterministic.
"""

import binascii
import hashlib
import json
import struct

import kasa
from kasa.credentials import Credentials
from kasa.discover import Discover
from kasa.transports.klaptransport import KlapEncryptionSession, KlapTransport, KlapTransportV2
from kasa.transports.xortransport import XorEncryption


def h(b: bytes) -> str:
    return b.hex()


out = {"python_kasa_version": getattr(kasa, "__version__", "0.12.0")}

# --- XOR autokey (legacy Kasa, TCP/UDP 9999) ---
xor_msgs = [
    '{"system":{"get_sysinfo":{}}}',
    '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":'
    '{"on_off":1,"brightness":42,"hue":120,"saturation":75,"color_temp":0,"transition_period":500,"ignore_default":1}}}',
    "",
]
out["xor"] = [
    {"plain": m, "framed": h(XorEncryption.encrypt(m)), "decrypted": XorEncryption.decrypt(XorEncryption.encrypt(m)[4:])}
    for m in xor_msgs
]
# Discovery datagram on UDP 9999 is the frame without its length prefix.
out["discovery_legacy"] = h(XorEncryption.encrypt(json.dumps(Discover.DISCOVERY_QUERY))[4:])
out["discovery_legacy_plain"] = json.dumps(Discover.DISCOVERY_QUERY)
out["discovery_query_2"] = h(Discover.DISCOVERY_QUERY_2)

# 20002 header with a payload: same packing as python-kasa's _AesDiscoveryQuery.generate_query,
# with a fixed serial and payload instead of random ones.
def disco_query(payload: bytes, serial: int, flags: int = 17) -> bytes:
    header = struct.pack(">BBHHBBII", 2, 0, 1, len(payload), flags, 0, serial, 0x5A6B7C8D)
    q = bytearray(header + payload)
    q[12:16] = binascii.crc32(q).to_bytes(4, "big")
    return bytes(q)

payload = json.dumps({"params": {"rsa_key": "-----BEGIN PUBLIC KEY-----\nTEST\n-----END PUBLIC KEY-----\n"}}).encode()
out["discovery_20002"] = {
    "payload": payload.decode(),
    "serial": 0x01020304,
    "flags": 17,
    "query": h(disco_query(payload, 0x01020304)),
}

# --- KLAP ---
creds = Credentials("User@Example.com", "Pa55word!")
local_seed = bytes(range(16))
remote_seed = bytes(range(0x10, 0x20))
out["klap"] = {
    "username": creds.username,
    "password": creds.password,
    "local_seed": h(local_seed),
    "remote_seed": h(remote_seed),
    "v1_auth_hash": h(KlapTransport.generate_auth_hash(creds)),
    "v2_auth_hash": h(KlapTransportV2.generate_auth_hash(creds)),
    "blank_v1_auth_hash": h(KlapTransport.generate_auth_hash(Credentials())),
    "blank_v2_auth_hash": h(KlapTransportV2.generate_auth_hash(Credentials())),
    "lowercase_v2_auth_hash": h(KlapTransportV2.generate_auth_hash(Credentials(creds.username.lower(), creds.password))),
}
for v, cls in (("v1", KlapTransport), ("v2", KlapTransportV2)):
    auth = cls.generate_auth_hash(creds)
    out["klap"][f"{v}_handshake1_server_hash"] = h(cls.handshake1_seed_auth_hash(local_seed, remote_seed, auth))
    out["klap"][f"{v}_handshake2_payload"] = h(cls.handshake2_seed_auth_hash(local_seed, remote_seed, auth))

auth = KlapTransportV2.generate_auth_hash(creds)
session = KlapEncryptionSession(local_seed, remote_seed, auth)
out["klap_session"] = {
    "key": h(session._key),
    "iv": h(session._iv),
    "seq": session._seq,
    "sig": h(session._sig),
    "messages": [],
}
for msg in ['{"method":"get_device_info"}', '{"method":"set_device_info","params":{"device_on":true,"brightness":50}}']:
    payload, seq = session.encrypt(msg)
    # The device answers with the same IV/sequence: sig(32) + AES-CBC(PKCS7(response)).
    response_plain = '{"error_code":0,"result":{"device_on":true}}'
    from cryptography.hazmat.primitives import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    padder = padding.PKCS7(128).padder()
    padded = padder.update(response_plain.encode()) + padder.finalize()
    enc = Cipher(algorithms.AES(session._key), modes.CBC(session._iv + struct.pack(">l", seq))).encryptor()
    ct = enc.update(padded) + enc.finalize()
    sig = hashlib.sha256(session._sig + struct.pack(">l", seq) + ct).digest()
    response = sig + ct
    out["klap_session"]["messages"].append({
        "plain": msg,
        "seq": seq,
        "payload": h(payload),
        "response_plain": response_plain,
        "response": h(response),
        "decrypted": session.decrypt(response),
    })

# Sequence wrap-around: python packs the sequence as a signed 32-bit int (">l").
out["klap_seq_pack"] = {str(s): h(struct.pack(">l", s)) for s in (-2147483648, -1, 0, 1, 2147483647)}

print(json.dumps(out, indent=2, sort_keys=True))
