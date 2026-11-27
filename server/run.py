#!/usr/bin/env python3
"""入口：加载配置、启动 HTTPS 同步服务。

用法::

    python3 run.py            # 读取环境变量并启动
    python3 run.py --check    # 只做配置自检，打印摘要后退出
"""

from __future__ import annotations

import argparse
import logging
import signal
import sys
import threading
from typing import Sequence

from guideline_sync.app import build_server
from guideline_sync.config import ConfigError, load_settings

_LOG = logging.getLogger("guideline_sync")


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="guideline-sync",
        description="GuideLine 整份数据备份同步服务（只用 Python 标准库）",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="只加载并校验配置，打印绑定地址 / 数据目录 / 是否 TLS 后退出",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)

    try:
        settings = load_settings()
    except ConfigError as exc:
        print(f"配置错误: {exc}", file=sys.stderr)
        return 2

    logging.basicConfig(
        level=logging.DEBUG if settings.debug_log else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    for line in settings.summary():
        print(line, flush=True)

    if args.check:
        return 0

    try:
        server = build_server(settings)
    except Exception:  # 配置已校验过，这里多半是绑定失败或证书/权限问题
        _LOG.exception("启动失败")
        return 1

    stop_requested = threading.Event()

    def _request_shutdown(signum: int, _frame: object) -> None:
        if stop_requested.is_set():
            return
        stop_requested.set()
        _LOG.info("收到信号 %s，正在关闭", signum)
        # shutdown() 会阻塞到 serve_forever 退出，必须放到另一个线程里调用，
        # 否则信号处理函数会在主线程死锁。
        threading.Thread(target=server.shutdown, name="shutdown", daemon=True).start()

    for signame in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(signame, _request_shutdown)
        except (ValueError, OSError):  # 非主线程 / 平台不支持
            _LOG.warning("无法注册信号 %s", signame)

    _LOG.info("guideline-sync 已启动: %s://%s", settings.scheme, settings.bind)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        _LOG.info("guideline-sync 已关闭")
    return 0


if __name__ == "__main__":
    sys.exit(main())
