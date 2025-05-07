FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_BREAK_SYSTEM_PACKAGES=1

RUN apt-get update -qq && \
    apt-get install -qq -y --no-install-recommends \
    ccache \
    curl \
    distro-info-data \
    git \
    lsb-release \
    mmdebstrap \
    netcat-openbsd \
    python3-full \
    python3-pip \
    sbuild \
    schroot \
    squid-deb-proxy \
    sudo \
    which \
    && rm -rf /var/lib/apt/lists/*

# Download yq binary
RUN curl -o /usr/local/bin/yq -sSfL https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_$(dpkg --print-architecture) && \
    chmod +x /usr/local/bin/yq && \
    yq --version

COPY . /workspace
WORKDIR /workspace
ENTRYPOINT ["bash", "build.sh"]
