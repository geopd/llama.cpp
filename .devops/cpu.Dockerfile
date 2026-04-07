ARG UBUNTU_VERSION=24.04

FROM ubuntu:$UBUNTU_VERSION AS build

ARG TARGETARCH

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential git libssl-dev lsb-release wget software-properties-common gnupg autoconf automake libtool \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

RUN git clone https://github.com/facebook/jemalloc.git && \
    cd jemalloc && \
    ./autogen.sh --prefix=/usr --with-jemalloc-prefix= --disable-stats && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf jemalloc

RUN wget -q https://github.com/Kitware/CMake/releases/download/v4.1.2/cmake-4.1.2-linux-aarch64.tar.gz && \
    tar zxvf cmake-4.1.2-linux-aarch64.tar.gz -C /opt && \
    rm cmake-4.1.2-linux-aarch64.tar.gz && \
    ln -sf /opt/cmake-4.1.2-linux-aarch64/bin/cmake /usr/local/bin/cmake && \
    ln -sf /opt/cmake-4.1.2-linux-aarch64/bin/ctest /usr/local/bin/ctest && \
    ln -sf /opt/cmake-4.1.2-linux-aarch64/bin/cpack /usr/local/bin/cpack

RUN wget -qO- https://apt.llvm.org/llvm.sh | bash -s -- 22

WORKDIR /app

COPY . .

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libomp-22-dev libc++-22-dev libc++abi-22-dev pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

RUN wget -q https://developer.arm.com/-/cdn-downloads/permalink/Arm-Performance-Libraries/Version_25.07/arm-performance-libraries_25.07_deb_gcc.tar && \
    tar xf arm-performance-libraries_25.07_deb_gcc.tar && \
    ./arm-performance-libraries_25.07_deb/arm-performance-libraries_25.07_deb.sh --accept && \
    rm -rf arm-performance-libraries_25.07_deb_gcc.tar arm-performance-libraries_25.07_deb

ENV CC=clang-22
ENV CXX=clang++-22
ENV LD=ld.lld-22

ENV ARMPL_DIR=/opt/arm/armpl_25.07_gcc
ENV ARMPL_INCLUDES=${ARMPL_DIR}/include
ENV ARMPL_LIBRARIES=${ARMPL_DIR}/lib
ENV LD_LIBRARY_PATH=${ARMPL_LIBRARIES}
ENV PKG_CONFIG_PATH=${ARMPL_LIBRARIES}/pkgconfig

RUN rm -rf /app/build

RUN cmake -S . -B build \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_C_COMPILER=clang-22 \
    -DCMAKE_CXX_COMPILER=clang++-22 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-march=armv8.2-a+fp16+dotprod+simd+crc+crypto -mtune=neoverse-n1 -O3 -ftree-vectorize -fno-strict-overflow -funsafe-math-optimizations -flto -fopenmp=libomp -I${ARMPL_DIR}/include" \
    -DCMAKE_CXX_FLAGS="-march=armv8.2-a+fp16+dotprod+simd+crc+crypto -mtune=neoverse-n1 -O3 -ftree-vectorize -fno-strict-overflow -funsafe-math-optimizations -flto -fopenmp=libomp -I${ARMPL_DIR}/include" \
    -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -ljemalloc -L${ARMPL_DIR}/lib -larmpl_lp64_mp -lamath -lastring -lm -lomp -Wl,--lto-O3" \
    -DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld -ljemalloc -L${ARMPL_DIR}/lib -larmpl_lp64_mp -lamath -lastring -lm -lomp -Wl,--lto-O3 -Wl,--gc-sections" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DGGML_CCACHE=OFF \
    -DCURL_INCLUDE_DIR=/usr/aarch64-linux-gnu/include \
    -DGGML_NATIVE=OFF \
    -DGGML_LTO=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=ARMPL \
    -DBLAS_LIBRARIES="${ARMPL_LIBRARIES}/libarmpl_lp64_mp.so;${ARMPL_LIBRARIES}/libamath.so;${ARMPL_LIBRARIES}/libastring.so" \
    -DBLAS_INCLUDE_DIRS="${ARMPL_INCLUDES}" \
    -DGGML_CUDA=OFF \
    -DGGML_HIP=OFF \
    -DGGML_VULKAN=OFF \
    -DGGML_METAL=OFF \
    -DGGML_CPU_KLEIDIAI=ON \
    -DGGML_OPENMP=ON \
    -DGGML_SCHED_MAX_COPIES=1 \
    -DLLAMA_BUILD_TESTS=OFF

