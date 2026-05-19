# busybox:1.36.1 - linux/amd64
FROM busybox:1.36.1@sha256:851281100cc5f93d8a8f8e1a8976a57ec40a9bc9edd66ad3a621e4aa63326915

COPY repl.sh /repl.sh
RUN chmod +x /repl.sh

# Keep the container running so callers can drive it via exec sessions.
# The terminal API launches its own process inside the container; this
# entrypoint is only here to prevent the container from exiting.
ENTRYPOINT ["sleep", "infinity"]
