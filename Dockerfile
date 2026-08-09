FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    curl \
    expect \
    gawk \
    openssh-client

WORKDIR /app

COPY scripts/ ./
RUN chmod +x main.sh get_stats.exp entrypoint.sh \
    && adduser -D -u 1000 exporter

USER exporter

ENTRYPOINT ["/app/entrypoint.sh"]
