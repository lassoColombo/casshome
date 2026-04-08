ARG REGISTRY_HOST
ARG BUILD_PLATFORM
ARG BUILD_ARCH

FROM ghcr.io/nushell/nushell:0.111.0 as nu
FROM --platform=${BUILD_PLATFORM}/${BUILD_ARCH} ${REGISTRY_HOST}/proxy-cache/library/alpine:3.21

RUN apk update --no-cache && \
  apk upgrade --no-cache --available && \
  apk add \
  openssh-client \
  difftastic \
  python3 \
  curl \
  git \

COPY --from=nu /usr/bin/nu /usr/bin/nu

