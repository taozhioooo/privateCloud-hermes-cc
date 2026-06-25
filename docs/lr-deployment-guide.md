# Hermes Docker 部署引导说明

本文档基于当前 `/opt/workspace/hermes-docker-deploy/users/users.yaml` 重新生成。

生成时间：2026-05-26

## 1. 当前部署对象

当前用户注册表只启用了 1 个员工：

| 员工登录名 | 工号 | seq | 部门 | 角色 | 状态 |
|---|---|---:|---|---|---|
| lr | GM20230204 | 1 | engineering | engineer | enabled |

使用镜像：

- Hermes: `registry.cn-chengdu.aliyuncs.com/gmsoft_hub/hermes-agent:2026052201`
- Claude: `registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:2026052204`

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

## 1.1 Claude Code settings.json 初始化策略

当前部署保留“首次启动使用公司模板，后续允许用户自定义”的方案：

| 路径 | 类型 | 说明 |
|---|---|---|
| `config/claude-settings.json` | 宿主机模板 | 公司默认 Claude Code settings；可能包含 provider/env/permissions；已 gitignore |
| `/etc/claude/settings.json` | 容器只读模板 | 由 `config/claude-settings.json` 只读挂载得到 |
| `data/lr-GM20230204/claude-home/` | 宿主持久化目录 | 当前 LR 用户的 Claude home |
| `/home/claude/.claude/settings.json` | 容器用户配置 | Claude Code 官方默认读取的实际配置文件 |

启动行为：

1. 如果 `/home/claude/.claude/settings.json` 不存在，Claude entrypoint 从 `/etc/claude/settings.json` 复制一份。
2. 如果 `/home/claude/.claude/settings.json` 已存在，entrypoint 认为用户已经自定义，后续重启不会覆盖。
3. `settings.json` 中的 `env` 会被 entrypoint 生成到 `/home/claude/.claude/claude-code-env.sh`，并在 `.bashrc` 中 source，确保 SSH 登录和 `claude -p` 都能拿到 Anthropic-compatible endpoint 环境变量。

如需让新的公司模板重新作用于已有 LR 用户：

```bash
cd /opt/workspace/hermes-docker-deploy
cp data/lr-GM20230204/claude-home/settings.json    data/lr-GM20230204/claude-home/settings.json.bak.$(date +%Y%m%d-%H%M%S)
rm data/lr-GM20230204/claude-home/settings.json
./scripts/cluster restart lr
```

注意：不要直接把 `/etc/claude/settings.json` 当作 Claude Code 默认配置路径；Claude Code 默认读取的是 `~/.claude/settings.json`。

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
docker pull registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:2026052204
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
./scripts/cluster list --ports --status
./scripts/cluster ps
./scripts/cluster health lr
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

停止/删除 LR 容器（保留数据）：

```bash
./scripts/cluster stop lr
```

注意：当前 `cluster stop` 实现为 `docker compose rm -fs`，会停止并删除 `hermes-lr` / `claude-lr` 容器，但不会删除 `data/lr-GM20230204/` bind-mounted 数据。再次 `cluster start lr` 会按当前 compose 重新创建容器。

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
docker pull registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:2026052204
./scripts/cluster stop lr
./scripts/cluster start lr
```

如果只是重启当前容器、不要求强制换镜像，可使用：

```bash
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

5. 钉钉变量当前统一使用 `DINGTALK_CLIENT_ID` / `DINGTALK_CLIENT_SECRET` / `DINGTALK_ALLOWED_USERS`。旧变量名 `DINGTALK_APP_KEY` / `DINGTALK_APP_SECRET` 不应再写入新的 compose/env 示例。

6. 当前 Claude Code 镜像为 `registry.cn-chengdu.aliyuncs.com/gmsoft_hub/claude-code:2026052204`；如 `users/users.yaml` 中 tag 更新，应重新执行 `./scripts/cluster render` 并以渲染文件为准。
