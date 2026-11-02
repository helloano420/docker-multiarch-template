# Minimal multi-arch example image.
#
# This file exists so the template repository can exercise its own reusable
# workflow end to end. Replace it with your real build - everything in
# .github/workflows/docker-publish.yml works with any Dockerfile.
FROM alpine:3.22

# $TARGETARCH is set by BuildKit for every --platform in the build. It is the
# canonical way to pull arch-specific artefacts without shell branching:
#   RUN curl -fsSL "https://example.com/tool-linux-${TARGETARCH}" -o /usr/local/bin/tool
ARG TARGETARCH

# Bake the resolved arch into the image so the test step can prove the
# per-platform build really produced different content.
RUN printf '%s\n' "$TARGETARCH" > /etc/image-arch

RUN apk add --no-cache ca-certificates

COPY --chmod=0755 hello.sh /usr/local/bin/hello

LABEL org.opencontainers.image.title="docker-multiarch-template" \
      org.opencontainers.image.description="Example image built by the reusable multi-arch publish workflow" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/usr/local/bin/hello"]
