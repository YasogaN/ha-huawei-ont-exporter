FROM alpine:3.21

LABEL org.opencontainers.image.title="Huawei ONT Exporter" \
      org.opencontainers.image.description="Reads byte counters from a Huawei ONT over SSH and pushes them to Home Assistant as sensors" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache \
    openssh-client \
    sshpass \
    tzdata

WORKDIR /app

COPY scripts/ ./
RUN chmod +x main.sh get_stats.sh entrypoint.sh healthcheck.sh \
    && adduser -D -u 1000 exporter

USER exporter

HEALTHCHECK --interval=60s --timeout=5s --start-period=90s --retries=3 \
    CMD /app/healthcheck.sh

ENTRYPOINT ["/app/entrypoint.sh"]
