FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl build-essential libssl-dev zlib1g-dev
WORKDIR /src
RUN curl -fsSL https://github.com/TelegramMessenger/MTProxy/archive/f36d8af769ffaeac36978d38c2c0f6d1104c2137.tar.gz -o /tmp/src.tar.gz && echo '919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655  /tmp/src.tar.gz' | sha256sum -c - && tar --strip-components=1 -xzf /tmp/src.tar.gz && make -j2
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl iproute2 libssl3 zlib1g && rm -rf /var/lib/apt/lists/* && useradd -r mtproxy
COPY --from=build /src/objs/bin/mtproto-proxy /usr/local/bin/mtproto-proxy
COPY mtproxy-entrypoint.sh /entrypoint.sh
ENTRYPOINT ["bash", "/entrypoint.sh"]
