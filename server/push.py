from __future__ import annotations
"""APNs 推送（HTTP/2 + ES256 .p8）。

关键实现坑（别踩）
1. cryptography 的 ECDSA 签名默认是 DER 编码，APNs 要的是固定的 64 字节 r||s，
   必须 decode_dss_signature() 之后再拼，否则永远 403 InvalidProviderToken。
2. jwt 有效期：Apple 要求 20~60 分钟刷新一次，这里 40 分钟。
3. 自签 App 的证书决定环境：development 描述文件 -> sandbox 主机，
   所以每台设备单独存 env，服务器按 env 选主机。
4. 410 Unregistered / BadDeviceToken -> 直接删设备，避免无限重试。
"""
import json
import logging
import time
import base64

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

import config

log = logging.getLogger("push")

_key = None
_jwt = ""
_jwt_exp = 0.0


def _b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _load_key():
    global _key
    if _key is not None:
        return _key
    if not config.APNS_KEY_ID or not config.APNS_TEAM_ID:
        raise RuntimeError("APNS_KEY_ID / APNS_TEAM_ID 未配置")
    with open(config.APNS_P8, "rb") as f:
        _key = serialization.load_pem_private_key(f.read(), password=None)
    return _key


def token() -> str:
    global _jwt, _jwt_exp
    if _jwt and time.time() < _jwt_exp:
        return _jwt
    key = _load_key()
    hdr = _b64u(json.dumps({"alg": "ES256", "kid": config.APNS_KEY_ID},
                           separators=(",", ":")).encode())
    clm = _b64u(json.dumps({"iss": config.APNS_TEAM_ID, "iat": int(time.time())},
                           separators=(",", ":")).encode())
    signing_input = (hdr + "." + clm).encode()
    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = utils.decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")
    _jwt = hdr + "." + clm + "." + _b64u(raw)
    _jwt_exp = time.time() + 40 * 60
    return _jwt


def host_for(env: str) -> str:
    return config.APNS_HOST_SANDBOX if env == "sandbox" else config.APNS_HOST_PROD


async def send(device_token: str, env: str, *, article_id: str, title: str,
               body: str, site: str, url: str,
               sound: str = "default") -> tuple[int, str]:
    """返回 (status_code, reason)。2xx 表示成功。"""
    payload = {
        "aps": {
            "alert": {"title": title[:120], "body": body[:180]},
            "sound": sound,
            "mutable-content": 1,
            "interruption-level": "time-sensitive",
            "thread-id": "bpc." + site,
            "relevance-score": 0.9,
        },
        "aid": article_id,
        "src": site,
        "u": url,
    }
    headers = {
        "authorization": "bearer " + token(),
        "apns-topic": config.APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": str(int(time.time()) + 6 * 3600),
        "apns-collapse-id": ("bpc-" + site + "-" + article_id)[:64],
        "content-type": "application/json",
    }
    try:
        async with httpx.AsyncClient(http2=True, timeout=20) as client:
            r = await client.post(host_for(env) + "/3/device/" + device_token,
                                  content=json.dumps(payload, ensure_ascii=False).encode(),
                                  headers=headers)
    except Exception as e:
        log.warning("apns exception %s: %s", device_token[:12], e)
        return 0, str(e)[:200]

    if r.status_code == 200:
        return 200, "ok"
    reason = ""
    try:
        reason = r.json().get("reason", "")
    except Exception:
        reason = r.text[:120]
    log.warning("apns %s -> %s %s", device_token[:12], r.status_code, reason)
    return r.status_code, reason


async def send_to_device(store, device: dict, **kw) -> bool:
    code, reason = await send(device["token"], device.get("env", "sandbox"), **kw)
    if code == 200:
        return True
    if code in (400, 410) and reason in ("BadDeviceToken", "Unregistered",
                                         "DeviceTokenNotForTopic"):
        log.info("remove dead device %s (%s)", device["token"][:12], reason)
        await store.delete_device(device["token"])
    return False


async def send_summary(store, device: dict, items: list[dict]) -> bool:
    """静默时段/降噪：把多条合并成一条摘要推送。"""
    if not items:
        return False
    head = items[0]["title_zh"]
    more = len(items) - 1
    body = head if more <= 0 else (head + " 等 %d 条" % len(items))
    return await send_to_device(
        store, device,
        article_id=items[0]["id"], title="财经速递 · %d 条新消息" % len(items),
        body=body, site=items[0]["site"], url=items[0]["url"])
