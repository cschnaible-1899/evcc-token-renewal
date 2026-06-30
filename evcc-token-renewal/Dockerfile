ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN apk add --no-cache curl python3

COPY rootfs /
RUN chmod a+x /etc/services.d/evcc_token_renewal/run

LABEL io.hass.type="addon"
