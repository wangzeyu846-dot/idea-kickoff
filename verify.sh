#!/usr/bin/env bash
# 自检脚本：由脚本而不是 AI 判断六件事（mock 测试 / 真实冒烟记录 / 密钥排除 / 重启恢复 / 前端构建 / 文件齐全与位置）。
# 每个产品一个文件夹：projects/<产品名>/。脚本进到这个文件夹里检查。
# 用法：./verify.sh [产品名] <阶段目录名>     例：./verify.sh 我的第一个产品 阶段2-1   （提示"权限不够"时在前面加 bash）
# projects/ 下只有一个产品时，产品名可以省略：./verify.sh 阶段2-1
# 必须给阶段目录名，会把完整输出写到 projects/<产品名>/docs/evidence/<阶段目录名>/verify-输出.txt。
# 退出码：六项与版本核对全部通过或 N/A 为 0；失败或待验为 1；参数或环境错误为 2。
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# ---------- 选产品 ----------
PRODUCTS=()
for d in projects/*/; do [ -d "$d" ] && PRODUCTS+=("$(basename "$d")"); done
if [ $# -ge 1 ] && [ -d "projects/$1" ]; then
  PRODUCT="$1"; STAGE="${2:-}"
elif [ "${#PRODUCTS[@]}" -eq 1 ] && { [ $# -eq 0 ] || [[ "$1" == 阶段* ]]; }; then
  PRODUCT="${PRODUCTS[0]}"; STAGE="${1:-}"
else
  [ $# -ge 1 ] && echo "找不到产品\"$1\"，它也不是阶段名（阶段名以\"阶段\"开头，如 阶段2-1）。"
  echo "请让 AI 指明产品和阶段：bash verify.sh <产品名> <阶段N>"
  echo "projects/ 下现有的产品：${PRODUCTS[*]:-（没有）}"
  exit 2
fi
if [ "$#" -gt 2 ] || ! [[ "$STAGE" =~ ^阶段(0|1|2-[1-9][0-9]*|3-(0|[1-9][0-9]*)|4|5)$ ]]; then
  echo "必须提供有效阶段名：阶段0、阶段1、阶段2-1、阶段3-0、阶段3-1、阶段4、阶段5 等。"
  echo "请让 AI 根据当前进度运行：bash verify.sh \"$PRODUCT\" <当前阶段>。"
  exit 2
fi
P="projects/$PRODUCT"
CHECKS="$ROOT/scripts/kit_checks.py"
# 开始检查时就撤销旧成功；中断的自检不能继续使用上次凭据。
STARTED="$(python3 "$CHECKS" begin "$ROOT/$P" "$STAGE" 2>&1)"; BEGIN_RC=$?
if [ "$BEGIN_RC" -ne 0 ] || ! [[ "$STARTED" =~ ^([0-9a-f]{64})[[:blank:]]+([A-Za-z0-9_-]+)$ ]]; then
  echo "无法建立本次自检的待验凭据，请让 AI 修复后重新自检：$STARTED"
  exit 2
fi
BEFORE="${BASH_REMATCH[1]}"; VERIFICATION_ID="${BASH_REMATCH[2]}"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
sect() { log ""; log "================ $* ================"; }

R1="未配置"; R2="未配置"; R3="未配置"; R4="N/A（本阶段无正式前端）"; R5=""; R6="待验"
NOCODE=0; case "$STAGE" in 阶段0|阶段1|阶段3-0|阶段5) NOCODE=1;; esac   # 无代码阶段（AGENTS.md 第 4 节）：测试、冒烟和重启检查不适用
D1=""; D2=""; D3=""; D4=""

log "verify.sh 自检  $(date '+%Y-%m-%d %H:%M:%S')  产品：${PRODUCT}（${ROOT}/${P}）"
cd "$P"

# 只读取 scripts 对象；命令名出现在依赖或其他字段里不算配置。
PACKAGE_STATE="absent"; PACKAGE_FLAGS=""
if [ "$NOCODE" -eq 0 ] && [ -f frontend/package.json ]; then
  PACKAGE_FLAGS="$(python3 - <<'PY'
import json
import os
from pathlib import Path
try:
    package = json.loads(Path("frontend/package.json").read_text(encoding="utf-8"))
    scripts = package.get("scripts", {}) if isinstance(package, dict) else None
    if not isinstance(scripts, dict):
        raise ValueError()
    flags = [key for key in ("test", "lint", "build", "typecheck")
             if isinstance(scripts.get(key), str) and scripts[key].strip()]
    typescript = any("typescript" in package.get(key, {})
                     for key in ("dependencies", "devDependencies")
                     if isinstance(package.get(key, {}), dict))
    for directory, names, files in os.walk("frontend"):
        names[:] = [name for name in names if name not in {
            "node_modules", ".next", "dist", "out", "build", ".git"}]
        if any(name.endswith((".ts", ".tsx")) or
               (name.startswith("tsconfig") and name.endswith(".json")) for name in files):
            typescript = True
    if typescript:
        flags.append("typescript")
    print(" ".join(flags))
except (OSError, ValueError, TypeError):
    raise SystemExit(1)
PY
)"; PACKAGE_RC=$?
  if [ "$PACKAGE_RC" -eq 0 ]; then PACKAGE_STATE="valid"; else PACKAGE_STATE="invalid"; fi
fi
has_frontend_script() { case " $PACKAGE_FLAGS " in *" $1 "*) return 0;; *) return 1;; esac; }
result_passed() { case "$1" in 通过|通过（*|N/A|N/A（*) return 0;; *) return 1;; esac; }

# ---------- 1. mock 自动化测试 ----------
sect "1. mock 自动化测试"
if [ "$NOCODE" -eq 1 ]; then
  R1="N/A（无代码阶段）"
elif [ -d backend/tests ]; then
  PY="$ROOT/$P/backend/.venv/bin/python"; [ -x "$PY" ] || PY="$(command -v python3)"
  T="$(mktemp)"
  (cd backend && MODEL_API_KEY="" "$PY" -m pytest -q 2>&1) > "$T"; RC=$?
  cat "$T" >> "$LOG"
  PASSED="$(grep -Eo '[0-9]+ passed' "$T" | tail -1 | grep -Eo '[0-9]+')"; PASSED="${PASSED:-0}"
  FAILED="$(grep -Eo '[0-9]+ (failed|error)' "$T" | grep -Eo '[0-9]+' | paste -sd+ - | bc 2>/dev/null)"; FAILED="${FAILED:-0}"
  TOTAL=$((PASSED + FAILED))
  if [ "$RC" -eq 0 ] && [ "$PASSED" -ge 5 ]; then R1="通过（${PASSED}/${TOTAL}）"
  elif [ "$RC" -eq 0 ]; then R1="不通过（只有 ${PASSED} 条测试通过，至少要 5 条，防止空测试充数）"
  else R1="不通过（通过 ${PASSED}/${TOTAL}，退出码 ${RC}）"; fi
  D1="后端 pytest"
  rm -f "$T"
else
  log "未找到 backend/tests，跳过后端测试。"
fi
if [ "$NOCODE" -eq 0 ] && [ -f frontend/package.json ]; then
  if [ "$PACKAGE_STATE" = invalid ]; then
    R1="不通过（frontend/package.json 无法解析为有效的 scripts 配置）"
  elif ! has_frontend_script test; then
    R1="未配置（前端缺少 scripts.test；后端结果：${R1}）"
    log "请让 AI 配置 frontend/package.json 的 scripts.test，并重新自检。"
  else
    T="$(mktemp)"
    (cd frontend && npm test --silent -- --run 2>&1) > "$T"; RC=$?
    cat "$T" >> "$LOG"
    if [ "$RC" -eq 0 ]; then R1="${R1}；前端测试通过"; else R1="不通过（前端测试退出码 ${RC}）"; fi
    rm -f "$T"
  fi
fi
log "结果：$R1"

# ---------- 2. 真实模型冒烟记录 ----------
sect "2. 真实模型冒烟记录（核对本阶段结构化结果、实际状态和输入版本）"
if [ "$NOCODE" -eq 1 ]; then
  R6="N/A（无代码阶段）"
else
  R6="$(python3 "$CHECKS" smoke "$ROOT/$P" "$STAGE" 2>&1)"; SMOKE_RC=$?
  if [ "$SMOKE_RC" -eq 0 ]; then
    case "$R6" in 通过|通过（*) ;; *) R6="不通过（冒烟检查未返回明确的通过结果，请让 AI 修复并重验）";; esac
  else
    case "$R6" in 不通过*|待验*) ;; *) R6="不通过（冒烟检查未正常完成，请让 AI 修复并重验）";; esac
  fi
fi
log "结果：$R6"

# ---------- 3. 密钥排除 ----------
sect "3. 密钥排除（扫描整个仓库会进 git 的文件，以及本产品的构建产物）"
cd "$ROOT"
# 样式：OpenAI/DeepSeek 等 sk-…、火山引擎 AKLT…、腾讯云 SecretId AKID…、AWS AKIA…、以及"名字像密钥 = 长值"
PAT='sk-[A-Za-z0-9]{20,}|AKLT[A-Za-z0-9]{10,}|AKID[A-Za-z0-9]{10,}|AKIA[0-9A-Z]{16}|(api[_-]?key|secret|password|token)[[:space:]]*[=:][[:space:]]*["'"'"']?[A-Za-z0-9_-]{20,}'
HITS=0
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "问题：工具包文件夹不是 Git 仓库，无法判断哪些文件会进仓库。请先让 AI 执行 git init 并配置 .gitignore。"
  HITS=$((HITS+1))
fi
# 扫描范围：已跟踪文件 + 未跟踪但没被 .gitignore 忽略的文件（即下次 git add 会进仓库的）
lsfiles() { git ls-files -z --cached --others --exclude-standard 2>/dev/null; }
# 2a. .env 类文件不得被跟踪
ENV_TRACKED="$(git ls-files | grep -E '(^|/)\.env(\.[A-Za-z0-9_-]+)?$' | grep -v '\.env\.example$' || true)"
if [ -n "$ENV_TRACKED" ]; then log "问题：以下 .env 文件被 git 跟踪："; log "$ENV_TRACKED"; HITS=$((HITS+1)); else log "通过：没有 .env 文件被 git 跟踪。"; fi
# 2b. 跟踪文件中的密钥样式
M="$(lsfiles | xargs -0 grep -InE --exclude=verify.sh "$PAT" 2>/dev/null | sed -E 's/([A-Za-z0-9_-]{6})[A-Za-z0-9_-]{8,}/\1******/g' || true)"
if [ -n "$M" ]; then log "问题：会进仓库的文件中发现疑似密钥（已打码）："; log "$M"; HITS=$((HITS+1)); else log "通过：会进仓库的文件中未发现密钥样式字符串。"; fi
# 2c. 构建产物中的密钥样式
for d in "$P/frontend/.next" "$P/frontend/dist" "$P/frontend/out" "$P/backend/dist"; do
  [ -d "$d" ] || continue
  M="$(grep -rIlE "$PAT" "$d" 2>/dev/null || true)"
  if [ -n "$M" ]; then log "问题：构建产物 $d 中发现疑似密钥，文件："; log "$M"; HITS=$((HITS+1)); else log "通过：构建产物 $d 未发现密钥样式字符串。"; fi
