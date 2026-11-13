from __future__ import annotations
"""反检测层：让 Playwright 看起来像「一个真人打开的 Chrome」。

为什么必须做（而不是只改 UA）：
  付费墙站在 Cloudflare / DataDome / HUMAN(PerimeterX) / Akamai 上做的是
  **交叉校验**——UA、sec-ch-ua、platform、时区、语言、WebGL、字体、
  navigator.webdriver、鼠标轨迹、页面停留、Referer 链，任何一处自相矛盾
  就会被判定为自动化。只改 UA 等于自报家门。

本模块做四件事：
  1) PROFILE：一整套自洽的浏览器指纹（UA <-> UA-CH <-> 视口 <-> 时区 <-> WebGL）
  2) STEALTH_JS：抹掉 headless 特征（webdriver / plugins / chrome 对象 / WebGL …）
  3) validate()：启动前自检头信息有没有互相打脸（有就直接拒绝发请求）
  4) detect_block()：识别 Cloudflare/DataDome/HUMAN/Akamai 的拦截页并分类

另有 bot 模式（Googlebot）：SEO cloak 的老办法，但必须配「极简且一致」的
头集合——爬虫不发 sec-ch-ua / sec-fetch-*，多发一个头就是破绽。
"""
import asyncio
import os
import random
import re
from urllib.parse import urlparse

# ---------------------------------------------------------------- 指纹档案

CHROME_MAJOR = "150"

PROFILES = {
    # Windows 11 + Chrome 桌面版：命中率最高、与绝大多数住宅代理自洽
    "win_desktop": {
        "ua": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
               "(KHTML, like Gecko) Chrome/%s.0.0.0 Safari/537.36" % CHROME_MAJOR),
        "platform_token": "Windows",
        "platform": "Win32",
        "viewport": {"width": 1512, "height": 945},
        "screen": {"width": 1920, "height": 1080},
        "locale": "en-US",
        "timezone": "America/New_York",
        "languages": ["en-US", "en"],
        "hardware_concurrency": 8,
        "device_memory": 8,
        "webgl_vendor": "Google Inc. (NVIDIA)",
        "webgl_renderer": ("ANGLE (NVIDIA, NVIDIA GeForce GTX 1660 Ti Direct3D11 "
                           "vs_5_0 ps_5_0, D3D11)"),
        "color_depth": 24,
    },
    # macOS：财经编辑/交易员的高频组合，Bloomberg 读者画像里非常多
    "mac_desktop": {
        "ua": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
               "(KHTML, like Gecko) Chrome/%s.0.0.0 Safari/537.36" % CHROME_MAJOR),
        "platform_token": "macOS",
        "platform": "MacIntel",
        "viewport": {"width": 1440, "height": 900},
        "screen": {"width": 1680, "height": 1050},
        "locale": "en-US",
        "timezone": "America/New_York",
        "languages": ["en-US", "en"],
        "hardware_concurrency": 10,
        "device_memory": 8,
        "webgl_vendor": "Google Inc. (Apple)",
        "webgl_renderer": "ANGLE (Apple, Apple M1 Pro, OpenGL 4.1)",
        "color_depth": 24,
    },
    # Linux 桌面：只在用数据中心 IP 时选它（住宅 IP + Linux 反而不自然）
    "linux_desktop": {
        "ua": ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
               "(KHTML, like Gecko) Chrome/%s.0.0.0 Safari/537.36" % CHROME_MAJOR),
        "platform_token": "Linux",
        "platform": "Linux x86_64",
        "viewport": {"width": 1366, "height": 768},
        "screen": {"width": 1920, "height": 1080},
        "locale": "en-US",
        "timezone": "UTC",
        "languages": ["en-US", "en"],
        "hardware_concurrency": 4,
        "device_memory": 8,
        "webgl_vendor": "Google Inc. (Intel)",
        "webgl_renderer": ("ANGLE (Intel, Mesa Intel(R) UHD Graphics 630 (CFL GT2), "
                           "OpenGL 4.6)"),
        "color_depth": 24,
    },
}

BOT_UA = {
    "googlebot": ("Mozilla/5.0 (compatible; Googlebot/2.1; "
                  "+http://www.google.com/bot.html)"),
    "googlebot_news": ("Mozilla/5.0 (compatible; Googlebot-News/2.1; "
                       "+http://www.google.com/bot.html)"),
    "bingbot": ("Mozilla/5.0 (compatible; bingbot/2.0; "
                "+http://www.bing.com/bingbot.htm)"),
}

# ---------------------------------------------------------------- 头信息

