"""Generates aidot_fixtures.json from the upstream python-aidot library (MIT, AiDot-Development-Team).

Run from Packages/Providers/AiDotKit/Tests/AiDotCodecTests/Fixtures:

    docker run --rm -v "<abs path to this folder>:/w" -w /w python:3.12 \
        bash -c "pip install -q python-aidot==0.3.59 && python gen_fixtures.py"

Only pure functions/dataclasses of the library are used (no network, no asyncio).
Fixed inputs replace the clock-derived fields (seq, tst, timestamp) so outputs are deterministic.
"""

import ctypes
import hashlib
import json

from aidot.aes_utils import aes_encrypt
from aidot.const import SUPPORTED_COUNTRYS, ServerErrorCode
from aidot.device_client import DeviceClient, DeviceStatusData
from aidot.login_const import API_URL_TEMPLATE, APP_ID, PUBLIC_KEY_PEM
from aidot.models.device_client_model import (
    DeviceActionRequest,
    DeviceAttr,
    LoginPayload,
    LoginRequest,
    PingRequest,
)
from aidot.models.discover_model import DiscoverRequest, DiscoverRequestPayload

USER_ID = "1840000000000000001"
DEV_ID = "8a040e2233a243e7a07eb6a1b7a210a7"
DEV_PW = "devpass-0001"
TST = 1761475200123


def client(aes_key: str, model: str = "LK.light.A001493") -> DeviceClient:
    # No "properties" key -> the constructor does not schedule an asyncio connect.
    device = {"id": DEV_ID, "aesKey": [aes_key], "password": DEV_PW, "modelId": model, "name": "Lamp"}
    return DeviceClient(device, {"id": USER_ID}, None)


out = {}

# ---- constants -----------------------------------------------------------
out["appId"] = APP_ID
out["apiUrlUS"] = API_URL_TEMPLATE.format(region="us")
out["publicKeyPem"] = PUBLIC_KEY_PEM.decode()
out["errorCodes"] = {e.name: int(e) for e in ServerErrorCode}
out["countries"] = [{"id": c["id"], "name": c["name"], "region": c["region"].lower()} for c in SUPPORTED_COUNTRYS]
out["terminalIdFallbackMd5"] = hashlib.md5("gvz3gjae10l4zii00t7y0".encode()).hexdigest()

# ---- discovery (discover.py) --------------------------------------------
disc_key = bytearray(b"T54uednca587".ljust(32, b"\x00"))
req = DiscoverRequest(
    seq="475200124",
    srcAddr=f"0.{USER_ID}",
    tst=TST,
    payload=DiscoverRequestPayload(timestamp=str(TST)),
)
disc_json = json.dumps(req.to_dict())
out["discoveryRequest"] = {
    "userId": USER_ID,
    "tst": TST,
    "seq": "475200124",
    "json": disc_json,
    "cipherHex": aes_encrypt(disc_json.encode(), disc_key).hex(),
}
disc_resp = {
    "protocolVer": "2.0.0",
    "service": "device",
    "method": "devDiscoveryRsp",
    "seq": "475200124",
    "srcAddr": DEV_ID,
    "ack": {"code": 200, "tst": "1761475200200"},
    "payload": {
        "ip": "192.168.1.42",
        "mac": "a4:c1:38:00:00:01",
        "devId": DEV_ID,
        "productModel": "LK.light.A001493",
        "bindFlag": 1,
        "conMode": 0,
        "lanMode": 1,
        "wifiMode": 1,
        "wifiBand": 0,
        "version": 2,
        "extends": {"srvHost": "prod-us-mqtt.arnoo.com"},
    },
}
out["discoveryResponse"] = {"json": json.dumps(disc_resp), "cipherHex": aes_encrypt(json.dumps(disc_resp).encode(), disc_key).hex()}

# ---- TCP frames (device_client.py) ----------------------------------------
dc = client("0123456789abcdef")
login = LoginRequest(
    seq="475200123",
    srcAddr=USER_ID,
    deviceId=DEV_ID,
    payload=LoginPayload(userId=USER_ID, password=DEV_PW, timestamp="2026-10-26 12:34:56.789012"),
)
login_json = json.dumps(login.to_dict())
out["loginFrame"] = {
    "aesKey": "0123456789abcdef",
    "keyHex": bytes(dc.aes_key).hex(),
    "json": login_json,
    "frameHex": dc.get_send_packet(login_json.encode(), 1).hex(),
}


def rgbw(r, g, b, w):
    return ctypes.c_int32((r << 24) | (g << 16) | (b << 8) | w).value


def action(method, attr, simple_version, asc=5, seq="ha9300002"):
    a = DeviceActionRequest.from_params(
        method=method,
        user_id=USER_ID,
        device_id=DEV_ID,
        password=DEV_PW,
        ascNumber=asc,
        attr=attr,
        seq=seq,
        simpleVersion=simple_version,
    )
    a.tst = TST
    j = json.dumps(a.to_dict())
    return {"json": j, "frameHex": dc.get_send_packet(j.encode(), 1).hex()}


set_attr = {"OnOff": 1, "Dimming": 40, "RGBW": rgbw(255, 128, 0, 10)}
out["setDevAttrFull"] = dict(action("setDevAttrReq", set_attr, "1"), attr=set_attr, simpleVersion="1")
out["setDevAttrSimple"] = dict(action("setDevAttrReq", {"CCT": 4000}, None, asc=9, seq="ha9300003"), attr={"CCT": 4000})
out["getDevAttrEmpty"] = action("getDevAttrReq", [], None, asc=2, seq="ha9300004")
out["getDevAttrD0006"] = action("getDevAttrReq", ["OnOff", "Dimming", "RGBW", "CCT"], None, asc=2, seq="ha9300005")
ping = json.dumps(PingRequest().to_dict())
out["pingFrame"] = {"json": ping, "frameHex": dc.get_send_packet(ping.encode(), 2).hex()}

# Status push as a device would send it (encrypted with the device key).
push = {
    "service": "device",
    "method": "devAttrNotify",
    "seq": "123",
    "srcAddr": DEV_ID,
    "deviceId": DEV_ID,
    "tst": TST,
    "payload": {
        "devId": DEV_ID,
        "ascNumber": 7,
        "attr": {"OnOff": 1, "Dimming": 55, "RGBW": rgbw(0, 0, 255, 0), "CCT": 4000, "effectUniqueID": "fx-1"},
    },
}
out["statusPush"] = {"json": json.dumps(push), "frameHex": dc.get_send_packet(json.dumps(push).encode(), 1).hex()}

# Key padding variants (bytearray(16); key[:len] = bytes).
out["keys"] = [{"aesKey": k, "keyHex": bytes(client(k).aes_key).hex()} for k in ["abc123", "0123456789abcdef", "0123456789abcdef01234567"]]
short = client("abc123")
out["shortKeyPingFrameHex"] = short.get_send_packet(ping.encode(), 2).hex()

# ---- RGBW packing / unpacking -------------------------------------------
cases = [(255, 0, 0, 0), (0, 0, 255, 0), (128, 64, 32, 16), (127, 255, 255, 255), (255, 255, 255, 255), (0, 0, 0, 0)]
packs = []
for c in cases:
    v = rgbw(*c)
    s = DeviceStatusData()
    s.update(DeviceAttr(RGBW=v))
    packs.append({"rgbw": list(c), "packed": v, "unpacked": list(s.rgbw)})
out["rgbw"] = packs

print(json.dumps(out, indent=1, sort_keys=True), file=open("aidot_fixtures.json", "w"))
print("wrote aidot_fixtures.json")
