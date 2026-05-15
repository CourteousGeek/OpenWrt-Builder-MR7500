FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Core tools: dd, wget, tar, zstd, squashfs-tools, python3/pip
RUN apt-get update && apt-get install -y --no-install-recommends \
    # UBI/squashfs extraction
    squashfs-tools \
    mtd-utils \
    # Python for ubi_reader
    python3 \
    python3-pip \
    # ImageBuilder prereqs
    wget \
    tar \
    zstd \
    build-essential \
    libncurses5-dev \
    libncursesw5-dev \
    zlib1g-dev \
    gawk \
    git \
    gettext \
    libssl-dev \
    xsltproc \
    rsync \
    unzip \
    python3-distutils-extra \
    file \
    # squashfs-tools-ng for sqfs2tar
    squashfs-tools-ng \
    && rm -rf /var/lib/apt/lists/*

# Install ubi_reader
RUN pip3 install --break-system-packages ubi_reader

WORKDIR /workspace

COPY extract-aqr-firmware.sh build-openwrt.sh ./
RUN chmod +x extract-aqr-firmware.sh build-openwrt.sh

CMD ["bash"]