def _ua_ch_brands(major: str) -> str:
    return ('"Chromium";v="%s", "Google Chrome";v="%s", "Not?A_Brand";v="24"'
            % (major, major))


def browser_headers(profile: dict, referer: str | None = None,
                    sec_fetch_site: str | None = None) -> dict:
    """构造与 profile 完全自洽的请求头。"""
    major = CHROME_MAJOR
    h = {
        "Accept": ("text/html,application/xhtml+xml,application/xml;q=0.9,"
                   "image/avif,image/webp,image/apng,*/*;q=0.8"),
        "Accept-Language": "en-US,en;q=0.9",
        "sec-ch-ua": _ua_ch_brands(major),
        "sec-ch-ua-mobile": "?0",
        "sec-ch-ua-platform": '"%s"' % profile["platform_token"],
        "Upgrade-Insecure-Requests": "1",
        "sec-fetch-dest": "document",
        "sec-fetch-mode": "navigate",
        "sec-fetch-site": sec_fetch_site or ("cross-site" if referer else "none"),
        "sec-fetch-user": "?1",
    }
    if referer:
        h["Referer"] = referer
    return h


def bot_headers(kind: str = "googlebot", referer: str | None = None) -> dict:
    """爬虫头：极简、无 UA-CH、无 Sec-Fetch。多一个头都是破绽。"""
    h = {
        "User-Agent": BOT_UA[kind],
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
    }
    if referer:
        h["Referer"] = referer
    return h


CONTRADICTIONS = [
    (re.compile(r"HeadlessChrome", re.I), "UA 里带 HeadlessChrome"),
    (re.compile(r"Electron|PhantomJS|SlimerJS|Phantom", re.I), "UA 是自动化工具"),
]


def validate(ua: str, headers: dict) -> list[str]:
    """头信息自检：返回矛盾点列表，非空就别发请求。"""
    bad: list[str] = []
    hu = {k.lower(): v for k, v in headers.items()}

    for pat, msg in CONTRADICTIONS:
        if pat.search(ua):
            bad.append(msg)

    is_bot = bool(re.search(r"bot|externalhit|spider|crawl", ua, re.I))
    is_chrome = "Chrome/" in ua and "Chromium" not in ua.split("Chrome/")[0]
    mobile = "Mobile" in ua

    if is_bot:
        for h in ("sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
                  "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest"):
            if h in hu:
                bad.append("爬虫 UA 却带了浏览器专属头 %s" % h)
    else:
        if "sec-ch-ua" not in hu and is_chrome:
            bad.append("Chrome UA 缺 sec-ch-ua（高级指纹校验会直接判定异常）")
        if "sec-ch-ua-platform" in hu:
            plat = hu["sec-ch-ua-platform"].strip('"')
            if "Windows" in ua and plat != "Windows":
                bad.append("UA=Windows 但 sec-ch-ua-platform=%s" % plat)
            if "Macintosh" in ua and plat not in ("macOS", "mac"):
                bad.append("UA=macOS 但 sec-ch-ua-platform=%s" % plat)
            if "Linux" in ua and plat != "Linux":
                bad.append("UA=Linux 但 sec-ch-ua-platform=%s" % plat)
        if "sec-ch-ua-mobile" in hu:
            want = "?1" if mobile else "?0"
            if hu["sec-ch-ua-mobile"] != want:
                bad.append("移动标记不一致：UA mobile=%s / header=%s"
                           % (mobile, hu["sec-ch-ua-mobile"]))
        if not hu.get("accept-language") and not is_bot:
            bad.append("缺 Accept-Language")
    if hu.get("referer") and hu.get("sec-fetch-site") == "none":
        bad.append("有 Referer 却声明 sec-fetch-site=none")
    return bad


# ---------------------------------------------------------------- 隐藏 headless

