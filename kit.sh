#!/usr/bin/env bash
# 流程管家：看门人。记住做哪个产品、第几阶段；给出本阶段任务；自检没过不让翻页。
# 不碰模型、不花钱、不存密钥。规则仍在 AGENTS.md 和手册里，管家只保证"该交的交了、该停的停了"。
#
# 主路线（AI 在对话里调用，产品经理只管聊天）：
#   bash kit.sh 任务 [产品名]              给出本阶段任务（写到 docs/本阶段任务.md 并打印）
#   bash kit.sh 自检 [产品名]              跑 verify.sh，结果记入状态；退出码 0 = 过
#   bash kit.sh 通过 [产品名] [下一阶段]    产品经理在对话里说"验收通过"后才能调；自检没过会被拒绝
#   bash kit.sh 状态 [产品名]              现在到哪了
#   bash kit.sh 回到 [产品名] 阶段X         管家记的阶段和实际不符时手动校正
# 副路线（产品经理双击 开工.command）：
#   bash kit.sh                            一个窗口带着走：打开编码工具、关掉后自检、问验收
#   bash kit.sh 换工具 [产品名]             下次双击重新选编码工具
# 只有一个产品时产品名可省略。
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

say()  { printf '%s\n' "$*"; }
line() { say "────────────────────────────────────────────────────────"; }
ask()  { # 交互模式用。ask "问题" → ANS
  printf '%s ' "$1"
  if ! IFS= read -r ANS; then say; say "没有收到输入，先到这里。下次双击开工继续。"; exit 1; fi
  ANS="$(printf '%s' "$ANS" | tr -d '[:space:]')"
}
ask_yn() { while :; do ask "$1 [y/n]"; case "$ANS" in y|Y|是) return 0;; n|N|否) return 1;; esac; say "请输入 y 或 n。"; done; }

# ---------- 参数：子命令 [产品名] [其他] ----------
CMD="${1:-}"; shift || true
PRODUCTS=()
for d in projects/*/; do [ -d "$d" ] && PRODUCTS+=("$(basename "$d")"); done
if [ "${#PRODUCTS[@]}" -eq 0 ]; then say "projects/ 下没有产品文件夹。先按 README 放好 PRD，或让 AI 新建产品。"; exit 2; fi
PRODUCT=""
if [ $# -ge 1 ] && [ -d "projects/$1" ]; then PRODUCT="$1"; shift
elif [ "${#PRODUCTS[@]}" -eq 1 ]; then PRODUCT="${PRODUCTS[0]}"
elif [ -n "$CMD" ]; then
  say "有多个产品，请指明：bash kit.sh ${CMD} <产品名> ...   现有：${PRODUCTS[*]}"; exit 2
else
  say "有多个产品，这次做哪个？"; i=1
  for p in "${PRODUCTS[@]}"; do
    st="还没开始"; [ -f "projects/$p/docs/流程状态.txt" ] && st="$(grep -m1 '^阶段=' "projects/$p/docs/流程状态.txt" | cut -d= -f2-)"
    say "  $i) ${p}（${st}）"; i=$((i+1))
  done
  while :; do ask "输入编号："; if [[ "$ANS" =~ ^[0-9]+$ ]] && [ "$ANS" -ge 1 ] && [ "$ANS" -le "${#PRODUCTS[@]}" ]; then PRODUCT="${PRODUCTS[$((ANS-1))]}"; break; fi; done
fi
P="projects/$PRODUCT"
STATE="$P/docs/流程状态.txt"
HIST="$P/docs/流程历史.txt"
TASK="$P/docs/本阶段任务.md"
mkdir -p "$P/docs"

# ---------- 状态文件（key=value） ----------
sget() { [ -f "$STATE" ] && grep -m1 "^$1=" "$STATE" | cut -d= -f2- || true; }
sset() { local t; t="$(mktemp)"; { [ -f "$STATE" ] && grep -v "^$1=" "$STATE"; printf '%s=%s\n' "$1" "$2"; } > "$t" 2>/dev/null; mv "$t" "$STATE"; }
hist() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >> "$HIST"; }
valid_stage() { [[ "$1" =~ ^(阶段0|阶段1|阶段2-[1-9][0-9]*|阶段3-(0|[1-9][0-9]*)|阶段4|阶段5|完成)$ ]]; }

if [ ! -f "$STATE" ]; then
  sset 阶段 阶段0
  sset 状态 待开工
  if [ -f "$P/docs/项目状态.md" ]; then
    sset 待恢复 是
    say "已找到原有项目记录，将由 AI 核对并恢复进度；你不需要填写阶段编号或重填需求。"
    hist "找到旧项目，等待 AI 根据已有记录恢复"
  else
    hist "管家开始记录，起点 阶段0"
  fi
fi

# 目录可以被 AI 改名，内部编号随状态文件移动，窗口据此接回同一产品。
PROJECT_ID="$(sget 产品编号)"
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID="kit-$(date +%s)-$$-$RANDOM-$RANDOM"
  sset 产品编号 "$PROJECT_ID"
fi

rebind_product() {
  local statepath
  local matches=()
  for statepath in projects/*/docs/流程状态.txt; do
    [ -f "$statepath" ] || continue
    if grep -Fxq -- "产品编号=$PROJECT_ID" "$statepath"; then
      matches+=("${statepath%/docs/流程状态.txt}")
    fi
  done
  if [ "${#matches[@]}" -ne 1 ]; then
    say "暂未找到唯一的原项目记录。请让 AI 核对刚才的目录改名或移动，再继续；已有文件保留。"
    return 1
  fi
  P="${matches[0]}"; PRODUCT="${P#projects/}"
  STATE="$P/docs/流程状态.txt"; HIST="$P/docs/流程历史.txt"; TASK="$P/docs/本阶段任务.md"
}

