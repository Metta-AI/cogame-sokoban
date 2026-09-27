# Build Docker. ONE image, TWO entrypoints: /bin/sokoban (rules, validation,
# results and replay) and /bin/sokoban-player (scripted or prompt policy).
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/sokoban
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
ARG NimFlags="-d:release -d:useMalloc --opt:speed --stackTrace:on"
ARG NimCommand="c"
ARG NimMain="src/sokoban.nim"
RUN nim $NimCommand \
  $NimFlags \
  --nimcache:/tmp/sokoban-nimcache \
  --out:sokoban \
  $NimMain && \
  nim c \
  $NimFlags \
  --nimcache:/tmp/sokoban-player-nimcache \
  --out:sokoban-player \
  src/sokoban_player.nim

# Run Docker.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/sokoban
COPY --from=build /workspace/sokoban/sokoban /bin/sokoban
COPY --from=build /workspace/sokoban/sokoban-player /bin/sokoban-player
COPY --from=build /workspace/sokoban/*.json ./
COPY --from=build /workspace/sokoban/data ./data
COPY --from=build /workspace/sokoban/client ./client

CMD ["/bin/sokoban"]
