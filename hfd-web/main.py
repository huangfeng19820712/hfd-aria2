import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, Form, Request
from fastapi.responses import FileResponse, HTMLResponse

APP_DIR = Path(__file__).parent


def load_env_file(path: Path) -> None:
    """Load KEY=VALUE pairs without overriding variables already in os.environ.

    Mirrors load_env_file() in hfd-aria2-lib.sh so the shell scripts and the web
    service share one config file. Existing environment wins, so docker-compose
    `environment:` still takes precedence over the file.
    """
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if not key.isidentifier():
            continue
        os.environ.setdefault(key, value)


SCRIPT_DIR = os.environ.get("HFD_SCRIPT_DIR", "/hfd-scripts")
load_env_file(Path(SCRIPT_DIR) / "hfd-aria2.env")

LOG_DIR = Path(os.environ.get("LOG_DIR", "/app/data/logs"))
LOG_DIR.mkdir(parents=True, exist_ok=True)

ARIA2_DIR_PREFIX = os.environ.get("ARIA2_DIR_PREFIX", "/downloads/models").rstrip("/")
ARIA2_RPC = os.environ.get("ARIA2_RPC", "http://127.0.0.1:6800/jsonrpc")
ARIA2_SECRET = os.environ.get("ARIA2_SECRET", "")

HF_HOST = r"(?:huggingface\.co|hf-mirror\.com)"
# .../org/repo/blob|resolve/<rev>/<path>  -> a single file
HF_FILE_RE = re.compile(
    rf"^https?://{HF_HOST}/([^/\s]+)/([^/\s]+)/(?:blob|resolve)/([^/\s]+)/(.+)$"
)
# .../org/repo/tree/<rev>[/<subdir>]      -> a directory (or the whole repo)
HF_TREE_RE = re.compile(
    rf"^https?://{HF_HOST}/([^/\s]+)/([^/\s]+)/tree/([^/\s]+)(?:/(.*))?$"
)
# .../org/repo                            -> the whole repository
HF_REPO_RE = re.compile(rf"^https?://{HF_HOST}/([^/\s]+)/([^/\s]+)$")

# Files that are never worth downloading: documentation images and OS cruft.
# Matched against the file path; "*" is a wildcard.
DEFAULT_EXCLUDES = [
    ".DS_Store",
    ".gitattributes",
    "*.jpg",
    "*.jpeg",
    "*.png",
    "*.gif",
    "*.webp",
    "*.svg",
    "*.bmp",
    "*.tiff",
    "*.ico",
    "*.mp4",
    "*.mov",
    "*.gifv",
]


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_DIR / "hfd-web.log", "a") as f:
        f.write(f"[{ts}] {msg}\n")


def parse_hf_url(line: str):
    """Parse a Hugging Face URL.

    Returns (repo_id, prefix, kind) or None.
      kind == "file" -> prefix is the exact file path
      kind == "dir"  -> prefix is a directory path ("" means the whole repo)
    """
    line = line.strip().split("?")[0].rstrip("/")
    if not line:
        return None

    m = HF_FILE_RE.match(line)
    if m:
        return f"{m.group(1)}/{m.group(2)}", m.group(4), "file"

    m = HF_TREE_RE.match(line)
    if m:
        return f"{m.group(1)}/{m.group(2)}", (m.group(4) or ""), "dir"

    m = HF_REPO_RE.match(line)
    if m:
        return f"{m.group(1)}/{m.group(2)}", "", "dir"

    return None


def hf_api_url(repo_id: str, revision: str = "main") -> str:
    endpoint = os.environ.get("HF_ENDPOINT", "https://hf-mirror.com").rstrip("/")
    api_path = repo_id if repo_id.startswith("datasets/") else f"models/{repo_id}"
    return f"{endpoint}/api/{api_path}/revision/{revision}?blobs=true"


