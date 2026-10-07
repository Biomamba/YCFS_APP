"""
MinerU PDF-to-Markdown Converter (Online API Batch Mode)

Usage:
    python mineru_convert.py <pdf_path> <output_dir> [--model-version vlm] [--language en]

API Key:
    从 .agents/skills/paper-reading/api_key/key.txt 读取 Token
    绝不在代码中硬编码、日志中打印或以任何方式泄露 API Key
"""

import argparse
import json
import os
import shutil
import sys
import time
import zipfile
from pathlib import Path

# Windows 终端兼容：强制 UTF-8 输出，防止 GBK 编码崩溃
os.environ.setdefault("PYTHONIOENCODING", "utf-8")
if sys.stdout.encoding and sys.stdout.encoding.lower() not in ("utf-8", "utf8"):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# ---------- 常量 ----------
MINERU_API_BASE = "https://mineru.net/api/v4"
POLL_INTERVAL_SEC = 5
MAX_POLL_ATTEMPTS = 120  # 最多等 10 分钟

# API Key 文件的相对路径（相对于本脚本所在位置）
_SCRIPT_DIR = Path(__file__).resolve().parent
_KEY_FILE = _SCRIPT_DIR.parent / "api_key" / "key.txt"

# 支持的模型版本
SUPPORTED_MODELS = ("pipeline", "vlm", "MinerU-HTML")
DEFAULT_MODEL = "vlm"
DEFAULT_LANGUAGE = "en"


def _load_api_token() -> str:
    if not _KEY_FILE.exists():
        print(f"[ERROR] API Key file not found: {_KEY_FILE}", file=sys.stderr)
        sys.exit(1)
    token = _KEY_FILE.read_text(encoding="utf-8").strip()
    if not token:
        print("[ERROR] API Key file is empty", file=sys.stderr)
        sys.exit(1)
    # 仅显示前 4 位用于身份确认，绝不泄露完整 Token
    print(f"[AUTH] API Token loaded ({token[:4]}****)")
    return token


def convert(pdf_path: str, output_dir: str, model_version: str = DEFAULT_MODEL, language: str = DEFAULT_LANGUAGE) -> bool:
    try:
        import requests
    except ImportError:
        print("[ERROR] requires 'requests'. Run: pip install requests", file=sys.stderr)
        return False

    pdf_path = os.path.abspath(pdf_path)
    if not os.path.exists(pdf_path):
        print(f"[ERROR] PDF not found: {pdf_path}", file=sys.stderr)
        return False

    if model_version not in SUPPORTED_MODELS:
        print(f"[ERROR] Unsupported model_version '{model_version}'. Choose from: {SUPPORTED_MODELS}", file=sys.stderr)
        return False

    token = _load_api_token()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

    os.makedirs(output_dir, exist_ok=True)
    pdf_filename = os.path.basename(pdf_path)
    file_size_mb = os.path.getsize(pdf_path) / (1024 * 1024)

    print(f"[CONVERT] PDF: {pdf_path} ({file_size_mb:.1f} MB)")
    print(f"[CONVERT] Output: {output_dir}")
    print(f"[CONVERT] Model: {model_version} | Language: {language}")

    # ========== Step 1: 申请上传 URL ==========
    print("[STEP 1/4] Requesting upload URL...")
    try:
        url = f"{MINERU_API_BASE}/file-urls/batch"
        payload = {
            "files": [{"name": pdf_filename}],
            "model_version": model_version,
            "language": language,
        }
        resp = requests.post(url, headers=headers, json=payload, timeout=30)
        if resp.status_code != 200:
            print(f"[ERROR] Upload URL request failed (HTTP {resp.status_code})", file=sys.stderr)
            print(f"[ERROR] Response: {resp.text[:500]}", file=sys.stderr)
            return False

        data = resp.json()
        if data.get("code") != 0:
            print(f"[ERROR] API error: {data.get('msg')}", file=sys.stderr)
            return False

        batch_id = data["data"]["batch_id"]
        upload_url = data["data"]["file_urls"][0]
        print(f"[STEP 1/4] OK. batch_id: {batch_id}")

    except requests.exceptions.RequestException as e:
        print(f"[ERROR] Network error: {e}", file=sys.stderr)
        return False

    # ========== Step 2: 上传文件至 OSS ==========
    print("[STEP 2/4] Uploading PDF to MinerU server...")
    try:
        with open(pdf_path, "rb") as f:
            # OSS presigned URL 上传用 PUT，直接发二进制，不加 Authorization
            resp_upload = requests.put(upload_url, data=f, timeout=120)

        if resp_upload.status_code != 200:
            print(f"[ERROR] Upload failed (HTTP {resp_upload.status_code})", file=sys.stderr)
            print(f"[ERROR] Response: {resp_upload.text[:500]}", file=sys.stderr)
            return False

        print("[STEP 2/4] Upload OK!")

    except requests.exceptions.RequestException as e:
        print(f"[ERROR] Upload exception: {e}", file=sys.stderr)
        return False

    # ========== Step 3: 轮询解析结果 ==========
    print("[STEP 3/4] Waiting for MinerU to parse (may take a few minutes)...")

    status_url = f"{MINERU_API_BASE}/extract-results/batch/{batch_id}"
    download_url = None

    for attempt in range(MAX_POLL_ATTEMPTS):
        try:
            resp_status = requests.get(status_url, headers=headers, timeout=30)
            status_data = resp_status.json()

            if status_data.get("code") != 0:
                print(f"[ERROR] Status query failed: {status_data.get('msg')}", file=sys.stderr)
                return False

            results = status_data.get("data", {}).get("extract_result", [])
            if not results:
                elapsed = (attempt + 1) * POLL_INTERVAL_SEC
                print(f"  [WAIT] No result yet... ({elapsed}s)")
                time.sleep(POLL_INTERVAL_SEC)
                continue

            file_result = results[0]
            state = file_result.get("state", "unknown")

            if state in ("done", "completed", "success"):
                print("[STEP 3/4] Parse complete!")
                download_url = file_result.get("download_url") or file_result.get("full_zip_url")
                if not download_url:
                    download_url = file_result.get("result", {}).get("url")
                break
            elif state in ("failed", "error"):
                err_msg = file_result.get("err_msg") or "unknown error"
                print(f"[ERROR] Parse failed: {err_msg}", file=sys.stderr)
                return False
            else:
                elapsed = (attempt + 1) * POLL_INTERVAL_SEC
                # 显示解析进度（如果 API 返回了 extract_progress）
                progress = file_result.get("extract_progress", {})
                extracted = progress.get("extracted_pages")
                total = progress.get("total_pages")
                if extracted is not None and total:
                    pct = int(extracted / total * 100)
                    print(f"  [WAIT] Parsing... {extracted}/{total} pages ({pct}%) ({elapsed}s) state={state}")
                else:
                    print(f"  [WAIT] Processing... ({elapsed}s) state={state}")
                time.sleep(POLL_INTERVAL_SEC)

        except requests.exceptions.RequestException as e:
            print(f"  [WARN] Poll error: {e}, retrying...", file=sys.stderr)
            time.sleep(POLL_INTERVAL_SEC)
    else:
        print("[ERROR] Timeout (>10 min)", file=sys.stderr)
        return False

    # ========== Step 4: 下载并解压结果 ==========
    if not download_url:
        print("[ERROR] Parse succeeded but no download URL found", file=sys.stderr)
        return False

    print("[STEP 4/4] Downloading results...")
    try:
        resp_download = requests.get(download_url, timeout=120)
        if resp_download.status_code != 200:
            print(f"[ERROR] Download failed (HTTP {resp_download.status_code})", file=sys.stderr)
            return False

        content_type = resp_download.headers.get("Content-Type", "")
        if "zip" in content_type or download_url.endswith(".zip") or resp_download.content[:4] == b"PK\x03\x04":
            zip_path = os.path.join(output_dir, "_result.zip")
            with open(zip_path, "wb") as f:
                f.write(resp_download.content)

            with zipfile.ZipFile(zip_path, "r") as zf:
                zf.extractall(output_dir)
            os.remove(zip_path)
            print(f"[STEP 4/4] ZIP extracted to: {output_dir}")
        else:
            md_path = os.path.join(output_dir, "full.md")
            with open(md_path, "wb") as f:
                f.write(resp_download.content)
            print(f"[STEP 4/4] Markdown saved: {md_path}")

        _normalize_output(output_dir, pdf_path)
        return True

    except Exception as e:
        print(f"[ERROR] Download/extract error: {e}", file=sys.stderr)
        return False


