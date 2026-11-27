"""HTTP API 集成测试：真实起一个 GL_TLS=off 的线程服务器。"""

from __future__ import annotations

import gzip
import hashlib
import http.client
import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_ROOT))

from guideline_sync.app import build_server  # noqa: E402
from guideline_sync.config import Settings  # noqa: E402

TOKEN = "unit-test-token-0123456789abcdef"
TOKEN_SHA256 = hashlib.sha256(TOKEN.encode("utf-8")).hexdigest()
MAX_BYTES = 2048
SAVED_AT = 1_700_000_000_000


def gz(text: str) -> bytes:
    return gzip.compress(text.encode("utf-8"), mtime=0)


def auth(token: str = TOKEN) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


class ApiTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="guideline-api-")
        env = {
            "GL_BIND": "127.0.0.1:0",
            "GL_DATA": str(Path(self._tmp.name) / "data"),
            "GL_TLS": "off",
            "GL_TOKEN_SHA256": TOKEN_SHA256,
            "GL_HISTORY": "10",
            "GL_MAX_BYTES": str(MAX_BYTES),
            "GL_LOG": "debug",
        }
        self.settings = Settings.from_env(env)
        self.server = build_server(self.settings)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(
            target=self.server.serve_forever,
            kwargs={"poll_interval": 0.05},
            daemon=True,
        )
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self._tmp.cleanup()

    # ------------------------------------------------------------- helpers
    def request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            data = response.read()
            return (
                response.status,
                {key.lower(): value for key, value in response.getheaders()},
                data,
            )
        finally:
            conn.close()

    def put(
        self,
        body: bytes,
        *,
        base: int = 0,
        saved_at: int = SAVED_AT,
        record_count: int | None = None,
        app_version: str | None = None,
        token: str = TOKEN,
    ) -> tuple[int, dict[str, str], bytes]:
        headers = {
            **auth(token),
            "X-Base-Revision": str(base),
            "X-Backup-Saved-At": str(saved_at),
        }
        if record_count is not None:
            headers["X-Record-Count"] = str(record_count)
        if app_version is not None:
            headers["X-App-Version"] = app_version
        return self.request("PUT", "/v1/backup", body=body, headers=headers)

    @staticmethod
    def json_body(data: bytes) -> dict:
        return json.loads(data.decode("utf-8"))

    # ---------------------------------------------------------------- tests
    def test_healthz_needs_no_auth(self) -> None:
        status, headers, body = self.request("GET", "/healthz")
        self.assertEqual(status, 200)
        self.assertTrue(headers["content-type"].startswith("application/json"))
        self.assertEqual(
            self.json_body(body),
            {"ok": True, "service": "guideline-sync", "api": 1},
        )
        self.assertEqual(
            body, b'{"ok":true,"service":"guideline-sync","api":1}'
        )

    def test_requires_bearer_token(self) -> None:
        status, headers, body = self.request("GET", "/v1/backup")
        self.assertEqual(status, 401)
        self.assertIn("bearer", headers.get("www-authenticate", "").lower())
        self.assertEqual(self.json_body(body)["error"], "unauthorized")

        status, _, _ = self.request("GET", "/v1/backup", headers=auth("wrong-token"))
        self.assertEqual(status, 401)

        # 带 body 的 PUT 用错 token：服务端要先读掉小 body 再回 401，
        # 否则关闭连接时的 RST 可能让客户端收不到响应。
        status, _, body = self.put(gz("rejected"), token="wrong-token")
        self.assertEqual(status, 401)
        self.assertEqual(self.json_body(body)["error"], "unauthorized")

        status, _, _ = self.request(
            "GET", "/v1/backup", headers={"Authorization": "Basic abc"}
        )
        self.assertEqual(status, 401)

    def test_empty_backup_is_404(self) -> None:
        status, _, body = self.request("GET", "/v1/backup", headers=auth())
        self.assertEqual(status, 404)
        self.assertEqual(
            self.json_body(body), {"error": "empty", "message": "还没有备份"}
        )

        status, _, body = self.request("HEAD", "/v1/backup", headers=auth())
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

        status, _, body = self.request("GET", "/v1/backup/meta", headers=auth())
        self.assertEqual(status, 404)
        self.assertEqual(self.json_body(body)["error"], "empty")

    def test_put_creates_backup(self) -> None:
        body = gz('{"records":[1,2,3]}')
        status, headers, payload = self.put(
            body, base=0, record_count=3, app_version="1.4.0"
        )
        self.assertEqual(status, 201)
        meta = self.json_body(payload)
        self.assertEqual(meta["revision"], 1)
        self.assertEqual(meta["sha256"], hashlib.sha256(body).hexdigest())
        self.assertEqual(meta["size"], len(body))
        self.assertEqual(meta["savedAt"], SAVED_AT)
        self.assertEqual(meta["recordCount"], 3)
        self.assertEqual(meta["appVersion"], "1.4.0")
        self.assertIsInstance(meta["updatedAt"], int)
        self.assertGreater(meta["updatedAt"], 0)

        self.assertEqual(headers["x-backup-revision"], "1")
        self.assertEqual(headers["x-backup-sha256"], meta["sha256"])
        self.assertEqual(headers["x-backup-saved-at"], str(SAVED_AT))
        self.assertEqual(headers["x-record-count"], "3")
        self.assertEqual(headers["x-app-version"], "1.4.0")

    def test_get_returns_raw_bytes_and_headers(self) -> None:
        body = gz("read-me-back")
        self.put(body, record_count=2, app_version="9.9.9")

        status, headers, data = self.request("GET", "/v1/backup", headers=auth())
        self.assertEqual(status, 200)
        self.assertEqual(data, body)
        self.assertEqual(headers["content-type"], "application/gzip")
        self.assertEqual(headers["content-length"], str(len(body)))
        self.assertEqual(headers["x-backup-revision"], "1")
        self.assertEqual(headers["x-backup-sha256"], hashlib.sha256(body).hexdigest())
        self.assertEqual(headers["x-backup-saved-at"], str(SAVED_AT))
        self.assertEqual(headers["x-record-count"], "2")
        self.assertEqual(headers["x-app-version"], "9.9.9")

    def test_head_returns_same_headers_without_body(self) -> None:
        body = gz("head-me")
        self.put(body)

        status, headers, data = self.request("HEAD", "/v1/backup", headers=auth())
        self.assertEqual(status, 200)
        self.assertEqual(data, b"")
        self.assertEqual(headers["content-length"], str(len(body)))
        self.assertEqual(headers["x-backup-revision"], "1")
        self.assertEqual(headers["x-backup-sha256"], hashlib.sha256(body).hexdigest())
        self.assertEqual(headers["x-record-count"], "0")
        self.assertEqual(headers["x-app-version"], "")

    def test_meta_endpoint(self) -> None:
        body = gz("meta")
        _, _, created = self.put(body, record_count=5, app_version="2.0.0")
        created_meta = self.json_body(created)

        status, headers, data = self.request(
            "GET", "/v1/backup/meta", headers=auth()
        )
        self.assertEqual(status, 200)
        self.assertTrue(headers["content-type"].startswith("application/json"))
        self.assertEqual(
            self.json_body(data),
            {
                "revision": 1,
                "sha256": hashlib.sha256(body).hexdigest(),
                "size": len(body),
                "savedAt": SAVED_AT,
                "recordCount": 5,
                "appVersion": "2.0.0",
                "updatedAt": created_meta["updatedAt"],
            },
        )

    def test_conflict_does_not_change_backup(self) -> None:
        first = gz("first")
        self.put(first)

        status, _, body = self.put(gz("second"), base=0)
        self.assertEqual(status, 409)
        self.assertEqual(
            self.json_body(body),
            {"error": "version_conflict", "currentRevision": 1},
        )

        status, _, data = self.request("GET", "/v1/backup", headers=auth())
        self.assertEqual(status, 200)
        self.assertEqual(data, first)

        _, _, data = self.request("GET", "/v1/backup/meta", headers=auth())
        self.assertEqual(self.json_body(data)["revision"], 1)

    def test_conflict_when_store_is_empty(self) -> None:
        status, _, body = self.put(gz("nope"), base=5)
        self.assertEqual(status, 409)
        self.assertEqual(self.json_body(body)["currentRevision"], 0)

        status, _, _ = self.request("GET", "/v1/backup", headers=auth())
        self.assertEqual(status, 404)

    def test_empty_body_rejected(self) -> None:
        status, _, body = self.put(b"")
        self.assertEqual(status, 400)
        self.assertEqual(self.json_body(body)["error"], "bad_request")

        status, _, _ = self.request("GET", "/v1/backup", headers=auth())
        self.assertEqual(status, 404)

    def test_missing_or_bad_headers_rejected(self) -> None:
        status, _, _ = self.request(
            "PUT",
            "/v1/backup",
            body=gz("x"),
            headers={**auth(), "X-Base-Revision": "0"},
        )
        self.assertEqual(status, 400)

        status, _, _ = self.request(
            "PUT",
            "/v1/backup",
            body=gz("x"),
            headers={
                **auth(),
                "X-Base-Revision": "abc",
                "X-Backup-Saved-At": str(SAVED_AT),
            },
        )
        self.assertEqual(status, 400)

        status, _, _ = self.request(
            "GET", "/v1/backup", headers={**auth(), "X-Base-Revision": "0"}
        )
        self.assertEqual(status, 404)  # 仍然没有备份

    def test_oversize_rejected(self) -> None:
        status, _, body = self.put(b"x" * (MAX_BYTES + 1))
        self.assertEqual(status, 413)
        self.assertEqual(self.json_body(body)["error"], "payload_too_large")

        status, _, _ = self.request("GET", "/v1/backup", headers=auth())
        self.assertEqual(status, 404)

    def test_history_and_revision_endpoint(self) -> None:
        first = gz("first")
        second = gz("second")
        self.put(first, base=0, record_count=1)
        self.put(second, base=1, record_count=2)

        status, _, data = self.request("GET", "/v1/history", headers=auth())
        self.assertEqual(status, 200)
        items = self.json_body(data)["items"]
        self.assertEqual([item["revision"] for item in items], [2, 1])
        self.assertEqual(items[0]["sha256"], hashlib.sha256(second).hexdigest())
        self.assertEqual(items[1]["sha256"], hashlib.sha256(first).hexdigest())

        status, headers, data = self.request(
            "GET", "/v1/history/1", headers=auth()
        )
        self.assertEqual(status, 200)
        self.assertEqual(data, first)
        self.assertEqual(headers["content-type"], "application/gzip")
        self.assertEqual(headers["x-backup-revision"], "1")
        self.assertEqual(headers["x-record-count"], "1")

        status, _, data = self.request("GET", "/v1/history/2", headers=auth())
        self.assertEqual(status, 200)
        self.assertEqual(data, second)

        status, _, body = self.request("GET", "/v1/history/99", headers=auth())
        self.assertEqual(status, 404)
        self.assertEqual(self.json_body(body)["error"], "not_found")

        status, _, body = self.request("GET", "/v1/history/abc", headers=auth())
        self.assertEqual(status, 404)

    def test_unknown_paths(self) -> None:
        status, _, body = self.request("GET", "/v1/nope", headers=auth())
        self.assertEqual(status, 404)
        self.assertEqual(self.json_body(body)["error"], "not_found")

        status, _, _ = self.request("GET", "/nope")
        self.assertEqual(status, 404)

        status, _, _ = self.request("GET", "/v1/nope")
        self.assertEqual(status, 401)  # /v1/* 先鉴权

    def test_method_not_allowed(self) -> None:
        status, headers, body = self.request(
            "POST", "/v1/backup", body=b"ignored-body", headers=auth()
        )
        self.assertEqual(status, 405)
        self.assertIn("PUT", headers["allow"])
        self.assertEqual(self.json_body(body)["error"], "method_not_allowed")

        status, _, _ = self.request(
            "POST", "/healthz", body=b"", headers={}
        )
        self.assertEqual(status, 405)

    def test_app_version_is_truncated(self) -> None:
        long_version = "v" * 60
        status, headers, data = self.put(gz("truncate"), app_version=long_version)
        self.assertEqual(status, 201)
        self.assertEqual(len(headers["x-app-version"]), 40)
        self.assertEqual(len(self.json_body(data)["appVersion"]), 40)

    def test_path_trailing_slash_and_query(self) -> None:
        self.put(gz("slash"))
        status, _, data = self.request("GET", "/v1/backup/?x=1", headers=auth())
        self.assertEqual(status, 200)
        self.assertEqual(data, gz("slash"))


if __name__ == "__main__":
    unittest.main()
