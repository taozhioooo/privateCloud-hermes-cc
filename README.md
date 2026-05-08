# =============================================================================
# Hermes Enterprise Platform — Docker 部署指南
# 双镜像架构: Hermes Agent + Claude Code（独立构建，SSH 协同）
# =============================================================================

## 架构概览

    ┌─────────────────────────────────────────────────────────────────┐
    │                      Docker Network: hermes-net                 │
    │                                                                  │
    │  ┌──────────────────┐    SSH     ┌──────────────────┐          │
    │  │  hermes-zhangsan  │ ────────→ │  claude-zhangsan  │          │
    │  │                   │           │                   │          │
    │  │  Hermes Agent     │           │  Claude Code CLI  │          │
    │  │  + 钉钉 SDK       │           │  + Node.js 22     │          │
    │  │  + 网络搜索       │           │  + tmux           │          │
    │  │  + SSH Server     │           │  + SSH Server     │          │
    │  │                   │           │                   │          │
    │  │  :8701 Gateway    │           │  :22 SSH          │          │
    │  │  :22  SSH         │           │                   │          │
    │  └──────┬───────────┘           └───────┬───────────┘          │
    │         │     共享 workspace 卷           │                      │
    │         └───────────────────────────────┘                      │
    │                                                                  │
    │  SSH 公钥共享卷 (ssh_pub):                                        │
    │    Hermes 启动时生成 ed25519 密钥对 → 公钥写入共享卷              │
    │    Claude Code 启动时读取公钥 → 写入 authorized_keys              │
    │    结果: Hermes → Claude Code 自动免密 SSH                       │
    │                                                                  │
    │  ┌──────────┐                                                   │
    │  │  Redis   │                                                   │
    │  │  :6379   │                                                   │
    │  └──────────┘                                                   │
    └─────────────────────────────────────────────────────────────────┘


## SSH 接入矩阵

    ┌─────────────────┬──────────────┬──────────────┬─────────────────┐
    │                  │ 用户 → Hermes │ 用户 → Claude │ Hermes → Claude │
    ├─────────────────┼──────────────┼──────────────┼─────────────────┤
    │ 协议             │ SSH          │ SSH          │ SSH             │
    │ 认证方式         │ 密码/公钥    │ 密码/公钥    │ 公钥(自动)      │
    │ 默认密码         │ hermes       │ claude       │ —               │
    │ 端口示例(seq 01) │ 10001        │ 11001        │ 内部网络        │
    │ 用途             │ 管理Hermes   │ 管理Claude   │ 任务调度        │
    └─────────────────┴──────────────┴──────────────┴─────────────────┘


## 快速部署（3 步）

### 第 1 步: 配置 API 密钥

    cd /opt/workspace/hermes-docker-deploy
    cp .env.example .env
    nano .env

    必填:
      ANTHROPIC_API_KEY=sk-ant-xxx

    推荐:
      BRAVE_API_KEY=xxx       网络搜索
      GITHUB_TOKEN=ghp_xxx    GitHub 搜索

    可选 SSH 配置:
      HERMES_SSH_PASS=hermes       Hermes SSH 密码
      CLAUDE_SSH_PASS=claude       Claude SSH 密码
      SSH_PUBLIC_KEY=ssh-ed25519...  免密登录公钥

### 第 2 步: 部署

    chmod +x setup.sh
    ./setup.sh

### 第 3 步: 验证 SSH

    # 从外部 SSH 进入 Hermes 容器
    ssh hermes@服务器IP -p 10001
    # 输入密码: hermes

    # 从外部 SSH 进入 Claude Code 容器
    ssh claude@服务器IP -p 11001
    # 输入密码: claude

    # 如果已注入公钥，可直接免密登录
    ssh -i ~/.ssh/id_ed25519 hermes@服务器IP -p 10001
    ssh -i ~/.ssh/id_ed25519 claude@服务器IP -p 11001

    # 在 Hermes 容器内测试到 Claude Code 的连接
    docker exec hermes-zhangsan ssh claude@claude-zhangsan 'claude --version'


## 端口分配

    每个容器独占 100 个主机端口
    第 1 个端口用于 SSH
    后面 98 个端口用于 Web 服务

    Hermes:
      seq 01  → 10001, 10002-10099
      seq 04  → 10301, 10302-10399
      seq 70  → 16901, 16902-16999

    Claude Code:
      seq 01  → 11001, 11002-11099
      seq 04  → 11301, 11302-11399
      seq 70  → 17901, 17902-17999

    计算公式:
      Hermes SSH      = 10001 + (seq-1) × 100
      Hermes Web      = SSH+1  到 SSH+98
      Claude SSH      = 11001 + (seq-1) × 100
      Claude Web      = SSH+1  到 SSH+98


## SSH 使用场景

### 场景 1: 用户 SSH 进入 Hermes 容器

    # 直接 SSH
    ssh hermes@192.168.1.100 -p 10001

    # 进入后使用 Hermes
    hermes                              # 交互式对话
    hermes chat -q "你好"               # 单次查询
    hermes gateway status               # 检查钉钉连接
    hermes skills list                  # 查看技能
    hermes doctor                       # 环境诊断

