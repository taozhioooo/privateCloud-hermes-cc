# 员工开通说明

本文档说明如何为新员工新增一组 Hermes 和 Claude Code 容器，并配置 SSH 登录。

## 脚本位置

    /opt/workspace/hermes-docker-deploy/scripts/provision_employee.sh

## 当前用法

    ./scripts/provision_employee.sh <用户名> <域> <角色> <序号(01-70)> [SSH公钥或公钥文件路径]

第 5 个参数可选。
不传时，员工先用密码登录。
传入后，Hermes 和 Claude Code 都会自动写入这个公钥，支持免密 SSH。

## 参数说明

    用户名
      用于生成 hermes-<用户名> 和 claude-<用户名>

    域
      比如 engineering、marketing、finance

    角色
      比如 senior-engineer、product-manager、analyst

    序号
      必须是 01 到 70
      脚本会自动计算 Hermes 和 Claude Code 的 SSH 与 Web 端口

    SSH公钥或公钥文件路径
      支持 ~/.ssh/id_ed25519.pub 这类文件路径
      也支持直接传 ssh-ed25519、ssh-rsa、ecdsa-sha2-nistp256 公钥文本

## 示例

    # 只开通账号，先用密码登录
    ./scripts/provision_employee.sh sunqi marketing product-manager 05

    # 传公钥文件路径
    ./scripts/provision_employee.sh zhaoliu engineering senior-engineer 04 ~/.ssh/id_ed25519.pub

    # 直接传公钥内容
    ./scripts/provision_employee.sh zhaoliu engineering senior-engineer 04 \
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... user@host"

## 端口规则

    Hermes SSH      = 10001 + (seq-1) × 100
    Hermes Web      = SSH+1  到 SSH+98
    Claude SSH      = 11001 + (seq-1) × 100
    Claude Web      = SSH+1  到 SSH+98

例如:

    seq 01
      Hermes 10001, 10002-10099
      Claude 11001, 11002-11099

    seq 04
      Hermes 10301, 10302-10399
      Claude 11301, 11302-11399

    seq 70
      Hermes 16901, 16902-16999
      Claude 17901, 17902-17999

## 执行后会发生什么

脚本会把两个服务块追加到 docker-compose.yml。
Hermes 服务使用镜像
    registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:latest
Claude Code 服务使用镜像
    registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:latest

如果传了 SSH 公钥，脚本会把 SSH_PUBLIC_KEY 写进两个服务的 environment。
容器启动后，公钥会进入对应用户的 authorized_keys。

## 开通后启动

    cd /opt/workspace/hermes-docker-deploy
    docker compose pull hermes-zhaoliu claude-zhaoliu
    docker compose up -d hermes-zhaoliu claude-zhaoliu

## 登录方式

如果未传公钥，可先用默认密码。

    ssh hermes@服务器IP -p 10301
    ssh claude@服务器IP -p 11301

默认密码是
    Hermes 账号 hermes
    Claude 账号 claude

如果传了公钥，可直接用私钥免密登录。

    ssh -i ~/.ssh/id_ed25519 hermes@服务器IP -p 10301
    ssh -i ~/.ssh/id_ed25519 claude@服务器IP -p 11301

## 验证

    docker compose ps
    docker compose logs --tail=50 hermes-zhaoliu
    docker compose logs --tail=50 claude-zhaoliu

    ssh -o StrictHostKeyChecking=no hermes@服务器IP -p 10301 'hermes --version'
    ssh -o StrictHostKeyChecking=no claude@服务器IP -p 11301 'claude --version'

    docker exec hermes-zhaoliu ssh -o StrictHostKeyChecking=no \
      claude@claude-zhaoliu 'claude --version'

## 常见错误

公钥格式不对时，脚本会直接报错，不会写入 compose。
如果用户名已存在，脚本也会直接退出。
如果改了 compose 后没拉新镜像，容器可能还是旧版本，记得先执行 docker compose pull 。