# ---------- 阶段信息（来自 AGENTS.md 第 7 节加载表） ----------
stage_info() { # 设置 READ OUT PM PASS NOCODE
  NOCODE=0
  case "$1" in
    阶段0) READ="AGENTS.md；docs/PRD/；通用手册第二节与《二之一、PRD 体检》"
           OUT="docs/阶段文档/阶段0-PRD补全清单.md；docs/evidence/阶段0/是否表.md；docs/项目状态.md（新建或更新）"
           PM="只回答本轮关键问题（通常 1–3 个，最多 5 个，可回复\"按推荐\"）；AI 整理材料"
           PASS="《PRD 补全清单》中本轮必须明确的事项已关闭；后续事项记好验证时机"; NOCODE=1 ;;
    阶段1) READ="通用手册第一部分（一至六节）"
           OUT="docs/阶段文档/技术适配声明.md（含第 7 节子阶段规划）；决策台账初版；docs/evidence/阶段1/是否表.md"
           PM="确认三件事：理解和子阶段规划对不对 / 有没有新增费用·平台·范围 / 暂缓项影不影响验收"
           PASS="台账无影响本阶段的待定项"; NOCODE=1 ;;
    阶段2-*) READ="通用手册第二、三部分"
           OUT="docs/阶段文档/$1技术开发文档.md；代码；产品 README.md；证据包 docs/evidence/$1/（截图、照着做清单、是否表、verify-输出、冒烟记录）"
           PM="需要真实验证时配置模型 Key；按\"照着做\"清单验收；判断真实样例是否有用"
           PASS="证据包已交 + 是否表全\"是\"" ;;
    阶段3-0) READ="前端手册全文"
           OUT="docs/阶段文档/前端适配声明.md；docs/evidence/阶段3-0/是否表.md"
           PM="给视觉方向（或说\"中性风格\"）；确认前端适配声明"
           PASS="声明经产品经理确认"; NOCODE=1 ;;
    阶段3-*) READ="前端手册全文（重点第 22 节本子阶段对应部分）"
           OUT="docs/阶段文档/$1技术开发文档.md；前端代码；产品 README.md；证据包 docs/evidence/$1/"
           PM="看代表页反馈；用手机走一遍"
           PASS="证据包已交 + 是否表全\"是\"" ;;
    阶段4) READ="部署手册全文"
           OUT="docs/阶段文档/上线方案摘要.md（含费用与耗时估算）；部署；产品 README.md；证据包 docs/evidence/阶段4/"
           PM="注册腾讯云并实名、浏览器授权命令行登录、开通云开发环境并启用云托管、创建服务端 API Key 并点复制、确认费用、按验收清单验证"
           PASS="部署手册第六部分验收清单全过" ;;
    阶段5) READ="部署手册第五部分\"收尾\""
           OUT="产品 README.md；docs/项目状态.md 记录本轮交付范围、待验证项与可选下轮改进；已上线的再完成登录退出和密钥到期提醒"
           PM="确认本轮成果和使用办法；已上线的确认退出本机登录后服务仍正常"
           PASS="状态文件记录完成"; NOCODE=1 ;;
    *) READ="（未知阶段）"; OUT=""; PM=""; PASS="" ;;
  esac
}

