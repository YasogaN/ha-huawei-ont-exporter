FROM alpine:3.21

RUN apk add --no-cache \
    openssh-client \
    sshpass

WORKDIR /app

COPY scripts/ ./
RUN chmod +x main.sh get_stats.sh entrypoint.sh \
    && adduser -D -u 1000 exporter

USER exporter

ENTRYPOINT ["/app/entrypoint.sh"]