done
# 2d. 本机 .env 里的真实 Key 值不得出现在任何跟踪文件或构建产物里（值本身不打印）
#     范围：产品文件夹下所有 .env* 文件（.env.example 除外，依赖目录除外）+ 根目录 .env。产品名不含空格（AGENTS.md 第 9 节），按空白切分即可。
ENVFILES="$(find "$P" -maxdepth 3 -name '.env*' ! -name '.env.example' -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/.next/*' 2>/dev/null)"
for envf in $ENVFILES .env; do
  [ -f "$envf" ] || continue
  while IFS= read -r line; do
    case "$line" in \#*|"") continue;; esac
    name="${line%%=*}"
    # 只检查名字像密钥的变量（KEY / SECRET / TOKEN / PASSWORD / ACCESS），URL、模型名之类不算
    echo "$name" | grep -qiE 'key|secret|token|pass|access' || continue
    val="${line#*=}"; val="${val%\"}"; val="${val#\"}"
    [ "${#val}" -ge 12 ] || continue
    FOUND="$(lsfiles | xargs -0 grep -IlF -- "$val" 2>/dev/null || true)"
    for d in "$P/frontend/.next" "$P/frontend/dist" "$P/frontend/out" "$P/backend/dist"; do [ -d "$d" ] && FOUND="$FOUND $(grep -rIlF -- "$val" "$d" 2>/dev/null || true)"; done
    FOUND="$(echo "$FOUND" | xargs 2>/dev/null || true)"
    if [ -n "$FOUND" ]; then log "问题：$envf 中 ${line%%=*} 的值出现在：$FOUND"; HITS=$((HITS+1)); else log "通过：$envf 中 ${line%%=*} 的值未出现在任何跟踪文件或构建产物中。"; fi
  done < "$envf"
