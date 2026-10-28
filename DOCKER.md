# Docker 部署指南（含离线部署）

将 nifi-mcp-server 打包为 Docker 镜像部署，无需在目标机上装 Python 环境。配置全部走环境变量。

## 镜像说明

- 基础镜像 `python:3.12-slim`，非 root 用户运行
- 依赖安装默认使用**清华 TUNA pip 镜像源**（`https://pypi.tuna.tsinghua.edu.cn/simple`），国内网络可直连构建
- 默认 `MCP_TRANSPORT=streamable-http`，监听 `0.0.0.0:3030`
- MCP 端点：
  - streamable-http 模式 → `http://<服务器IP>:3030/mcp`
  - sse 模式（`MCP_TRANSPORT=sse`）→ `http://<服务器IP>:3030/sse`
- 自带 TCP 级健康检查（`docker ps` 中显示 `healthy`）

## 1. 在线构建（有外网或内网 pip 镜像）

```bash
# 1) 准备配置
cp .env.example .env
vi .env        # 必填 NIFI_API_BASE，通常还需 KNOX_TOKEN

# 2) 构建并启动（pip 源默认已指向清华 TUNA 镜像，国内可直连）
docker compose up -d

# 如需换源，可在 .env 中修改 PIP_INDEX_URL（阿里云/腾讯云/官方），或构建时显式覆盖：
# docker compose build --build-arg PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
```

不使用 compose 时直接用 docker CLI：

```bash
docker build -t nifi-mcp-server:0.8.0 .
docker run -d --name nifi-mcp-server \
  --env-file .env \
  -p 3030:3030 \
  --restart unless-stopped \
  nifi-mcp-server:0.8.0
```

## 2. 完全离线部署（目标机无外网）

思路：**在能联网的机器上构建镜像 → `docker save` 导出 tar → 拷贝到目标机 → `docker load` 导入**。目标机只需要 tar 文件、`docker-compose.yml`（可选）和 `.env`。

### ① 在能联网的机器上构建并导出

Windows PowerShell（本仓库开发机）：

```powershell
docker build -t nifi-mcp-server:0.8.0 .
# pip 源默认清华镜像，国内可直连；如需换源：
# docker build -t nifi-mcp-server:0.8.0 --build-arg PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/ .
docker save -o nifi-mcp-server-0.8.0.tar nifi-mcp-server:0.8.0
```

Linux：

```bash
docker build -t nifi-mcp-server:0.8.0 .
docker save -o nifi-mcp-server-0.8.0.tar nifi-mcp-server:0.8.0
```

### ② 传输到目标服务器

U 盘 / scp / 内网共享均可，例如：

```bash
scp nifi-mcp-server-0.8.0.tar user@target-server:/opt/nifi-mcp/
```

### ③ 目标服务器导入并运行

```bash
docker load -i /opt/nifi-mcp/nifi-mcp-server-0.8.0.tar
docker images | grep nifi-mcp-server   # 确认镜像已导入

# 准备配置（只需要 .env 文件，无需源码；从仓库拷 .env.example 改名编辑）
vi /opt/nifi-mcp/.env

# 方式 A：直接 run
docker run -d --name nifi-mcp-server \
  --env-file /opt/nifi-mcp/.env \
  -p 3030:3030 \
  --restart unless-stopped \
  nifi-mcp-server:0.8.0
```

方式 B：目标机放一份 `docker-compose.yml`（把 `build:` 段删掉，保留 `image: nifi-mcp-server:0.8.0`），然后：

```bash
cd /opt/nifi-mcp && docker compose up -d
```

> 注意：容器内请使用 `streamable-http` 或 `sse` 传输模式。`stdio` 是给本地客户端直启进程用的，容器里没有监听端口，健康检查会一直失败。

## 3. 验证部署

