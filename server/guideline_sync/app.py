"""组装 ThreadingHTTPServer 与 TLS 上下文。"""

from __future__ import annotations

import logging
import socket
import ssl

from http.server import ThreadingHTTPServer

from .config import Settings
from .handler import GuidelineSyncHandler
from .store import BackupStore

_LOG = logging.getLogger(__name__)


class SyncHTTPServer(ThreadingHTTPServer):
    """带 Settings / BackupStore 引用的线程服务器。"""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        settings: Settings,
        store: BackupStore,
    ) -> None:
        self.settings = settings
        self.store = store
        self.ssl_context: ssl.SSLContext | None = None
        if ":" in server_address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(server_address, GuidelineSyncHandler)

    def get_request(self):  # type: ignore[no-untyped-def]
        sock, addr = super().get_request()
        context = self.ssl_context
        if context is None:
            return sock, addr
        try:
            return context.wrap_socket(sock, server_side=True), addr
        except (ssl.SSLError, OSError):
            try:
                sock.close()
            except OSError:
                pass
            raise

    def handle_error(self, request, client_address) -> None:  # type: ignore[no-untyped-def]
        _LOG.exception("处理来自 %s 的连接时出错", client_address)


def build_tls_context(settings: Settings) -> ssl.SSLContext | None:
    """按配置构造 TLS 上下文；``GL_TLS=off`` 返回 ``None``。"""
    if not settings.tls:
        return None
    if settings.tls_cert is None or settings.tls_key is None:
        raise ValueError("启用 TLS 但缺少证书或私钥路径")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(str(settings.tls_cert), str(settings.tls_key))
    return context


def build_server(settings: Settings) -> SyncHTTPServer:
    """创建服务器（已绑定端口、套好 TLS），调用方负责 serve_forever / shutdown。"""
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    store = BackupStore(settings.data_dir, settings.history)
    context = build_tls_context(settings)
    server = SyncHTTPServer(
        (settings.bind_host, settings.bind_port), settings=settings, store=store
    )
    server.ssl_context = context
    return server
