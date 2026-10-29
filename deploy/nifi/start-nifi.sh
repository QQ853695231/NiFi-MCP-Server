#!/usr/bin/env bash
#
# Apache NiFi 2.12.0 Docker 启动脚本
# conf/日志/state/三类仓库/扩展目录 全部持久化到宿主机，删除容器不丢数据。
#
# ⚠️ 注意：如果服务器上已有旧的 nifi 容器在运行，本脚本会删除并重建它；
#    新数据目录是全新实例。要接管旧数据，请把 DATA_DIR 指向旧容器的挂载目录。
#
# 用法:
#   ./start-nifi.sh        启动（幂等，重复执行会重建容器，数据不丢）
#   ./start-nifi.sh stop   停止并删除容器（数据保留）
#   ./start-nifi.sh status 查看容器状态
#   ./start-nifi.sh logs   跟踪日志
#
set -euo pipefail

# ========================= 可按需修改 =========================
NIFI_VERSION="2.12.0"
CONTAINER_NAME="nifi"

# 宿主机监听端口（同时作为容器内 HTTPS 端口。两者一致可避免 Unknown Host 问题）
HTTPS_PORT="10443"
# Site-to-Site 远程输入端口（不做远程数据传输可删掉下面对应的 -p 映射）
SITE_TO_SITE_PORT="10000"

# 宿主机数据目录（conf/日志/state/仓库/敏感密钥全在这里）
DATA_DIR="/opt/tools/nifi/nifi-data"

# 自定义数据库驱动目录（用于存放 JDBC 驱动等）
CUSTOM_DRIVERS_DIR="${DATA_DIR}/custom_drivers"

# 单用户登录账号（NIFI_UI_USERNAME 留空 = 首次启动随机生成，用 docker logs 查看）
NIFI_UI_USERNAME="admin"
NIFI_UI_PASSWORD="NiFiAdmin123456"    # 必须 ≥12 位

# 服务器 IP（用于 NIFI_WEB_PROXY_HOST，防止 Unknown Host 访问报错）
PUBLIC_HOST="192.168.31.175"

# JVM 堆大小（按服务器内存调整；NiFi 最低建议 1g）
HEAP_INIT="1g"
HEAP_MAX="2g"

TZ_VALUE="Asia/Shanghai"
# =============================================================

IMAGE="apache/nifi:${NIFI_VERSION}"
NIFI_HOME="/opt/nifi/nifi-current"

# 需要持久化的目录（与官方镜像 Dockerfile 的 VOLUME 声明一一对应）
VOL_DIRS=(
  "conf"                  # 配置文件（nifi.properties / authorizers.xml 等）
  "logs"                  # 日志
  "state"                 # 组件本地状态
  "database_repository"   # 流程数据库（user/parameter 等持久化）
  "flowfile_repository"   # FlowFile 元数据
  "content_repository"    # FlowFile 内容
  "provenance_repository" # 数据溯源
  "python_extensions"     # 2.x Python 扩展
  "nar_extensions"        # 自定义 NAR 扩展
  "custom_drivers"        # 自定义数据库驱动等
)

info()  { echo -e "\033[32m[INFO]\033[0m $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m $*"; }
fatal() { echo -e "\033[31m[FATAL]\033[0m $*" >&2; exit 1; }

command -v docker >/dev/null || fatal "未找到 docker 命令"

SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

case "${1:-start}" in
  stop)
    docker rm -f "$CONTAINER_NAME" && info "已停止并移除容器 $CONTAINER_NAME（数据保留在 $DATA_DIR）"
    exit 0
    ;;
  status)
    docker ps -a --filter "name=^${CONTAINER_NAME}$"
    exit 0
    ;;
  logs)
    exec docker logs -f "$CONTAINER_NAME"
    ;;
  start) ;;
  *)
    fatal "用法: $0 {start|stop|status|logs}"
    ;;
esac

# ---- 校验单用户密码强度 ----
if [ -n "$NIFI_UI_USERNAME" ] && [ "${#NIFI_UI_PASSWORD}" -lt 12 ]; then
  fatal "NIFI_UI_PASSWORD 必须 ≥12 位（NiFi 单用户模式要求），当前长度 ${#NIFI_UI_PASSWORD}"
fi

# ---- 镜像就绪（离线机器需先 docker load）----
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  info "本地无镜像 $IMAGE，尝试拉取 ..."
  docker pull "$IMAGE" || fatal "拉取失败。离线机器请先在有网的机器上 docker save 镜像并拷贝后 docker load"
