ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apk add --no-cache bash curl python3

COPY rootfs /
RUN chmod +x /usr/bin/run.sh

CMD ["/usr/bin/run.sh"]