done
if [ "$HITS" -eq 0 ]; then R2="通过"; else R2="不通过（${HITS} 处问题，见输出）"; fi
log "结果：$R2"
cd "$P"

# ---------- 4. 重启恢复 ----------
sect "4. 数据重启恢复（verify.sh 自己起服务、写随机标记、杀进程、再起、读回；钩子 scripts/restart-check.sh 只提供 start/write/read/stop）"
if [ "$NOCODE" -eq 1 ]; then
  R3="N/A（无代码阶段）"
elif [ -f scripts/restart-check.sh ]; then
  export RESTART_CHECK_DIR="$(mktemp -d)"
  NONCE="rc-$(date +%s)-${RANDOM}${RANDOM}"
  FAIL=""; PID1=""; PID2=""; RID=""
  hook() { bash scripts/restart-check.sh "$@" 2>>"$LOG" | tail -1 | tr -d '[:space:]'; }   # 取标准输出最后一行
  alive() { local st; st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"; [ -n "$st" ] && [ "${st:0:1}" != "Z" ]; }   # 僵尸不算活着
  PID1="$(hook start)"
  if ! [[ "$PID1" =~ ^[0-9]+$ ]] || ! alive "$PID1"; then FAIL="第 1 步 start 没有返回一个正在运行的进程号（得到：${PID1:-空}）"; fi
  if [ -z "$FAIL" ]; then
    RID="$(hook write "$NONCE")"
    [ -n "$RID" ] || FAIL="第 2 步 write 没有返回记录 ID"
  fi
  if [ -z "$FAIL" ]; then
    kill -9 "$PID1" 2>/dev/null; sleep 1
    alive "$PID1" && FAIL="第 3 步 进程 ${PID1} 杀不掉"
  fi
  if [ -z "$FAIL" ]; then
    PID2="$(hook start)"
    if ! [[ "$PID2" =~ ^[0-9]+$ ]] || ! alive "$PID2"; then FAIL="第 4 步 重启后 start 没有返回一个正在运行的进程号（得到：${PID2:-空}）"
    elif [ "$PID2" = "$PID1" ]; then FAIL="第 4 步 重启后进程号没变（${PID1}），没有真的重启"; fi
  fi
  if [ -z "$FAIL" ]; then
    GOT="$(hook read "$RID")"
    [ "$GOT" = "$NONCE" ] || FAIL="第 5 步 重启后读回的标记和 verify.sh 生成的随机标记不一致（得到：${GOT:-空}）"
  fi
  [ -n "$PID2" ] && kill "$PID2" 2>/dev/null
  bash scripts/restart-check.sh stop >/dev/null 2>&1 || true
  rm -rf "$RESTART_CHECK_DIR"; unset RESTART_CHECK_DIR
  if [ -z "$FAIL" ]; then
    log "通过：起服务（PID ${PID1}）→ 写入随机标记 → 杀掉 → 再起（PID ${PID2}）→ 按 ID ${RID} 读回，标记一致。"
    R3="通过（进程 ${PID1}→${PID2}，随机标记读回一致）"
  else
    log "不通过：${FAIL}。钩子契约见通用手册第十节。"; R3="不通过（${FAIL}）"
  fi
else
  log "未找到 scripts/restart-check.sh。有可重启的服务时，AI 必须按通用手册第十节的契约写这个钩子（start / write / read / stop）。"
fi
log "结果：$R3"

# ---------- 5. 前端类型检查 / Lint / 生产构建 ----------
sect "5. 前端类型检查 / Lint / 生产构建"
if [ "$NOCODE" -eq 1 ]; then
  R4="N/A（无代码阶段）"
elif [ "$PACKAGE_STATE" = invalid ]; then
  R4="不通过（frontend/package.json 无法解析为有效的 scripts 配置）"
elif [ "$PACKAGE_STATE" = valid ]; then
  FAIL=""; MISSING=""
  T="$(mktemp)"
  for check in lint build; do
    if has_frontend_script "$check"; then
      (cd frontend && npm run "$check" 2>&1) >> "$T" || FAIL="$FAIL $check"
    else
      MISSING="$MISSING $check"
    fi
  done
  if has_frontend_script typescript; then
    if has_frontend_script typecheck; then
      (cd frontend && npm run typecheck 2>&1) >> "$T" || FAIL="$FAIL 类型检查"
    elif [ -x frontend/node_modules/.bin/tsc ]; then
      (cd frontend && ./node_modules/.bin/tsc --noEmit 2>&1) >> "$T" || FAIL="$FAIL 类型检查"
    else
      MISSING="$MISSING typecheck（或本地 tsc）"
    fi
  fi
  cat "$T" >> "$LOG"; rm -f "$T"
  if [ -n "$FAIL" ]; then
    R4="不通过（失败项：${FAIL}；缺少配置：${MISSING:-无}）"
  elif [ -n "$MISSING" ]; then
    R4="未配置（缺少前端检查：${MISSING}）"
  else
    R4="通过"
  fi
  if [ -n "$MISSING" ]; then
    log "请让 AI 补齐 frontend/package.json 的 scripts 或本地依赖，再重新自检；不会自动联网安装。"
  fi
elif [[ "$STAGE" == 阶段3-* ]] || [ -d frontend ]; then
  R4="未配置（缺少 frontend/package.json，正式前端不能按不适用放行）"
  log "请让 AI 补齐本阶段前端工程和 test/lint/build 检查后重新自检。"
else
  log "未找到 frontend/package.json，本阶段无正式前端。"
fi
log "结果：$R4"

# ---------- 6. 文件齐全与位置 ----------
sect "6. 文件齐全与位置（AGENTS.md 第 7 节的产出清单；根目录不放产品文件；前面阶段有没有被跳过）"
MISS=0; STRAY=0
cd "$ROOT"
# 5a. 根目录只放工具包自己的文件，产品的代码、依赖、数据都应在 projects/<产品名>/ 里
for e in * .[!.]*; do
  [ -e "$e" ] || continue
  case "$e" in
    AGENTS.md|CLAUDE.md|README.md|开始看这里.md|LICENSE|verify.sh|kit.sh|开工.command|.gitignore|assets|docs|projects|.git|.DS_Store) ;;
    scripts|tests)
      while IFS= read -r -d '' f; do
        case "$f" in
          scripts/export-clean-kit.sh|scripts/kit_checks.py|tests/test_kit_checks.py|tests/test_verify.py|tests/test_kit_flow.py) ;;
          scripts/__pycache__|tests/__pycache__) ;;
          scripts/__pycache__/kit_checks.cpython-*.pyc|tests/__pycache__/test_kit_checks.cpython-*.pyc|tests/__pycache__/test_verify.cpython-*.pyc|tests/__pycache__/test_kit_flow.cpython-*.pyc) ;;
          *) log "放错位置：${f}（应在产品文件夹里）"; STRAY=$((STRAY+1)) ;;
        esac
      done < <(find "$e" -mindepth 1 -print0)
      ;;
    .venv|.env|.env.*|.next|.vefaas|.pytest_cache) log "放错位置：${e}（应在产品文件夹里）"; STRAY=$((STRAY+1)) ;;
    .*) ;;  # 其他隐藏文件夹多为编码工具自己的配置
    *) log "放错位置：${e}（应在产品文件夹里）"; STRAY=$((STRAY+1)) ;;
  esac
