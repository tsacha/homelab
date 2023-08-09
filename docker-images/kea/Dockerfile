FROM alpine:latest
RUN apk add -u kea-dhcp6 && \
    mkdir /run/kea

VOLUME /config
CMD kea-dhcp6 -d -c /config/dhcp6.json