# 下一阶段的候选：唯一时 NEXT_FIXED 有值；有分岔时 NEXT_OPTS 列出可选项
next_options() {
  local cur="$1" n; NEXT_FIXED=""; NEXT_OPTS=""
  case "$cur" in
    阶段0) NEXT_FIXED=阶段1 ;;
    阶段1) NEXT_FIXED=阶段2-1 ;;
    阶段2-*) n="${cur#阶段2-}"; NEXT_OPTS="阶段2-$((n+1)) 阶段3-0" ;;
    阶段3-0) NEXT_FIXED=阶段3-1 ;;
    阶段3-*) n="${cur#阶段3-}"; NEXT_OPTS="阶段3-$((n+1)) 阶段4 阶段5" ;;
    阶段4) NEXT_FIXED=阶段5 ;;
    阶段5) NEXT_FIXED=完成 ;;
    *) NEXT_FIXED=完成 ;;
  esac
}
explain_options() { # 用产品语言解释分岔
  case "$1" in
    阶段2-*) say "  阶段2-$(( ${1#阶段2-} + 1 ))：阶段 2 还有下一个子阶段（看《技术适配声明》第 7 节子阶段规划）"; say "  阶段3-0：阶段 2 做完了，进入正式前端" ;;
    阶段3-*) say "  阶段3-$(( ${1#阶段3-} + 1 ))：阶段 3 还有下一个子阶段"; say "  阶段4：上线（要注册腾讯云）"; say "  阶段5：这次做到合格为止，直接收尾" ;;
  esac
}

