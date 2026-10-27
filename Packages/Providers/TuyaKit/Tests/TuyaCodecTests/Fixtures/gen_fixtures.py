"""Generates tuya_fixtures.json from the upstream tinytuya library (MIT, Jason A. Cox).

Run from Packages/Providers/TuyaKit/Tests/TuyaCodecTests/Fixtures:

    docker run --rm -v "<abs path to this folder>:/w" -w /w python:3.12 \
        bash -c "pip install -q tinytuya==1.20.0 && python gen_fixtures.py"

Only tinytuya's pure functions are used (generate_payload, _encode_message, pack/unpack_message,
the session-key negotiation steps, decrypt_udp, BulbDevice colour helpers); nothing touches the
network. The clock (`t`) and the randomness (client nonce, GCM IVs) are pinned so the output is
deterministic. Device->client frames (which tinytuya never builds) are assembled here and then
round-tripped through tinytuya's own decoder, so every vector is checked by the upstream code.
"""

import binascii
import hmac
import json
import struct
from hashlib import md5, sha256

import tinytuya
from tinytuya import BulbDevice
import importlib
from tinytuya.core import crypto_helper, udp_helper
from tinytuya.core import command_types as CT
from tinytuya.core import header as H
from tinytuya.core.message_helper import TuyaMessage, pack_message, unpack_message

XD = importlib.import_module("tinytuya.core.XenonDevice")

DEV_ID = "bf8d3e7a1c2b4f5e6a7b"
LOCAL_KEY = "a1B2c3D4e5F6g7H8"
T = 1761475200

LOCAL_NONCE = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
REMOTE_NONCE = bytes.fromhex("f0e1d2c3b4a5968778695a4b3c2d1e0f")

# ---- pin clock and randomness -------------------------------------------
XD.time.time = lambda: T + 0.25  # generate_payload truncates to int seconds

_iv_queue = []


def fake_urandom(n):
    if n == 16:
        return LOCAL_NONCE
    if n == 12:
        return _iv_queue.pop(0)
    raise AssertionError("unexpected urandom(%d)" % n)


XD.os.urandom = fake_urandom
crypto_helper.os.urandom = fake_urandom


def iv(n):
    return bytes([n]) * 12


def hx(b):
    return binascii.hexlify(b).decode()


def device(version, dev_type="default"):
    d = tinytuya.Device(DEV_ID, address="127.0.0.1", local_key=LOCAL_KEY, version=version, dev_type=dev_type)
    d.disabledetect = True
    return d


def encode(d, cmd, data=None, gcm_iv=None):
    msg = d.generate_payload(cmd, data)
    if gcm_iv is not None:
        _iv_queue.append(gcm_iv)
    frame = d._encode_message(msg)
    assert not _iv_queue
    return {"cmd": msg.cmd, "json": msg.payload.decode(), "frame": hx(frame)}


def device_frame_55aa(seq, cmd, payload, hmac_key=None, retcode=0):
    """A device->client 55AA frame: header, retcode, payload, CRC32 or HMAC, suffix."""
    end = 36 if hmac_key else 8
    body = struct.pack(">I", retcode) + payload
    head = struct.pack(">4I", H.PREFIX_55AA_VALUE, seq, cmd, len(body) + end)
    data = head + body
    if hmac_key:
        data += hmac.new(hmac_key, data, sha256).digest()
    else:
        data += struct.pack(">I", binascii.crc32(data) & 0xFFFFFFFF)
    return data + H.SUFFIX_BIN


def device_frame_6699(seq, cmd, payload, key, gcm_iv, retcode=0):
    return pack_message(TuyaMessage(seq, cmd, retcode, payload, 0, True, H.PREFIX_6699_VALUE, gcm_iv), hmac_key=key)


def ecb(key, raw, pad=True):
    return crypto_helper.AESCipher(key).encrypt(raw, use_base64=False, pad=pad)


def decoded(d, frame, hmac_key=None):
    msg = unpack_message(frame, hmac_key=hmac_key)
    assert msg.crc_good, "bad trailer"
    return {"seqno": msg.seqno, "cmd": msg.cmd, "retcode": msg.retcode, "json": d._decode_payload(msg.payload)}


key = LOCAL_KEY.encode()
out = {
    "devId": DEV_ID,
    "localKey": LOCAL_KEY,
    "t": T,
    "localNonce": hx(LOCAL_NONCE),
    "remoteNonce": hx(REMOTE_NONCE),
    "udpKey": hx(udp_helper.udpkey),
    "tinytuya": tinytuya.__version__,
}

