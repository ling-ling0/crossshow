# CrossShow API 服务镜像。
# 后端使用纯 Go SQLite 驱动（CGO_ENABLED=0），最终镜像含 tzdata 以满足
# "服务端打包时包含时区数据"（开发文档 5.1）。构建上下文必须是仓库根目录：
#   docker build -f deploy/Dockerfile .
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/crossshow-api ./cmd/api

FROM alpine:3.20
RUN apk add --no-cache tzdata ca-certificates \
    && addgroup -g 10001 app \
    && adduser -D -u 10001 -G app app
COPY --from=build /out/crossshow-api /usr/local/bin/crossshow-api
USER app
VOLUME ["/data"]
EXPOSE 8080
# 配置通过环境变量传入，见 deploy/docker-compose.yml 与 deploy/config.example.env
ENTRYPOINT ["/usr/local/bin/crossshow-api"]
