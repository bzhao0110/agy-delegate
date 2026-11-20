#!/bin/bash
# agy.sh — Antigravity 委派控制台
# ZCode/DSH 当主脑，通过本地 RPC 驱动本机 Antigravity 执行任务。
# 用法: agy.sh <locate|new|send|steps|approve|quota> [参数]
# 详见同目录 ../SKILL.md
set -euo pipefail

AGY_CONV_DIR="$HOME/.gemini/antigravity/conversations"
SERVICE="exa.language_server_pb.LanguageServerService"

# 默认模型：Gemini 4 Hydrogen (High 思考)。仅当用户点名其他模型时才用 --model 覆盖。
# 2026-11-06 真机验证：StartCascade 与 SendUserCascadeMessage 均需带 cascadeConfig.plannerConfig.planModel
AGY_DEFAULT_MODEL="MODEL_PLACEHOLDER_M525"   # gemini-4-hydrogen-high
AGY_MODEL="${AGY_DEFAULT_MODEL}"

die() { echo "ERROR: $*" >&2; exit 1; }

# resolve_model <key或enum> → 输出 enum（key 表来自 GetAvailableModels 2026-11-06 快照）
resolve_model() {
  local in="$1"
  case "$in" in
    MODEL_*) echo "$in"; return 0 ;;
    gemini-4-hydrogen-high)  echo "MODEL_PLACEHOLDER_M525" ;;
    gemini-4-hydrogen-medium) echo "MODEL_PLACEHOLDER_M526" ;;
    gemini-4-hydrogen-low)   echo "MODEL_PLACEHOLDER_M527" ;;
    gemini-4-hydrogen-xhigh) echo "MODEL_PLACEHOLDER_M528" ;;
    gemini-3.8-flash-high)   echo "MODEL_PLACEHOLDER_M318" ;;
    gemini-3.8-flash-medium) echo "MODEL_PLACEHOLDER_M319" ;;
    gemini-3.8-flash-low)    echo "MODEL_PLACEHOLDER_M320" ;;
    gemini-3-flash)          echo "MODEL_PLACEHOLDER_M18" ;;
    gemini-3.1-flash-lite)   echo "MODEL_PLACEHOLDER_M50" ;;
    gemini-3.5-flash-lite)   echo "MODEL_PLACEHOLDER_M198" ;;
    gemini-2.5-flash)        echo "MODEL_GOOGLE_GEMINI_2_5_FLASH" ;;
    gemini-2.5-flash-lite)   echo "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE" ;;
    gemini-2.5-flash-thinking) echo "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING" ;;
    gemini-2.5-pro)          echo "MODEL_GOOGLE_GEMINI_2_5_PRO" ;;
    gemini-4-argon-high)     echo "MODEL_PLACEHOLDER_M417" ;;
    gemini-4-argon-medium)   echo "MODEL_PLACEHOLDER_M418" ;;
    gemini-4-argon-low)      echo "MODEL_PLACEHOLDER_M419" ;;
    claude-opus-5-5-high)    echo "MODEL_PLACEHOLDER_M402" ;;
    claude-opus-5-5-medium)  echo "MODEL_PLACEHOLDER_M401" ;;
    claude-opus-5-5-low)     echo "MODEL_PLACEHOLDER_M400" ;;
    claude-sonnet-5-5-high)  echo "MODEL_PLACEHOLDER_M405" ;;
    claude-sonnet-5-5-medium) echo "MODEL_PLACEHOLDER_M404" ;;
    claude-sonnet-5-5-low)   echo "MODEL_PLACEHOLDER_M403" ;;
    *) die "未知模型: ${in}（可用 key 见上表 / enum 直接传 MODEL_*；查全表用 agy.sh quota）" ;;
  esac
}

