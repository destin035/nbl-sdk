# The tag is retained for readability; the digest makes the Ubuntu base image
# immutable.  The matching amd64 manifest is recorded in source-lock.json.
FROM docker.io/library/ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      binutils \
      bison \
      build-essential \
      bzip2 \
      ca-certificates \
      curl \
      file \
      flex \
      gawk \
      git \
      gzip \
      libtool \
      make \
      patch \
      perl \
      python3 \
      rsync \
      tar \
      texinfo \
      wget \
      xz-utils \
      zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/container-builder.sh /opt/nbl-sdk/bin/nbl-sdk-builder

RUN chmod 0755 /opt/nbl-sdk/bin/nbl-sdk-builder \
 && mkdir -p /work \
 && chmod 0777 /work

WORKDIR /work
ENTRYPOINT ["/opt/nbl-sdk/bin/nbl-sdk-builder"]