RUN cmake --build build -j $(nproc)

#RUN if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
#        cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DLLAMA_BUILD_TESTS=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON; \
#    else \
#        echo "Unsupported architecture"; \
#        exit 1; \
#    fi && \
#    cmake --build build -j $(nproc)

RUN mkdir -p /app/lib && \
    find build -name "*.so*" -exec cp -P {} /app/lib \;

RUN mkdir -p /app/full \
    && cp build/bin/* /app/full \
    && cp *.py /app/full \
    && cp -r gguf-py /app/full \
    && cp -r requirements /app/full \
    && cp requirements.txt /app/full \
    && cp .devops/tools.sh /app/full/tools.sh

RUN mkdir -p /app/armpl_libs && \
    cp ${ARMPL_LIBRARIES}/libarmpl_lp64_mp.so* /app/armpl_libs/ && \
    cp ${ARMPL_LIBRARIES}/libamath*.so* /app/armpl_libs/ && \
    cp ${ARMPL_LIBRARIES}/libastring*.so* /app/armpl_libs/ && \
    find /usr/lib -name "libomp.so*" -exec cp -d {} /app/armpl_libs/ \;

## Base image
FROM ubuntu:$UBUNTU_VERSION AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    libgomp1 curl \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

COPY --from=build /app/lib/ /app
COPY --from=build /app/armpl_libs/ /usr/lib/
#COPY --from=build /usr/lib/llvm-22/lib/libomp* /usr/lib/
COPY --from=build /usr/lib/aarch64-linux-gnu/libomp* /usr/lib/aarch64-linux-gnu/
COPY --from=build /usr/lib/libjemalloc.so* /usr/lib/

### Full
FROM base AS full

COPY --from=build /app/full /app

WORKDIR /app

RUN apt-get update \
    && apt-get install -y \
    git \
    python3 \
    python3-pip \
    && pip install --upgrade pip setuptools wheel \
    && pip install -r requirements.txt \
    && apt autoremove -y \
    && apt clean -y \
    && rm -rf /tmp/* /var/tmp/* \
    && find /var/cache/apt/archives /var/lib/apt/lists -not -name lock -type f -delete \
    && find /var/cache -type f -delete

ENTRYPOINT ["/app/tools.sh"]

### Light, CLI only
FROM base AS light

COPY --from=build /app/full/llama-cli /app

WORKDIR /app

ENTRYPOINT [ "/app/llama-cli" ]

### Server, Server only
FROM base AS server

ENV LLAMA_ARG_HOST=0.0.0.0

COPY --from=build /app/full/llama-server /app

WORKDIR /app

ENV LD_LIBRARY_PATH=/usr/lib
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2
ENV MALLOC_CONF="percpu_arena:phycpu,dirty_decay_ms:-1,muzzy_decay_ms:-1,metadata_thp:always,retain:true,abort_conf:true,confirm_conf:true"

HEALTHCHECK CMD [ "curl", "-f", "http://localhost:8080/health" ]

ENTRYPOINT [ "/app/llama-server" ]

### llama-bench
FROM base AS bench

COPY --from=build /app/full/llama-bench /app

WORKDIR /app

ENV LD_LIBRARY_PATH=/usr/lib
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2
ENV MALLOC_CONF="percpu_arena:phycpu,dirty_decay_ms:-1,muzzy_decay_ms:-1,metadata_thp:always,retain:true,abort_conf:true,confirm_conf:true"

ENTRYPOINT [ "/app/llama-bench" ]