# =============================================================================
# Hermes Enterprise — All-in-one image
# 基础镜像:   Ubuntu 24.04
# 运行用户:   hermes
# 内含:       hermes-agent (uv 安装)  +  hermes-web-ui  +  openssh-server
# 数据持久化: /opt/data  /workspace  (docker volume 挂载)
# 只读技能卷: /opt/skills/L1  /opt/skills/L2  /opt/skills/L3
# 对外端口:   8700 SSH  8701 WebUI  8702-8709 gateway  8710-8799 临时服务
# =============================================================================

# ---------- stage: uv 二进制 ----------
FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie AS uv_source

# ---------- stage: gosu 二进制 ----------
FROM tianon/gosu:1.19-trixie AS gosu_source

# ---------- stage: hermes-web-ui 构建 ----------
FROM node:23.11.0-bookworm-slim AS webui_build

# slim 镜像缺 python3 + 编译工具链,node-pty 找不到 linux-x64 prebuild 时
# 会回退到 node-gyp rebuild,必须有 python + g++ 才能编译成功。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        python3 python-is-python3 make g++ ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# 先拷 manifest,命中缓存层
# 注:hermes-web-ui 的 .gitignore 排除了 package-lock.json,CI clone 没有 lock,
# 所以用通配 copy (package*.json) 避免缺文件报错,npm install 会按 package.json 解析。
COPY hermes-web-ui/package*.json ./
ENV NODE_OPTIONS=--max-old-space-size=4096
RUN npm install --ignore-scripts && npm rebuild node-pty

# 拷剩余源码,构建 dist/
COPY hermes-web-ui/ ./
RUN npm run build && npm prune --omit=dev

# ---------- stage: 最终运行镜像 ----------
FROM ubuntu:24.04

LABEL maintainer="Hermes Enterprise Platform"
LABEL description="Hermes Agent + Web UI  —  SSH-accessible, uv-installed, Playwright Chromium"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    PYTHONUNBUFFERED=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    HERMES_HOME=/opt/data \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_BIN=/opt/hermes/.venv/bin/hermes \
    PATH=/opt/hermes/.venv/bin:/opt/data/.local/bin:/usr/local/bin:/usr/bin:/sbin:/bin

# ── 系统依赖(一层) ────────────────────────────────────────────────────
# - openssh-server: SSH 接入
# - build-essential/python3-dev/libffi-dev: uv 编译原生扩展
# - nodejs/npm: hermes-agent TUI + web-ui 运行时
# - tini: 1 号进程回收僵尸子进程
# - gosu 来自独立 stage; 不从 apt 装
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget git gnupg lsb-release xz-utils tini \
        build-essential python3 python3-dev python3-venv python3-pip python3-yaml \
        libffi-dev ripgrep ffmpeg procps \
        openssh-server openssh-client \
        vim nano tmux jq htop \
        dnsutils iputils-ping net-tools \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# ── 复制跨阶段二进制 ────────────────────────────────────────────────
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/
COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/

# ── Node.js 23 (hermes-web-ui 要求 >=23,ubuntu 仓库版本太旧) ────────
RUN ARCH=$(dpkg --print-architecture) \
 && case "$ARCH" in amd64) NODE_ARCH=x64 ;; arm64) NODE_ARCH=arm64 ;; *) NODE_ARCH="$ARCH" ;; esac \
 && curl -fsSL "https://nodejs.org/dist/v23.11.0/node-v23.11.0-linux-${NODE_ARCH}.tar.gz" -o /tmp/node.tgz \
 && tar -xzf /tmp/node.tgz -C /usr/local --strip-components=1 \
 && rm -f /tmp/node.tgz \
 && node --version && npm --version

# ── 创建 hermes 用户(home 目录留给 SSH,数据走 /opt/data 卷) ────────
RUN groupadd -g 999 hermes \
 && useradd  -u 999 -g hermes -m -s /bin/bash -d /home/hermes -G sudo hermes \
 && echo "hermes ALL=(ALL) NOPASSWD: /usr/sbin/sshd" > /etc/sudoers.d/hermes-sshd \
 && chmod 0440 /etc/sudoers.d/hermes-sshd

# ╔═════════════════════════════════════════════════════════════════╗
# ║  hermes-agent  — uv 官方路线                                    ║
# ╚═════════════════════════════════════════════════════════════════╝
WORKDIR /opt/hermes

