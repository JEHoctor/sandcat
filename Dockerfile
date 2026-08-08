# CLI image - build context should be project root to access .git

FROM alpine:3 AS builder

RUN apk add --update --no-cache git

WORKDIR /build
COPY .git /build/.git
COPY cli /build/cli

RUN set -eux; \
	date=$(git log -n1 --date=format:%Y%m%d.%H%M%S --format=%cd); \
	sha=$(git describe --abbrev=7 --dirty --always --tags); \
	echo "$date-$sha" > cli/.version; \
	cat cli/.version

FROM alpine:3

# Previously `FROM docker:29-cli`, which bundled the Docker CLI and so pinned
# the tool to one engine. sandcat now resolves its engine at runtime (see
# cli/lib/engine.bash), preferring podman, so both clients ship here and
# SANDCAT_ENGINE picks between them.
#
# podman-remote rather than the full podman: this container drives an engine
# running on the host over a socket, exactly as the Docker CLI did. It does not
# run containers itself.
#
# docker-cli-compose also serves as the compose provider for `podman compose`,
# which delegates to whichever provider it finds.
RUN apk add --update --no-cache \
	bash yq ncurses \
	podman-remote \
	docker-cli docker-cli-compose

WORKDIR /app
ENTRYPOINT ["/opt/sandcat/bin/sandcat"]

COPY --from=builder /build/cli /opt/sandcat
