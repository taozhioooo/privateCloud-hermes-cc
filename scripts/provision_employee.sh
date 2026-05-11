#!/bin/bash
# =============================================================================
# [DEPRECATED] 本脚本已废弃，保留仅为兼容旧流程。
#
# 新流程使用集中式用户注册表 (users/users.yaml) + 动态渲染：
#
#   ./scripts/cluster add <name> --seq <N> --domain <D> --role <R> [--pubkey <key>]
#
# 详见: ./scripts/cluster --help
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cat >&2 <<'WARN'
[DEPRECATED] provision_employee.sh 已废弃，请改用 cluster CLI：

    ./scripts/cluster add <name> --seq <N> --domain <D> --role <R> [--pubkey <key|file>]

本次调用将转换为等效的 cluster add 执行。
WARN

USERNAME="$1"
DOMAIN="${2:-engineering}"
ROLE="${3:-engineer}"
SEQ="${4:-}"
SSH_PUB_INPUT="${5:-}"

if [ -z "$USERNAME" ] || [ -z "$SEQ" ]; then
    cat >&2 <<'USAGE'
用法: provision_employee.sh <用户名> <域> <角色> <序号> [SSH公钥或公钥文件路径]

等效新命令:
    ./scripts/cluster add <用户名> --seq <序号> --domain <域> --role <角色> [--pubkey <key|file>]
USAGE
    exit 1
fi

SEQ_NUM=$((10#$SEQ))

CMD=("${SCRIPT_DIR}/cluster" add "$USERNAME" --seq "$SEQ_NUM" --domain "$DOMAIN" --role "$ROLE")
if [ -n "$SSH_PUB_INPUT" ]; then
    CMD+=(--pubkey "$SSH_PUB_INPUT")
fi

echo >&2 "[INFO] 执行: ${CMD[*]}"
exec "${CMD[@]}"