# ---------- 公共：动态定位 language_server（每次调用自动执行） ----------
PID=""; PORT=""; TOKEN=""
locate_ls() {
  PID=$(ps aux | grep "bin/language_server" | grep -v grep | awk '{print $2}' | head -1)
  [ -n "$PID" ] || die "Antigravity language_server 未运行——先启动 Antigravity 桌面版"
  local args
  args=$(ps -p "$PID" -o command=)
  TOKEN=$(echo "$args" | grep -o -- '--csrf_token [^ ]*' | awk '{print $2}')
  [ -n "$TOKEN" ] || die "未能从进程参数提取 csrf_token (pid=$PID)"
  PORT=$(lsof -nP -p "$PID" -a -i TCP -sTCP:LISTEN 2>/dev/null \
    | awk '{print $9}' | grep -o '127\.0\.0\.1:[0-9]*' | head -1 | cut -d: -f2)
  [ -n "$PORT" ] || die "未能找到 language_server 的本地 https 监听端口 (pid=$PID)"
}

# rpc <Method> <jsonBody>  → stdout 为响应体
rpc() {
  local method="$1" body="$2"
  curl -sk --max-time 90 -X POST \
    "https://127.0.0.1:${PORT}/${SERVICE}/${method}" \
    -H "Content-Type: application/json" \
    -H "x-codeium-csrf-token: ${TOKEN}" \
    -d "$body"
}

usage() {
  cat <<'EOF'
agy.sh — Antigravity 委派控制台
  agy.sh locate                     定位 port/token + 列出最近会话
  agy.sh new [--model X] [目录...]  新建会话（挂到对应项目下，可多个），输出 cascadeId
  agy.sh send [--model X] <id> <text...> 向会话发指令
  agy.sh steps <cascadeId> [N]      查轨迹步骤（默认只显示最后 N=15 步摘要）
  agy.sh approve <cascadeId> [--deny]  批准/拒绝当前待决权限（自动找 WAITING 步骤）
  agy.sh quota                      查三组两窗口配额余量

模型：默认 gemini-4-hydrogen-high (High 思考)；--model 接 key 或 MODEL_* enum 覆盖
     （仅当用户点名其他模型时才覆盖）。key 表：gemini-4-hydrogen-{high,medium,low,xhigh}、
     gemini-3.8-flash-{high,medium,low}、gemini-4-argon-{high,medium,low}、
     claude-{opus,sonnet}-5-5-{high,medium,low} 等，全表用 agy.sh quota 查。
EOF
}

# ---------- 子命令 ----------
cmd_locate() {
  locate_ls
  echo "PID=$PID"
  echo "PORT=$PORT"
  echo "TOKEN=$TOKEN"
  echo "BASE=https://127.0.0.1:${PORT}"
  echo "--- 最近会话（按修改时间倒序，取前 10） ---"
  if [ -d "$AGY_CONV_DIR" ]; then
    ls -t "$AGY_CONV_DIR" 2>/dev/null | grep '\.db$' | head -10 | while read -r f; do
      local id="${f%.db}"
      local when
      when=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$AGY_CONV_DIR/$f" 2>/dev/null || echo "?")
      echo "  $id  (mtime $when)"
    done
  else
    echo "  (无 $AGY_CONV_DIR)"
  fi
}

cmd_new() {
  # --model 必须在最前（可选）；默认 gemini-4-hydrogen-high
  if [ "${1:-}" = "--model" ]; then
    [ -n "${2:-}" ] || die "--model 需要一个值"
    AGY_MODEL=$(resolve_model "$2")
    shift 2
  fi
  locate_ls
  local ws="[]" dir items=""
  for dir in "$@"; do
    [ -d "$dir" ] || die "工作区目录不存在: $dir"
    items="${items}\"file://$(cd "$dir" && pwd)\","
  done
  [ -n "$items" ] && ws="[$(echo "$items" | sed 's/,$//')]"
  local id
  id=$(/usr/bin/uuidgen | tr 'A-Z' 'a-z')
  local body="{\"cascadeId\":\"${id}\",\"source\":\"CORTEX_TRAJECTORY_SOURCE_CASCADE_CLIENT\",\"workspaceUris\":${ws},\"overrideWorkspaceUris\":[],\"cascadeConfig\":{\"plannerConfig\":{\"planModel\":\"${AGY_MODEL}\"}}}"
  local resp
  resp=$(rpc StartCascade "$body")
  echo "CASCADE_ID=$id"
  echo "MODEL=${AGY_MODEL}"
  echo "RESP=${resp:0:300}"
}

