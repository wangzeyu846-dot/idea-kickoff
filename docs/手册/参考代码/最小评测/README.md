# 最小评测与验收记录（给 AI 和维护者）

用户只需提供少量真实场景，并判断结果是否有用。本目录的结构化文件、记录函数和命令由 AI 维护，不要求用户学习或手填。

先读产品已有评测和决策，能复用就复用。最小目标是回答：**这次改动是否改善了已确认的场景，有没有把原来可用的结果改坏？**

## 1. 从业务样例整理要求

在原 PRD 的输入、输出与成功标准中确定：

- 用户目前怎么完成这件事，最痛的是哪一步。
- 本轮要验证什么改善，例如少改几轮、减少遗漏；不要凭空填收益数字。
- 几个脱敏输入，对应“可以接受”和“不可接受”的结果。先覆盖核心场景和关键失败场景，数量按本阶段风险决定。
- 需要重复几次。模型输出不稳定的关键链路，按已经确认的次数运行，不能只挑一次好结果。

将样例存到产品的 `docs/阶段文档/样例集.json`，也可继续用已有评测文件。不要放在被摘要排除的运行数据目录 `data/`。参考本目录的 `样例集示例.json`，其中是演示内容，不是真实用户证据。

AI 同时生成 `docs/阶段文档/<阶段>-验收要求.json`，参照 `验收要求示例.json`：

- `schema_version`：固定为 1。
- `model`：本次实际使用的模型名，必须与运行记录一致。
- `parameters`：可选，仅记录非秘密的模型参数，例如温度。禁止放 Key、凭据、用户输入或响应正文。
- `required_cases`：本阶段必需样例；每项 `id` 唯一，`runs` 是至少为 1 的整数。

不要为了让检查通过而减少已确认的样例或次数。范围确实变化时，先解释业务影响并更新已有决策，再真实重验。

## 2. 接入已有真实冒烟脚本

保留产品自己的模型调用和响应结构验证。在真实调用前开始记录；在收到实际结果后完成记录。以下是接入示意，**不是可直接运行的模型测试**，其中 `invoke` 要接到产品现有的真实调用适配器。适配器需基于实际 HTTP/SDK 结果和 Schema 校验返回元信息，不能写固定成功。

~~~python
import importlib.util
import json

# toolkit_root 是工具包根目录；product 是 projects/产品名。
spec = importlib.util.spec_from_file_location(
    "kit_checks", toolkit_root / "scripts" / "kit_checks.py"
)
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)

requirements = json.loads(
    (product / "docs" / "阶段文档" / f"{stage}-验收要求.json")
    .read_text(encoding="utf-8")
)
# 模型配置必须先与 requirements["model"] 核对。
run = checks.start_smoke_run(product, stage, requirements["model"])
results = []
try:
    for required in requirements["required_cases"]:
        for index in range(1, required["runs"] + 1):
            item = {
                "id": required["id"], "run_index": index,
                "status": "失败", "schema_valid": False,
            }
            try:
                # 真实调用已有适配器；不要用虚构响应代替。
                actual = invoke(required["id"])
                item["schema_valid"] = actual["schema_valid"] is True
                if actual["ok"] is True and item["schema_valid"]:
                    item["status"] = "通过"
                # 仅传脱敏元信息；Key、原始输入输出和异常正文不进入记录。
                for field in ("request_id", "input_tokens", "output_tokens",
                              "elapsed_ms", "cost", "retries"):
                    if field in actual:
                        item[field] = actual[field]
            except Exception:
                # 留下失败项；详细排障用产品已有的脱敏日志。
                pass
            results.append(item)
finally:
    checks.finish_smoke_run(product, run, results)
~~~

调用模型仍以用户已授权的范围和费用为准；本工具包不会自行发起请求。如果没有 Key、服务不可用或尚未获准付费调用，保留“待验”，继续本阶段可独立完成的准备工作。不要填写假的通过结果。

`start_smoke_run` 会立即把当前记录设为“待验”，使旧成功失效。进程意外退出时，待验记录留在原地；失败批次也会替换旧成功。并发时，旧批次不能覆盖更新批次。

`finish_smoke_run` 写入 `docs/evidence/<阶段>/冒烟结果.json`，包含运行编号、阶段、模型、输入摘要、状态、时间和样例结果。`run_index` 从 1 开始，同一样例不能重复编号；每个必需样例都要达到本批次要求的次数。已有 `冒烟记录.md` 继续作为便于人阅读的摘要，但不能单靠它取得通过凭据。

不要手写、回填或复制旧 JSON 冒充新调用。记录检查只能核对文件一致性，不能替代真实请求，也不能验证写入者的身份。

## 3. 自检与业务验收

AI 在工具包根目录调用：

~~~bash
bash kit.sh 自检 "产品名"
~~~

内部的 `verify.sh` 需要完整产品名与阶段，例如 `bash verify.sh "产品名" 阶段2-1`；用户无须记住阶段编号。自检开始时就把 `验证结果.json` 设为本批次“待验”，结束时核对同一验证编号并更新结果；中断不会保留旧成功，旧批次也不能覆盖新批次。只有当前版本的全部适用检查通过，才允许进入用户验收。

机器记录里的样例“通过”表示真实调用成功且结构校验满足要求。**内容质量、是否解决业务问题、是否比现有办法更值得使用，仍要按原 PRD 和样例标准判断。** AI 应给用户展示可接受/不可接受的对照，不把结构正确当成效果合格。

改提示词、模型公开参数、业务代码或需求后，在同一份样例上复测，把前后结果概述放进原有冒烟记录或评测摘要中：哪些变好、哪些变差、质量/耗时/费用是否可接受。不必增加评分平台，也不强制增加用户表单。

用户明确验收当前结果后，AI 才运行 `bash kit.sh 通过 "产品名"`。聊天和双击入口都核对同一份当前自检凭据；历史记录不足时，提示 AI 重验，保留已有文档和业务数据。

## 4. 摘要范围与恢复边界

摘要按内容计算，包含产品的代码、提示词、需求、非秘密配置、样例、未跟踪文件，以及工具包三个检查脚本；新增、删除和保留修改时间的改动也能被识别。

以下内容不参与摘要：`.env` 及其变体（`.env.example` 除外）、依赖目录、常见缓存与构建产物、`data`、`logs`、`uploads`、证据目录、流程状态和任务文件。这避免把用户数据、Key 或自检自己生成的文件混入版本依据。不要把代码、提示词或验收样例放进这些排除目录。

**改 Key、运行时模型配置、服务地址或外部服务后，AI 要主动重跑真实验证。** 文件摘要不会读取秘密配置，也无法检测云端服务变化。记录中只写非秘密的实际模型与参数。

无代码阶段 0、1、3-0、5 不要求真实模型记录；收尾阶段按已确认交付范围整理，不额外发起付费调用。缺部署素材不阻断需求澄清；当前代码阶段缺真实结果时，只能继续本阶段无需该依赖的工作。

符号链接输入、格式不完整、未知状态、当前批次缺项、失败、重复序号、旧记录、版本变化都不会自动放行。恢复方法是让 AI 修正对应输入并重新验证，无需用户清空产品或重填需求。