fi

# ---- 创建宿主机数据目录 ----
for d in "${VOL_DIRS[@]}"; do $SUDO mkdir -p "${DATA_DIR}/${d}"; done

# ---- 首次部署：从镜像提取默认 conf（挂载空 conf 目录会导致 NiFi 启动失败）----
if [ ! -f "${DATA_DIR}/conf/nifi.properties" ]; then
  info "首次部署：从镜像提取默认配置文件 -> ${DATA_DIR}/conf"
  cid=$(docker create "$IMAGE")
  docker cp "${cid}:${NIFI_HOME}/conf/." "${DATA_DIR}/conf/"
  docker rm "$cid" >/dev/null
fi

# ---- sensitive props key：加密流程中的敏感属性，必须跨重启一致 ----
KEY_FILE="${DATA_DIR}/.nifi_sensitive_props_key"
if [ ! -s "$KEY_FILE" ]; then
  (openssl rand -base64 24 | tr -d '\n' > "$KEY_FILE" 2>/dev/null) || \
    (head -c 24 /dev/urandom | base64 | tr -d '\n' > "$KEY_FILE")
  chmod 600 "$KEY_FILE"
  info "已生成 NIFI_SENSITIVE_PROPS_KEY -> ${KEY_FILE}"
  warn "请勿删除该文件，否则流程中已配置的敏感属性将无法解密"
fi
SENSITIVE_KEY="$(cat "$KEY_FILE")"

# ---- 目录属主对齐镜像内 nifi 用户 (uid/gid 1000) ----
$SUDO chown -R 1000:1000 "$DATA_DIR"

# ---- 幂等：删除同名旧容器 ----
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  warn "检测到已有容器 $CONTAINER_NAME，删除重建（数据在 $DATA_DIR 中，不会丢失）"
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

# ---- 组装挂载与环境变量 ----
VOL_ARGS=()
for d in "${VOL_DIRS[@]}"; do VOL_ARGS+=( -v "${DATA_DIR}/${d}:${NIFI_HOME}/${d}" ); done

ENV_ARGS=(
  -e "NIFI_WEB_HTTPS_PORT=${HTTPS_PORT}"
  -e "NIFI_WEB_HTTPS_HOST=0.0.0.0"
  -e "NIFI_WEB_PROXY_HOST=${PUBLIC_HOST}:${HTTPS_PORT},localhost:${HTTPS_PORT}"
  -e "NIFI_SENSITIVE_PROPS_KEY=${SENSITIVE_KEY}"
  -e "NIFI_JVM_HEAP_INIT=${HEAP_INIT}"
  -e "NIFI_JVM_HEAP_MAX=${HEAP_MAX}"
  -e "TZ=${TZ_VALUE}"
)
if [ -n "$NIFI_UI_USERNAME" ]; then
  ENV_ARGS+=( -e "SINGLE_USER_CREDENTIALS_USERNAME=${NIFI_UI_USERNAME}" )
  ENV_ARGS+=( -e "SINGLE_USER_CREDENTIALS_PASSWORD=${NIFI_UI_PASSWORD}" )
fi

info "启动 ${IMAGE} ..."
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --init \
  -p "${HTTPS_PORT}:${HTTPS_PORT}" \
  "${VOL_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "$IMAGE"

echo
info "容器已启动，NiFi 完全就绪约需 1~3 分钟（看 CPU）"
info "Web UI:   https://${PUBLIC_HOST}:${HTTPS_PORT}/nifi"
if [ -n "$NIFI_UI_USERNAME" ]; then
  info "登录账号: ${NIFI_UI_USERNAME} / ${NIFI_UI_PASSWORD}"
else
  info "随机账号: docker logs ${CONTAINER_NAME} | grep Generated"
fi
info "日志:     docker logs -f ${CONTAINER_NAME}"
info "自定义驱动: ${CUSTOM_DRIVERS_DIR}"
echo
info "配套的 nifi-mcp-server 环境变量（写入其 .env 即可对接）："
echo "  NIFI_API_BASE=https://${PUBLIC_HOST}:${HTTPS_PORT}/nifi-api"
echo "  NIFI_USERNAME=${NIFI_UI_USERNAME}"
echo "  NIFI_PASSWORD=${NIFI_UI_PASSWORD}"
echo "  KNOX_VERIFY_SSL=false"