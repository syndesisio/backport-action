FROM alpine:latest

RUN apk add --update --no-cache \
    bash \
    ca-certificates \
    curl \
    jq \
    git

COPY backport /usr/bin/backport

USER 1001:115

ENTRYPOINT ["backport"]
