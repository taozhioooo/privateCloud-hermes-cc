# =============================================================================
# Claude Code CLI — 独立镜像
# 包含: SSH Server(用户接入 + Hermes远程调用) + Claude Code CLI
# 模型通过 DEEPSEEK_MODEL 环境变量配置，写入 settings.json
#
# 用户: claude (UID=999, GID=999) — 与 hermes-agent 容器的 hermes 用户一致
#       确保共享 workspace 卷时文件权限兼容
# =============================================================================

FROM node:22-bookworm-slim

LABEL maintainer="Hermes Enterprise Platform"
LABEL description="Claude Code CLI — SSH Accessible Coding Agent"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# ── 系统依赖 ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git ca-certificates \
    vim nano tmux jq htop \
    dnsutils iputils-ping net-tools \
    openssh-server openssh-client \
    sudo python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ── 安装 Claude Code CLI ──
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# ── 常用全局 npm 工具 ──
RUN npm install -g typescript ts-node 2>/dev/null || true \
    && npm cache clean --force

# ── 创建 claude 用户 (UID=999, GID=999) ──
# 与 hermes-agent 容器的 hermes 用户 UID/GID 一致，共享 workspace 无权限问题
RUN groupadd -g 999 claude \
    && useradd -u 999 -g claude -m -s /bin/bash -d /home/claude claude \
    && echo "claude:claude" | chpasswd \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude

# ── SSH Server 配置 ──
RUN mkdir -p /run/sshd \
    && ssh-keygen -A \
    && sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && echo "AllowUsers claude" >> /etc/ssh/sshd_config

# ── Claude Code 配置目录 + SSH 目录 + workspace ──
USER claude
WORKDIR /home/claude

RUN mkdir -p \
    /home/claude/.claude \
    /home/claude/.ssh \
    /home/claude/workspace \
    && chmod 700 /home/claude/.ssh

# ── Claude Code 默认 settings.json ──
RUN cat > /home/claude/.claude/settings.json << 'EOF'
{
  "model": "deepseek-v4-pro",
  "permissions": {
    "allow": [
      "Read",
      "Edit",
      "Write",
      "Bash",
      "WebSearch",
      "WebFetch"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(:(){ :|:& };:)"
    ]
  }
}
EOF

# ── 启动脚本 ──
COPY --chown=claude:claude scripts/entrypoint-claude.sh /home/claude/entrypoint.sh
RUN chmod +x /home/claude/entrypoint.sh

EXPOSE 22

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD claude --version || exit 1

WORKDIR /home/claude/workspace
# 以 root 启动，entrypoint 完成初始化后前台运行 sshd
USER root
ENTRYPOINT ["/home/claude/entrypoint.sh"]
