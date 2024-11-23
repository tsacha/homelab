FROM alpine:latest
RUN apk add -u kea-dhcp4 && \
    mkdir /run/kea

VOLUME /config
CMD kea-dhcp4 -d -c /config/dhcp4.json