STEALTH_JS = r"""
(() => {
  const noop = () => {};
  const patch = (obj, prop, getter, setter) => {
    try {
      Object.defineProperty(obj, prop, {
        get: getter, set: setter || noop, configurable: true, enumerable: true
      });
    } catch (e) {}
  };
  const CFG = __CFG__;

  // 1) navigator.webdriver -> undefined（最大特征）
  try { delete Object.getPrototypeOf(navigator).webdriver; } catch (e) {}
  patch(navigator, 'webdriver', () => undefined);

  // 2) 语言 / 平台 / 内存 / 核心数，与 profile 对齐
  patch(navigator, 'languages', () => CFG.languages);
  patch(navigator, 'language', () => CFG.languages[0]);
  patch(navigator, 'platform', () => CFG.platform);
  patch(navigator, 'hardwareConcurrency', () => CFG.hardware_concurrency);
  patch(navigator, 'deviceMemory', () => CFG.device_memory);
  patch(navigator, 'vendor', () => 'Google Inc.');
  patch(navigator, 'maxTouchPoints', () => 0);

  // 3) plugins / mimeTypes（headless 是空数组，真机有 PDF 查看器）
  const pluginList = [
    {name: 'PDF Viewer', filename: 'internal-pdf-viewer', desc: 'Portable Document Format'},
    {name: 'Chrome PDF Viewer', filename: 'internal-pdf-viewer', desc: 'Portable Document Format'},
    {name: 'Chromium PDF Viewer', filename: 'internal-pdf-viewer', desc: 'Portable Document Format'},
    {name: 'Microsoft Edge PDF Viewer', filename: 'internal-pdf-viewer', desc: 'Portable Document Format'},
    {name: 'WebKit built-in PDF', filename: 'internal-pdf-viewer', desc: 'Portable Document Format'}
  ];
  const fakePlugins = pluginList.map(p => {
    const o = Object.create(Plugin.prototype);
    Object.defineProperties(o, {
      name: {value: p.name}, filename: {value: p.filename},
      description: {value: p.desc}, length: {value: 1}
    });
    return o;
  });
  patch(navigator, 'plugins', () => {
    const arr = fakePlugins.slice();
    arr.item = i => arr[i] || null;
    arr.namedItem = n => arr.find(p => p.name === n) || null;
    arr.refresh = noop;
    return arr;
  });
  patch(navigator, 'mimeTypes', () => {
    const arr = [{type: 'application/pdf', suffixes: 'pdf', description: 'Portable Document Format'}];
    arr.item = i => arr[i] || null;
    arr.namedItem = n => arr.find(m => m.type === n) || null;
    return arr;
  });

  // 4) window.chrome（headless 里缺失，真 Chrome 必有）
  if (!window.chrome) { window.chrome = {}; }
  if (!window.chrome.runtime) {
    window.chrome.runtime = {
      connect: noop, sendMessage: noop, id: undefined,
      OnInstalledReason: {}, OnRestartRequiredReason: {}, PlatformArch: {},
      PlatformOs: {}, RequestUpdateCheckStatus: {}
    };
  }
  if (!window.chrome.app) {
    window.chrome.app = {
      isInstalled: false, InstallState: {DISABLED: 'disabled'},
      RunningState: {RUNNING: 'running'}, getDetails: noop, getIsInstalled: noop
    };
  }

  // 5) WebGL 厂商/渲染器（与 profile 一致，避免 SwiftShader 露馅）
  const patchGL = (proto) => {
    if (!proto) return;
    const orig = proto.getParameter;
    proto.getParameter = function (p) {
      if (p === 37445) return CFG.webgl_vendor;      // UNMASKED_VENDOR_WEBGL
      if (p === 37446) return CFG.webgl_renderer;    // UNMASKED_RENDERER_WEBGL
      return orig.apply(this, arguments);
    };
  };
  patchGL(window.WebGLRenderingContext && WebGLRenderingContext.prototype);
  patchGL(window.WebGL2RenderingContext && WebGL2RenderingContext.prototype);

  // 6) Notification.permission / permissions.query 一致化
  patch(Notification, 'permission', () => 'default');

  // 7) navigator.connection（数据中心机器常见缺失）
  if (!navigator.connection) {
    patch(navigator, 'connection', () => ({
      downlink: 10, effectiveType: '4g', rtt: 50, saveData: false,
      onchange: null, addEventListener: noop, removeEventListener: noop
    }));
  }

  // 8) 屏蔽 Function.prototype.toString 对 native 的识破
  const nativeToString = Function.prototype.toString;
  const marked = new WeakSet();
  const fakeNative = function () { return 'function () { [native code] }'; };
  marked.add(fakeNative);
  Function.prototype.toString = function () {
    if (marked.has(this)) return 'function () { [native code] }';
    return nativeToString.call(this);
  };

  // 9) 去掉 Playwright 注入的痕迹
  try { delete window.__playwright; } catch (e) {}
  try { delete window.__pw_manual; } catch (e) {}
  try { delete window.__PW_inspect; } catch (e) {}

  // 10) 时区/屏幕尺寸与 profile 对齐由 context 负责；这里补 screen 一致性
  patch(screen, 'colorDepth', () => CFG.color_depth);
  patch(screen, 'pixelDepth', () => CFG.color_depth);
})();
"""


