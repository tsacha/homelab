FROM alpine:latest
RUN apk -u --no-cache add tftp-hpa busybox syslog-ng

CMD ["sh", "-c", "busybox syslogd -n -O /dev/stdout & in.tftpd -6 -Lvvv -s /assets"]