def _normalize_output(output_dir: str, pdf_path: str):
    """
    标准化输出结构：确保最终有 full.md 和 images/ 目录。
    """
    output_path = Path(output_dir)
    pdf_stem = Path(pdf_path).stem

    if (output_path / "full.md").exists():
        print("[OK] full.md ready")
        return

    # 寻找 markdown 文件
    possible_names = [
        output_path / f"{pdf_stem}.md",
        output_path / "auto" / pdf_stem / f"{pdf_stem}.md",
        output_path / pdf_stem / f"{pdf_stem}.md",
    ]

    md_file = None
    for p in possible_names:
        if p.exists():
            md_file = p
            break

    if md_file is None:
        md_files = list(output_path.rglob("*.md"))
        if md_files:
            md_file = max(md_files, key=lambda f: f.stat().st_size)

    if md_file is None:
        print("[WARN] No markdown file found", file=sys.stderr)
        return

    # 重命名为 full.md
    target_md = output_path / "full.md"
    if md_file != target_md:
        shutil.copy2(md_file, target_md)
        print(f"[OK] Renamed {md_file.name} -> full.md")

    # 汇总 images 目录
    target_images = output_path / "images"
    if not target_images.exists():
        for img_dir in output_path.rglob("images"):
            if img_dir.is_dir() and img_dir != target_images:
                shutil.copytree(img_dir, target_images, dirs_exist_ok=True)
                print("[OK] Images directory consolidated -> images/")
                break


def main():
    parser = argparse.ArgumentParser(
        description="MinerU PDF-to-Markdown Converter (Online API Batch Mode)",
    )
    parser.add_argument("pdf_path", help="Input PDF file path")
    parser.add_argument("output_dir", help="Output directory for Markdown")
    parser.add_argument(
        "--model-version",
        choices=SUPPORTED_MODELS,
        default=DEFAULT_MODEL,
        help=f"MinerU model version (default: {DEFAULT_MODEL}). "
             "'vlm' = high accuracy, 'pipeline' = lightweight, 'MinerU-HTML' = for HTML files",
    )
    parser.add_argument(
        "--language",
        default=DEFAULT_LANGUAGE,
        help=f"OCR language hint (default: {DEFAULT_LANGUAGE}). "
             "Common: en, ch, japan, korean. See MinerU docs for full list.",
    )

    args = parser.parse_args()
    success = convert(args.pdf_path, args.output_dir, args.model_version, args.language)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
