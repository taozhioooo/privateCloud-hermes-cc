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
- users/users.yaml：用户注册表，定义用户、seq、角色、公钥、镜像和端口规则
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

    ./scripts/cluster ps

查看日志：

    ./scripts/cluster logs zhaoliu --tail 100

## 端口规则

users/users.yaml 中默认：
- Hermes base: 10001
- Claude base: 11001
- step: 100
- range_size: 100

例如 seq=1：
- Hermes SSH: 10001 -> 容器 8700
- Hermes Web UI: 10002 -> 容器 8701
- Hermes Gateway/API: 10003 -> 容器 8642
- Hermes 临时服务: 10011-10100 -> 容器 8710-8799
- Claude SSH: 11001 -> 容器 22
- Claude 端口范围: 11002-11100

## 镜像构建

GitHub Actions 文件：

    .github/workflows/build-images.yml

会构建并推送：
- registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent
- registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code