# -------- Node 端依赖(分层缓存) --------
# 先拷 manifest,lock 没变就复用
COPY hermes-agent/package.json  hermes-agent/package-lock.json  ./
COPY hermes-agent/web/package.json   hermes-agent/web/package-lock.json    web/
COPY hermes-agent/ui-tui/package.json hermes-agent/ui-tui/package-lock.json ui-tui/
# file: workspace 依赖需要完整源码,否则 npm 解析失败
COPY hermes-agent/ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/

# npm 10+ 默认 install-links=false,显式锁住避免 Debian 自带 npm 行为漂移
ENV npm_config_install_links=false
RUN npm install --prefer-offline --no-audit \
 && npx playwright install --with-deps chromium --only-shell \
 && (cd web    && npm install --prefer-offline --no-audit) \
 && (cd ui-tui && npm install --prefer-offline --no-audit) \
 && npm cache clean --force

# -------- Python 依赖(分层缓存) --------
COPY hermes-agent/pyproject.toml hermes-agent/uv.lock ./
# pyproject.toml 的 readme 字段会读 README.md, 占位
RUN touch ./README.md \
 && uv sync --frozen --no-install-project --extra all

# -------- 源码 + 构建 --------
COPY hermes-agent/ ./
RUN cd web    && npm run build \
 && cd ../ui-tui && npm run build

# 可编辑安装 hermes-agent 本体(快,不解析依赖)
RUN uv pip install --no-cache-dir --no-deps -e "."

# ╔═════════════════════════════════════════════════════════════════╗
# ║  hermes-web-ui  — 从 build stage 拷构建产物                     ║
# ╚═════════════════════════════════════════════════════════════════╝
WORKDIR /opt/hermes-web-ui
COPY --from=webui_build /src/dist         ./dist
COPY --from=webui_build /src/node_modules ./node_modules
COPY --from=webui_build /src/package.json ./
COPY --from=webui_build /src/bin          ./bin

# ╔═════════════════════════════════════════════════════════════════╗
# ║  运行时目录骨架                                                 ║
# ╚═════════════════════════════════════════════════════════════════╝
# /opt/data 是 HERMES_HOME,数据卷。挂载覆盖时仍需骨架
RUN mkdir -p \
        /opt/data/skills \
        /opt/data/sessions \
        /opt/data/logs \
        /opt/data/.ssh \
        /workspace/projects \
        /workspace/outputs \
        /workspace/downloads \
        /opt/skills/L1 \
        /opt/skills/L2 \
        /opt/skills/L3 \
        /var/run/sshd \
 && chmod 700 /opt/data/.ssh \
 && chown -R hermes:hermes /opt/hermes /opt/hermes-web-ui /opt/data /workspace

# ╔═════════════════════════════════════════════════════════════════╗
# ║  SSH 服务  — 纯公钥 · 禁 root · 仅 hermes                      ║
# ╚═════════════════════════════════════════════════════════════════╝
RUN ssh-keygen -A \
 && sed -i \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
        -e 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        -e 's/^#\?UsePAM.*/UsePAM yes/' \
        /etc/ssh/sshd_config \
 && echo ""                         >> /etc/ssh/sshd_config \
 && echo "AllowUsers hermes"        >> /etc/ssh/sshd_config \
 && echo "Port 8700"                >> /etc/ssh/sshd_config

# ╔═════════════════════════════════════════════════════════════════╗
# ║  Entrypoint                                                     ║
# ╚═════════════════════════════════════════════════════════════════╝
COPY --chmod=0755 entrypoint.sh /usr/local/bin/hermes-entrypoint.sh

# ╔═════════════════════════════════════════════════════════════════╗
# ║  端口声明  (宿主机映射在 compose 里)                             ║
# ║   8700       SSH                                                ║
# ║   8701       hermes-web-ui                                      ║
# ║   8702-8709  hermes gateway / webhook                           ║
# ║   8710-8799  员工临时 web 服务                                   ║
# ╚═════════════════════════════════════════════════════════════════╝
EXPOSE 8700-8799

VOLUME [ "/opt/data", "/workspace" ]

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8701/health >/dev/null || exit 1

WORKDIR /workspace

# tini 作 1 号进程,entrypoint 以 root 启动(做 chown + sshd),再 gosu 降到 hermes 起 web-ui
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/usr/local/bin/hermes-entrypoint.sh" ]
