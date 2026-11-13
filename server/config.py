from __future__ import annotations
"""全局配置：所有密钥走环境变量，仓库里不落任何凭据。"""
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = Path(os.getenv("DATA_DIR", BASE_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)

# ---- 服务端鉴权（App -> 服务器 的共享密钥）----
API_TOKEN = os.getenv("API_TOKEN", "CHANGE_ME_please")
if API_TOKEN == "CHANGE_ME_please":
    print("[warn] API_TOKEN 未设置，使用占位值；上线前务必改掉")

# ---- APNs ----
APNS_KEY_ID = os.getenv("APNS_KEY_ID", "")
APNS_TEAM_ID = os.getenv("APNS_TEAM_ID", "")
APNS_BUNDLE_ID = os.getenv("APNS_BUNDLE_ID", "com.yourname.bpcnews")
APNS_P8 = os.getenv("APNS_P8", str(BASE_DIR / "AuthKey.p8"))
APNS_HOST_PROD = "https://api.push.apple.com"
APNS_HOST_SANDBOX = "https://api.sandbox.push.apple.com"

# ---- LLM 翻译 ----
LLM_URL = os.getenv("LLM_URL", "https://api.deepseek.com/chat/completions")
LLM_KEY = os.getenv("LLM_KEY", "")
LLM_MODEL = os.getenv("LLM_MODEL", "deepseek-chat")

# ---- 采集 / 抓取 ----
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "45"))
FETCH_CONCURRENCY = int(os.getenv("FETCH_CONCURRENCY", "2"))
MAX_PUSH_AGE_SECONDS = int(os.getenv("MAX_PUSH_AGE_SECONDS", "10800"))  # 3h，防首次部署刷屏
ARTICLE_TTL_DAYS = int(os.getenv("ARTICLE_TTL_DAYS", "30"))
TZ = os.getenv("TZ", "Asia/Shanghai")

DB_PATH = str(DATA_DIR / "bpc.db")
