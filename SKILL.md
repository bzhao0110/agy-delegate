---
name: agy-delegate
description: 委派任务给本机 Antigravity（ZCode/DSH 当主脑、Antigravity 当执行副引擎）：本地 RPC 定位、新建/选择会话、发指令、监控轨迹步骤、远程批权限、查配额。当用户要把编码/文档/生成类任务交给 Antigravity 执行、或提到 agy 委派、Antigravity 副引擎、双引擎时使用。
---

# agy-delegate — Antigravity 委派控制台

通过 Antigravity 本地 language_server 的 Connect RPC（127.0.0.1 随机端口 + CSRF token），
把主脑 Agent 写好的 prompt 注入 Antigravity 会话执行，主脑负责监控、批权限、验收产物。
2026-11-01 全流程实测跑通（批权限 4 次、交付 PPT），本技能是该方法论的固化。

**前提**：Antigravity 桌面版正在运行（重启后端口/token 会变，脚本每次调用自动重定位，无需关心）。

## 快速流程（标准委派循环）

```bash
S=~/.agents/skills/agy-delegate/scripts/agy.sh

$S locate                  # 1. 拿会话清单（或 new 新建）
$S new ~/Documents/某项目   #    新任务建议新建会话，带工作区目录
$S send <cascadeId> <指令>  # 2. 发任务（指令它当用户原话执行）
# 3. 监控循环：
$S steps <cascadeId>       #    看进度；出现 ⚠ WAITING-PERMISSION 就处理
$S approve <cascadeId>     #    批权限（ONCE；自动显示命令；危险模式拒批转人工）
$S send <cascadeId> 继续    #    停滞时发"继续"唤醒
# 4. 验收：steps 全 DONE 后，检查磁盘产物并汇报给用户
```

**默认模型：`gemini-4-hydrogen-high`（Gemini 4 Hydrogen，High 思考）**。`new`/`send`
已内置自动携带（`cascadeConfig.plannerConfig.planModel`，StartCascade 与每条消息都带），
无需任何额外参数。**只有用户明确点名其他模型时**才用 `--model` 覆盖，例如：
`$S new --model claude-opus-5-5-high ~/Documents/某项目`。不要自行替用户换挡。

## 硬性规矩

1. **发出的指令会被 Antigravity 当作用户原话执行**——重要 prompt 发前给用户过目。
2. **危险命令（删文件、git push、覆盖产物）必须先向用户确认**；`approve` 内置危险模式
   守门（rm -rf / git push / sudo / curl|sh 等），命中即拒批退出码 3，此时转人工处理。
3. 主脑 Agent 的职责：写 prompt → 监控 → 核内容后批权限 → 验收**磁盘产物**并汇报。
   不要只看 Antigravity 说"完成"就交付。
4. 每次委派消耗 Antigravity 配额（任何消息地板成本 ≈1.7 万 token）：
   **默认 `gemini-4-hydrogen-high`，不问就用它**；用户点名其他模型才 `--model` 换挡。
   Hydrogen 与 3.8 Flash 共用同一 Gemini 配额组（周 + 5h 双窗口），日常随便用；
   **Argon 全周仅 ≈48 次调用，留关键节点，默认绝不使用**；
   Claude 组（Opus/Sonnet 5.5）与 Gemini 配额互不占，是白送第二引擎，定稿级任务可建议
   `claude-opus-5-5-high`（但先问用户）。用 `$S quota` 查余量。

## 子命令参考

| 命令 | 说明 |
|---|---|
| `locate` | 输出 PID/PORT/TOKEN/BASE + 最近 10 个会话（mtime 倒序） |
| `new [--model X] [目录...]` | StartCascade 新建会话（默认模型 gemini-4-hydrogen-high），输出 CASCADE_ID；目录转 file:// workspaceUri。**会话挂在对应项目分组下**（UI 左侧 Projects 与 workspace 目录一一对应，2026-11-06 实测 blob 归属一致）；可传多个目录挂多工作区 |
| `send [--model X] <id> <text>` | SendUserCascadeMessage 发指令（每条消息都带默认/指定模型）；JSON 由 python3 转义，引号换行随意 |
| `steps <id> [N]` | GetCascadeTrajectorySteps；宽松解析出每步 type/status，显示最后 N=15 步；WAITING+permission 高亮并提示 approve |
| `approve <id> [--deny]` | 自动定位最新待决步骤 → 打印命令 → 守门检查 → HandleCascadeUserInteraction（scope=ONCE 最稳） |
| `quota` | RetrieveUserQuotaSummary + GetAvailableModels（配额组映射） |