done
for e in docs/*; do
  case "$e" in docs/手册|docs/PRD模板.md) ;; *) log "放错位置：${e}（产品文档应在 ${P}/docs/ 里）"; STRAY=$((STRAY+1)) ;; esac
done
[ "$STRAY" -eq 0 ] && log "通过：根目录没有放错位置的文件。"
cd "$P"
# 5b. 本阶段必须产出的文件
NEED=(); EVI=0
case "$STAGE" in
  "") ;;
  阶段0) NEED=(docs/阶段文档/阶段0-PRD补全清单.md "docs/evidence/$STAGE/是否表.md") ;;
  阶段1) NEED=(docs/阶段文档/技术适配声明.md "docs/evidence/$STAGE/是否表.md") ;;
  阶段2*) NEED=("docs/阶段文档/${STAGE}技术开发文档.md"); EVI=1 ;;
  阶段3-0) NEED=(docs/阶段文档/前端适配声明.md "docs/evidence/$STAGE/是否表.md") ;;
  阶段3*) NEED=(docs/阶段文档/前端适配声明.md "docs/阶段文档/${STAGE}技术开发文档.md"); EVI=1 ;;
  阶段4) NEED=(docs/阶段文档/上线方案摘要.md); EVI=1 ;;
  阶段5) ;;
  *) log "问题：不认识的阶段名 ${STAGE}（应为 阶段0、阶段1、阶段2-1、阶段3-0、阶段3-1、阶段4、阶段5 这类）。"; MISS=$((MISS+1)) ;;
esac
if [ -n "$STAGE" ]; then
  NEED+=(docs/项目状态.md)
  [ "$EVI" -eq 1 ] && NEED+=(README.md "docs/evidence/$STAGE/照着做清单.md" "docs/evidence/$STAGE/是否表.md")
  for f in ${NEED[@]+"${NEED[@]}"}; do
    if [ -s "$f" ]; then log "有：$f"; else log "缺：$f"; MISS=$((MISS+1)); fi
  done
  if [ "$EVI" -eq 1 ]; then
    SHOTS="$(ls "docs/evidence/$STAGE" 2>/dev/null | grep -icE '\.(png|jpe?g)$')"
    if [ "$SHOTS" -gt 0 ]; then log "有：docs/evidence/$STAGE/ 下 $SHOTS 张截图"; else log "缺：docs/evidence/$STAGE/ 下至少一张截图（.png / .jpg）"; MISS=$((MISS+1)); fi
  fi
fi
# 5c. 前面阶段的产物：AI 跳过了前面的阶段，在这里报出来（阶段 4 可选，阶段 5 不要求它）
stage_files() {  # 参数：阶段名 → 该阶段必须有的文件，每行一个
  case "$1" in
    阶段0) echo docs/阶段文档/阶段0-PRD补全清单.md; echo docs/evidence/阶段0/是否表.md ;;
    阶段1) echo docs/阶段文档/技术适配声明.md; echo docs/evidence/阶段1/是否表.md ;;
    阶段3-0) echo docs/阶段文档/前端适配声明.md; echo docs/evidence/阶段3-0/是否表.md ;;
    阶段2-*|阶段3-*) echo "docs/阶段文档/$1技术开发文档.md"; echo "docs/evidence/$1/是否表.md" ;;
    阶段4) echo docs/阶段文档/上线方案摘要.md; echo docs/evidence/阶段4/是否表.md ;;
  esac
}
PRIOR=(); N=""
case "$STAGE" in
  阶段1) PRIOR=(阶段0) ;;
  阶段2-*) N="${STAGE#阶段2-}"; PRIOR=(阶段0 阶段1); i=1; while [[ "$N" =~ ^[0-9]+$ ]] && [ "$i" -lt "$N" ]; do PRIOR+=("阶段2-$i"); i=$((i+1)); done ;;
  阶段3-0) PRIOR=(阶段0 阶段1 阶段2-1) ;;
  阶段3-*) N="${STAGE#阶段3-}"; PRIOR=(阶段0 阶段1 阶段2-1 阶段3-0); i=1; while [[ "$N" =~ ^[0-9]+$ ]] && [ "$i" -lt "$N" ]; do PRIOR+=("阶段3-$i"); i=$((i+1)); done ;;
  阶段4|阶段5) PRIOR=(阶段0 阶段1 阶段2-1 阶段3-0 阶段3-1) ;;
esac
PMISS=0
for st in ${PRIOR[@]+"${PRIOR[@]}"}; do
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ ! -s "$f" ]; then log "缺：${f}（前面的阶段 ${st} 没做完就到了 ${STAGE}）"; PMISS=$((PMISS+1)); fi
  done < <(stage_files "$st")
done
[ "${#PRIOR[@]}" -gt 0 ] && [ "$PMISS" -eq 0 ] && log "通过：前面阶段（${PRIOR[*]}）的产物都在。"
MISS=$((MISS+PMISS))
if [ "$MISS" -gt 0 ] || [ "$STRAY" -gt 0 ]; then
  R5="不通过（缺 ${MISS} 个文件，${STRAY} 处放错位置）"
  [ "$PMISS" -gt 0 ] && R5="不通过（缺 ${MISS} 个文件，其中 ${PMISS} 个属于前面没做完的阶段；${STRAY} 处放错位置）"
elif [ -z "$STAGE" ]; then R5="通过（只查了文件位置；给阶段名才查文件齐全）"
else R5="通过"; fi
log "结果：$R5"

# ---------- 汇总 ----------
sect "汇总（抄进是否表的就是这六行）"
log "是否表第 2 项  mock 测试：      $R1"
log "是否表第 3 项  真实模型冒烟：   $R6"
log "是否表第 4 项  前端检查与构建： $R4"
log "是否表第 5 项  密钥排除：       $R2"
log "是否表第 6 项  重启后数据恢复： $R3"
log "是否表第 10 项 文件齐全与位置： $R5"
EXIT=0
for r in "$R1" "$R2" "$R3" "$R4" "$R5" "$R6"; do
  result_passed "$r" || EXIT=1
done
if [ "$EXIT" -eq 0 ]; then
  log "六项检查通过或不适用，正在核对本次输入版本。"
else
  log "六项检查有失败、未配置、待验或未知结果；本阶段尚未通过。"
  log "已完成：通过项的工程检查已保留；待验项见上方六行。"
  log "可继续：让 AI 修复失败项、完成同阶段不依赖模型配置的工作，再重新自检；真实效果待验时需提供模型配置或实际验证。"
fi

# 先保存文本，再封存凭据；seal 会使执行中改变的输入和旧成功失效。
if ! mkdir -p "docs/evidence/$STAGE" || ! cp "$LOG" "docs/evidence/$STAGE/verify-输出.txt"; then
  log "不通过：无法保存本次自检输出，请让 AI 修复文件权限后重验。"
  EXIT=1
fi
SEALED="$(python3 "$CHECKS" seal "$ROOT/$P" "$STAGE" "$BEFORE" "$EXIT" "$VERIFICATION_ID" 2>&1)"; SEAL_RC=$?
log "$SEALED"
if [ "$SEAL_RC" -ne 0 ]; then EXIT=1; fi
if [ "$EXIT" -eq 0 ]; then
  log "总判定：六项全部通过或不适用，且本次输入版本核对通过。"
else
  log "总判定：本阶段未通过；对应是否表填否或待验，请让 AI 按上方原因修复后重新自检。"
fi
log "完整输出已写入：$P/docs/evidence/$STAGE/verify-输出.txt"
cp "$LOG" "docs/evidence/$STAGE/verify-输出.txt" || EXIT=1
exit "$EXIT"
