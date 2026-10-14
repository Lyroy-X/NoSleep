ARG BASE=debian:trixie-slim
FROM ${BASE} AS ocserv-build

# Unmodified upstream release. Its initial auth form includes both username
# and password; version/hash are independent of the distro's older package.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential meson ninja-build pkg-config curl ca-certificates \
      xz-utils ipcalc libgnutls28-dev nettle-dev libtalloc-dev \
      libprotobuf-c-dev protobuf-c-compiler libreadline-dev libev-dev \
    && rm -rf /var/lib/apt/lists/*
RUN curl --fail --show-error --silent --location --proto '=https' \
      https://www.infradead.org/ocserv/download/ocserv-1.4.2.tar.xz -o /tmp/ocserv.tar.xz \
    && echo 'e35d748a5244b10be3a92ad4df95a534c8280c43680eecaf3cb1b20d2a22b1a5  /tmp/ocserv.tar.xz' | sha256sum --check - \
    && mkdir /tmp/ocserv-source \
    && tar -xJf /tmp/ocserv.tar.xz --strip-components=1 -C /tmp/ocserv-source \
    && meson setup /tmp/ocserv-build /tmp/ocserv-source --prefix=/usr/local \
      -Dsystemd=disabled -Dseccomp=disabled -Dpam=disabled -Dradius=disabled \
      -Dgssapi=disabled -Dliboath=disabled -Dlibnl=disabled -Dmaxmind=disabled \
      -Dgeoip=disabled -Dlibwrap=disabled -Dlz4=disabled \
    && meson compile -C /tmp/ocserv-build -j 2 \
    && meson install -C /tmp/ocserv-build

FROM ${BASE}

# All tunnel devices and route changes belong to the Docker VM/container only.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 iptables iputils-ping ocserv openconnect \
      openssl python3 vpnc-scripts \
    && rm -rf /var/lib/apt/lists/*
COPY --from=ocserv-build /usr/local/ /usr/local/
COPY server.py client.py control.py stream.py /opt/lab/
ENV PYTHONUNBUFFERED=1
LABEL local.nosleep.vpn-lab.ocserv-release="1.4.2"
CMD ["python3", "/opt/lab/client.py"]
