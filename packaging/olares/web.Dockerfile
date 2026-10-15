# syntax=docker/dockerfile:1
# Olares web image: the wasm build (`cargo xtask web`, see docs/web.md) served by nginx on :8080.
# Build from the repository root: docker build -f packaging/olares/web.Dockerfile .
ARG RUST_VERSION=1.99
ARG NGINX_VERSION=1.28-alpine

# The wasm output is architecture-independent, so multi-arch builds compile it once natively.
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-slim-bookworm AS builder
# Must match `WASM_BINDGEN` in xtask/src/main.rs.
ARG WASM_BINDGEN_VERSION=0.2.129
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && rustup target add wasm32-unknown-unknown
RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) arch=x86_64 ;; \
        aarch64) arch=aarch64 ;; \
        *) echo 'The web builder supports amd64 and arm64' >&2; exit 1 ;; \
    esac; \
    name="wasm-bindgen-${WASM_BINDGEN_VERSION}-${arch}-unknown-linux-musl"; \
    url="https://github.com/wasm-bindgen/wasm-bindgen/releases/download/${WASM_BINDGEN_VERSION}"; \
    cd /tmp; \
    curl -fsSL --retry 3 "$url/$name.tar.gz" -o "$name.tar.gz"; \
    curl -fsSL --retry 3 "$url/$name.tar.gz.sha256sum" -o "$name.sha256sum"; \
    printf '%s  %s\n' "$(cut -d' ' -f1 "$name.sha256sum")" "$name.tar.gz" | sha256sum -c -; \
    tar -xzf "$name.tar.gz" -C /usr/local/bin --strip-components=1 "$name/wasm-bindgen"; \
    rm "$name.tar.gz" "$name.sha256sum"; \
    wasm-bindgen --version

WORKDIR /src
COPY . .
ARG CARGO_BUILD_JOBS=4
ENV CARGO_TARGET_DIR=/src/target
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo xtask web \
    && test -s target/web/dist/index.html \
    && mkdir -p /out \
    && cp -R target/web/dist/. /out/ \
    && gzip -9 -k /out/*.wasm /out/*.js /out/index.html

FROM nginx:${NGINX_VERSION} AS runtime
COPY packaging/olares/nginx.conf /etc/nginx/nginx.conf
COPY --from=builder /out/ /usr/share/nginx/html/
COPY LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md /usr/share/nginx/html/
# Bypass the stock entrypoint: this configuration needs no runtime rewriting.
USER nginx
EXPOSE 8080
ENTRYPOINT []
CMD ["nginx", "-g", "daemon off;"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