def fetch_repo_files(repo_id: str, revision: str = "main") -> list[dict]:
    """List the files of a HF repo via the API (proxied to avoid CORS)."""
    url = hf_api_url(repo_id, revision)
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "hfd-aria2-web", "Accept": "application/json"},
    )
    token = os.environ.get("HF_TOKEN", "").strip()
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode("utf-8", "replace"))

    files = []
    for sib in data.get("siblings") or []:
        path = sib.get("rfilename")
        if not path:
            continue
        lfs = sib.get("lfs") or {}
        size = lfs.get("size") or sib.get("size") or 0
        files.append({"path": path, "size": int(size or 0)})
    files.sort(key=lambda f: f["path"])
    return files


def is_excluded(path: str, excludes: list[str]) -> bool:
    import fnmatch

    return any(fnmatch.fnmatch(path, pat) or fnmatch.fnmatch(os.path.basename(path), pat)
               for pat in excludes)


def aria2_web_url(request: Request) -> str:
    env_url = os.environ.get("ARIA2_WEB_URL", "").strip()
    if env_url:
        return env_url
    host = request.headers.get("host", "").split(":")[0]
    return f"http://{host}:6880"


def aria2_ping() -> tuple[bool, str]:
    """Probe the aria2 RPC endpoint. Returns (ok, message)."""
    if not ARIA2_SECRET:
        return False, "ARIA2_SECRET 未设置"
    payload = (
        '{"jsonrpc":"2.0","id":"ping","method":"aria2.getVersion",'
        '"params":["token:' + ARIA2_SECRET + '"]}'
    ).encode()
    req = urllib.request.Request(
        ARIA2_RPC, data=payload, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=3) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.URLError as e:
        return False, f"无法连接 {ARIA2_RPC} ({e.reason})"
    except Exception as e:  # noqa: BLE001
        return False, f"连接异常: {e}"
    m = re.search(r'"version"\s*:\s*"([^"]+)"', body)
    if m:
        return True, f"aria2 {m.group(1)} 已连接"
    if '"error"' in body:
        return False, "RPC 返回错误（检查 ARIA2_SECRET）"
    return False, f"无法解析响应: {body[:120]}"


def safe_name(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "_", text)[:60]


app = FastAPI(title="hfd-aria2 Web")


@app.get("/api/ping")
def api_ping():
    ok, msg = aria2_ping()
    return {"ok": ok, "message": msg, "rpc": ARIA2_RPC}


@app.get("/api/files")
def api_files(repo: str, revision: str = "main"):
    """List the files of a HF repo so the UI can preview and select them."""
    repo = repo.strip().strip("/")
    if "/" not in repo:
        return {"ok": False, "error": "仓库格式应为 org/repo"}
    try:
        files = fetch_repo_files(repo, revision)
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"HF API 返回 {e.code}"}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": str(e)}

    for f in files:
        f["excluded"] = is_excluded(f["path"], DEFAULT_EXCLUDES)
    total = sum(f["size"] for f in files)
    kept = sum(f["size"] for f in files if not f["excluded"])
    return {
        "ok": True,
        "repo": repo,
        "files": files,
        "count": len(files),
        "total_size": total,
        "kept_size": kept,
        "kept_count": sum(1 for f in files if not f["excluded"]),
    }


@app.get("/", response_class=HTMLResponse)
def index():
    html = (APP_DIR / "index.html").read_text(encoding="utf-8")
    html = html.replace("{{LOCAL_DIR_ROOT}}", ARIA2_DIR_PREFIX)
    html = html.replace("{{ARIA2_RPC}}", ARIA2_RPC)
    return HTMLResponse(html)


@app.get("/logs/{job_id}", response_class=HTMLResponse)
def view_log(job_id: str):
    safe = safe_name(job_id)
    path = LOG_DIR / f"{safe}.log"
    if not path.exists():
        return HTMLResponse(
            "<h3>日志不存在</h3><p><a href='/'>← 返回</a></p>", status_code=404
        )
    content = path.read_text(encoding="utf-8", errors="replace")
    return HTMLResponse(
        f"""<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8">
        <title>日志 {safe}</title>
        <style>
        body {{ font-family: -apple-system, sans-serif; margin: 20px; }}
        pre {{ background: #1e1e1e; color: #d4d4d4; padding: 16px; border-radius: 6px;
               overflow-x: auto; font-size: 13px; line-height: 1.5; }}
        </style></head><body>
        <h3>{safe}.log</h3>
        <p><a href="/">← 返回</a></p>
        <pre>{content}</pre>
        </body></html>"""
    )


