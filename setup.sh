#!/bin/bash
# =============================================================================
# Hermes Enterprise Platform — 一键部署
# =============================================================================

set -e

echo "============================================"
echo "  Hermes Enterprise Platform"
echo "  双镜像: Hermes Agent + Claude Code"
echo "============================================"
echo ""

# ── 前置检查 ──
echo "[1/8] 检查前置条件..."
if ! command -v docker &> /dev/null; then
    echo "[ERROR] Docker 未安装: curl -fsSL https://get.docker.com | sh"
    exit 1
fi
if ! docker compose version &> /dev/null; then
    echo "[ERROR] Docker Compose v2 未安装"
    exit 1
fi
echo "[OK] Docker $(docker --version | awk '{print $3}')"
echo "[OK] Compose $(docker compose version --short)"

# ── .env ──
echo ""
echo "[2/8] 检查环境变量..."
if [ ! -f .env ]; then
    cp .env.example .env
    echo "[WARN] 已创建 .env，请编辑填入 API 密钥:"
    echo "  nano .env"
    read -p "编辑完成后按 Enter 继续..."
fi

source .env
if [ -z "$ANTHROPIC_API_KEY" ] || [[ "$ANTHROPIC_API_KEY" == *"xxx"* ]]; then
    echo "[ERROR] ANTHROPIC_API_KEY 未配置"
    exit 1
fi
echo "[OK] ANTHROPIC_API_KEY 已配置"
[ -n "$BRAVE_API_KEY" ] && echo "[OK] BRAVE_API_KEY（网络搜索）"
[ -n "$GOOGLE_API_KEY" ] && echo "[OK] GOOGLE_API_KEY（Google 搜索）"
[ -n "$GITHUB_TOKEN" ] && echo "[OK] GITHUB_TOKEN（GitHub 搜索）"

# ── 技能目录 ──
echo ""
echo "[3/8] 创建技能目录..."
mkdir -p skills/L1 skills/L2/engineering skills/L2/marketing
mkdir -p skills/L3/engineering/senior-engineer skills/L3/engineering/junior-engineer
mkdir -p skills/L3/marketing/product-manager
echo "[OK] 完成"

# ── 默认 SOUL ──
echo ""
echo "[4/8] 创建默认 SOUL 模板..."
if [ ! -f skills/L1/SOUL-company.md ]; then
    cat > skills/L1/SOUL-company.md << 'EOF'
# 公司 AI 助理规范

## 行为准则
- 使用中文回复
- 保持专业、简洁
- 代码输出使用绝对路径

## 安全红线
- 不泄露 API 密钥和内部配置
- 不执行未经授权的破坏性操作
EOF
    echo "[OK] 已创建"
else
    echo "[OK] 已存在，跳过"
fi

# ── 构建镜像 ──
echo ""
echo "[5/8] 构建 Hermes Agent 镜像..."
docker compose build hermes-zhangsan

echo ""
echo "[6/8] 构建 Claude Code 镜像..."
docker compose build claude-zhangsan

# ── 启动 ──
echo ""
echo "[7/8] 启动所有容器..."
docker compose up -d

echo ""
echo "[8/8] 等待服务就绪（约 30 秒）..."
sleep 30

echo ""
echo "============================================"
echo "  容器状态:"
echo "============================================"
docker compose ps

echo ""
echo "============================================"
echo "  验证命令:"
echo "============================================"
echo ""

# SSH 连通性测试
echo "# 测试 Hermes SSH"
echo "ssh -o StrictHostKeyChecking=no hermes@localhost -p 9201 'hermes --version'"
echo ""
echo "# 测试 Claude Code SSH"
echo "ssh -o StrictHostKeyChecking=no claude@localhost -p 9301 'claude --version'"
echo ""
echo "# 测试 Hermes → Claude Code SSH（容器间自动免密）"
echo "docker exec hermes-zhangsan ssh claude@claude-zhangsan 'claude --version'"
echo ""
echo "# 测试 Hermes 对话"
echo "docker exec hermes-zhangsan hermes chat -q '你好'"
echo ""
echo "# 测试网络搜索"
echo "docker exec hermes-zhangsan hermes chat -q '搜索今天的科技新闻'"
echo ""
echo "============================================"
echo "  部署完成！"
echo "============================================"