```bash
docker ps                                          # STATUS 应为 Up (healthy)
docker logs -f nifi-mcp-server                     # 应无报错

# 探活 MCP 端点（返回 200 即正常）
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3030/mcp \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

## 4. 环境变量一览

| 变量 | 必填 | 说明 |
|---|---|---|
| `NIFI_API_BASE` | 是* | NiFi API 完整 URL（CDP 例：`https://host/nifi-2-dh/cdp-proxy/nifi-app/nifi-api`）|
| `KNOX_GATEWAY_URL` | 否* | Knox 网关 URL（替代 `NIFI_API_BASE`）|
| `KNOX_TOKEN` | 是* | Knox JWT（CDP 推荐，以 `hadoop-jwt` Cookie 发送）|
| `KNOX_COOKIE` | 否 | 完整 Cookie 串（替代 token，优先级最高）|
| `KNOX_USER` / `KNOX_PASSWORD` | 否 | Basic 认证换 JWT（需 `KNOX_TOKEN_ENDPOINT`）|
| `KNOX_TOKEN_ENDPOINT` | 否 | Knox token 端点，默认 `<gateway>/knoxtoken/api/v1/token` |
| `KNOX_PASSCODE_TOKEN` | No | passcode token（自动换取 JWT）|
| `NIFI_USERNAME` / `NIFI_PASSWORD` | 否* | **自建 NiFi（非 Knox）用户名密码登录**：启动自动换取 JWT，过期自动续签 |
| `NIFI_TOKEN` | 否* | 手动获取的 NiFi JWT，以 `Authorization: Bearer` 发送（与上面二选一）|
| `NIFI_TOKEN_ENDPOINT` | 否 | NiFi 登录端点，默认 `{NIFI_API_BASE}/access/token` |
| `NIFI_READONLY` | 否 | 只读模式，默认 `true`；`false` 开放写操作 |
| `KNOX_VERIFY_SSL` | 否 | 校验 SSL 证书，默认 `true` |
| `KNOX_CA_BUNDLE` | 否 | CA 证书包路径（容器内路径，配合 volume 挂载）|
| `NIFI_PROXY_CONTEXT_PATH` | 否 | CDP 代理上下文路径（`X-ProxyContextPath` 头）|
| `HTTP_TIMEOUT_SECONDS` | 否 | HTTP 超时，默认 `30` |
| `HTTP_MAX_RETRIES` | 否 | HTTP 重试次数，默认 `3` |
| `MCP_TRANSPORT` | 否 | `streamable-http`（容器默认）/ `sse` / `stdio` |
| `MCP_HOST` | 否 | HTTP 绑定地址，容器内必须 `0.0.0.0` |
| `MCP_PORT` | 否 | HTTP 绑定端口，默认 `3030`（同时用于宿主机映射）|

\* `NIFI_API_BASE` 或 `KNOX_GATEWAY_URL` 至少一个；认证至少配置一种方式。

## 5. 连接自建 NiFi（非 Knox/CDP）

如果你的 NiFi 是自己部署的（例如 `https://192.168.31.175:10443`，Docker 部署），**不需要任何 Knox 配置**，`.env` 这样写：

```env
NIFI_API_BASE=https://192.168.31.175:10443/nifi-api
NIFI_USERNAME=<你的NiFi用户名>
NIFI_PASSWORD=<你的NiFi密码>
KNOX_VERIFY_SSL=false     # 内网自签名证书时需要；有正规CA证书可删掉这行
NIFI_READONLY=true
```

要点：

- **用户名密码去哪找**：NiFi 默认开启单用户模式，首次启动自动生成账号密码，存在 NiFi 容器的 `conf/authorizers.xml` 里（`single-user-login-identity-provider`）。查看：
  ```bash
  docker exec <nifi容器名> sh -c "grep -B2 -A6 'single-user' /opt/nifi/nifi-current/conf/authorizers.xml"
  ```
  如果你后来配置了自己的管理员账号/LDAP，就用你平时登录 NiFi Web UI 的账号密码。
