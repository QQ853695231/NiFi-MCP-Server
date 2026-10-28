FROM swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/python:3.12-slim

LABEL org.opencontainers.image.title="nifi-mcp-server" \
      org.opencontainers.image.description="MCP server for Apache NiFi behind Knox with flow building capabilities" \
      org.opencontainers.image.version="0.8.0" \
      org.opencontainers.image.licenses="Apache-2.0"

# Container defaults: run as an HTTP MCP service reachable from outside.
# stdio mode is only useful when the client spawns the process itself (Claude Desktop local).
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    MCP_TRANSPORT=streamable-http \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=3030

WORKDIR /app

# PyPI mirror default: TUNA (directly reachable from China mainland networks).
# Override if needed: docker build --build-arg PIP_INDEX_URL=https://pypi.org/simple .
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

COPY pyproject.toml README.md ./
COPY src ./src
RUN pip install --no-cache-dir --index-url "${PIP_INDEX_URL}" .

# Run as non-root user
RUN useradd --create-home --uid 1000 mcp
USER mcp

EXPOSE 3030

# TCP-level liveness check (transport-agnostic, works for sse and streamable-http)
HEALTHCHECK --interval=30s --timeout=6s --start-period=15s --retries=3 \
    CMD python -c "import os,socket; socket.create_connection(('127.0.0.1', int(os.getenv('MCP_PORT','3030'))), timeout=4).close()"

ENTRYPOINT ["python", "-m", "nifi_mcp_server.server"]
