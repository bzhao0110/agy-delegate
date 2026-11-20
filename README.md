# agy-delegate

> 让 ZCode、DSH（DeepSeek Harness）等终端 Agent 工具，一键委派任务给本机正在运行的 **Antigravity 桌面版**——把 Antigravity 变成你手头 Agent 的「执行副引擎」。

## 这是什么 / 解决什么问题

很多人机器上同时装了两类 AI 编程工具：

- **终端 Agent CLI**（ZCode、DSH / DeepSeek Harness 等）：擅长规划、读代码、长链路编排，是可靠的「主脑」；
- **Antigravity 桌面版**：自带 Gemini / Claude 等模型配额，执行编码、文档、生成类任务很强，但它是一个独立 GUI，平时只能人工点。

`agy-delegate` 在两者之间架了一条**本机自动化通道**：主脑 Agent 把写好的 prompt 直接注入 Antigravity 会话，让 Antigravity 执行；主脑随后自动监控执行轨迹、远程批准权限弹窗、验收磁盘产物。全程不需要你手动在两个窗口之间切换复制。

```
┌──────────────┐   ① 写 prompt 注入会话        ┌────────────────────┐
│ ZCode / DSH   │ ────────────────────────────▶ │  Antigravity 桌面版  │
│ （主脑 Agent） │   ② 监控轨迹步骤 WAITING       │  （执行副引擎）       │
│              │ ◀──────────────────────────── │  Gemini / Claude 模型│
└──────────────┘   ③ 远程批权限 / 验收产物       └────────────────────┘
          全程走本机回环 Connect RPC（127.0.0.1）
```

**典型收益**：

- 双引擎并行：主脑继续思考下一个任务，副引擎在 Antigravity 里埋头干活；
- 配额独立：消耗的是 Antigravity 账号自己的模型配额（Gemini 组 / Claude 组互不占用），等于给主脑白送第二套模型池；
- 主脑验收：产物落盘后由主脑 Agent 核对内容再交付，而不是盲信「Antigravity 说做完了」。

## 工作原理

Antigravity 桌面版启动时会拉起一个 `language_server` 子进程，在 `127.0.0.1` 的**随机端口**上监听自签 HTTPS，并提供 Connect RPC 接口；鉴权用的 CSRF token 就写在进程启动参数里。

`agy.sh` 每次被调用时：

1. 从进程表里找到 `language_server` 的 PID；
2. 从进程参数提取 `--csrf_token`；
3. 用 `lsof` 找到它监听的回环端口。

所以**无需任何配置文件**——Antigravity 重启后端口和 token 变了也无所谓，下次调用自动重新定位；token 只存活于当次调用，不落盘、不外发。之后就是普通的 unary JSON over HTTPS 调用（`StartCascade`、`SendUserCascadeMessage`、`GetCascadeTrajectorySteps`、`HandleCascadeUserInteraction`、`RetrieveUserQuotaSummary` 等方法）。

> 网络流量全部走本机回环；本技能本身不向你机器之外的任何地址发送数据。

## 安装

**方式一：装成 Agent 技能（推荐，ZCode / DSH 可直接自动触发）**

```bash
git clone https://github.com/bzhao0110/agy-delegate.git ~/.agents/skills/agy-delegate
chmod +x ~/.agents/skills/agy-delegate/scripts/agy.sh
```

- ZCode、DSH 原生读取 `~/.agents/skills/` 目录，装完即生效（新会话开始生效）；
- 其他支持 SKILL.md 约定的 Agent 工具，把仓库克隆到其技能目录即可。

**方式二：当独立命令行工具用**

克隆到任意位置，直接调 `scripts/agy.sh`，不依赖任何 Agent。

**前置依赖**：

| 依赖 | 说明 |
|---|---|
| macOS | 脚本用了 `ps` / `lsof` / `stat -f` / `uuidgen`，Windows / Linux 未适配 |
| Antigravity 桌面版 | 已安装并登录，且正在运行 |
| bash + curl + python3 | 系统自带即可 |

