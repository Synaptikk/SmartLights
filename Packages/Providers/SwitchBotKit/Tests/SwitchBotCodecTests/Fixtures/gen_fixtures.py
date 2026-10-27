#!/usr/bin/env python3
"""Generates switchbot_fixtures.json for SwitchBotCodecTests.

`sign` follows the "Python 3 example code" of OpenWonderLabs/SwitchBotAPI README.md @ dc9a6b0
(string_to_sign = token + t + nonce; base64(HMAC-SHA256(secret, string_to_sign))).
Replies are the README samples and the shapes in devices/lighting/*.md.

Run: python3 gen_fixtures.py > switchbot_fixtures.json
"""
import base64
import hashlib
import hmac
import json


def sign(token, secret, t, nonce):
    string_to_sign = bytes('{}{}{}'.format(token, t, nonce), 'utf-8')
    return str(base64.b64encode(hmac.new(bytes(secret, 'utf-8'), msg=string_to_sign, digestmod=hashlib.sha256).digest()), 'utf-8')


out = {
    "signatures": [
        {"token": t, "secret": s, "t": ts, "nonce": n, "sign": sign(t, s, ts, n)}
        for (t, s, ts, n) in [
            ("4f6a3c2b1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0", "0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d", 1661927531000, "5c2f6b1e-36a4-4d70-9e2c-0f3a5b7c9d11"),
            ("token", "secret", 1700000000000, ""),
        ]
    ],
    "devices": {
        "statusCode": 100,
        "body": {
            "deviceList": [
                {"deviceId": "500291B269BE", "deviceName": "Living Room Humidifier", "deviceType": "Humidifier",
                 "enableCloudService": True, "hubDeviceId": "000000000000"},
                {"deviceId": "6055F92B4F5A", "deviceName": "Bedroom bulb", "deviceType": "Color Bulb",
                 "enableCloudService": True, "hubDeviceId": "000000000000"},
                {"deviceId": "C1D2E3F4A5B6", "deviceName": "TV strip", "deviceType": "Strip Light",
                 "enableCloudService": True, "hubDeviceId": "000000000000"},
                {"deviceId": "F0E1D2C3B4A5", "deviceName": "Ceiling", "deviceType": "Ceiling Light",
                 "enableCloudService": True, "hubDeviceId": "FA7310762361"},
                {"deviceId": "AA11BB22CC33", "deviceName": "Hallway bulb", "deviceType": "Color Bulb",
                 "enableCloudService": False, "hubDeviceId": "FA7310762361"},
                {"deviceId": "FA7310762361", "deviceName": "Hub 2", "deviceType": "Hub 2", "hubDeviceId": "000000000000"},
            ],
            "infraredRemoteList": [
                {"deviceId": "02-202008110034-13", "deviceName": "Living Room TV", "remoteType": "TV", "hubDeviceId": "FA7310762361"}
            ],
        },
        "message": "success",
    },
    "status_color_bulb": {"statusCode": 100, "body": {
        "deviceId": "6055F92B4F5A", "deviceType": "Color Bulb", "hubDeviceId": "000000000000", "power": "on",
        "brightness": 80, "version": "V3.1-6.3", "color": "255:0:128", "colorTemperature": 4000}, "message": "success"},
    "status_color_bulb_white": {"statusCode": 100, "body": {
        "deviceId": "6055F92B4F5A", "deviceType": "Color Bulb", "power": "off", "brightness": 10,
        "color": "255:255:255", "colorTemperature": 2700}, "message": "success"},
    "status_ceiling": {"statusCode": 100, "body": {
        "deviceId": "F0E1D2C3B4A5", "deviceType": "Ceiling Light", "hubDeviceId": "FA7310762361", "power": "ON",
        "brightness": "35", "colorTemperature": 6500}, "message": "success"},
    "command_ok": {"statusCode": 100, "body": {}, "message": "success"},
    "command_offline": {"statusCode": 161, "body": {}, "message": "device offline"},
    "command_unsupported": {"statusCode": 160, "message": "command is not supported"},
    "unauthorized": {"message": "Unauthorized"},
}

print(json.dumps(out, indent=1, sort_keys=True))
