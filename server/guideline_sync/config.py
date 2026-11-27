"""配置：集中从环境变量读取并校验。

所有可调项都在这里，其它模块只接收已经校验过的 :class:`Settings`。
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

#: 默认监听地址（首次部署建议改成 127.0.0.1 或防火墙白名单）
DEFAULT_BIND = "0.0.0.0:8443"
#: 默认数据目录
DEFAULT_DATA = "/var/lib/guideline-sync"
#: 默认 token 摘要文件（只含 64 位十六进制）
DEFAULT_TOKEN_FILE = "/etc/guideline-sync/token.sha256"
#: 默认历史保留条数
DEFAULT_HISTORY = 10
#: 默认单次上传上限（32 MiB）
DEFAULT_MAX_BYTES = 32 * 1024 * 1024

_HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")


class ConfigError(ValueError):
    """环境变量缺失或格式不合法。"""


@dataclass(frozen=True)
class Settings:
    """服务端运行参数。"""

    bind_host: str
    bind_port: int
    data_dir: Path
    tls: bool
    tls_cert: Path | None
    tls_key: Path | None
    token_sha256: str
    history: int
    max_bytes: int
    debug_log: bool

    @property
    def bind(self) -> str:
        """规范化的 ``host:port`` 文本（IPv6 带方括号）。"""
        host = f"[{self.bind_host}]" if ":" in self.bind_host else self.bind_host
        return f"{host}:{self.bind_port}"

    @property
    def scheme(self) -> str:
        return "https" if self.tls else "http"

    def summary(self) -> list[str]:
        """``--check`` 用的可读摘要；不包含 token 原文。"""
        if self.tls:
            tls_line = f"开启（证书 {self.tls_cert}，密钥 {self.tls_key}）"
        else:
            tls_line = "关闭（明文 HTTP，仅限本地测试，不要用于生产）"
        return [
            f"绑定地址: {self.bind}",
            f"数据目录: {self.data_dir}",
            f"TLS: {tls_line}",
            f"历史保留: {self.history} 条",
            f"请求体上限: {self.max_bytes} 字节",
            f"Token SHA-256: {self.token_sha256[:12]}…（只保存摘要）",
            f"日志级别: {'debug' if self.debug_log else 'info'}",
        ]

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Settings":
        """从映射（默认 ``os.environ``）构造并校验配置。"""
        source: Mapping[str, str] = os.environ if env is None else env

        bind_host, bind_port = _parse_bind(source.get("GL_BIND", DEFAULT_BIND))

        data_raw = source.get("GL_DATA", DEFAULT_DATA).strip()
        if not data_raw:
            raise ConfigError("GL_DATA 不能为空")
        data_dir = Path(data_raw)

        tls = _parse_tls(source.get("GL_TLS", ""))
        tls_cert: Path | None = None
        tls_key: Path | None = None
        if tls:
            cert_raw = source.get("GL_TLS_CERT", "").strip()
            key_raw = source.get("GL_TLS_KEY", "").strip()
            if not cert_raw:
                raise ConfigError("启用 TLS 时必须设置 GL_TLS_CERT")
            if not key_raw:
                raise ConfigError("启用 TLS 时必须设置 GL_TLS_KEY")
            tls_cert = Path(cert_raw)
            tls_key = Path(key_raw)
            _require_file(tls_cert, "GL_TLS_CERT")
            _require_file(tls_key, "GL_TLS_KEY")

        token_sha256 = _load_token_sha256(source)

        history = _parse_int(
            source.get("GL_HISTORY", ""), "GL_HISTORY", DEFAULT_HISTORY, minimum=1, maximum=100
        )
        max_bytes = _parse_int(
            source.get("GL_MAX_BYTES", ""), "GL_MAX_BYTES", DEFAULT_MAX_BYTES, minimum=1
        )
        debug_log = source.get("GL_LOG", "").strip().lower() == "debug"

        return cls(
            bind_host=bind_host,
            bind_port=bind_port,
            data_dir=data_dir,
            tls=tls,
            tls_cert=tls_cert,
            tls_key=tls_key,
            token_sha256=token_sha256,
            history=history,
            max_bytes=max_bytes,
            debug_log=debug_log,
        )


def load_settings(env: Mapping[str, str] | None = None) -> Settings:
    """``Settings.from_env`` 的便捷别名。"""
    return Settings.from_env(env)


def _parse_bind(raw: str) -> tuple[str, int]:
    text = raw.strip()
    if not text:
        raise ConfigError("GL_BIND 不能为空，格式为 host:port")
    if text.startswith("["):
        host, sep, rest = text[1:].partition("]")
        if not sep or not rest.startswith(":"):
            raise ConfigError(f"GL_BIND 格式不对: {raw!r}，IPv6 需写成 [::]:8443")
        port_text = rest[1:]
        host = host or "::"
    else:
        host, sep, port_text = text.rpartition(":")
        if not sep:
            raise ConfigError(f"GL_BIND 格式不对: {raw!r}，应为 host:port")
        host = host or "0.0.0.0"
    try:
        port = int(port_text, 10)
    except ValueError as exc:
        raise ConfigError(f"GL_BIND 端口不是整数: {port_text!r}") from exc
    # 0 表示让系统分配端口，只用于本地测试（生产部署应当固定端口）。
    if not 0 <= port <= 65535:
        raise ConfigError(f"GL_BIND 端口超出范围 0~65535: {port}")
    return host, port


def _parse_tls(raw: str) -> bool:
    value = raw.strip().lower()
    if value in ("", "on", "1", "true", "yes"):
        return True
    if value in ("off", "0", "false", "no"):
        return False
    raise ConfigError(f"GL_TLS 只能是 off 或 on（收到 {raw!r}）")


def _require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise ConfigError(f"{label} 指向的文件不存在: {path}")


def _load_token_sha256(source: Mapping[str, str]) -> str:
    inline = source.get("GL_TOKEN_SHA256", "").strip()
    if inline:
        if not _HEX64.match(inline):
            raise ConfigError("GL_TOKEN_SHA256 必须是 64 位十六进制")
        return inline.lower()

    token_file = Path(source.get("GL_TOKEN_FILE", DEFAULT_TOKEN_FILE).strip() or DEFAULT_TOKEN_FILE)
    try:
        content = token_file.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ConfigError(
            f"没有可用的 token 摘要：请设置 GL_TOKEN_SHA256，或提供 {token_file}"
        ) from exc
    if not _HEX64.match(content):
        raise ConfigError(f"{token_file} 必须只包含 64 位十六进制 token 摘要")
    return content.lower()


def _parse_int(
    raw: str,
    name: str,
    default: int,
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    value = raw.strip()
    if not value:
        return default
    try:
        parsed = int(value, 10)
    except ValueError as exc:
        raise ConfigError(f"{name} 必须是整数（收到 {raw!r}）") from exc
    if minimum is not None and parsed < minimum:
        raise ConfigError(f"{name} 不能小于 {minimum}（收到 {parsed}）")
    if maximum is not None and parsed > maximum:
        raise ConfigError(f"{name} 不能大于 {maximum}（收到 {parsed}）")
    return parsed