# ---------- 本阶段任务文件 ----------
write_task() { # $1 阶段 $2 模式 chat|window
  local st="$1" mode="$2" n lastfail=""
  if [ "$(sget 待恢复)" = "是" ]; then
    {
      say "# 先恢复已有进度（由 AI 处理）"
      say "先读取 AGENTS.md 和 $P/docs/项目状态.md，核对已有需求、阶段产物、决定和待验事项。"
      say "不重填需求，不重做已有工作，不让用户输入阶段编号。"
      say "确定当前阶段后，运行 bash kit.sh 回到 \"$PRODUCT\" <当前阶段>，再运行 bash kit.sh 任务 \"$PRODUCT\"，按新任务继续。"
      say "无法从材料确定时，只询问目前做到什么结果；已有证据不足时由 AI 安排重验。"
    } > "$TASK"
    return
  fi
  stage_info "$st"
  n="$(sget 开工次数)"; n=$(( ${n:-0} + 1 )); sset 开工次数 "$n"
  if [ "$(sget 状态)" = "自检没过" ] && [ -f "$P/docs/evidence/$st/verify-输出.txt" ]; then
    lastfail="$( { grep -E '^(缺：|问题：|放错位置：)' "$P/docs/evidence/$st/verify-输出.txt"; sed -n '/汇总/,$p' "$P/docs/evidence/$st/verify-输出.txt" | grep -E '不通过|未配置|待验'; } | sort -u || true)"
  fi
  {
    say "# 本阶段任务（流程管家自动生成，每次开工覆盖；AI 不要改这个文件）"
    say
    say "- 产品：${PRODUCT}（文件夹 projects/${PRODUCT}/）"
    say "- 阶段：${st}（本阶段第 ${n} 次开工）"
    say "- 生成时间：$(date '+%Y-%m-%d %H:%M')"
    say
    say "## 先做"
    say "1. 读工具包根目录的 AGENTS.md，按第 0 节启动流程处理这个产品（有 docs/项目状态.md 就是老项目，从它记录的地方接着做）。"
    say "2. 本阶段只读这些手册内容：${READ}。读完按 AGENTS.md 第 7 节做一次对账（列出与十条底线冲突的句子，没有就说\"已对账，无冲突\"）。"
    say
    say "## 本阶段要交的"
    say "${OUT}"
    say "证据包的固定文件见 AGENTS.md 第 5 节。"
    say
    say "## 产品经理这阶段要做的（由你翻译成\"去哪、点什么、填什么、看到什么算对\"）"
    say "${PM}"
    say
    say "## 通过条件"
    say "${PASS}"
    if [ -n "$lastfail" ]; then
      say
      say "## 上次自检没过的项（先解决这些）"
      say '```'
      say "$lastfail"
      say '```'
    fi
    say
    say "## 规矩"
    say "- 只做 ${st}，不做下一阶段的事。$( [ "$NOCODE" -eq 1 ] && say "这是无代码阶段，不要写代码、不要建 backend/ frontend/。" )"
    say "- 需要产品经理决定的事，用决策卡当面问他（一次不超过 5 个），记入 docs/项目状态.md。"
    say "- 做完后在工具包根目录运行 \`bash kit.sh 自检 ${PRODUCT}\`（它会跑 verify.sh 并记录结果），把六项结果抄进是否表。"
    say "- 不要修改 docs/本阶段任务.md、docs/流程状态.txt、docs/流程历史.txt，它们归流程管家。"
    if [ "$mode" = "chat" ]; then
      say "- 自检通过后，把 docs/evidence/${st}/照着做清单.md 的内容用产品语言讲给产品经理，请他验收；他明确说\"验收通过\"后，才运行 \`bash kit.sh 通过 ${PRODUCT}\`（有分岔时按它提示带上下一阶段名）。他没说通过，就不要调。"
    else
      say "- 全部做完后对产品经理说这句话：\"本阶段实现与证据已准备好，请回到开工窗口查看自检结果。\""
    fi
  } > "$TASK"
}

run_verify() { # 跑自检并记状态；返回 verify 退出码
  local st="$1" rc
  if [ "$(sget 待恢复)" = "是" ]; then
    say "先让 AI 根据已有项目状态恢复进度，再检查对应阶段。"
    return 1
  fi
  bash verify.sh "$PRODUCT" "$st"; rc=$?
  if [ "$rc" -eq 0 ]; then sset 状态 等验收; hist "${st} 自检通过"; else sset 状态 自检没过; hist "${st} 自检没过"; fi
  return "$rc"
}

receipt() {
  if ! command -v python3 >/dev/null 2>&1; then
    say "待验：电脑上缺少 Python 3，请让 AI 协助准备检查环境。"; return 1
  fi
  python3 -B scripts/kit_checks.py gate "$P" "$1"
}

advance() { # 聊天和双击都在此核对当前版本，再记录用户验收
  local verification
  if ! verification="$(receipt "$1")"; then
    say "$verification"
    sset 状态 自检没过; hist "$1 验收未推进：当前版本缺少有效自检结果"
    say "下一步：让 AI 运行 bash kit.sh 自检 \"$PRODUCT\"，通过后再验收。"
    return 1
  fi
  hist "$1 验收通过 → $2（验证编号：${verification}）"
  sset 最近验收编号 "$verification"
  sset 阶段 "$2"; sset 状态 待开工; sset 开工次数 0
}

show_status() {
  local st status
  st="$(sget 阶段)"; status="$(sget 状态)"; stage_info "$st"
  line; say "产品：${PRODUCT}"; say "阶段：${st}　　状态：${status}"
  [ -n "$(sget 工具)" ] && say "编码工具：$(tool_name "$(sget 工具)")"
  if [ "$st" = "完成" ]; then
    say "已完成：本轮确认范围已交付。"
    say "待验：以项目状态中的待验证项为准；工程交付不代表市场需求已被验证。"
    say "可继续：使用产品，收集真实反馈，由 AI 整理下轮改进。"
    say "你的下一步：按产品 README 使用；有反馈时直接告诉 AI。"
  else
    if [ "$status" = "等验收" ]; then
      say "已完成：本阶段当前版本的自动检查。"
      say "待验：你确认实际结果是否满足需求。"
      say "可继续：按 AI 提供的验收步骤体验本轮结果。"
      say "你的下一步：结果符合预期时说“验收通过”；有问题直接描述。"
    else
      say "已完成：已有材料与决定保留；具体进度见项目状态。"
      say "待验：本阶段尚未取得当前版本的有效验收结果。"
      say "可继续：补需求、整理样例，或修复本阶段不依赖缺失配置的内容。"
      say "你的下一步：对 AI 说“继续这个项目，告诉我目前只需要做什么”。"
    fi
  fi
  line
}

