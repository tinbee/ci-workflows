# The review container's only way out: it sits on an --internal network with no route, and
# this proxy (on that network and the default bridge) forwards CONNECT to the hosts in
# proxy-allow.txt and refuses the rest.
FROM alpine:3.22

RUN apk add --no-cache tinyproxy
# Build context: review/ (the parent of this directory), like review.Dockerfile.
COPY local/proxy.conf /etc/tinyproxy/tinyproxy.conf
COPY local/proxy-allow.txt /etc/tinyproxy/allow

USER tinyproxy
ENTRYPOINT ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