装完先跑 `agy.sh locate` 自检：能打出 `PID= / PORT= / TOKEN=` 和最近会话列表，就是连通了。

## 快速上手（标准委派循环）

把下面这个循环告诉你的主脑 Agent（ZCode / DSH 装了技能后它会自己按 `SKILL.md` 走）：

```bash
S=~/.agents/skills/agy-delegate/scripts/agy.sh

$S locate                   # 1. 拿会话清单（或 new 新建）
$S new ~/Projects/my-app    #    新任务建议新建会话，带工作区目录 → 输出 CASCADE_ID
$S send <CASCADE_ID> <指令>  # 2. 发任务（指令会被当作用户原话执行）
# 3. 监控循环：
$S steps <CASCADE_ID>      #    看进度；出现 ⚠ WAITING-PERMISSION 就处理
$S approve <CASCADE_ID>    #    核对命令内容后批权限（scope=ONCE）
$S send <CASCADE_ID> 继续   #    停滞时发"继续"唤醒
# 4. 验收：steps 全 DONE 后，人工/主脑检查磁盘产物
```

一个具体例子：

```bash
$S new ~/Projects/demo-api
# CASCADE_ID=3f2b...（复制这个 id）

$S send 3f2b... "在 src/api 下新增 /health 健康检查接口，补一个单测，全部跑通后汇报改动文件清单"

$S steps 3f2b...
# [12] RUN_COMMAND           DONE
#      ⚠ WAITING-PERMISSION 待批命令: npm install vitest
$S approve 3f2b...
# 待批步骤 stepIndex=12 / 命令内容: npm install vitest
# APPROVED(ONCE) → ...

$S steps 3f2b...           # 等到全部 DONE
# 打开 ~/Projects/demo-api 验收实际改动
```

## 子命令参考

| 命令 | 说明 |
|---|---|
| `locate` | 定位 language_server（PID/PORT/TOKEN/BASE），列出最近 10 个会话 |
| `new [--model X] [目录...]` | 新建会话，输出 CASCADE_ID；传入的目录成为工作区（转 file:// URI），会话自动挂到 Antigravity 对应项目分组；可传多个目录 |
| `send [--model X] <id> <text>` | 向会话发指令；JSON 转义由 python3 处理，引号、换行随意写 |
| `steps <id> [N]` | 查执行轨迹，默认显示最后 15 步；有等待批准的权限时高亮 `⚠ WAITING-PERMISSION` 并显示待批命令 |
| `approve <id> [--deny]` | 自动定位最新待决步骤 → 打印命令内容 → 危险模式守门 → 以 `PERMISSION_SCOPE_ONCE` 批准（或拒绝） |
| `quota` | 查模型配额（三组两窗口余量 + 重置时间 + 可用模型全表） |

`--model` 必须紧跟在子命令后，接受模型 key 或 `MODEL_*` enum。

## 默认模型与换挡

默认 **`gemini-4-hydrogen-high`**（High 思考档）：`new` / `send` 会自动携带，无需任何参数。只有你明确想换模型时才用 `--model` 覆盖，例如：

```bash
$S new --model claude-opus-5-5-high ~/Projects/final-report   # 定稿级任务用 Claude 组
$S send --model gemini-4-hydrogen-medium <id> 降档跑这个就行
```

常用模型（key → enum，随 Antigravity 版本可能变化，全表以 `$S quota` 输出为准）：

| 模型 key | enum | 说明 |
|---|---|---|
| `gemini-4-hydrogen-high` | `MODEL_PLACEHOLDER_M525` | **默认**，日常委派 |
| `gemini-4-hydrogen-medium` / `-low` | `M526` / `M527` | 降档省配额 |
| `gemini-4-hydrogen-xhigh` | `M528` | 超高档，重任务可选 |
| `gemini-3.8-flash-high` / `-medium` / `-low` | `M318` / `M319` / `M320` | 上一代默认，与 Hydrogen 共用 Gemini 配额组 |
| `gemini-4-argon-high` / `-medium` / `-low` | `M417` / `M418` / `M419` | Argon 周配额极少，慎用 |
| `claude-opus-5-5-high` / `-medium` / `-low` | `M402` / `M401` / `M400` | 定稿级，Claude 组配额独立 |
| `claude-sonnet-5-5-high` / `-medium` / `-low` | `M405` / `M404` / `M403` | Claude 组 |

