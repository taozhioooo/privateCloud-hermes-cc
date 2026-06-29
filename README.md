# Hermes Docker Enterprise Deploy

当前目录是新版 Hermes 企业 Docker 部署项目，只保留：
- 新版 Dockerfile 镜像构建文件
- 新版 compose 模板/渲染流程
- users/users.yaml 用户注册表
- scripts/cluster 集群管理命令
- Team Skills 技能库

旧版根目录 docker-compose.yml、setup.sh、provision_employee.sh 以及旧员工开通文档已移除。

## 核心架构

每个用户一组双容器：
- hermes-<name>：Hermes Agent + Web UI + Gateway + SSH
- claude-<name>：Claude Code CLI + SSH

Hermes 容器通过共享 ssh-pub 卷把自己的公钥交给 Claude 容器，从而实现 Hermes -> Claude 免密 SSH。

当前不再使用 Redis。

## 目录

- images/hermes-agent/：Hermes all-in-one 镜像 Dockerfile、entrypoint 和 provider 配置
- images/claude-code/：Claude Code 镜像 Dockerfile 和 entrypoint
- users/users.yaml：用户注册表，定义用户、seq、角色、公钥、镜像和端口规则；当前默认镜像为 hermes-agent:2026052201、claude-code:2026052204
- compose/base.yml：只声明 hermes-net 网络，不包含 Redis
- compose/templates/user.yml.j2：用户双容器 compose 模板
- compose/rendered/：由 cluster 渲染生成的用户 compose 片段
- scripts/cluster：新版集群管理 CLI
- scripts/lib/：cluster 的 Python 实现
- skills/L1,L2,L3：静态技能挂载目录
- gmsoft-hermes-skills/：Team Skills 技能库及同步脚本
- deploy/：针对具体服务器/测试环境的独立部署包
- demo/：本地测试运行数据，非生产入口

## 常用命令

先配置环境变量：

    cp .env.example .env
    # 编辑 .env，填入 DEEPSEEK_API_KEY / SSH_PUBLIC_KEY 等

渲染 compose：

    ./scripts/cluster render

查看用户：

    ./scripts/cluster list

添加用户：

    ./scripts/cluster add zhaoliu --seq 4 --domain engineering --role senior-engineer --pubkey ~/.ssh/id_ed25519.pub

启动单个用户：

    ./scripts/cluster start zhaoliu

启动全部用户：

    ./scripts/cluster start

查看状态：

    ./scripts/cluster list --ports --status
    ./scripts/cluster ps
    ./scripts/cluster health

查看日志：

    ./scripts/cluster logs zhaoliu --tail 100

停止/删除容器：

    ./scripts/cluster stop zhaoliu

说明：当前 `cluster stop` 实现为 `docker compose rm -fs`，会停止并删除该用户的两个容器，但保留 `data/<name>-<employee_id>/` 下的 bind-mounted 数据。再次 `cluster start` 会按当前配置重建容器。



## windows操作

 ```python
 # 进入scripts目录后
 python -m lib.cli list  # 查看用户
 python -m lib.cli render  # 渲染docker compose
 python -m lib.cli start {name}  # 启动全部用户/（单个）
 ```



## Claude Code settings.json 约定

保留当前“公司模板首次初始化 + 用户后续自定义”的方案：

- `config/claude-settings.json`：宿主机上的公司默认模板，可能包含 DeepSeek/Anthropic-compatible endpoint、默认模型、权限策略等；该文件可能包含密钥，已被 `.gitignore` 忽略。
- `compose/templates/user.yml.j2` 将模板只读挂载到 Claude 容器的 `/etc/claude/settings.json:ro`。
- 每个用户的 Claude 配置目录持久化在 `data/<name>-<employee_id>/claude-home/`，挂载到容器内 `/home/claude/.claude`。
- Claude Code 官方默认读取的是 `~/.claude/settings.json`，也就是容器内 `/home/claude/.claude/settings.json`；`/etc/claude/settings.json` 只是本项目约定的公司模板路径。
- Claude entrypoint 首次启动时，如果 `/home/claude/.claude/settings.json` 不存在，就从 `/etc/claude/settings.json` 复制一份；如果已经存在，则保留用户自定义，不再覆盖。
- 如果公司模板更新，需要对已有用户生效，需手动备份/删除该用户的 `data/<name>-<employee_id>/claude-home/settings.json` 后重启或重建 Claude 容器；否则已有用户继续使用自己的配置。

验证示例：

    docker inspect claude-lr --format '{{range .Mounts}}{{println .Source "->" .Destination "(" .Mode ")"}}{{end}}'
    docker exec claude-lr ls -l /etc/claude/settings.json /home/claude/.claude/settings.json

## 端口规则

以当前 `users/users.yaml` 为准：
- Hermes base: 10000
- Claude base: 10100
- step: 100
- range_size: 100

公式（seq=N）：
- Hermes SSH: `10000 + (N-1)*100`
- Hermes Web UI: `Hermes SSH + 1`
- Hermes Gateway/API: `Hermes SSH + 2` -> 容器 `8642`
- Hermes 临时服务: `Hermes SSH + 10` 到 `Hermes SSH + 99` -> 容器 `8710-8799`
- Claude SSH: `10100 + (N-1)*100` -> 容器 `22`
- Claude 端口范围: `Claude SSH + 1` 到 `Claude SSH + 99`

例如 seq=1：
- Hermes SSH: 10000 -> 容器 8700
- Hermes Web UI: 10001 -> 容器 8701
- Hermes Gateway/API: 10002 -> 容器 8642
- Hermes 临时服务: 10010-10099 -> 容器 8710-8799
- Claude SSH: 10100 -> 容器 22
- Claude 端口范围: 10101-10199

注意：以 `./scripts/cluster list --ports` 和 `compose/rendered/user.<name>.yml` 为运行时真相；不要按旧版 10001/11001 规则推算。

## 镜像构建

GitHub Actions 文件：

    .github/workflows/build-images.yml

会构建并推送：
- registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent
- registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code

当前 `users/users.yaml` 固定使用：
- registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:2026052201
- registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:2026052204

如更新镜像 tag，修改 `users/users.yaml` 后执行 `./scripts/cluster render`，再以 `compose/rendered/user.<name>.yml` 为准启动。