# ---------- 编码工具（只有双击路线用） ----------
tool_name() { case "$1" in
  claude) echo "Claude Code";; codex) echo "Codex";; pi) echo "Pi";; gemini) echo "Gemini CLI";; opencode) echo "OpenCode";;
  cursor) echo "Cursor 命令行版";; kimi) echo "Kimi Code";; mimo) echo "MiMo Code";; zcode) echo "Z Code";;
  other) echo "其他工具（Cursor、Windsurf、Trae 等带界面的）";; *) echo "$1";; esac; }
tool_mode() { case "$1" in claude|codex|pi|gemini|opencode|cursor) echo auto;; kimi|mimo|zcode) echo semi;; *) echo manual;; esac; }
tool_bin()  { case "$1" in cursor) command -v cursor-agent >/dev/null 2>&1 && echo cursor-agent || echo agent;; *) echo "$1";; esac; }
detect_tools() { FOUND=(); for t in claude codex pi gemini opencode cursor kimi mimo zcode; do command -v "$(tool_bin "$t")" >/dev/null 2>&1 && FOUND+=("$t"); done; }
choose_tool() {
  detect_tools
  if [ "${#FOUND[@]}" -eq 0 ]; then say "电脑上没找到我认识的编码工具，用通用模式。"; TOOL=other; return; fi
  say "电脑上装了这些编码工具："; i=1
  for t in "${FOUND[@]}"; do say "  $i) $(tool_name "$t")"; i=$((i+1)); done
  say "  $i) $(tool_name other)"
  while :; do ask "用哪个？输入编号（直接回车 = 1）："; [ -z "$ANS" ] && ANS=1
    if [[ "$ANS" =~ ^[0-9]+$ ]] && [ "$ANS" -ge 1 ] && [ "$ANS" -le "$i" ]; then
      if [ "$ANS" -eq "$i" ]; then TOOL=other; else TOOL="${FOUND[$((ANS-1))]}"; fi; break
    fi
  done
}
copy_clip() { if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$1" | pbcopy; return 0; fi; return 1; }
launch_tool() { # $1 工具 $2 开场白
  local t="$1" prompt="$2" mode bin
  mode="$(tool_mode "$t")"; bin="$(tool_bin "$t")"
  case "$mode" in
    auto)
      say "正在打开 $(tool_name "$t")，开场白已经贴好。像平时一样和它对话；它说\"本阶段实现与证据已准备好\"你就关掉它（输入 /exit 或按两次 Ctrl+C），回到这个窗口。"
      line
      case "$t" in
        claude|codex|pi|cursor) "$bin" "$prompt" ;;
        gemini)   "$bin" -i "$prompt" ;;
        opencode) "$bin" --prompt "$prompt" ;;
      esac ;;
    semi)
      if copy_clip "$prompt"; then say "开场白已复制到剪贴板。"; else say "开场白如下（请复制）："; say "    $prompt"; fi
      say "正在打开 $(tool_name "$t")。打开后按 Command+V 粘贴开场白并回车；它说\"本阶段实现与证据已准备好\"你就关掉它，回到这个窗口。"
      line
      "$bin" ;;
    *)
      if copy_clip "$prompt"; then say "开场白已复制到剪贴板。"; else say "开场白如下（请复制）："; fi
      say "    $prompt"
      say "现在打开你的编码工具，让它打开工具包文件夹，粘贴上面这句并发送。它说\"本阶段实现与证据已准备好\"你就回到这个窗口。"
      ask "聊完后按回车继续："
      ;;
  esac
  line
}

