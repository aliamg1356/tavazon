# syntax=docker/dockerfile:1

# ---- build ----
# Same image as the dev toolchain, so the host caches only one image. It always
# runs on the build host's own platform and cross-compiles to the target, so a
# multi-arch build needs no QEMU emulation.
FROM --platform=$BUILDPLATFORM golang:1.27 AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends upx-ucl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# Only what the build reads, so doc or config edits don't bust the layer cache.
COPY go.mod go.sum ./
COPY vendor/ vendor/
COPY cmd/ cmd/
COPY internal/ internal/
ARG TARGETOS TARGETARCH TARGETVARIANT
ARG VERSION=dev
# -s -w drops the symbol and DWARF tables; UPX then packs the binary to roughly a
# third of its size. It unpacks itself in memory at startup.
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH GOARM=${TARGETVARIANT#v} \
    go build -trimpath -mod=vendor \
    -ldflags "-s -w -X main.version=${VERSION}" -o /out/tavazon ./cmd/tavazon \
 && upx --best --lzma -q /out/tavazon

# ---- run ----
# scratch: Tavazon is a static CGO-free binary with embedded tzdata, no outbound
# TLS and no DNS/user lookups, so it needs nothing from a base image.
FROM scratch
ARG VERSION=dev
LABEL org.opencontainers.image.title="tavazon" \
      org.opencontainers.image.description="Keep an asymmetric hosting quota in balance by sending shaped, distributed junk traffic." \
      org.opencontainers.image.source="https://github.com/salehi/tavazon" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"
COPY --from=build /out/tavazon /tavazon
COPY config.example.json /config.json
VOLUME ["/data"]
EXPOSE 8081
ENTRYPOINT ["/tavazon", "-config", "/config.json"]
