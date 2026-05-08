# =============================================================================
# Hermes Agent — 独立镜像
# 包含: SSH Server + SSH Client + Hermes Agent + 自动 Provider 配置
# =============================================================================

FROM ubuntu:24.04

LABEL maintainer="Hermes Enterprise Platform"
LABEL description="Hermes Agent — Auto Provider Config + SSH Accessible"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# ── 系统依赖 ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git ca-certificates gnupg lsb-release \
    xz-utils \
    python3 python3-pip python3-venv python3-yaml \
    vim nano tmux jq htop \
    dnsutils iputils-ping net-tools \
    openssh-server openssh-client sshpass \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# ── 创建 hermes 用户 ──
RUN groupadd -g 999 hermes \
    && useradd -u 999 -g hermes -m -s /bin/bash -G sudo hermes \
    && echo "hermes:hermes" | chpasswd \
    && echo "hermes ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/hermes

USER hermes
WORKDIR /home/hermes

# ── Python 虚拟环境 ──
RUN python3 -m venv /home/hermes/.venv \
    && . /home/hermes/.venv/bin/activate \
    && pip install --upgrade pip setuptools wheel

# ── 安装 Hermes Agent ──
# 官方安装脚本会安装 Playwright Chromium，镜像会膨胀数 GB。
# 这台构建机磁盘只有 10GB，所以这里采用轻量安装：保留 Hermes CLI、网关、钉钉/飞书、Google、Web API 能力，不预装浏览器引擎。
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /home/hermes/.hermes/hermes-agent \
    && . /home/hermes/.venv/bin/activate \
    && cd /home/hermes/.hermes/hermes-agent \
    && pip install -e '.[termux,messaging,cli,pty,mcp,acp,dingtalk,feishu,google,web]' \
    && printf '#!/usr/bin/env bash\nsource /home/hermes/.venv/bin/activate\nexec /home/hermes/.venv/bin/hermes "$@"\n' > /home/hermes/.local-hermes \
    && chmod +x /home/hermes/.local-hermes \
    && sudo ln -sf /home/hermes/.local-hermes /usr/local/bin/hermes \
    && rm -rf /home/hermes/.cache/pip /home/hermes/.cache/uv /home/hermes/.npm /tmp/*

# ── 安装钉钉 SDK + 网络搜索依赖 + PyYAML ──
RUN . /home/hermes/.venv/bin/activate \
    && pip install lark-oapi httpx beautifulsoup4 lxml pyyaml \
    && rm -rf /home/hermes/.cache/pip /tmp/*

# ── 目录结构 ──
RUN mkdir -p \
    /home/hermes/.hermes/skills \
    /home/hermes/.hermes/sessions \
    /home/hermes/.hermes/logs \
    /home/hermes/.ssh \
    /home/hermes/.ssh-pub \
    /home/hermes/config \
    /home/hermes/workspace/projects \
    /home/hermes/workspace/outputs \
    /home/hermes/workspace/downloads

RUN chmod 700 /home/hermes/.ssh

# ── 复制配置文件 ──
COPY --chown=hermes:hermes config/company-providers.yaml /home/hermes/config/company-providers.yaml
COPY --chown=hermes:hermes config/config.yaml /home/hermes/config/config.yaml.template
COPY --chown=hermes:hermes scripts/entrypoint-hermes.sh /home/hermes/entrypoint.sh
RUN chmod +x /home/hermes/entrypoint.sh

# ── SSH Server 配置 ──
USER root
RUN mkdir -p /run/sshd \
    && ssh-keygen -A \
    && sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowUsers hermes" >> /etc/ssh/sshd_config

EXPOSE 22 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD su - hermes -c "hermes status" || exit 1

WORKDIR /home/hermes/workspace
ENTRYPOINT ["/home/hermes/entrypoint.sh"]