# ---- CRC32 ----------------------------------------------------------------
out["crc32"] = [{"hex": hx(s), "crc": binascii.crc32(s) & 0xFFFFFFFF}
                for s in (b"", b"123456789", b"\x00\x00\x55\xaa", bytes(range(256)))]

STATUS_JSON = json.dumps({"devId": DEV_ID, "dps": {"20": True, "21": "colour", "22": 800, "23": 500,
                                                  "24": "00f003e803e8"}, "t": T}).replace(" ", "")
STATUS_JSON_V34 = json.dumps({"protocol": 4, "t": T, "data": {"dps": {"20": False, "22": 10}}}).replace(" ", "")
SET_DPS = {"20": True, "21": "white", "22": 500, "23": 250}

# ---- 3.1 ------------------------------------------------------------------
d = device(3.1)
v31 = {
    "control": encode(d, CT.CONTROL, SET_DPS),
    "dpQuery": encode(d, CT.DP_QUERY),
    "heartbeat": encode(d, CT.HEART_BEAT),
}
# Device answers DP_QUERY in plaintext; pushes are "3.1" + md5[8:24] + base64(AES-ECB).
plain = device_frame_55aa(2, CT.DP_QUERY, STATUS_JSON.encode())
b64 = crypto_helper.AESCipher(key).encrypt(STATUS_JSON.encode(), use_base64=True, pad=True)
sig = md5(b"data=" + b64 + b"||lpv=3.1||" + key).hexdigest()[8:24].encode()
push = device_frame_55aa(7, CT.STATUS, b"3.1" + sig + b64)
v31["dpQueryResponse"] = {"frame": hx(plain), **decoded(d, plain)}
v31["statusPush"] = {"frame": hx(push), **decoded(d, push)}
out["v31"] = v31

# ---- 3.3 ------------------------------------------------------------------
d = device(3.3)
v33 = {
    "control": encode(d, CT.CONTROL, SET_DPS),
    "dpQuery": encode(d, CT.DP_QUERY),
    "heartbeat": encode(d, CT.HEART_BEAT),
    "updateDps": encode(d, CT.UPDATEDPS, [20, 21, 22]),
}
resp = device_frame_55aa(2, CT.DP_QUERY, ecb(key, STATUS_JSON.encode()))
push = device_frame_55aa(9, CT.STATUS, H.PROTOCOL_33_HEADER + ecb(key, STATUS_JSON.encode()))
ack = device_frame_55aa(1, CT.CONTROL, b"")
hb = device_frame_55aa(3, CT.HEART_BEAT, b"")
v33["dpQueryResponse"] = {"frame": hx(resp), **decoded(d, resp)}
v33["statusPush"] = {"frame": hx(push), **decoded(d, push)}
v33["controlAck"] = {"frame": hx(ack), "seqno": 1, "cmd": CT.CONTROL, "retcode": 0}
v33["heartbeatResponse"] = {"frame": hx(hb), "seqno": 3, "cmd": CT.HEART_BEAT, "retcode": 0}
unvalid = device_frame_55aa(2, CT.DP_QUERY, ecb(key, b"json obj data unvalid"))
v33["dataUnvalid"] = {"frame": hx(unvalid)}
d22 = device(3.3, dev_type="device22")
d22.dps_to_request = {"1": None, "20": None}
v33["device22Query"] = encode(d22, CT.DP_QUERY)
out["v33"] = v33


