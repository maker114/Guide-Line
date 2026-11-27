"""BackupStore 的单元测试：版本、原子写与历史保留。"""

from __future__ import annotations

import gzip
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

SERVER_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_ROOT))

from guideline_sync.store import BackupMeta, BackupStore, VersionConflict  # noqa: E402


def payload(text: str) -> bytes:
    return gzip.compress(text.encode("utf-8"), mtime=0)


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class BackupStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="guideline-store-")
        self.data_dir = Path(self._tmp.name) / "data"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def make_store(self, history_limit: int = 10) -> BackupStore:
        return BackupStore(self.data_dir, history_limit)

    def read_meta_json(self) -> dict:
        return json.loads((self.data_dir / "meta.json").read_text(encoding="utf-8"))

    def test_first_put_writes_all_files(self) -> None:
        store = self.make_store()
        body = payload("first")
        meta = store.put(
            body,
            base_revision=0,
            saved_at=1_700_000_000_000,
            record_count=7,
            app_version="2.1.0",
        )

        self.assertEqual(meta.revision, 1)
        self.assertEqual(meta.sha256, sha(body))
        self.assertEqual(meta.size, len(body))
        self.assertEqual(meta.savedAt, 1_700_000_000_000)
        self.assertEqual(meta.recordCount, 7)
        self.assertEqual(meta.appVersion, "2.1.0")
        self.assertGreater(meta.updatedAt, 0)

        self.assertEqual((self.data_dir / "current.gz").read_bytes(), body)
        self.assertEqual((self.data_dir / "history" / "rev-1.gz").read_bytes(), body)
        self.assertEqual(self.read_meta_json(), meta.to_dict())
        self.assertEqual(store.current(), meta)
        self.assertEqual(store.read_current(), (meta, body))
        self.assertEqual(store.read_revision(1), (meta, body))
        self.assertEqual(store.history(), [meta])
        self.assertIsNone(store.read_revision(2))

    def test_revision_increments_and_history_is_newest_first(self) -> None:
        store = self.make_store()
        saved: list[bytes] = []
        meta = None
        for index in range(3):
            body = payload(f"payload-{index}")
            saved.append(body)
            meta = store.put(
                body,
                base_revision=meta.revision if meta else 0,
                saved_at=1_700_000_000_000 + index,
            )
            self.assertEqual(meta.revision, index + 1)

        assert meta is not None
        self.assertEqual(store.current(), meta)
        self.assertEqual(store.read_current(), (meta, saved[-1]))
        self.assertEqual([item.revision for item in store.history()], [3, 2, 1])
        self.assertEqual(store.read_revision(2), (store.history()[1], saved[1]))

    def test_version_conflict_leaves_files_untouched(self) -> None:
        store = self.make_store()
        body = payload("original")
        store.put(body, base_revision=0, saved_at=1_700_000_000_000)

        current_before = (self.data_dir / "current.gz").read_bytes()
        meta_before = (self.data_dir / "meta.json").read_bytes()
        history_before = sorted(
            path.name for path in (self.data_dir / "history").iterdir()
        )

        with self.assertRaises(VersionConflict) as caught:
            store.put(payload("conflict"), base_revision=0, saved_at=1_700_000_000_001)
        self.assertEqual(caught.exception.current_revision, 1)

        self.assertEqual((self.data_dir / "current.gz").read_bytes(), current_before)
        self.assertEqual((self.data_dir / "meta.json").read_bytes(), meta_before)
        self.assertEqual(
            sorted(path.name for path in (self.data_dir / "history").iterdir()),
            history_before,
        )
        self.assertEqual(store.current().revision, 1)
        self.assertEqual(store.read_current()[1], body)

    def test_history_keeps_only_latest_n(self) -> None:
        store = self.make_store(history_limit=3)
        meta = None
        for index in range(5):
            meta = store.put(
                payload(f"rev-{index}"),
                base_revision=meta.revision if meta else 0,
                saved_at=1_700_000_000_000 + index,
            )

        self.assertEqual([item.revision for item in store.history()], [5, 4, 3])
        for revision in (1, 2):
            self.assertFalse((self.data_dir / "history" / f"rev-{revision}.gz").exists())
            self.assertFalse(
                (self.data_dir / "history" / f"rev-{revision}.json").exists()
            )
            self.assertIsNone(store.read_revision(revision))
        for revision in (3, 4, 5):
            self.assertTrue((self.data_dir / "history" / f"rev-{revision}.gz").exists())
            self.assertTrue(
                (self.data_dir / "history" / f"rev-{revision}.json").exists()
            )
            self.assertIsNotNone(store.read_revision(revision))

    def test_meta_always_matches_bytes_after_put(self) -> None:
        store = self.make_store()
        meta = None
        for index in range(3):
            body = payload(f"consistent-{index}")
            meta = store.put(
                body,
                base_revision=meta.revision if meta else 0,
                saved_at=1_700_000_000_000 + index,
                record_count=index,
                app_version=f"1.0.{index}",
            )

            on_disk = self.read_meta_json()
            current = (self.data_dir / "current.gz").read_bytes()
            hist_json = json.loads(
                (self.data_dir / "history" / f"rev-{meta.revision}.json").read_text(
                    encoding="utf-8"
                )
            )
            hist_gz = (self.data_dir / "history" / f"rev-{meta.revision}.gz").read_bytes()

            self.assertEqual(on_disk, meta.to_dict())
            self.assertEqual(on_disk["sha256"], sha(current))
            self.assertEqual(on_disk["size"], len(current))
            self.assertEqual(current, body)
            self.assertEqual(hist_json, on_disk)
            self.assertEqual(hist_gz, body)

        self.assertEqual(store.current().revision, 3)

    def test_orphan_history_file_is_ignored_on_restart(self) -> None:
        store = self.make_store()
        body = payload("real")
        meta = store.put(body, base_revision=0, saved_at=1_700_000_000_000)

        orphan_body = b"orphan-not-a-real-revision"
        orphan_meta = BackupMeta(
            revision=2,
            sha256=sha(orphan_body),
            size=len(orphan_body),
            savedAt=1_700_000_000_001,
            recordCount=0,
            appVersion="orphan",
            updatedAt=1_700_000_000_001,
        )
        history_dir = self.data_dir / "history"
        (history_dir / "rev-2.gz").write_bytes(orphan_body)
        (history_dir / "rev-2.json").write_text(
            json.dumps(orphan_meta.to_dict()), encoding="utf-8"
        )

        reopened = self.make_store()
        self.assertEqual(reopened.current(), meta)
        self.assertEqual(reopened.read_current(), (meta, body))
        self.assertEqual([item.revision for item in reopened.history()], [1])
        self.assertIsNone(reopened.read_revision(2))

    def test_stale_meta_is_recovered_from_history(self) -> None:
        store = self.make_store()
        first = payload("first")
        store.put(first, base_revision=0, saved_at=1_700_000_000_000)
        stale_meta = (self.data_dir / "meta.json").read_bytes()

        second = payload("second")
        second_meta = BackupMeta(
            revision=2,
            sha256=sha(second),
            size=len(second),
            savedAt=1_700_000_000_001,
            recordCount=1,
            appVersion="1.0.0",
            updatedAt=1_700_000_000_001,
        )
        history_dir = self.data_dir / "history"
        (history_dir / "rev-2.gz").write_bytes(second)
        (history_dir / "rev-2.json").write_text(
            json.dumps(second_meta.to_dict()), encoding="utf-8"
        )
        (self.data_dir / "current.gz").write_bytes(second)
        (self.data_dir / "meta.json").write_bytes(stale_meta)

        reopened = self.make_store()
        self.assertEqual(reopened.current(), second_meta)
        self.assertEqual(reopened.read_current(), (second_meta, second))
        self.assertEqual(self.read_meta_json(), second_meta.to_dict())

    def test_invalid_writes_are_rejected(self) -> None:
        store = self.make_store()
        with self.assertRaises(ValueError):
            store.put(b"", base_revision=0, saved_at=1)
        with self.assertRaises(VersionConflict) as caught:
            store.put(b"x", base_revision=3, saved_at=1)
        self.assertEqual(caught.exception.current_revision, 0)
        self.assertIsNone(store.current())


if __name__ == "__main__":
    unittest.main()