# ======================================================================
# 主路线：AI 在对话里调用的子命令（不交互）
# ======================================================================
STAGE="$(sget 阶段)"; STATUS="$(sget 状态)"
# 恢复旧项目或改动过输入时，不能把历史“等验收”当成本版本已通过。
if [ "$STATUS" = "等验收" ] && [ "$STAGE" != "完成" ]; then
  case "$CMD" in
    任务|状态|通过|"")
      if ! CURRENT_RECEIPT="$(receipt "$STAGE")"; then
        say "$CURRENT_RECEIPT"
        sset 状态 自检没过; STATUS=自检没过
        hist "$STAGE 当前验收依据失效，保留进度等待重新自检"
        say "下一步：让 AI 运行 bash kit.sh 自检 \"$PRODUCT\"，通过后再验收。"
        case "$CMD" in 通过|"") exit 1;; esac
      fi ;;
  esac
fi
case "$CMD" in
  状态) show_status; exit 0 ;;

  任务)
    if [ "$STAGE" = "完成" ]; then say "这个产品的流程已经走完。要再改，先：bash kit.sh 回到 ${PRODUCT} 阶段X"; exit 0; fi
    if [ "$STATUS" = "等验收" ]; then
      say "${STAGE} 的自检已经通过，现在等产品经理验收。"
      say "把 docs/evidence/${STAGE}/照着做清单.md 讲给他，请他验收；他说\"验收通过\"后运行：bash kit.sh 通过 ${PRODUCT}"
      say "他要改东西，就改完再跑一次：bash kit.sh 自检 ${PRODUCT}"
      exit 0
    fi
    write_task "$STAGE" chat; sset 状态 做中; hist "${STAGE} 开工（第 $(sget 开工次数) 次，对话模式）"
    cat "$TASK"; exit 0 ;;

  自检)
    if [ "$STAGE" = "完成" ]; then say "流程已完成，没有要自检的阶段。"; exit 0; fi
    run_verify "$STAGE"; rc=$?
    line
    if [ "$rc" -eq 0 ]; then say "管家记录：${STAGE} 自检通过，状态=等验收。下一步请产品经理验收；他说\"验收通过\"后运行：bash kit.sh 通过 ${PRODUCT}"
    else say "管家记录：${STAGE} 自检没过，状态=自检没过。先补上面报的项，再跑一次自检。不能进下一阶段。"; fi
    exit "$rc" ;;

  通过)
    WANT="${1:-}"
    if [ "$STAGE" = "完成" ]; then say "流程已完成。"; exit 0; fi
    if [ "$STATUS" != "等验收" ]; then
      say "拒绝：${STAGE} 的状态是\"${STATUS}\"，不是\"等验收\"。先运行 bash kit.sh 自检 ${PRODUCT} 并通过，再请产品经理验收。"; exit 1
    fi
    next_options "$STAGE"
    if [ -n "$NEXT_FIXED" ]; then
      [ -n "$WANT" ] && [ "$WANT" != "$NEXT_FIXED" ] && { say "拒绝：${STAGE} 之后只能是 ${NEXT_FIXED}。"; exit 1; }
      NEXT="$NEXT_FIXED"
    else
      if [ -z "$WANT" ]; then
        say "${STAGE} 之后有分岔，请先按已有子阶段规划选择；只有范围或费用出现新决定时才询问产品经理。由 AI 带上下一阶段名重新运行：bash kit.sh 通过 ${PRODUCT} <下一阶段>"
        explain_options "$STAGE"; exit 1
      fi
      ok=0; for o in $NEXT_OPTS; do [ "$o" = "$WANT" ] && ok=1; done
      [ "$ok" -eq 1 ] || { say "拒绝：${STAGE} 之后只能是：${NEXT_OPTS}"; explain_options "$STAGE"; exit 1; }
      NEXT="$WANT"
    fi
    advance "$STAGE" "$NEXT" || exit 1
    if [ "$NEXT" = "完成" ]; then say "已记录：${STAGE} 验收通过。全部完成！"; else say "已记录：${STAGE} 验收通过，翻到 ${NEXT}。下一步运行：bash kit.sh 任务 ${PRODUCT}"; fi
    exit 0 ;;

  回到)
    WANT="${1:-}"; valid_stage "$WANT" || { say "用法：bash kit.sh 回到 ${PRODUCT} 阶段2-1（阶段名要像 阶段0、阶段2-1、阶段3-0 这样）"; exit 1; }
    sset 待恢复 否; sset 阶段 "$WANT"; sset 状态 待开工; sset 开工次数 0; hist "手动校正到 ${WANT}"; say "已回到 ${WANT}。"; exit 0 ;;

  换工具) sset 工具 ""; say "好，下次双击开工会重新问用哪个工具。"; exit 0 ;;
  "") ;;
  *) say "不认识的子命令：${CMD}。可用：任务 / 自检 / 通过 / 状态 / 回到 / 换工具（见 kit.sh 开头）"; exit 1 ;;
