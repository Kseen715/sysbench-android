# Stage 1: download and extract the NDK only.
# This layer is cached until NDK_VERSION changes — adding/removing apt packages
# in stage 2 will not trigger a re-download.
FROM mirror.gcr.io/library/debian:bookworm-slim AS ndk-fetch
ARG NDK_VERSION=r10e
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates unzip wget \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt
RUN wget -q https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux-x86_64.zip \
    && unzip -q android-ndk-${NDK_VERSION}-linux-x86_64.zip \
    && rm -f android-ndk-${NDK_VERSION}-linux-x86_64.zip

# Stage 2: build environment.
# NDK r10e host binaries are glibc-linked; Debian provides a native glibc environment.
FROM mirror.gcr.io/library/debian:bookworm-slim
ARG NDK_VERSION=r10e
ARG SYSBENCH_REF=master

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bison \
        ca-certificates \
        file \
        flex \
        gawk \
        git \
        g++ \
        gcc \
    g++-multilib \
    gcc-multilib \
        libtool \
        make \
        patch \
        pkg-config \
        python3 \
        texinfo \
        unzip \
        wget \
        xz-utils \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ndk-fetch /opt/android-ndk-${NDK_VERSION} /opt/android-ndk-${NDK_VERSION}

ENV ANDROID_NDK_HOME=/opt/android-ndk-${NDK_VERSION}
ENV PATH=${ANDROID_NDK_HOME}:$PATH

WORKDIR /work
RUN git clone --depth=1 --branch ${SYSBENCH_REF} --recurse-submodules --shallow-submodules https://github.com/akopytov/sysbench.git \
    && git -C /work/sysbench submodule update --init --recursive --depth=1 \
    && test -d /work/sysbench/third_party/luajit/luajit \
    && test -d /work/sysbench/third_party/concurrency_kit/ck

VOLUME ["/out"]

CMD ["/bin/bash", "/work/build-sysbench-android.sh"]
