# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known ref (tag/branch) and repo. Defaults to upstream main.
# For private repos, set OPENCLAW_GIT_TOKEN to a GitHub PAT with repo scope.
ARG OPENCLAW_GIT_REPO=https://github.com/openclaw/openclaw.git
ARG OPENCLAW_GIT_TOKEN=
ARG OPENCLAW_GIT_REF=main
RUN if [ -n "${OPENCLAW_GIT_TOKEN}" ]; then \
      REPO_URL=$(echo "${OPENCLAW_GIT_REPO}" | sed "s|https://|https://${OPENCLAW_GIT_TOKEN}@|"); \
    else \
      REPO_URL="${OPENCLAW_GIT_REPO}"; \
    fi && \
    git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" "${REPO_URL}" .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

# Install base packages
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    chromium \
    ffmpeg \
    poppler-utils \
  && rm -rf /var/lib/apt/lists/*

# Install Eclipse Temurin JRE 21 (signal-cli requires Java 21+)
ARG JAVA_VERSION=21.0.2+13
RUN echo "Installing Temurin JRE 21..." \
  && wget -q "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.2%2B13/OpenJDK21U-jre_x64_linux_hotspot_21.0.2_13.tar.gz" -O /tmp/jre.tar.gz \
  && mkdir -p /opt/java \
  && tar xf /tmp/jre.tar.gz -C /opt/java --strip-components=1 \
  && rm /tmp/jre.tar.gz \
  && ln -s /opt/java/bin/java /usr/local/bin/java
ENV JAVA_HOME=/opt/java
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Install signal-cli for Signal channel support
ARG SIGNAL_CLI_VERSION=0.13.23
RUN echo "Downloading signal-cli v${SIGNAL_CLI_VERSION}..." \
  && wget -q "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}.tar.gz"
RUN echo "Extracting signal-cli..." \
  && tar xf "signal-cli-${SIGNAL_CLI_VERSION}.tar.gz" -C /opt
RUN echo "Creating symlink..." \
  && ln -s "/opt/signal-cli-${SIGNAL_CLI_VERSION}/bin/signal-cli" /usr/local/bin/signal-cli
RUN echo "Cleaning up..." \
  && rm "signal-cli-${SIGNAL_CLI_VERSION}.tar.gz"
RUN echo "Verifying signal-cli installation..." \
  && signal-cli --version

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
CMD ["node", "src/server.js"]
