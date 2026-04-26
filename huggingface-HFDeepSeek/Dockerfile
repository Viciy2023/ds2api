FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    PORT=7860 \
    LOG_LEVEL=INFO \
    DS2API_AUTO_BUILD_WEBUI=false \
    DS2API_CONFIG_PATH=/data/config.json \
    DS2API_ENV_WRITEBACK=1 \
    DS2API_RELEASE_REPO=CJackHwang/ds2api \
    DS2API_RELEASE_TAG=latest \
    DS2API_ARCH=auto

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        python3 \
        tar \
        gzip \
        xz-utils \
        file \
    && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
    && case "$arch" in amd64) ds2_arch="amd64" ;; arm64) ds2_arch="arm64" ;; *) echo "unsupported arch: $arch" >&2; exit 1 ;; esac \
    && if [ "${DS2API_RELEASE_TAG}" = "latest" ]; then resolved_tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${DS2API_RELEASE_REPO}/releases/latest" | awk -F/ '{print $NF}')"; else resolved_tag="${DS2API_RELEASE_TAG}"; fi \
    && test -n "$resolved_tag" \
    && archive_name="ds2api_${resolved_tag}_linux_${ds2_arch}.tar.gz" \
    && archive_url="https://github.com/${DS2API_RELEASE_REPO}/releases/download/${resolved_tag}/${archive_name}" \
    && mkdir -p /tmp/ds2api-release /opt/ds2api \
    && curl -fL --retry 3 --retry-delay 2 -o "/tmp/${archive_name}" "${archive_url}" \
    && tar -xzf "/tmp/${archive_name}" -C /tmp/ds2api-release \
    && extracted_dir="$(find /tmp/ds2api-release -mindepth 1 -maxdepth 1 -type d | head -n 1)" \
    && test -d "${extracted_dir}" \
    && test -f "${extracted_dir}/ds2api" \
    && test -f "${extracted_dir}/static/admin/index.html" \
    && cp -R "${extracted_dir}/." /opt/ds2api/ \
    && chmod +x /opt/ds2api/ds2api \
    && printf '%s\n' "$resolved_tag" > /opt/ds2api/BUILD_RELEASE_TAG \
    && rm -rf /tmp/ds2api-release "/tmp/${archive_name}"

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh \
    && mkdir -p /app /data /tmp/ds2api-runtime \
    && chmod -R 777 /data

WORKDIR /app
EXPOSE 7860

CMD ["/bin/bash", "/app/start.sh"]
