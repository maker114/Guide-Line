"""备份存储：原子写、版本号与历史保留。

磁盘布局（``GL_DATA``）::

    current.gz                 最新一份原始 gzip 字节
    meta.json                  当前版本的元数据
    history/rev-<n>.gz         历史版本字节（含当前版本）
    history/rev-<n>.json       历史版本元数据

写入顺序固定为 ``history/`` → ``current.gz`` → ``meta.json``，每一步都是
"同目录临时文件 + fsync + os.replace"。进程在任意一步崩溃，最多留下一个
孤儿历史文件或者让 meta.json 落后一步；后者在下次启动时按 history 自动补齐。
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

_LOG = logging.getLogger(__name__)

CURRENT_NAME = "current.gz"
META_NAME = "meta.json"
HISTORY_DIR_NAME = "history"

_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_HISTORY_FILE = re.compile(r"^rev-(\d+)\.(gz|json)$")


class VersionConflict(Exception):
    """``X-Base-Revision`` 与当前版本不一致。"""

    def __init__(self, current_revision: int) -> None:
        super().__init__(f"当前版本是 {current_revision}")
        self.current_revision = current_revision


@dataclass(frozen=True)
class BackupMeta:
    """一份备份的元数据；字段名与 API JSON 完全一致。"""

    revision: int
    sha256: str
    size: int
    savedAt: int
    recordCount: int
    appVersion: str
    updatedAt: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "revision": self.revision,
            "sha256": self.sha256,
            "size": self.size,
            "savedAt": self.savedAt,
            "recordCount": self.recordCount,
            "appVersion": self.appVersion,
            "updatedAt": self.updatedAt,
        }


def _now_ms() -> int:
    return int(time.time() * 1000)


def atomic_write_bytes(path: Path, data: bytes) -> None:
    """同目录临时文件写入并 fsync，再用 ``os.replace`` 原子替换。"""
    path = Path(path)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        _fsync_directory(path.parent)
    except BaseException:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _fsync_directory(path: Path) -> None:
    """尽量 fsync 目录项；Windows 不支持打开目录，失败只警告不抛出。"""
    if os.name == "nt":
        return
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError as exc:
        # 目录 fsync 失败时文件已经替换成功，这里只提醒，避免调用方误以为
        # 写入没发生而破坏“meta 与字节一致”的内存状态。
        _LOG.warning("fsync 目录 %s 失败: %s", path, exc)
    finally:
        os.close(fd)


def _meta_bytes(meta: BackupMeta) -> bytes:
    text = json.dumps(meta.to_dict(), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _parse_meta(obj: Any) -> BackupMeta | None:
    if not isinstance(obj, dict):
        return None
    try:
        meta = BackupMeta(
            revision=int(obj["revision"]),
            sha256=str(obj["sha256"]),
            size=int(obj["size"]),
            savedAt=int(obj["savedAt"]),
            recordCount=int(obj["recordCount"]),
            appVersion=str(obj["appVersion"]),
            updatedAt=int(obj["updatedAt"]),
        )
    except (KeyError, TypeError, ValueError):
        return None
    if meta.revision < 1:
        return None
    if not _HEX64.match(meta.sha256):
        return None
    if meta.size < 0 or meta.savedAt < 0 or meta.recordCount < 0 or meta.updatedAt < 0:
        return None
    return meta


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_file(path: Path) -> str | None:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()


def _read_meta_file(path: Path) -> BackupMeta | None:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        _LOG.warning("元数据不是合法 JSON: %s", path)
        return None
    meta = _parse_meta(obj)
    if meta is None:
        _LOG.warning("元数据字段不完整或非法: %s", path)
    return meta


class BackupStore:
    """线程安全的备份仓库：所有写操作和版本判定共用一把锁。"""

    def __init__(self, data_dir: str | os.PathLike[str], history_limit: int = 10) -> None:
        if history_limit < 1:
            raise ValueError("history_limit 至少为 1")
        self.data_dir = Path(data_dir)
        self.history_limit = int(history_limit)
        self._current_path = self.data_dir / CURRENT_NAME
        self._meta_path = self.data_dir / META_NAME
        self._history_dir = self.data_dir / HISTORY_DIR_NAME
        self._lock = threading.Lock()

        self._history_dir.mkdir(parents=True, exist_ok=True)
        self._meta = _read_meta_file(self._meta_path)
        self._repair_if_needed()

    # ------------------------------------------------------------------ 读
    def current(self) -> BackupMeta | None:
        with self._lock:
            return self._meta

    def read_current(self) -> tuple[BackupMeta, bytes] | None:
        """返回当前版本（元数据, 原始字节）；没有备份时返回 ``None``。"""
        with self._lock:
            meta = self._meta
            if meta is None:
                return None
            try:
                data = self._current_path.read_bytes()
            except OSError as exc:
                _LOG.error("读取 %s 失败: %s", self._current_path, exc)
                return None
            return meta, data

    def read_revision(self, revision: int) -> tuple[BackupMeta, bytes] | None:
        """按版本号读取历史；当前版本的历史文件缺失时回退到 current.gz。"""
        with self._lock:
            if revision < 1 or self._meta is None or revision > self._meta.revision:
                return None
            meta = self._read_history_meta(revision)
            path = self._history_dir / f"rev-{revision}.gz"
            if meta is None or not path.is_file():
                if revision != self._meta.revision:
                    return None
                meta = self._meta
                path = self._current_path
            try:
                data = path.read_bytes()
            except OSError as exc:
                _LOG.error("读取历史版本 %d 失败: %s", revision, exc)
                return None
            return meta, data

    def history(self) -> list[BackupMeta]:
        """按版本号从新到旧返回，最多 ``history_limit`` 条。"""
        with self._lock:
            current_revision = self._meta.revision if self._meta is not None else 0
            items = [
                meta
                for meta in self._history_metas_unlocked()
                if meta.revision <= current_revision
            ]
            items.sort(key=lambda item: item.revision, reverse=True)
            return items[: self.history_limit]

    # ------------------------------------------------------------------ 写
    def put(
        self,
        body: bytes,
        *,
        base_revision: int,
        saved_at: int,
        record_count: int = 0,
        app_version: str = "",
    ) -> BackupMeta:
        """写入新版本；版本冲突抛 :class:`VersionConflict`，空 body 抛 ``ValueError``。"""
        if not isinstance(body, (bytes, bytearray)):
            raise TypeError("body 必须是 bytes")
        body = bytes(body)
        if not body:
            raise ValueError("body 不能为空")
        if base_revision < 0:
            raise ValueError("base_revision 不能为负")
        if saved_at < 0:
            raise ValueError("saved_at 不能为负")
        if record_count < 0:
            raise ValueError("record_count 不能为负")
        app_version = str(app_version)[:40]

        with self._lock:
            current_revision = self._meta.revision if self._meta is not None else 0
            if base_revision != current_revision:
                raise VersionConflict(current_revision)

            revision = current_revision + 1
            meta = BackupMeta(
                revision=revision,
                sha256=_sha256_bytes(body),
                size=len(body),
                savedAt=int(saved_at),
                recordCount=int(record_count),
                appVersion=app_version,
                updatedAt=_now_ms(),
            )
            history_gz = self._history_dir / f"rev-{revision}.gz"
            history_json = self._history_dir / f"rev-{revision}.json"

            # 1) 先落历史：这一步失败时当前版本完全没被改动。
            atomic_write_bytes(history_gz, body)
            atomic_write_bytes(history_json, _meta_bytes(meta))

            # 2) 再换 current.gz：原子替换，读方要么看到旧字节要么看到新字节。
            atomic_write_bytes(self._current_path, body)

            # 3) 最后写 meta.json。若这里失败，进程内仍按新版本记账（内存、
            #    current.gz、history 已经一致），重启后由 _repair_if_needed 补齐。
            try:
                atomic_write_bytes(self._meta_path, _meta_bytes(meta))
            except OSError:
                self._meta = meta
                raise

            self._meta = meta
            try:
                self._gc_unlocked()
            except OSError as exc:  # 清理失败不影响这次已经成功的写入
                _LOG.warning("清理旧历史失败: %s", exc)
            return meta

    # -------------------------------------------------------------- 内部
    def _read_history_meta(self, revision: int) -> BackupMeta | None:
        path = self._history_dir / f"rev-{revision}.json"
        meta = _read_meta_file(path)
        if meta is None or meta.revision != revision:
            return None
        return meta

    def _history_metas_unlocked(self) -> list[BackupMeta]:
        items: list[BackupMeta] = []
        try:
            paths = list(self._history_dir.glob("rev-*.json"))
        except OSError:
            return items
        for path in paths:
            match = _HISTORY_FILE.match(path.name)
            if match is None:
                continue
            meta = _read_meta_file(path)
            if meta is None or meta.revision != int(match.group(1)):
                continue
            if not (self._history_dir / f"rev-{meta.revision}.gz").is_file():
                continue
            items.append(meta)
        return items

    def _gc_unlocked(self) -> None:
        current_revision = self._meta.revision if self._meta is not None else 0
        revisions: set[int] = set()
        try:
            entries = list(self._history_dir.iterdir())
        except OSError:
            return
        for entry in entries:
            match = _HISTORY_FILE.match(entry.name)
            if match is None:
                continue
            revision = int(match.group(1))
            if revision <= current_revision:
                revisions.add(revision)
        ordered = sorted(revisions, reverse=True)
        for revision in ordered[self.history_limit :]:
            for suffix in (".gz", ".json"):
                try:
                    (self._history_dir / f"rev-{revision}{suffix}").unlink(missing_ok=True)
                except OSError as exc:
                    _LOG.warning("删除旧历史 rev-%d%s 失败: %s", revision, suffix, exc)

    def _repair_if_needed(self) -> None:
        """启动自检：current.gz 与 meta.json 必须一致。

        - 一致：正常。
        - 不一致但 history 里有 ``revision + 1`` 且 sha256 相同：说明上次
          在 current.gz 替换后、meta.json 替换前崩溃，补写 meta.json。
        - 其它：视为没有可用备份（不猜测数据），等客户端重新上传。
        """
        meta = self._meta
        if meta is None:
            return
        try:
            size = self._current_path.stat().st_size
        except OSError:
            size = -1
        actual = _sha256_file(self._current_path)
        if actual is not None and actual == meta.sha256 and size == meta.size:
            return

        candidate: BackupMeta | None = None
        if actual is not None:
            for item in self._history_metas_unlocked():
                history_gz = self._history_dir / f"rev-{item.revision}.gz"
                if (
                    item.revision == meta.revision + 1
                    and item.sha256 == actual
                    and item.size == size
                    and history_gz.is_file()
                ):
                    candidate = item
                    break
        if candidate is not None:
            _LOG.warning(
                "meta.json 落后于 current.gz，按 history/rev-%d 恢复", candidate.revision
            )
            try:
                atomic_write_bytes(self._meta_path, _meta_bytes(candidate))
            except OSError as exc:
                _LOG.warning("补写 meta.json 失败: %s", exc)
            self._meta = candidate
            return

        _LOG.warning("current.gz 与 meta.json 不一致，视为没有可用备份")
        self._meta = None
