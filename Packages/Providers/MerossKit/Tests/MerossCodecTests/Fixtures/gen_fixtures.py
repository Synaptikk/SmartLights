#!/usr/bin/env python3
"""Generates meross_fixtures.json for MerossCodecTests.

The signing/encryption functions below are copied verbatim (modulo imports) from
krahabb/meross_lan @ bafedb4 (MIT):
  merossclient/protocol/message.py  compute_message_signature, compute_encryption_key
  merossclient/cloudapi.py          async_cloudapi_post (sign), async_cloudapi_signin (params)
  merossclient/httpclient.py        enable_encryption / async_request_raw (AES-CBC body)
and albertogeniola/MerossIot @ 4fc8193 (MIT) http_api.py (_encode_params).
Device payloads are taken from meross_lan's emulator traces (msl320, msl450).

Run: python3 gen_fixtures.py > meross_fixtures.json   (needs `cryptography`)
"""
import base64
import json
from hashlib import md5

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

SECRET = "23x17ahWarFH6w29"


def compute_message_signature(messageid, key, timestamp):
    return md5("".join((messageid, key, str(timestamp))).encode("utf-8"), usedforsecurity=False).hexdigest()


def compute_encryption_key(uuid, key, mac):
    return md5("".join((uuid[3:22], key[1:9], mac, key[10:28])).encode("utf-8"), usedforsecurity=False).hexdigest().encode("utf-8")


def cloud_sign(timestamp, nonce, params):
    return md5("".join((SECRET, str(timestamp), nonce, params)).encode("utf-8")).hexdigest()


def encrypt(request: str, key: bytes) -> str:
    cipher = Cipher(algorithms.AES(key), modes.CBC("0000000000000000".encode("utf8")))
    request_bytes = request.encode("utf-8")
    request_bytes += bytes(16 - (len(request_bytes) % 16))
    encryptor = cipher.encryptor()
    return base64.b64encode(encryptor.update(request_bytes) + encryptor.finalize()).decode("utf-8")


out = {}

# Local message signatures.
out["signatures"] = [
    {"messageId": m, "key": k, "timestamp": t, "sign": compute_message_signature(m, k, t)}
    for (m, k, t) in [
        ("5c3a4f1e9b2d8c7a6e5f4d3c2b1a0918", "0123456789abcdef0123456789abcdef", 1670762076),
        ("aabbccddeeff00112233445566778899", "", 1600000000),
        ("00000000000000000000000000000000", "meross-test-key", 0),
    ]
]

# Cloud request signing: params encoded exactly as meross_lan does.
params = {"email": "user@example.com", "password": md5("s3cret-pw".encode("utf8")).hexdigest(),
          "accountCountryCode": "eu", "encryption": 1, "agree": 0}
encoded = base64.b64encode(json.dumps(params, ensure_ascii=False).encode("utf-8")).decode("utf-8")
out["cloud"] = {
    "timestamp": 1730000000123,
    "nonce": "ABCDEFGHIJ012345",
    "params": encoded,
    "sign": cloud_sign(1730000000123, "ABCDEFGHIJ012345", encoded),
    "passwordMD5": params["password"],
}

# ECDHE body encryption.
uuid = "2106040981431251802148e1e9a1b2c3"
key = "0123456789abcdef0123456789abcdef"
mac = "48:e1:e9:a1:b2:c3"
ekey = compute_encryption_key(uuid, key, mac)
plain = '{"header":{"messageId":"x"},"payload":{"all":{}}}'
out["encryption"] = {
    "uuid": uuid,
    "key": key,
    "mac": mac,
    "derivedKey": ekey.decode(),
    "plaintext": plain,
    "ciphertext": encrypt(plain, ekey),
    "shortKeyDerived": compute_encryption_key("abc", "k", "m").decode(),
}