cmd_send() {
  # --model 必须在最前（可选）；默认 gemini-4-hydrogen-high（对已有会话也强制切到此模型）
  if [ "${1:-}" = "--model" ]; then
    [ -n "${2:-}" ] || die "--model 需要一个值"
    AGY_MODEL=$(resolve_model "$2")
    shift 2
  fi
  [ $# -ge 2 ] || die "用法: agy.sh send [--model X] <cascadeId> <text...>"
  local id="$1"; shift
  local text="$*"
  locate_ls
  # JSON 转义交给 python，避免引号/换行打爆 -d；cascadeConfig 每条消息都带（换挡模型靠它）
  local body
  body=$(python3 - "$id" "$text" "$AGY_MODEL" <<'PY'
import json,sys
print(json.dumps({"cascadeId":sys.argv[1],"items":[{"text":sys.argv[2]}],
                  "cascadeConfig":{"plannerConfig":{"planModel":sys.argv[3]}}},ensure_ascii=False))
PY
)
  rpc SendUserCascadeMessage "$body"
  echo ""
  echo "SENT → cascade ${id}（model=${AGY_MODEL}，用 'agy.sh steps $id' 监控）"
}

cmd_steps() {
  [ $# -ge 1 ] || die "用法: agy.sh steps <cascadeId> [tailN]"
  local id="$1" tailn="${2:-15}"
  locate_ls
  local resp
  resp=$(rpc GetCascadeTrajectorySteps "{\"cascadeId\":\"${id}\",\"stepOffset\":0,\"verbosity\":\"VERBOSITY_ALL\"}")
  [ -n "$resp" ] || die "空响应——检查 cascadeId 是否存在（locate 列表核对）"
  # 响应可能超 argv 上限，走临时文件
  local tmp; tmp=$(mktemp); printf '%s' "$resp" > "$tmp"
  python3 - "$tmp" "$tailn" <<'PY'
import json,sys
data=json.loads(open(sys.argv[1]).read()); tailn=int(sys.argv[2])
steps=[]
def walk(o):
    if isinstance(o,dict):
        if any(isinstance(v,str) and v.startswith("CORTEX_STEP_STATUS_") for v in o.values()):
            steps.append(o); return
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(data)
if not steps:
    print("(未解析到步骤，原始响应前 2000 字符：)")
    print(json.dumps(data,ensure_ascii=False)[:2000]); sys.exit(0)
def pick(d,prefix):
    for v in d.values():
        if isinstance(v,str) and v.startswith(prefix): return v[len(prefix):]
    return "?"
def dig(d,*ks):
    for k in ks:
        if isinstance(d,dict) and k in d: d=d[k]
        else: return None
    return d
waiting=0
for s in steps[-tailn:]:
    st=pick(s,"CORTEX_STEP_STATUS_"); ty=pick(s,"CORTEX_STEP_TYPE_")
    info=dig(s,"metadata","sourceTrajectoryStepInfo") or {}
    tid=info.get("trajectoryId","-"); idx=s.get("stepIndex",info.get("stepIndex","?"))
    perm=dig(s,"requestedInteraction","permission")
    flag=""
    if st=="WAITING" and perm:
        waiting+=1
        tgt=dig(perm,"resource","target") or "(无命令内容)"
        flag=f"\n    ⚠ WAITING-PERMISSION 待批命令: {tgt[:500]}"
    print(f"[{idx}] {ty:<28} {st:<10} traj={str(tid)[:12]}{flag}")
print(f"--- 共 {len(steps)} 步，显示最后 {min(tailn,len(steps))} 步；待批权限 {waiting} 个 ---")
if waiting:
    print("→ 用 'agy.sh approve <cascadeId>' 批准（先看上面 ⚠ 行的命令内容）")
PY
  rm -f "$tmp"
}

cmd_approve() {
  [ $# -ge 1 ] || die "用法: agy.sh approve <cascadeId> [--deny]"
  local id="$1" action="allow"
  [ "${2:-}" = "--deny" ] && action="deny"
  locate_ls
  local resp
  resp=$(rpc GetCascadeTrajectorySteps "{\"cascadeId\":\"${id}\",\"stepOffset\":0,\"verbosity\":\"VERBOSITY_ALL\"}")
  # 找最后一个 WAITING 且带 permission 的步骤（响应走临时文件，避免超 argv）
  local tmp found
  tmp=$(mktemp); printf '%s' "$resp" > "$tmp"
  found=$(python3 - "$tmp" <<'PY'
import json,sys
data=json.loads(open(sys.argv[1]).read())
steps=[]
def walk(o):
    if isinstance(o,dict):
        if any(isinstance(v,str) and v.startswith("CORTEX_STEP_STATUS_") for v in o.values()):
            steps.append(o); return
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(data)
def dig(d,*ks):
    for k in ks:
        if isinstance(d,dict) and k in d: d=d[k]
        else: return None
    return d
for s in reversed(steps):
    perm=dig(s,"requestedInteraction","permission")
    st=next((v for v in s.values() if isinstance(v,str) and v.startswith("CORTEX_STEP_STATUS_")),"")
    if perm and st.endswith("WAITING"):
        info=dig(s,"metadata","sourceTrajectoryStepInfo") or {}
        print(json.dumps({
            "trajectoryId":info.get("trajectoryId"),
            "stepIndex":info.get("stepIndex",s.get("stepIndex")),
            "target":dig(perm,"resource","target") or ""
        },ensure_ascii=False))
        break
PY
)
  rm -f "$tmp"
  [ -n "$found" ] || { echo "没有待决（WAITING + permission）的步骤，无事可批。"; exit 0; }
  local tid idx target
  tid=$(echo "$found" | python3 -c "import json,sys;print(json.load(sys.stdin)['trajectoryId'])")
  idx=$(echo "$found" | python3 -c "import json,sys;print(json.load(sys.stdin)['stepIndex'])")
  target=$(echo "$found" | python3 -c "import json,sys;print(json.load(sys.stdin)['target'])")
  echo "待批步骤 stepIndex=$idx"
  echo "命令内容: ${target:0:1000}"
  if [ "$action" = "allow" ]; then
    # 危险命令守门：命中即拒批，转人工
    if echo "$target" | grep -qEi 'rm[[:space:]]+(-[a-zA-Z]*[rf]|--force)|git[[:space:]]+(push|reset[[:space:]]+--hard|clean)|sudo|mkfs|diskutil[[:space:]]+(erase|apfs)|dd[[:space:]]+if=|(curl|wget)[^|]*\|[[:space:]]*(ba|z)?sh|chmod[[:space:]]+-R[[:space:]]+777|>:[[:space:]]*/dev/'; then
      echo "⛔ 危险命令模式命中，agy.sh 拒绝自动批准——请人工确认后用 --deny 或在 Antigravity UI 处理。"
      exit 3
    fi
    local body="{\"cascadeId\":\"${id}\",\"interaction\":{\"trajectoryId\":\"${tid}\",\"stepIndex\":${idx},\"permission\":{\"allow\":true,\"scope\":\"PERMISSION_SCOPE_ONCE\"}}}"
    local out; out=$(rpc HandleCascadeUserInteraction "$body")
    echo "APPROVED(ONCE) → $out"
  else
    local body="{\"cascadeId\":\"${id}\",\"interaction\":{\"trajectoryId\":\"${tid}\",\"stepIndex\":${idx},\"permission\":{\"allow\":false,\"scope\":\"PERMISSION_SCOPE_ONCE\"}}}"
    local out; out=$(rpc HandleCascadeUserInteraction "$body")
    echo "DENIED → $out"
  fi
}

cmd_quota() {
  locate_ls
  echo "=== RetrieveUserQuotaSummary（三组两窗口余量+resetTime）==="
  rpc RetrieveUserQuotaSummary "{}" | python3 -m json.tool 2>/dev/null || rpc RetrieveUserQuotaSummary "{}"
  echo ""
  echo "=== GetAvailableModels（模型→配额组映射，前 3000 字符）==="
  rpc GetAvailableModels "{}" | head -c 3000
  echo ""
}

case "${1:-}" in
  locate) shift; cmd_locate ;;
  new)    shift; cmd_new "$@" ;;
  send)   shift; cmd_send "$@" ;;
  steps)  shift; cmd_steps "$@" ;;
  approve) shift; cmd_approve "$@" ;;
  quota)  shift; cmd_quota ;;
  *) usage; exit 1 ;;
esac