# ---- 3.4 / 3.5 negotiation --------------------------------------------------
def negotiation(version):
    d = device(version)
    gcm = version >= 3.5
    res = {}
    step1 = d._negotiate_session_key_generate_step_1()
    if gcm:
        _iv_queue.append(iv(1))
    res["step1"] = {"cmd": step1.cmd, "frame": hx(d._encode_message(step1))}
    payload = REMOTE_NONCE + hmac.new(key, LOCAL_NONCE, sha256).digest()
    if gcm:
        step2 = device_frame_6699(100, CT.SESS_KEY_NEG_RESP, payload, key, iv(2))
    else:
        step2 = device_frame_55aa(1, CT.SESS_KEY_NEG_RESP, ecb(key, payload), hmac_key=key)
    res["step2"] = {"frame": hx(step2)}
    rkey = unpack_message(step2, hmac_key=key)
    assert rkey.crc_good
    step3 = d._negotiate_session_key_generate_step_3(rkey)
    assert step3
    if gcm:
        _iv_queue.append(iv(3))
    res["step3"] = {"cmd": step3.cmd, "frame": hx(d._encode_message(step3))}
    d._negotiate_session_key_generate_finalize()
    session = d.local_key
    res["sessionKey"] = hx(session)
    res["control"] = encode(d, CT.CONTROL, SET_DPS, gcm_iv=iv(4) if gcm else None)
    res["dpQuery"] = encode(d, CT.DP_QUERY, gcm_iv=iv(5) if gcm else None)
    res["heartbeat"] = encode(d, CT.HEART_BEAT, gcm_iv=iv(6) if gcm else None)
    vh = d.version_header
    if gcm:
        push = device_frame_6699(101, CT.STATUS, vh + STATUS_JSON_V34.encode(), session, iv(7))
        query = device_frame_6699(102, CT.DP_QUERY_NEW, STATUS_JSON.encode(), session, iv(8))
        ack = device_frame_6699(103, CT.CONTROL_NEW, b"", session, iv(9))
    else:
        push = device_frame_55aa(2, CT.STATUS, ecb(session, vh + STATUS_JSON_V34.encode()), hmac_key=session)
        query = device_frame_55aa(3, CT.DP_QUERY_NEW, ecb(session, STATUS_JSON.encode()), hmac_key=session)
        ack = device_frame_55aa(4, CT.CONTROL_NEW, b"", hmac_key=session)
    res["statusPush"] = {"frame": hx(push), **decoded(d, push, hmac_key=session)}
    res["dpQueryResponse"] = {"frame": hx(query), **decoded(d, query, hmac_key=session)}
    msg = unpack_message(ack, hmac_key=session)
    assert msg.crc_good and msg.payload == b""
    res["controlAck"] = {"frame": hx(ack), "seqno": msg.seqno, "cmd": msg.cmd, "retcode": msg.retcode}
    return res


out["v34"] = negotiation(3.4)
out["v35"] = negotiation(3.5)

# ---- UDP discovery ----------------------------------------------------------
udpkey = udp_helper.udpkey
DISC = {"ip": "192.168.1.42", "gwId": DEV_ID, "active": 2, "ability": 0, "mode": 0, "encrypt": True,
        "productKey": "keyabcdefgh12345", "version": "3.3"}
disc_json = json.dumps(DISC).encode()
disc35 = dict(DISC, version="3.5", token=True, wf_cfg=True)
disc35_json = json.dumps(disc35).encode()
frames = {
    "plain6666": device_frame_55aa(0, CT.UDP_NEW - 1, json.dumps(dict(DISC, version="3.1", encrypt=False)).encode()),
    "ecb6667": device_frame_55aa(0, CT.UDP_NEW, ecb(udpkey, disc_json)),
    "gcm6667": device_frame_6699(0, CT.BOARDCAST_LPV34, disc35_json, udpkey, iv(10)),
}
out["discovery"] = {name: {"frame": hx(f), "json": json.loads(udp_helper.decrypt_udp(f))} for name, f in frames.items()}
bcast = json.dumps({"from": "app", "ip": "192.168.1.5"}).encode()
_iv_queue.append(iv(11))
req = pack_message(TuyaMessage(0, CT.REQ_DEVINFO, None, bcast, 0, True, H.PREFIX_6699_VALUE, True), hmac_key=udpkey)
assert not _iv_queue
out["discovery"]["reqDevInfo"] = {"json": bcast.decode(), "frame": hx(req)}

# ---- colour helpers (BulbDevice) -------------------------------------------
cases = []
for (r, g, b) in [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 128, 0), (12, 34, 56), (255, 255, 255)]:
    cases.append({"rgb": [r, g, b],
                  "hsv16": BulbDevice.rgb_to_hexvalue(r, g, b, "hsv16"),
                  "rgb8": BulbDevice.rgb_to_hexvalue(r, g, b, "rgb8")})
hsv = []
for (h, s, v) in [(0.0, 1.0, 1.0), (0.5, 0.5, 0.25), (240 / 360, 1.0, 0.01), (1.0, 0.0, 1.0)]:
    hsv.append({"hsv": [h, s, v], "hsv16": BulbDevice.hsv_to_hexvalue(h, s, v, "hsv16")})
parse = []
for hexv in ["00f003e803e8", "0078012c01f4", "ff8000001effff", "00ff00007800ff"]:
    parse.append({"hex": hexv, "hsv": list(BulbDevice.hexvalue_to_hsv(hexv)), "rgb": list(BulbDevice.hexvalue_to_rgb(hexv))})
out["colour"] = {"fromRGB": cases, "fromHSV": hsv, "parse": parse}
out["dpset"] = {k: {kk: vv for kk, vv in v.items()} for k, v in BulbDevice.DEFAULT_DPSET.items()}

with open("tuya_fixtures.json", "w") as f:
    json.dump(out, f, indent=1, sort_keys=True)
    f.write("\n")
print("wrote tuya_fixtures.json")
