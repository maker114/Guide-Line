# guideline-sync

GuideLine 整份数据的备份同步服务端。Python 3.10+，**只用标准库**；客户端把整份数据打包成 gzip 后上传，服务端原样保存字节、只做版本号与历史管理。

## 目录结构

```
server/
├── run.py                     # 入口：读环境变量、起 HTTPS 服务；--check 自检
├── guideline_sync/
│   ├── __init__.py
│   ├── config.py              # Settings：环境变量读取与校验
│   ├── store.py               # 备份存储：原子写、版本号、历史保留
│   ├── handler.py             # HTTP 路由与 Bearer 鉴权
│   └── app.py                 # 组装 ThreadingHTTPServer / SSLContext
├── tests/
│   ├── test_store.py
│   └── test_api.py
├── deploy/guideline-sync.service
└── README.md
```

开发期运行（不装任何依赖）：

```bash
python3 -m unittest discover -s server/tests -v
python3 server/run.py --check          # 打印绑定地址 / 数据目录 / 是否 TLS
```

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `GL_BIND` | `0.0.0.0:8443` | 监听地址；IPv6 写成 `[::]:8443`；端口 `0` 表示随机端口，仅测试用 |
| `GL_DATA` | `/var/lib/guideline-sync` | 数据目录，须对运行用户可写 |
| `GL_TLS` | `on` | `off` = 明文 HTTP，**仅限本机测试** |
| `GL_TLS_CERT` | 无 | TLS 证书路径；启用 TLS 时必填 |
| `GL_TLS_KEY` | 无 | TLS 私钥路径；启用 TLS 时必填 |
| `GL_TOKEN_SHA256` | 无 | 64 位十六进制 SHA-256，优先于 token 文件 |
| `GL_TOKEN_FILE` | `/etc/guideline-sync/token.sha256` | 只含 64 位十六进制的文件 |
| `GL_HISTORY` | `10` | 历史保留条数，1~100（含当前版本） |
| `GL_MAX_BYTES` | `33554432` | 单次 PUT 上限，默认 32 MiB |
| `GL_LOG` | 空 | `debug` 时逐行打印请求方法 / 路径 / 状态 |

服务端只保存 token 的 SHA-256 摘要，请求时用 `hmac.compare_digest` 比较；token 原文不会落盘。

## HTTP API

除 `/healthz` 外，所有 `/v1/*` 都要 `Authorization: Bearer <token>`，否则 `401`。错误响应统一为 `{"error":"...","message":"..."}`；`409` 额外带 `currentRevision`。

| 方法 | 路径 | 成功 | 说明 |
|---|---|---|---|
| GET | `/healthz` | 200 JSON | `{"ok":true,"service":"guideline-sync","api":1}`，无需鉴权 |
| GET | `/v1/backup` | 200 gzip | 原样字节；头 `X-Backup-Revision/Sha256/Saved-At`、`X-Record-Count`、`X-App-Version`；没有备份时 404 `empty` |
| HEAD | `/v1/backup` | 200 | 与 GET 相同的头，无 body |
| GET | `/v1/backup/meta` | 200 JSON | 元数据；没有备份时 404 `empty` |
| PUT | `/v1/backup` | 201 JSON | 上传新版本；带 `X-Backup-*` 响应头 |
| GET | `/v1/history` | 200 JSON | `{"items":[meta...]}`，新的在前，最多 `GL_HISTORY` 条 |
| GET | `/v1/history/{revision}` | 200 gzip | 取历史版本；不存在 404 |

PUT 请求头：

- `X-Base-Revision`（必填）：客户端看到的当前版本，`0` 表示首次创建。
- `X-Backup-Saved-At`（必填）：客户端保存时间，Unix 毫秒。
- `X-Record-Count`（可选，默认 0）。
- `X-App-Version`（可选，服务端截到 40 字符）。

`X-Base-Revision` 与当前版本不一致时返回 `409 {"error":"version_conflict","currentRevision":n}`，不会改动任何数据；请求体超过 `GL_MAX_BYTES` 返回 `413`，空 body 返回 `400`。服务端不解析 gzip 内容。

## 存储与一致性

`GL_DATA` 下：

```
current.gz             最新一份原始字节
meta.json              当前版本元数据
history/rev-<n>.gz     历史字节（含当前版本）
history/rev-<n>.json   历史元数据
```

写入顺序是 `history/` → `current.gz` → `meta.json`，每步都走“同目录临时文件 + `fsync` + `os.replace`”。写入和版本判定在同一把 `threading.Lock` 里，并发 PUT 只有一个能成功。若进程在 `current.gz` 已替换、`meta.json` 未替换之间崩溃，下次启动会按 `history/rev-<n+1>` 补写元数据；只留下孤儿历史文件时则直接忽略。历史只保留最近 `GL_HISTORY` 条。

## systemd 部署（Debian/Ubuntu 示例）