def stealth_script(profile: dict) -> str:
    import json
    cfg = {
        "languages": profile["languages"],
        "platform": profile["platform"],
        "hardware_concurrency": profile["hardware_concurrency"],
        "device_memory": profile["device_memory"],
        "webgl_vendor": profile["webgl_vendor"],
        "webgl_renderer": profile["webgl_renderer"],
        "color_depth": profile["color_depth"],
    }
    return STEALTH_JS.replace("__CFG__", json.dumps(cfg))


# ---------------------------------------------------------------- 人味

def _bezier(p0, p1, steps=18):
    """两点之间给一条带弧度的手感轨迹（真人鼠标不是直线）"""
    cx = (p0[0] + p1[0]) / 2 + random.randint(-60, 60)
    cy = (p0[1] + p1[1]) / 2 + random.randint(-40, 40)
    out = []
    for i in range(1, steps + 1):
        t = i / steps
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * cx + t ** 2 * p1[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * cy + t ** 2 * p1[1]
        out.append((x, y))
    return out


async def human_read(page, intensity: float = 1.0) -> None:
    """模拟阅读：随机鼠标轨迹 + 分段滚动 + 停顿，时长与文章长度挂钩。"""
    try:
        vp = page.viewport_size or {"width": 1440, "height": 900}
        x, y = random.randint(200, vp["width"] - 200), random.randint(120, 400)
        await page.mouse.move(x, y, steps=random.randint(4, 10))
        for _ in range(random.randint(2, 4)):
            tx = random.randint(120, vp["width"] - 120)
            ty = random.randint(80, vp["height"] - 80)
            for px, py in _bezier((x, y), (tx, ty)):
                await page.mouse.move(px, py)
                await asyncio.sleep(random.uniform(0.004, 0.016))
            x, y = tx, ty
            await asyncio.sleep(random.uniform(0.15, 0.5))

        paragraphs = random.randint(3, 6)
        for _ in range(paragraphs):
            await page.mouse.wheel(0, random.randint(320, 720))
            await asyncio.sleep(random.uniform(0.45, 1.35) * intensity)
        if random.random() < 0.35:
            await page.mouse.wheel(0, -random.randint(120, 320))
            await asyncio.sleep(random.uniform(0.3, 0.8))
    except Exception:
        pass


# ---------------------------------------------------------------- 拦截识别

BLOCK_SIGNATURES = [
    ("cloudflare", [r"Just a moment", r"cf-browser-verification", r"cf_chl_opt",
                    r"Attention Required! \| Cloudflare", r"__cf_chl"]),
    ("datadome", [r"datadome", r"captcha-delivery\.com", r"geo\.captcha-delivery"]),
    ("human_px", [r"_px", r"px-captcha", r"Access to this page has been denied",
                  r"perimeterx", r"human-challenge"]),
    ("akamai", [r"Reference #\d+\.[0-9a-f]+", r"Access Denied.*akamai",
                r"akamai.*bot manager"]),
    ("arc_challenge", [r"Please enable JS and disable any ad blocker"]),
    ("paywall", [r"subscribe to continue", r"already a subscriber",
                 r"unlimited access", r"create a free account to continue",
                 r"this article is for subscribers", r"sign in to continue"]),
    ("rate_limit", [r"too many requests", r"rate limit exceeded"]),
]


def detect_block(status: int, html: str) -> str | None:
    """返回拦截类型；None 表示页面正常。"""
    if status in (429, 503):
        return "rate_limit"
    head = (html or "")[:20000]
    for kind, pats in BLOCK_SIGNATURES:
        if kind == "paywall":
            continue
        for p in pats:
            if re.search(p, head, re.I):
                return kind
    if status in (401, 403):
        return "forbidden"
    return None


def detect_paywall_text(text: str) -> bool:
    low = (text or "").lower()
    for kind, pats in BLOCK_SIGNATURES:
        if kind != "paywall":
            continue
        for p in pats:
            if re.search(p, low, re.I):
                return True
    return False


# ---------------------------------------------------------------- 环境

def proxy_from_env() -> dict | None:
    raw = os.getenv("PW_PROXY") or ""
    if not raw:
        return None
    u = urlparse(raw if "://" in raw else "http://" + raw)
    if not u.hostname:
        return None
    cfg = {"server": "%s://%s:%s" % (u.scheme or "http", u.hostname, u.port or 80)}
    if u.username:
        cfg["username"] = u.username
    if u.password:
        cfg["password"] = u.password
    return cfg


def pick_profile(name: str | None = None) -> dict:
    name = name or os.getenv("PW_PROFILE") or "win_desktop"
    return PROFILES.get(name, PROFILES["win_desktop"])