# Device payloads (meross_lan emulator traces; uuid/mac/ip anonymised there, filled in here).
out["msl320_all"] = {
    "header": {"messageId": "0f1e2d3c4b5a69788796a5b4c3d2e1f0", "namespace": "Appliance.System.All", "method": "GETACK",
               "payloadVersion": 1, "from": "/appliance/2106040981431251802148e1e9a1b2c3/publish",
               "timestamp": 1670762076, "timestampMs": 123, "sign": ""},
    "payload": {"all": {
        "system": {
            "hardware": {"type": "msl320cpr", "subType": "un", "version": "4.0.0", "chipType": "rtl8710cm",
                         "uuid": uuid, "macAddress": mac},
            "firmware": {"version": "4.3.5", "homekitVersion": "4.1", "compileTime": "2022/08/25-15:57:22",
                         "encrypt": 1, "wifiMac": "aa:bb:cc:dd:ee:ff", "innerIp": "192.168.1.50",
                         "server": "eu-iot.meross.com", "port": 443, "userId": 1234567},
            "time": {"timestamp": 1670762076, "timezone": "Europe/Lisbon"},
            "online": {"status": 1, "bindId": "sZuTwgzBpBN2TMQI", "who": 1}},
        "digest": {"togglex": [{"channel": 0, "onoff": 1, "lmTime": 1670761931}], "triggerx": [], "timerx": [],
                   "light": {"capacity": 6, "channel": 0, "rgb": 16711680, "temperature": 51, "luminance": 49,
                             "transform": 0}}}},
}
out["msl320_all"]["header"]["sign"] = compute_message_signature(
    out["msl320_all"]["header"]["messageId"], key, out["msl320_all"]["header"]["timestamp"])
out["msl320_ability"] = {"ability": {"Appliance.System.All": {}, "Appliance.Control.ToggleX": {},
                                     "Appliance.Control.Light": {"capacity": 15}, "Appliance.Control.Light.Effect": {}}}
out["msl450_light_getack"] = {"light": {"effect": 6, "capacity": 13, "channel": 0, "rgb": 62719, "temperature": 44,
                                        "luminance": 1, "transform": 0}}
out["msl450_togglex_getack"] = {"channel": 0, "togglex": {"channel": 0, "onoff": 1, "lmTime": 1672761899}}
out["invalid_key_reply"] = {
    "header": {"messageId": "11112222333344445555666677778888", "namespace": "Appliance.System.All", "method": "ERROR",
               "payloadVersion": 1, "from": "/appliance/2106040981431251802148e1e9a1b2c3/publish",
               "timestamp": 1670762077, "timestampMs": 1, "sign": "00"},
    "payload": {"error": {"code": 5001, "detail": "sign error"}},
}

# Cloud replies (shape from MerossIot / meross_lan cloudapi.py).
out["signin_ok"] = {"apiStatus": 0, "sysStatus": 0, "info": "Success", "timeStamp": 1730000000,
                    "data": {"userid": "1234567", "email": "user@example.com", "key": key, "token": "tok-abc",
                             "domain": "https://iotx-eu.meross.com", "mqttDomain": "mqtt-eu.meross.com"}}
out["signin_redirect"] = {"apiStatus": 1030, "info": "redirect",
                          "data": {"domain": "https://iotx-eu.meross.com", "mqttDomain": "mqtt-eu.meross.com"}}
out["signin_wrong_password"] = {"apiStatus": 1004, "info": "Wrong email or password", "data": {}}
out["devlist_ok"] = {"apiStatus": 0, "info": "Success", "data": [
    {"uuid": uuid, "onlineStatus": 1, "devName": "Desk lamp", "devIconId": "device045", "bindTime": 1650000000,
     "deviceType": "msl320cpr", "subType": "un", "channels": [{}], "region": "eu", "fmwareVersion": "4.3.5",
     "hdwareVersion": "4.0.0", "userDevIcon": "", "iconType": 1, "domain": "eu-iot.meross.com",
     "reservedDomain": "eu-iot.meross.com", "hardwareCapabilities": []},
    {"uuid": "1912345678901234567890abcdef0001", "onlineStatus": 1, "devName": "Kettle plug",
     "deviceType": "mss310", "subType": "us", "channels": [{}], "fmwareVersion": "6.1.8", "hdwareVersion": "6.0.0"},
]}

print(json.dumps(out, indent=1, sort_keys=True))
