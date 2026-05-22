# Hermes Docker 部署引导说明

本文档基于当前 `/opt/workspace/hermes-docker-deploy/users/users.yaml` 重新生成。

生成时间：2026-05-22

## 1. 当前部署对象

当前用户注册表只启用了 1 个员工：

| 员工登录名 | 工号 | seq | 部门 | 角色 | 状态 |
|---|---|---:|---|---|---|
| lr | GM20230204 | 1 | engineering | engineer | enabled |

使用镜像：

- Hermes: `registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:2026052201`
- Claude: `registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:2026052202`

端口规划：

| 服务 | 宿主机端口 | 容器端口 | 用途 |
|---|---:|---:|---|
| Hermes SSH | 10000 | 8700 | SSH 登录 Hermes 容器 |
| Hermes Web UI | 10001 | 8701 | 浏览器访问 Hermes Web UI |
| Hermes Gateway/API | 10002 | 8642 | Hermes API / OpenAI-compatible Gateway |
| Hermes 临时服务 | 10010-10099 | 8710-8799 | 员工临时启动 Web 服务使用 |
| Claude SSH | 10100 | 22 | SSH 登录 Claude Code 容器 |
| Claude Web Range | 10101-10199 | 10101-10199 | Claude 侧临时服务端口 |

已生成 Compose 文件：

- `compose/base.yml`
- `compose/rendered/user.lr.yml`

运行时目录（可用于 Windows 网络磁盘/Samba 挂载）：

- `/opt/workspace/hermes-docker-deploy/data/lr-GM20230204/`
  - `hermes/`：Hermes 配置、记忆、技能、日志、SSH key
  - `workspace/`：Hermes 与 Claude 共享工作区
  - `ssh-pub/`：Hermes → Claude 免密 SSH 公钥交换
  - `claude-home/`：Claude Code 用户配置目录

## 2. 首次部署准备

进入项目目录：

```bash
cd /opt/workspace/hermes-docker-deploy
```

确认 Docker 可用：

```bash
docker --version
docker compose version
```

如果服务器第一次从阿里云 ACR 拉取私有镜像，需要登录：

```bash
docker login registry.cn-chengdu.aliyuncs.com
```

按提示输入 ACR 用户名和密码。

## 3. 配置运行时环境变量

复制环境变量模板：

```bash
cp .env.example .env
```

编辑 `.env`：

```bash
vim .env
```

至少配置一个模型 API Key，例如：

```bash
DEEPSEEK_API_KEY=你的实际key
```

如需 Team Skills 远程同步，必须配置：

```bash
GITLAB_PRIVATE_TOKEN=你的GitLab访问token
SKILLS_RAW_BASE=https://gitlab.gm/api/v4/projects/devops%2Fgmsoft-hermes-skills/repository/files
SKILLS_REF=master
SKILLS_SYNC_INTERVAL=300
```

注意：

- 不要把真实 `.env` 提交到 GitHub。
- `users/users.yaml` 和生成的 yml 中不应写入真实 token。
- `GITLAB_PRIVATE_TOKEN` 只通过运行时环境变量传入容器。

## 4. 重新生成 Compose 配置

如果你修改了 `users/users.yaml`，执行：

```bash
./scripts/cluster render
```

当前渲染结果应包含：

```text
compose/rendered/user.lr.yml
```

查看员工端口和配置：

```bash
./scripts/cluster list --ports
./scripts/cluster show lr
```

检查项目配置：

```bash
./scripts/cluster doctor
```

## 5. 拉取镜像

拉取固定版本镜像：

```bash
docker pull registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:2026052201
docker pull registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:2026052202
```

## 6. 启动 LR 员工环境

推荐使用项目脚本启动：

```bash
./scripts/cluster start lr
```

或者直接使用 Docker Compose：

```bash
docker compose \
  --project-name hermes \
  --project-directory /opt/workspace/hermes-docker-deploy \
  --env-file /opt/workspace/hermes-docker-deploy/.env \
  -f compose/base.yml \
  -f compose/rendered/user.lr.yml \
  up -d
```

## 7. 验证运行状态

查看容器：

```bash
./scripts/cluster ps lr
```

或：

```bash
docker compose \
  --project-name hermes \
  --project-directory /opt/workspace/hermes-docker-deploy \
  --env-file /opt/workspace/hermes-docker-deploy/.env \
  -f compose/base.yml \
  -f compose/rendered/user.lr.yml \
  ps
```

查看日志：

```bash
./scripts/cluster logs lr
```

检查 Web UI：

```bash
curl -fsS http://127.0.0.1:10001/health
```

浏览器访问：

```text
http://服务器IP:10001
```

检查 Hermes SSH：

```bash
ssh hermes@服务器IP -p 10000
```

检查 Claude SSH：

```bash
ssh claude@服务器IP -p 10100
```

如果使用当前 `users/users.yaml` 中配置的公钥，应可使用对应私钥登录。
默认密码仍由容器环境控制：

- Hermes 默认：`hermes`
- Claude 默认：`claude`

生产环境建议使用公钥登录并禁用默认密码。

## 8. Hermes 到 Claude 连通性验证

进入 Hermes 容器后，验证 Hermes 能通过内网 SSH 调用 Claude：

```bash
docker exec hermes-lr su - hermes -c "ssh claude@claude-lr 'claude --version'"
```

也可以检查共享工作区：

```bash
docker exec hermes-lr bash -lc 'echo hello-from-hermes > /workspace/verify.txt'
docker exec claude-lr bash -lc 'cat /home/claude/workspace/verify.txt'
```

## 9. 常用运维命令

停止 LR：

```bash
./scripts/cluster stop lr
```

重启 LR：

```bash
./scripts/cluster restart lr
```

重新渲染并应用：

```bash
./scripts/cluster render
./scripts/cluster start lr
```

只更新镜像并重建容器：

```bash
docker pull registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:2026052201
docker pull registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:2026052202
./scripts/cluster restart lr
```

查看完整渲染文件：

```bash
sed -n '1,220p' compose/rendered/user.lr.yml
```

## 10. 当前已完成的本地校验

已执行并通过：

```bash
python3 -m py_compile scripts/lib/*.py
./scripts/cluster render
./scripts/cluster doctor
docker compose --project-name hermes --project-directory . --env-file .env -f compose/base.yml -f compose/rendered/user.lr.yml config --quiet
```

校验结论：

- `users/users.yaml` 可正常加载。
- 未发现端口冲突。
- 已成功生成 `compose/rendered/user.lr.yml`。
- Docker Compose 配置语法通过。
- `ssh_public_keys` 已按当前配置正确渲染为单条 SSH 公钥。

## 11. 注意事项

1. 当前 `users/users.yaml` 中 `ssh_public_keys` 是单行字符串形式，脚本已兼容并正确渲染。
   更推荐长期使用列表形式：

```yaml
ssh_public_keys:
  - ssh-ed25519 AAAA... user@host
```

2. 当前端口基准是：

```yaml
ports:
  hermes_base: 10000
  claude_base: 10100
  step: 100
  range_size: 100
```

所以 seq=1 的 LR 使用 10000-10099 与 10100-10199。

3. 如果继续新增员工，确保 seq 不重复；可使用：

```bash
./scripts/cluster add <name> --employee-id <工号> --seq <序号>
```

4. Team Skills 远程脚本要求 `GITLAB_PRIVATE_TOKEN` 在 `.env` 中配置；镜像和 yml 文件不会保存真实 token。
