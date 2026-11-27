"""HTTP 路由、鉴权与响应格式。"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import re
from http.server import BaseHTTPRequestHandler
from typing import Any
from urllib.parse import urlsplit

from .config import Settings
from .store import BackupMeta, BackupStore, VersionConflict

_LOG = logging.getLogger("guideline_sync.http")

_BEARER = re.compile(r"^Bearer[ \t]+(\S+)$", re.IGNORECASE)
_UINT = re.compile(r"^[0-9]{1,19}$")
_HISTORY_PATH = re.compile(r"^/v1/history/([0-9]{1,19})$")

#: 413 时最多愿意读掉多少请求体，避免在客户端还塞着数据时直接 RST。
_DRAIN_LIMIT = 1024 * 1024


def _json_bytes(payload: Any) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _header_safe(value: str) -> str:
    """把任意字符串压成合法的 HTTP 头值（latin-1，去掉换行）。"""
    if not value:
        return ""
    return (
        value.replace("\r", " ")
        .replace("\n", " ")
        .encode("latin-1", "replace")
        .decode("latin-1")
    )


class GuidelineSyncHandler(BaseHTTPRequestHandler):
    """``/healthz`` 与 ``/v1/*`` 的全部路由。"""

    protocol_version = "HTTP/1.1"
    server_version = "guideline-sync/1"
    sys_version = ""

    # ------------------------------------------------------------ 基础属性
    @property
    def settings(self) -> Settings:
        return self.server.settings  # type: ignore[attr-defined]

    @property
    def store(self) -> BackupStore:
        return self.server.store  # type: ignore[attr-defined]

    # ------------------------------------------------------------ 方法入口
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 约定
        self._dispatch("GET")

    def do_HEAD(self) -> None:  # noqa: N802
        self._dispatch("HEAD")

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch("PUT")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch("DELETE")

    def do_PATCH(self) -> None:  # noqa: N802
        self._dispatch("PATCH")

    def do_OPTIONS(self) -> None:  # noqa: N802
        self._dispatch("OPTIONS")

    def do_TRACE(self) -> None:  # noqa: N802
        self._dispatch("TRACE")

    def do_CONNECT(self) -> None:  # noqa: N802
        self._dispatch("CONNECT")

    def _dispatch(self, method: str) -> None:
        try:
            self._route(method)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True
        except Exception:  # pragma: no cover - 兜底，避免线程里静默死掉
            _LOG.exception("处理 %s %s 失败", method, self.path)
            if not getattr(self, "_responded", False):
                try:
                    self._send_json(
                        500,
                        {"error": "internal", "message": "服务器内部错误"},
                    )
                except Exception:
                    self.close_connection = True

    # ---------------------------------------------------------------- 路由
    def _route(self, method: str) -> None:
        path = urlsplit(self.path).path
        if len(path) > 1:
            path = path.rstrip("/")

        if path == "/healthz":
            if method in ("GET", "HEAD"):
                self._send_json(
                    200, {"ok": True, "service": "guideline-sync", "api": 1}
                )
            else:
                self._method_not_allowed("GET, HEAD")
            return

        if not (path == "/v1" or path.startswith("/v1/")):
            self._not_found()
            return

        # 所有 /v1/* 一律先鉴权，未知路径也不例外，避免泄露路径是否存在。
        if not self._authorized():
            self._unauthorized()
            return

        if path == "/v1/backup":
            if method in ("GET", "HEAD"):
                self._get_backup()
            elif method == "PUT":
                self._put_backup()
            else:
                self._method_not_allowed("GET, HEAD, PUT")
            return

        if path == "/v1/backup/meta":
            if method in ("GET", "HEAD"):
                self._get_backup_meta()
            else:
                self._method_not_allowed("GET, HEAD")
            return

        if path == "/v1/history":
            if method in ("GET", "HEAD"):
                self._get_history()
            else:
                self._method_not_allowed("GET, HEAD")
            return

        match = _HISTORY_PATH.match(path)
        if match is not None:
            if method not in ("GET", "HEAD"):
                self._method_not_allowed("GET, HEAD")
                return
            self._get_history_revision(int(match.group(1)))
            return

        self._not_found()

    # ---------------------------------------------------------------- 鉴权
    def _authorized(self) -> bool:
        raw = self.headers.get("Authorization")
        if not raw:
            return False
        match = _BEARER.match(raw.strip())
        if match is None:
            return False
        digest = hashlib.sha256(match.group(1).encode("utf-8")).hexdigest()
        return hmac.compare_digest(digest, self.settings.token_sha256)

    # ------------------------------------------------------------ GET /v1
    def _get_backup(self) -> None:
        loaded = self.store.read_current()
        if loaded is None:
            self._empty_backup()
            return
        meta, data = loaded
        self._send_backup(meta, data)

    def _get_backup_meta(self) -> None:
        meta = self.store.current()
        if meta is None:
            self._empty_backup()
            return
        self._send_json(200, meta.to_dict())

    def _get_history(self) -> None:
        items = [meta.to_dict() for meta in self.store.history()]
        self._send_json(200, {"items": items})

    def _get_history_revision(self, revision: int) -> None:
        loaded = self.store.read_revision(revision)
        if loaded is None:
            self._send_json(
                404, {"error": "not_found", "message": "找不到该历史版本"}
            )
            return
        meta, data = loaded
        self._send_backup(meta, data)

    # ---------------------------------------------------------------- PUT
    def _put_backup(self) -> None:
        base = self._optional_uint_header("X-Base-Revision", required=True)
        if base is None:
            return
        saved_at = self._optional_uint_header("X-Backup-Saved-At", required=True)
        if saved_at is None:
            return
        record_count = self._optional_uint_header("X-Record-Count", required=False)
        if record_count is None:
            return
        app_version = _header_safe(self.headers.get("X-App-Version", ""))[:40]

        length = self._content_length()
        if length is None:
            self._error(411, "length_required", "缺少或非法的 Content-Length", close=True)
            return
        if length > self.settings.max_bytes:
            if length <= _DRAIN_LIMIT:
                self._drain(length)
            self.close_connection = True
            self._error(
                413,
                "payload_too_large",
                f"请求体超过上限 {self.settings.max_bytes} 字节",
                close=True,
            )
            return
        if length == 0:
            self._bad_request("请求体为空")
            return

        body = self.rfile.read(length)
        if len(body) != length:
            self.close_connection = True
            self._bad_request("请求体不完整")
            return

        try:
            meta = self.store.put(
                body,
                base_revision=base,
                saved_at=saved_at,
                record_count=record_count,
                app_version=app_version,
            )
        except VersionConflict as exc:
            self._send_json(
                409,
                {"error": "version_conflict", "currentRevision": exc.current_revision},
            )
            return

        self._send_json(201, meta.to_dict(), extra_headers=self._backup_headers(meta))

    def _optional_uint_header(self, name: str, *, required: bool) -> int | None:
        raw = self.headers.get(name)
        if raw is None or not raw.strip():
            if required:
                # 请求体还没读，先读掉小 body 再关连接，避免把 body 当成下一个请求。
                self._reject_put(f"缺少 {name} 请求头")
                return None
            return 0
        text = raw.strip()
        if not _UINT.match(text):
            self._reject_put(f"{name} 必须是非负整数")
            return None
        return int(text)

    def _reject_put(self, message: str) -> None:
        """PUT 在读取 body 之前的 400：尽量读掉小 body，然后关闭连接。"""
        self._drain_small_body()
        self._bad_request(message, close=True)

    def _drain_small_body(self) -> None:
        """读掉不超过 ``_DRAIN_LIMIT`` 的请求体，避免关闭连接时 RST 吞掉响应。"""
        raw = self.headers.get("Content-Length")
        if raw is None or not _UINT.match(raw.strip()):
            return
        length = int(raw.strip())
        if 0 < length <= _DRAIN_LIMIT:
            self._drain(length)

    def _content_length(self) -> int | None:
        if self.headers.get("Transfer-Encoding"):
            return None
        raw = self.headers.get("Content-Length")
        if raw is None or not _UINT.match(raw.strip()):
            return None
        return int(raw.strip())

    def _drain(self, length: int) -> None:
        remaining = length
        try:
            while remaining > 0:
                chunk = self.rfile.read(min(remaining, 65536))
                if not chunk:
                    return
                remaining -= len(chunk)
        except OSError:
            return

    # ---------------------------------------------------------------- 响应
    def _send_backup(self, meta: BackupMeta, data: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(len(data)))
        for key, value in self._backup_headers(meta).items():
            self.send_header(key, value)
        self.end_headers()
        self._responded = True
        if self.command != "HEAD":
            self.wfile.write(data)

    @staticmethod
    def _backup_headers(meta: BackupMeta) -> dict[str, str]:
        return {
            "X-Backup-Revision": str(meta.revision),
            "X-Backup-Sha256": meta.sha256,
            "X-Backup-Saved-At": str(meta.savedAt),
            "X-Record-Count": str(meta.recordCount),
            "X-App-Version": _header_safe(meta.appVersion),
        }

    def _send_json(
        self,
        status: int,
        payload: Any,
        *,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        body = _json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self._responded = True
        if self.command != "HEAD":
            self.wfile.write(body)

    def _error(
        self,
        status: int,
        error: str,
        message: str,
        *,
        close: bool = False,
        headers: dict[str, str] | None = None,
    ) -> None:
        merged = dict(headers or {})
        if close:
            merged["Connection"] = "close"
        self._send_json(
            status, {"error": error, "message": message}, extra_headers=merged
        )

    def _bad_request(self, message: str, *, close: bool = False) -> None:
        self._error(400, "bad_request", message, close=close)

    def _unauthorized(self) -> None:
        close = self.command in ("PUT", "POST", "PATCH")
        if close:
            self._drain_small_body()
        headers = {"WWW-Authenticate": 'Bearer realm="guideline-sync"'}
        if close:
            headers["Connection"] = "close"
        self._error(401, "unauthorized", "需要有效的 Bearer token", headers=headers)

    def _empty_backup(self) -> None:
        self._error(404, "empty", "还没有备份")

    def _not_found(self) -> None:
        close = self.command in ("PUT", "POST", "PATCH")
        if close:
            self._drain_small_body()
        self._error(404, "not_found", "找不到该路径", close=close)

    def _method_not_allowed(self, allow: str) -> None:
        close = self.command in ("PUT", "POST", "PATCH")
        if close:
            self._drain_small_body()
        headers = {"Allow": allow}
        if close:
            headers["Connection"] = "close"
        self._error(405, "method_not_allowed", "不支持该请求方法", headers=headers)

    # ---------------------------------------------------------------- 日志
    def log_request(self, code: Any = "-", size: Any = "-") -> None:
        try:
            status = int(code)
        except (TypeError, ValueError):
            status = 0
        if self.settings.debug_log or status >= 400:
            super().log_request(code, size)

    def log_message(self, fmt: str, *args: Any) -> None:
        _LOG.info("%s - %s", self.address_string(), fmt % args)