- **token 自动续签**：用户名密码方式下，服务启动时自动 `POST /access/token` 换 JWT，token 过期（NiFi 默认 12 小时）触发 401 时会自动重新登录，容器长期运行无需人工干预。
- **HTTP 还是 HTTPS**：10443 若是 HTTPS 用 `https://`；如果你的 NiFi 跑的是 HTTP，改用 `http://192.168.31.175:10443/nifi-api`，且无需 SSL 相关配置。
- **网络可达性**：nifi-mcp-server 容器访问 `192.168.31.175` 走正常路由/NAT；如果两者在同一台宿主机上，用宿主机 IP 即可（也可以用 `host.docker.internal`）。
- **不启用认证的 NiFi**：如果你的 NiFi 关闭了登录认证，以上认证变量全部不填即可（匿名访问）。

在容器里手动验证认证是否通：

```bash
docker exec nifi-mcp-server python -c "import os,requests; r=requests.post(os.environ['NIFI_API_BASE'].rstrip('/')+'/access/token', data={'username':os.environ['NIFI_USERNAME'],'password':os.environ['NIFI_PASSWORD']}, verify=os.getenv('KNOX_VERIFY_SSL','true').lower()!='false', timeout=10); print(r.status_code, r.text[:30])"
```

返回 `200 eyJ...`（JWT 开头）说明认证配置正确。

## 6. 客户端接入

### Claude Desktop / Claude Code（本地 → 远程容器）

容器是 HTTP 服务，本地客户端通过桥接工具接入：

```json
{
  "mcpServers": {
    "nifi": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://<服务器IP>:3030/mcp"]
    }
  }
}
```

### 原生支持 streamable-http 的 MCP 客户端

直接填 URL：`http://<服务器IP>:3030/mcp`

## 7. 自签名证书 / 内网 CA

把 CA 证书放到宿主机 `./certs/ca-bundle.crt`，并在 `.env` 中设置：

```env
KNOX_CA_BUNDLE=/certs/ca-bundle.crt
```

compose 默认把 `./certs` 只读挂载到容器 `/certs`。临时调试也可 `KNOX_VERIFY_SSL=false`（不建议生产使用）。

## 8. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 构建时拉取基础镜像 `python:3.12-slim` 失败/超时 | Docker Hub 在国外，可能同样被墙。给 Docker 配置镜像加速：Docker Desktop → Settings → Docker Engine，在 JSON 中加 `"registry-mirrors": ["https://docker.1ms.run", "https://docker.m.daocloud.io"]` 后重启；Linux 则写入 `/etc/docker/daemon.json` 后 `systemctl restart docker`。或者从能联网的机器 `docker save`/`docker load` 整个镜像（见第 2 节） |
| pip 安装依赖超时 | 确认使用了国内源（默认已是清华源）；可在 `.env` 换阿里云源后重新构建 |
| 容器 `unhealthy` | 用了 stdio 模式（无监听端口）→ 改 `MCP_TRANSPORT=streamable-http`；或改了 `MCP_PORT` 但映射端口没同步 |
| 所有请求 401 | `KNOX_TOKEN` 模式：token 过期 → 更新 `.env` 后 `docker compose up -d` 重建容器。`NIFI_USERNAME/NIFI_PASSWORD` 模式会自动重新登录续签；若仍 401 说明账号密码或端点不对，见第 5 节的验证命令 |
| `Set NIFI_API_BASE...` 报错 | `.env` 未设置必填变量 |
| 端口被占用 | 修改 `.env` 中的 `MCP_PORT` |
| 连接 NiFi 报 SSL 错误 | 配 `KNOX_CA_BUNDLE`（见第 6 节），勿长期关闭校验 |
| 无法创建/修改流程 | 默认只读 → `NIFI_READONLY=false` 后重建容器，⚠️ 谨慎开启 |
