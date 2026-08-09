FROM alpine:3.23.5

LABEL org.opencontainers.image.title="Huawei ONT Exporter" \
      org.opencontainers.image.description="Reads byte counters from a Huawei ONT over SSH and pushes them to Home Assistant as sensors" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.licenses="MIT"

# dropbear >=2025 removed the legacy ssh-rsa host key algorithm that the ONT's
# old Dropbear only offers, so pin the client from the v3.21 repo.
RUN echo "@v321 https://dl-cdn.alpinelinux.org/alpine/v3.21/main" >> /etc/apk/repositories \
    && apk add --no-cache dropbear-dbclient@v321

WORKDIR /app

COPY scripts/ ./
RUN chmod +x main.sh get_stats.sh entrypoint.sh healthcheck.sh \
    && adduser -D -u 1000 exporter

USER exporter

HEALTHCHECK --interval=60s --timeout=5s --start-period=90s --retries=3 \
    CMD /app/healthcheck.sh

ENTRYPOINT ["/app/entrypoint.sh"]
