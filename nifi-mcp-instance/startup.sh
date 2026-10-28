#! /bin/bash
docker stop nifi-mcp-server
docker rm -f nifi-mcp-server
docker run -d --name nifi-mcp-server --env-file .env -p 3030:3030 --restart unless-stopped nifi-mcp-server:0.8.0