esac

# ======================================================================
# 副路线：双击 开工.command（交互）
# ======================================================================
if [ "$STAGE" = "完成" ]; then show_status; say "这个产品的流程已经走完。"; exit 0; fi
show_status

if [ "$STATUS" = "等验收" ]; then
  say "上次自检已通过，现在轮到你验收：按 docs/evidence/${STAGE}/照着做清单.md 点一遍（无代码阶段就是看文档、确认该确认的事）。"
  if ask_yn "验收通过了吗？"; then
    next_options "$STAGE"
    if [ -n "$NEXT_FIXED" ]; then NEXT="$NEXT_FIXED"
    else
      say "接下来做什么？"
      CHOICES=(); i=1
      for o in $NEXT_OPTS; do
        CHOICES+=("$o")
        case "$o" in
          阶段2-*) label="继续完成下一项核心能力" ;;
          阶段3-0) label="核心能力已完成，开始设计正式界面" ;;
          阶段3-*) label="继续完善下一部分界面" ;;
          阶段4) label="发布到线上（需要确认平台和费用）" ;;
          阶段5) label="本轮先做到这里，整理成果和使用说明" ;;
        esac
        say "  $i) $label"; i=$((i+1))
      done
      while :; do
        ask "输入编号："
        if [[ "$ANS" =~ ^[1-9][0-9]*$ ]] && [ "$ANS" -le "${#CHOICES[@]}" ]; then
          NEXT="${CHOICES[$((ANS-1))]}"; break
        fi
        say "请选择上面的编号。"
      done
    fi
    advance "$STAGE" "$NEXT" || exit 1
    if [ "$NEXT" = "完成" ]; then say "全部完成！"; exit 0; fi
    say "已翻到 ${NEXT}。"
    if ! ask_yn "现在就开始做 ${NEXT} 吗？"; then say "好，下次双击开工继续。"; exit 0; fi
    STAGE="$NEXT"; STATUS=待开工; show_status
  else
    sset 状态 做中; hist "${STAGE} 验收未通过，继续改"
    say "好，留在 ${STAGE}。把没通过的地方告诉 AI 去改。"
    if ! ask_yn "现在打开工具继续改吗？"; then exit 0; fi
  fi
fi

TOOL="$(sget 工具)"
if [ -z "$TOOL" ]; then choose_tool; sset 工具 "$TOOL"; fi
write_task "$STAGE" window; sset 状态 做中; hist "${STAGE} 开工（第 $(sget 开工次数) 次，工具 $(tool_name "$TOOL")）"
PROMPT="请读取 projects/${PRODUCT}/docs/本阶段任务.md，按其中要求做 ${STAGE}。"
launch_tool "$TOOL" "$PROMPT"
rebind_product || exit 1

# AI 可能在工具会话中恢复了老项目；始终使用恢复后的阶段。
STAGE="$(sget 阶段)"
say "工具已关闭，现在检查本阶段进度。"
line
run_verify "$STAGE"; RC=$?
line
if [ "$RC" -eq 0 ]; then
  say "自检通过。下一步轮到你验收：按 docs/evidence/${STAGE}/照着做清单.md 点一遍（无代码阶段就是看文档、确认该确认的事）。"
  say "验收完再双击开工，回答\"验收通过了吗\"。"
else
  say "自检没过（上面有哪几项）。不能进下一阶段。下次双击开工，AI 会看到没过的项并补齐。"
fi

exit "$RC"
