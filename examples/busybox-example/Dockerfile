# busybox:1.36.1 - linux/amd64
FROM busybox:1.36.1@sha256:851281100cc5f93d8a8f8e1a8976a57ec40a9bc9edd66ad3a621e4aa63326915

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