1. 建用户和目录：

   ```bash
   sudo useradd --system --home /var/lib/guideline-sync --shell /usr/sbin/nologin guideline
   sudo install -d -o guideline -g guideline -m 0700 /var/lib/guideline-sync
   sudo install -d -o root -g root -m 0755 /opt/guideline-sync
   sudo cp -r server/guideline_sync server/run.py /opt/guideline-sync/
   sudo install -d -o root -g guideline -m 0750 /etc/guideline-sync
   ```

2. 生成自签证书（把 `203.0.113.10` 换成服务器公网 IP；本机 curl 自测再加 `IP:127.0.0.1`）：

   ```bash
   sudo openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
     -keyout /etc/guideline-sync/tls.key \
     -out /etc/guideline-sync/tls.crt \
     -subj "/CN=guideline-sync" \
     -addext "subjectAltName=IP:203.0.113.10,IP:127.0.0.1"
   sudo chown root:guideline /etc/guideline-sync/tls.key
   sudo chmod 0640 /etc/guideline-sync/tls.key
   sudo chmod 0644 /etc/guideline-sync/tls.crt
   ```

   客户端固定指纹用：

   ```bash
   openssl x509 -in /etc/guideline-sync/tls.crt -noout -fingerprint -sha256
   ```

3. 生成 token 与它的 SHA-256：

   ```bash
   TOKEN=$(openssl rand -hex 32)
   printf '%s' "$TOKEN" | sha256sum | awk '{print $1}' | sudo tee /etc/guideline-sync/token.sha256 >/dev/null
   sudo chown root:guideline /etc/guideline-sync/token.sha256
   sudo chmod 0640 /etc/guideline-sync/token.sha256
   printf '%s\n' "$TOKEN"    # 立刻存进密码管理器，服务端不可恢复原文
   ```

4. 写 `/etc/guideline-sync/env`（root 可读即可，systemd 以 root 读取后再降权）：

   ```bash
   sudo install -m 0600 /dev/null /etc/guideline-sync/env
   sudo tee /etc/guideline-sync/env >/dev/null <<'EOF'
   GL_BIND=0.0.0.0:8443
   GL_DATA=/var/lib/guideline-sync
   GL_TLS_CERT=/etc/guideline-sync/tls.crt
   GL_TLS_KEY=/etc/guideline-sync/tls.key
   GL_TOKEN_FILE=/etc/guideline-sync/token.sha256
   GL_HISTORY=10
   GL_MAX_BYTES=33554432
   EOF
   ```

   生产环境不要写 `GL_TLS=off`。

5. 安装服务并自检：

   ```bash
   sudo install -m 0644 server/deploy/guideline-sync.service /etc/systemd/system/guideline-sync.service
   sudo bash -c 'set -a; . /etc/guideline-sync/env; set +a; python3 /opt/guideline-sync/run.py --check'
   sudo systemctl daemon-reload
   sudo systemctl enable --now guideline-sync
   sudo systemctl status guideline-sync --no-pager
   ```

   `--check` 只校验配置（token / 证书是否可读、端口是否合法），不会创建数据目录。日志：`sudo journalctl -u guideline-sync -f`。`SIGTERM` 会走正常关闭流程。

## curl 自测

```bash
# 1) 健康检查（不需要 token）
curl -fsS --cacert /etc/guideline-sync/tls.crt https://127.0.0.1:8443/healthz

# 2) 首次上传（TOKEN 换成第 3 步生成的原文）
TOKEN='<你的 token>'
printf 'self-test' | gzip -c > /tmp/backup.gz
curl -fsS -X PUT https://127.0.0.1:8443/v1/backup \
  --cacert /etc/guideline-sync/tls.crt \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Base-Revision: 0" \
  -H "X-Backup-Saved-At: $(date +%s%3N)" \
  -H "X-Record-Count: 0" \
  -H "Content-Type: application/gzip" \
  --data-binary @/tmp/backup.gz
```

读回用 `curl --cacert ... -H "Authorization: Bearer $TOKEN" https://127.0.0.1:8443/v1/backup -o current.gz`。

## 安全边界

- **单 token**：所有客户端共用同一个 token，没有用户体系、没有按设备区分权限；只适合自用。
- **不复用**：这个 token 只给 guideline-sync；不要和别的服务、GitHub、密码复用。怀疑泄露就生成新 token，更新 `token.sha256` 后重启服务。
- **只在自建服务器上用**：不要部署到不信任的共享主机；建议防火墙只放行自己的出口 IP，或把 `GL_BIND` 改成 `127.0.0.1` 再由反向代理转发。
- **TLS 固定指纹**：证书是自签的，客户端不要关闭校验，而是固定证书的 SHA-256 指纹（见上面的 `openssl ... -fingerprint`）；指纹变了就拒绝连接。
- **不是加密备份**：服务端保存的是客户端上传的 gzip 原字节，没有额外加密；数据目录权限保持 `0700`，主机被攻破就等于备份泄露。
- `GL_TLS=off` 只用于本机测试，会在网络上明文传输 Bearer token 和整份备份，**不要在生产环境使用**。