`--model` 必须是子命令的第一个参数，接模型 key 或 `MODEL_*` enum。

会话文件真源：`~/.gemini/antigravity/conversations/<uuid>.db`（cascadeId 即文件名去 `.db`）。

**项目 = 工作区目录**（UI 左侧 Projects 分组按 workspace 归属，与 `new` 传的目录一一对应）。
`new` 传哪个目录，会话就挂在哪个项目分组下；要挂到已有项目，传该项目的目录即可。

## 模型速查（key → enum，2026-11-15 GetAvailableModels 快照）

默认 **`gemini-4-hydrogen-high` = `MODEL_PLACEHOLDER_M525`**（High 思考，thinkingLevel=3）。
换挡只用 `--model`，key/enum 均可：

| 模型 key | enum | 说明 |
|---|---|---|
| `gemini-4-hydrogen-high` | `MODEL_PLACEHOLDER_M525` | **默认**，日常委派（2026-11-15 起接替 3.8-flash） |
| `gemini-4-hydrogen-medium` / `-low` | `M526` / `M527` | 降档省配额 |
| `gemini-4-hydrogen-xhigh` | `M528` | 超高档（thinkingLevel=100），重任务可选 |
| `gemini-3.8-flash-high` / `-medium` / `-low` | `M318` / `M319` / `M320` | 上一代默认，与 Hydrogen 共用 Gemini 配额组 |
| `gemini-4-argon-high` / `-medium` / `-low` | `M417` / `M418` / `M419` | Argon 全周仅 ≈48 次，慎用 |
| `claude-opus-5-5-high` / `-medium` / `-low` | `M402` / `M401` / `M400` | 定稿级，Claude 组配额独立 |
| `claude-sonnet-5-5-high` / `-medium` / `-low` | `M405` / `M404` / `M403` | Claude 组 |
| `gemini-flash-worker-agy` | `M669` | 内部 Orchestrator（Hydrogen），displayName 与主模型同名易混，勿手动指定 |
| `gemini-3-flash` | `M18` | 旧档 |
| `gemini-2.5-pro` / `gemini-2.5-flash` 系 | `MODEL_GOOGLE_GEMINI_2_5_*` | 旧 2.5 系（displayName 混乱，勿信 UI 名） |

配额分组（2026-11-15 实测）：Gemini 组 = Hydrogen + 3.8 Flash（周 + 5h 双窗口共享）；
Argon 独立周窗口；Claude/GPT 组独立。

注意：**UI/接口 displayName 不可信**（多个不同模型都显示 "Gemini 3.5 Flash Lite"），
认 key 和 enum。全表以 `$S quota` 实时输出为准。
StartCascade 带 `baseTrajectoryIdentifier` 是 fork 语义，会报 "not a local conversation"，不要用。

## 坑速查（全部实测过）

- 字段名是 `cascadeId`，不是 `conversationId`（后者报 "conversation id is required"）。
- 普通 unary JSON 调用即可；`connect+json` 流式帧会 415。
- `curl` 记得 `-X POST`（漏了会静默错）；证书自签必须 `-k`。
- 中途 `CORTEX_STEP_TYPE_ERROR_MESSAGE: streamGenerateContent EOF` 是网络瞬断，
  Antigravity 自动重试，不用管。
- `steps` 解析失败时会打印原始 JSON 前 2000 字符——直接读原始体找字段，别猜。
- 改 agy.sh 时：macOS bash 3.2 + 中文，`$var` 后紧跟中文字符会把多字节字节并进变量名
  （报 unbound variable）——必须写 `${var}中文`（2026-11-06 实测踩坑）。
- 本地 LS 只暴露少数 RPC 方法（如 GetUserQuotaSummary 404），不在清单里的方法不可用。
- 空会话（StartCascade 后未发消息）不耗配额；删除用 DeleteCascadeTrajectory。
- Antigravity 关闭后所有子命令都会报 "language_server 未运行"，先启动桌面版。

## 与 anet(AgentNetwork) 的关系

anet 官方虽有 Antigravity 插件，但官方从未实测过，且同机通讯要绕公网 hub。
本技能的 RPC 直连是当前唯一验证可用的同机委派路径（2026-11-06 调研结论）。
