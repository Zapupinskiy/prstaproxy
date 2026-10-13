FROM golang:1.26.5-bookworm AS build
ARG RELAY_COMMIT=c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8
WORKDIR /src
RUN git init && git remote add origin https://github.com/telegramdesktop/tproxy-server.git && git fetch --depth 1 origin "$RELAY_COMMIT" && git checkout FETCH_HEAD
RUN go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /tproxy-server ./cmd/tproxy-server
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY --from=build /tproxy-server /usr/local/bin/tproxy-server
ENTRYPOINT ["tproxy-server", "-config", "/etc/tproxy-server/config.json"]
