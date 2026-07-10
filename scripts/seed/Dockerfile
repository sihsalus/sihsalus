FROM alpine:3.23

RUN apk add --no-cache curl openssl

COPY apply-seed.sh /usr/local/bin/apply-seed.sh

ENTRYPOINT [ "/bin/sh", "/usr/local/bin/apply-seed.sh" ]