@app.post("/submit", response_class=HTMLResponse)
async def submit(
    request: Request,
    urls_text: str = Form(""),
    includes_text: str = Form(""),
    local_dir_root: str = Form(...),
    threads: int = Form(4),
    concurrent: int = Form(4),
):
    if not ARIA2_SECRET:
        return HTMLResponse(
            "<h3>服务端未配置 ARIA2_SECRET</h3><p>请在 .env 中设置后重建容器。</p>"
            "<p><a href='/'>← 返回</a></p>",
            status_code=400,
        )

    ok, msg = aria2_ping()
    if not ok:
        return HTMLResponse(
            f"<h3>aria2 RPC 不可用</h3><p>{msg}</p>"
            "<p>请检查 .env 中的 ARIA2_RPC / ARIA2_SECRET，以及 aria2 容器是否在运行。</p>"
            "<p><a href='/'>← 返回</a></p>",
            status_code=400,
        )

    # repo_id -> {"prefixes": [...], "files": [...] or None}
    by_repo: dict[str, dict] = {}
    bad_lines = []
    for raw in urls_text.splitlines():
        result = parse_hf_url(raw)
        if result:
            repo_id, prefix, kind = result
            entry = by_repo.setdefault(repo_id, {"prefixes": [], "files": []})
            if kind == "file":
                entry["files"].append(prefix)
            else:
                entry["prefixes"].append(prefix)
        elif raw.strip():
            bad_lines.append(raw.strip())

    manual_includes = [s.strip() for s in includes_text.splitlines() if s.strip()]

    if not by_repo and not manual_includes:
        return HTMLResponse(
            "<h3>没有可下载的内容</h3><p>请粘贴 HF 页面 URL 或填入手动 include patterns。</p>"
            "<p><a href='/'>← 返回</a></p>",
            status_code=400,
        )

    if manual_includes and not by_repo:
        return HTMLResponse(
            "<h3>手动 include 需要指定 repo</h3>"
            "<p>请粘贴至少一个 HF URL，或用命令行直接运行 hfd-aria2.sh。</p>"
            "<p><a href='/'>← 返回</a></p>",
            status_code=400,
        )

    # A repository or directory URL selects everything under it; express that as
    # an include pattern ("" = repo root, "sub/dir" = that directory).
    for entry in by_repo.values():
        for prefix in entry["prefixes"]:
            entry.setdefault("patterns", []).append(f"{prefix}/*" if prefix else "*")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    submitted = []
    failures = []

    for idx, (repo_id, entry) in enumerate(by_repo.items()):
        repo_dir_name = repo_id.replace("/", "__")
        local_dir = f"{local_dir_root.rstrip('/')}/{repo_dir_name}"
        job_id = f"{stamp}-{idx:02d}-{safe_name(repo_dir_name)}"
        log_path = LOG_DIR / f"{job_id}.log"

        patterns = list(entry.get("patterns", []))
        exact_files = list(entry.get("files") or [])

        # Resolve a repo/directory selection into concrete files so the count and
        # the default exclusions apply. Explicitly named files are always kept
        # (even if they look like an image); directory scope excludes them.
        n_files = len(exact_files)
        if patterns:
            try:
                all_files = fetch_repo_files(repo_id)
            except Exception as e:  # noqa: BLE001
                log(f"{repo_id}: file listing failed: {e}")
                all_files = []
            if all_files:
                selected = []
                for f in all_files:
                    path = f["path"]
                    in_scope = any(path.startswith(p) for p in entry["prefixes"])
                    if in_scope and is_excluded(path, DEFAULT_EXCLUDES):
                        continue
                    if in_scope or path in exact_files:
                        selected.append(path)
                if selected:
                    patterns = []
                    exact_files = sorted(set(selected))
                    n_files = len(exact_files)
            else:
                n_files = 0

        cmd = [
            "bash",
            f"{SCRIPT_DIR}/hfd-aria2.sh",
            repo_id,
            "--local-dir",
            local_dir,
            "-x",
            str(threads),
            "-j",
            str(concurrent),
        ]
        if exact_files:
            # Pass the exact selection through a file: hundreds of paths would
            # overflow the command line.
            list_path = LOG_DIR / f"{job_id}.files"
            list_path.write_text("\n".join(exact_files) + "\n", encoding="utf-8")
            cmd += ["--file-list", str(list_path)]
        for p in patterns:
            cmd += ["--include", p]
        if manual_includes:
            cmd += ["--include", *manual_includes]


        env = os.environ.copy()
        env["REPO_DIR_NAME"] = repo_dir_name

        log(f"submit {job_id}: {' '.join(cmd)}")
        with open(log_path, "wb") as out:
            proc = subprocess.Popen(
                cmd,
                stdout=out,
                stderr=subprocess.STDOUT,
                env=env,
                start_new_session=True,
            )

        # Give the script a moment to fail fast (missing tools, bad RPC, etc.).
        exited = None
        for _ in range(30):
            exited = proc.poll()
            if exited is not None:
                break
            time.sleep(0.1)

        if exited is not None and exited != 0:
            tail = ""
            try:
                tail = log_path.read_text(encoding="utf-8", errors="replace")[-3000:]
            except OSError:
                pass
            failures.append((job_id, repo_id, exited, tail))
            submitted.append((repo_id, n_files, local_dir, job_id))
            continue

        submitted.append((repo_id, n_files, local_dir, job_id))

    rows = "\n".join(
        f"<tr><td><code>{rid}</code></td>"
        f"<td>{nf + (len(manual_includes) if manual_includes else 0)}</td>"
        f"<td><code>{ld}</code></td>"
        f"<td><a href='/logs/{jid}'>日志</a></td></tr>"
        for rid, nf, ld, jid in submitted
    )

    total_files = sum(len(p) for _, p, _, _ in submitted) + len(manual_includes) * len(submitted)

    bad_html = ""
    if bad_lines:
        bad_items = "".join(f"<li><code>{b}</code></li>" for b in bad_lines)
        bad_html = (
            f"<details><summary style='color:orange;cursor:pointer'>"
            f"无法解析 {len(bad_lines)} 行（已忽略）</summary>"
            f"<ul>{bad_items}</ul></details>"
        )

    fail_html = ""
    if failures:
        blocks = []
        for jid, rid, code, tail in failures:
            blocks.append(
                f"<div class='err'><b>{rid}</b> 启动失败（退出码 {code}）"
                f"<pre>{tail or '(无输出)'}</pre>"
                f"<a href='/logs/{jid}'>查看完整日志</a></div>"
            )
        fail_html = "<h3>部分任务启动失败</h3>" + "".join(blocks)

    ariang = aria2_web_url(request)
    title = "✓ 已提交" if not failures else "⚠ 部分失败"

    return HTMLResponse(
        f"""
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8">
        <title>提交结果</title>
        <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                max-width: 900px; margin: 30px auto; padding: 0 20px; }}
        table {{ border-collapse: collapse; margin: 15px 0; width: 100%; }}
        th, td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        th {{ background: #f5f5f5; }}
        .btn {{ display: inline-block; padding: 12px 24px; background: #4CAF50; color: white;
                text-decoration: none; border-radius: 4px; font-size: 16px; margin-right: 10px; }}
        .btn-secondary {{ background: #888; }}
        .err {{ background: #fdecea; border: 1px solid #f5c6cb; border-radius: 6px;
                padding: 12px; margin: 10px 0; }}
        .err pre {{ background: #1e1e1e; color: #d4d4d4; padding: 12px; border-radius: 4px;
                    overflow-x: auto; font-size: 12px; white-space: pre-wrap; }}
        </style></head><body>
        <h2>{title} {len(submitted)} 个下载任务（共 {total_files} 个文件）</h2>
        <table>
        <tr><th>仓库</th><th>文件数</th><th>本地路径</th><th>日志</th></tr>
        {rows}
        </table>
        {fail_html}
        <p>
            <a class="btn" href="{ariang}" target="_blank">打开 AriaNg 看进度 →</a>
            <a class="btn btn-secondary" href="/">← 继续提交</a>
        </p>
        {bad_html}
        </body></html>
        """
    )