## 安全设计

- **危险命令守门**：`approve` 批准前必先打印命令原文；命中危险模式（`rm -rf`、`git push`、`git reset --hard`、`git clean`、`sudo`、`mkfs`、`diskutil erase`、`dd if=`、`curl|sh`、`chmod -R 777`、写 `/dev/` 设备等）会**拒绝自动批准**并以退出码 3 退出，转人工在 Antigravity UI 里处理。
- **最小授权**：权限批准固定用 `PERMISSION_SCOPE_ONCE`，一次一授，不产生长期白名单。
- **零外发**：脚本只与 `127.0.0.1` 上的 language_server 通信；CSRF token 每次从进程动态提取，不写任何文件。
- **提醒**：`send` 出去的文本会被 Antigravity 当作**用户原话**执行——让主脑 Agent 发重要 prompt 前先给你过目（`SKILL.md` 已写入此规矩）。
- 委派任务消耗的是**你自己 Antigravity 账号**的模型配额，`quota` 子命令随时可查。

## 坑速查（都是实测踩出来的）

- 字段名是 `cascadeId`，不是 `conversationId`（后者报 "conversation id is required"）。
- 普通 unary JSON 调用即可；`connect+json` 流式帧会 415。
- `curl` 记得 `-X POST`（漏了会静默错）；证书自签必须 `-k`。
- 执行中途报 `streamGenerateContent EOF` 是网络瞬断，Antigravity 会自动重试，不用管。
- `steps` 解析失败时会打印原始 JSON 前 2000 字符——直接读原始响应找字段，别猜。
- macOS 自带 bash 3.2：改脚本时 `$var` 后紧跟中文字符会把多字节并进变量名（报 unbound variable），必须写 `${var}中文`。
- 本地 language_server 只暴露少数 RPC 方法（如 `GetUserQuotaSummary` 是 404），不在清单里的方法不可用。
- 空会话（`new` 之后没发过消息）不耗配额；删除用 `DeleteCascadeTrajectory`。
- Antigravity 关闭后所有子命令都会报 "language_server 未运行"，先启动桌面版。
- 会话数据真源在 `~/.gemini/antigravity/conversations/<uuid>.db`（cascadeId 即文件名去 `.db`）。

## 已验证环境

- macOS（Apple Silicon，兼容系统自带 bash 3.2）+ Antigravity v2.28.x（2026-11 实测）
- 主脑侧：ZCode、DSH（DeepSeek Harness）
- 与 anet（AgentNetwork）的关系：anet 官方虽有 Antigravity 插件，但官方从未实测，且同机通讯要绕公网 hub；本方案 RPC 直连是当前唯一实测可用的同机委派路径。

## FAQ

**Q: 会把我的代码 / 数据上传到哪吗？**
本技能所有流量都走本机回环（127.0.0.1），不向任何外部地址发数据。Antigravity 自身执行任务时的云上行为，遵循其官方协议与你的账号设置。

**Q: Antigravity 重启后要重新配置吗？**
不用。端口和 token 每次调用时自动重新定位。

**Q: 支持 Windows / Linux 吗？**
暂不支持。定位逻辑用了 macOS 的 `ps` / `lsof` / `stat -f`；欢迎 PR 适配。

**Q: 和直接开两个窗口手动复制粘贴比，强在哪？**
主脑 Agent 能持续监控轨迹、自动批安全权限、在停滞时发「继续」唤醒、最后核对磁盘产物——整条委派循环不需要人盯。

## 许可证

[MIT](LICENSE)
