# The box every belt leg runs in. Built from runner/ (context), so the belt's code is baked in
# read-only at /opt/conveyor; the task trays are mounted at /belt and the work folder at /work.
# The AI seats' commands (the local agent's bash tool, every :: verify: check) run in here,
# never on the Mac. socat is only for the gateway container (the one door to the local model).
FROM debian:bookworm-slim
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      bash jq curl ca-certificates util-linux coreutils python3 git procps socat \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 belt
COPY --chown=root:root conveyor /opt/conveyor
RUN chmod -R a+rX,go-w /opt/conveyor \
 && chmod a+x /opt/conveyor/conveyor /opt/conveyor/conveyor-* /opt/conveyor/standalone/*-local
USER belt
ENV HOME=/home/belt CONVEYOR_ROOT=/belt CONVEYOR_STANDALONE=1 CONVEYOR_REVIEW_GATE=1
WORKDIR /work