### 场景 2: 用户 SSH 进入 Claude Code 容器

    # 直接 SSH
    ssh claude@192.168.1.100 -p 11001

    # 进入后使用 Claude Code
    claude                              # 交互式 REPL
    claude -p "写一个 hello world"      # 单次任务
    claude auth status                  # 检查认证
    claude --version                    # 版本

    # tmux 多会话
    tmux new -s coding
    claude --dangerously-skip-permissions

### 场景 3: Hermes 自动调用 Claude Code（容器间 SSH）

    # 在 Hermes 容器内，SSH 到 Claude Code 容器执行任务
    ssh claude@claude-zhangsan \
      "claude -p '修复 src/auth.py 的空指针' \
       --allowedTools 'Read,Write,Edit,Bash' \
       --max-turns 10"

    # 在 Claude Code 容器内执行并返回结果
    ssh claude@claude-zhangsan \
      "cd /home/claude/workspace && claude -p '列出所有 TODO 注释'"

    # tmux 交互模式（通过 SSH 远程操控）
    ssh claude@claude-zhangsan \
      "tmux new-session -d -s work 'claude --dangerously-skip-permissions'"
    ssh claude@claude-zhangsan \
      "tmux send-keys -t work '重构 src/order/ 模块' Enter"
    ssh claude@claude-zhangsan \
      "tmux capture-pane -t work -p"


## SSH 免密配置

### 方式 1: 员工开通时注入公钥

    # 传公钥文件路径
    ./scripts/provision_employee.sh zhaoliu engineering senior-engineer 04 ~/.ssh/id_ed25519.pub

    # 也可以直接传公钥内容
    ./scripts/provision_employee.sh zhaoliu engineering senior-engineer 04 \
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host"

    效果:
      - 公钥会同时注入 Hermes 和 Claude Code
      - 员工可用私钥直接免密 SSH 到两个容器

### 方式 2: 全局公钥

    # 在 .env 中设置
    SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host

    适合所有员工共用同一把公钥的场景

### 方式 3: 逐个复制

    # 生成密钥
    ssh-keygen -t ed25519

    # 手动分发到两个容器
    ssh-copy-id -p 10001 hermes@服务器IP
    ssh-copy-id -p 11001 claude@服务器IP

### 方式 4: Hermes → Claude Code 自动免密

    已自动配置，无需手动操作:
    1. Hermes 容器启动时自动生成 ed25519 密钥对
    2. 公钥写入共享卷 ssh_pub
    3. Claude Code 容器启动时读取公钥到 authorized_keys
    4. Hermes 可直接 ssh claude@claude-xxx 免密连接


## 镜像构建与更新

    日常使用 GitHub Actions 自动构建并推送镜像

    镜像地址:
      registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:latest
      registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:latest

    本地更新容器:
      docker compose pull
      docker compose up -d


## 添加新员工

    用法:
    ./scripts/provision_employee.sh <用户名> <域> <角色> <序号(01-70)> [SSH公钥或公钥文件路径]

    示例:
    ./scripts/provision_employee.sh zhaoliu engineering senior-engineer 04 ~/.ssh/id_ed25519.pub
    ./scripts/provision_employee.sh sunqi marketing product-manager 05

    启动新增员工容器:
    docker compose pull hermes-zhaoliu claude-zhaoliu
    docker compose up -d hermes-zhaoliu claude-zhaoliu

    生成结果:
      seq 04 → Hermes 10301 / Claude 11301
      如传入 SSH 公钥，两个容器都会自动支持免密登录

    详细说明见:
      /opt/workspace/hermes-docker-deploy/docs/employee-provisioning.md


## 资源配置

    镜像             CPU    内存    说明
    ────────────────────────────────────────────
    hermes-agent     2核    2GB     路由/对话/记忆
    claude-code      4核    4GB     编码/执行任务


## 网络搜索

    Hermes 端:
      hermes tools enable web          # 启用 web 搜索工具
      hermes chat -q "搜索新闻"        # 自动调用搜索引擎

    Claude Code 端（内置，无需配置）:
      claude -p "搜索 React 19" --allowedTools WebSearch


## 运维命令

    # 容器管理
    docker compose ps
    docker compose restart hermes-zhangsan
    docker compose logs -f hermes-zhangsan

    # SSH 连接测试
    docker exec hermes-zhangsan ssh -o StrictHostKeyChecking=no \
      claude@claude-zhangsan 'claude --version'

    # Hermes 操作
    docker exec hermes-zhangsan hermes doctor
    docker exec hermes-zhangsan hermes status

    # Claude Code 操作
    docker exec claude-zhangsan claude --version
    docker exec claude-zhangsan claude auth status

    # 批量更新
    docker compose pull
    docker compose up -d


## 参考资源

    - Hermes Agent:  https://hermes-agent.nousresearch.com/docs
    - Claude Code:   https://docs.anthropic.com/en/docs/claude-code
    - 钉钉开放平台:  https://open.dingtalk.com/
    - Brave Search:  https://brave.com/search/api/
