# Changelog

## 0.9.8（C 档参数表单 Denoising 解锁：从「看得到改不了」变成「改了就生效」）

背景：C 档 `sd-inject.ps1` 的参数表里，Denoising 一栏永远显示为灰掉（禁用）——用户既下拉不动也手填不了。

- **根因（三段全废）**：① 表单在**素体自检迭代之前**弹出，那一刻 `-HasBaseImage` 传参恒为 `$false`（`$baseWin` 还没产生），旧代码据此执行 `if (-not $HasBaseImage) { $cboDenoise.Enabled = $false }` → 控件**每次都被禁用**；② 解析段在同一条件下直接 `$den = 0`，手填的值也被丢掉；③ 最终出图硬编码 `Invoke-FinalIterate -InitImage "" -Denoising 0`，即使前两处放行也不生效。
- **修复（`sd-inject.ps1`）**：
  - **控件恒可编辑**：删掉 `Enabled = $false` 锁定逻辑，改为恒 `Enabled = $true` 的 `DropDown`（可下拉、可手填 0-0.95）；选项表改为 `0（文生图·不用底图）` / 0.3 / 0.4 / 0.5 / 0.6 / 0.7 / 0.8 / 0.9，**默认 `0（文生图·不用底图）`**（= 现状行为，不动默认出图链路）；下方新增 7pt 灰字提示「（0=文生图；0.3-0.5 贴底图；≥0.7 重画）」。
  - **解析恒定生效**：不再按 `HasBaseImage` 归零；取文本框开头的数字（兼容带说明的条目，`0,6` 这类逗号小数也认），空值/非法 → 0（保持现状），上限钳到 0.95。
  - **最终出图按值分派**：`Denoising = 0` → 文生图（默认行为不变，仍用完整 `$positive`）；`Denoising > 0` 且素体迭代有 winning 成品 → **图生图**（`-InitImage` 素体成品 + 表单 Denoising），素体无成品（`-NoIterate`/迭代失败）则回落文生图并给黄字提示；两处都打印模式日志（`最终出图走图生图：底图 = 素体成品（seed=…），denoising = …`）。
  - **「追加为空直接收尾」捷径加守卫**：`$defaultsOnly` 追加 `$P.Denoise -le 0`——用户填了 >0 就必须真出一轮图生图，不能被「素体图即最终图」那条捷径吃掉。
- **测试**：`sd-inject.ps1` 首三字节 `EF BB BF`（坑13/19：编辑工具会剥 BOM，已按流程补回）+ PS7 与 PS5.1 双 Parser `SYNTAX OK`；**抽发布代码段做行为验证**（`0（文生图·不用底图）`→0、`0.3`→0.3、`0,6`→0.6、`1`/`2`→钳 0.95、`abc`/空 → 0）；`npm test`（smoke-skill / test-install-record / test-settings / test-install-catalog）四条全绿。
- **四处同步**：dev 仓库、插件包（`node_modules\dsh-sd-bridge-guard`）、会话工作区、`release\` 的 `sd-inject.ps1` 内容一致（sha256 `15d4d407…` 相同、BOM 齐备）。原文件备份于 `dist\dsh-sd-bridge-guard-backup-20261015-185331\`。

## 0.9.7（C 档选项表：A 档出图后自动罗列 + 用户自调画风进 C 档表单 + 权重/镜像清单）

背景：「整理打包」本次把插件在本机的全部相关内容（源码、脚本、模型/VAE/LoRA 权重、用户自调画风）整理成可复现的一套，并解决「A 档出图后用户不知道还能改什么参数」这个体验缺口。

- **C 档选项表（新功能）**：`sd_txt2img` / `sd_img2img` / `sd_inpaint` 三个出图工具输出 schema 新增 `quickOptions` 字段（由 `buildQuickOptions()` 生成，本次一并导出供测试断言），内容 = C 档参数表单的全部可选项：**画风 / 模型 / LoRA / 比例 / 画质 / 迭代 / Denoising**（Markdown 表格 + 用法示例 + ★ 用户自调标记）。三个工具的 `hint` 明确要求：**A 档出图后必须把 `quickOptions` 原样贴到图片下方**，用户回一句「4 号画风 + majicMIX + 3:4 + 1024p，再来一张」即可改参数重出图；`sd-paint` 技能新增「## C 档选项表（A 档出图后必贴）」章节 + 回复骨架第 7 条，附画风编号对照表。
- **用户自调画风进 C 档画风下拉（`sd-inject.ps1`）**：`Get-StylePrompt` 新增两条实测配方——**「写实二次元·东亚脸」**（窄脸型 + 杏仁眼 + 虹膜高光 + 眼神光 + 正面偏侧柔光，负向压宽脸/宽眼距/西方面孔/过曝/真人照片；沿用「动漫底子 + `<lora:semirealisticanime:0.6>` 不切模型」路径，自动切模型判断同步扩成 `-in @('写实二次元','写实二次元·东亚脸')`）与 **「釉彩调色盘」**（本机 LoRA `<lora:釉彩·麻袋调色盘_v1.0:0.8>` + 釉面/粗布色域词）。画风下拉顺序：保持画风 / 二次元 / 写实二次元 / **写实二次元·东亚脸** / 彩色哥特 / **釉彩调色盘** / 国风 / 赛博朋克 / 写实 / 厚涂 / 水彩 / 像素风。
- **触发话术写进技能**：技能首段新增提示——新对话第一句说「**打开SD插件**」、出图要求前加「**用SD插件绘制**」，可显著提高技能与工具命中率（README 同步写成对照表）。
- **新增 `docs/models-loras.md`**：本机全部权重清单（6 个 HF checkpoint + 1 个本机 ReVAnimated + 2 VAE + 4 HF LoRA/嵌入 + 7 个国内自调 LoRA），**每条带 HF 镜像直链（`hf-mirror.com`）+ sha256 + 本机文件大小与用途**，另附镜像站对照、一键拉取命令、单文件 `curl` 示例与落盘位置。
- **README 重写（版本更新内容置顶）**：新增「版本更新内容（v0.9.7）」「这样用成功率最高」「效果图（实出图）」「两个档位怎么用」「C 档选项表」「模型 / LoRA 镜像清单」「本次随机测试记录」；图片用 `docs/assets/` 下 6 张**本次实拍/实出图**（含 C 档参数表单截屏与 5 张不同画风出图）。踩坑表新增 #25。
- **测试**：`smoke-skill.mjs` 新增 15 条断言（`quickOptions` 字段三工具齐备、表格含三项 ★ 自调画风与五类参数、技能含 C 档选项表章节与两条触发话术、`sd-inject.ps1` 含新画风与 LoRA 全名、东亚脸复用不切模型路径）；`npm test` 四条全绿。
- **真机随机测试 6 张**（银发少女樱花 / 写实二次元·东亚脸 / 国风山水 LoRA / 赛博朋克场景 LoRA / 釉彩调色盘 LoRA / majicMIX 写实人像）：全部通过自检；釉彩调色盘第 1 轮手部偏糊，第 2 轮加重手部负向 + 手不入镜后通过（seed 与结论记入 README）。
- 坑19 复踩记录：编辑工具改完 `sd-inject.ps1` 后 BOM 再次被剥掉（首三字节变成 `# s`），已按流程补回 `EF BB BF` 并用 PS7 + PS5.1 双 Parser 复核 `SYNTAX OK`。
- **补齐「本地模型评估链」文档**（README 新增专章 + `docs/models-loras.md` 新增第 4 节）：把 C 档一直存在但只在 CHANGELOG 里提过的本地评估流程写进用户文档——视觉质检模型 `qwen3-vl:8b`（脸+手 0-100 分、≥75 过关、`temperature=0.1`、超时 180s、答题前纯文本预热 300s 把模型加载进显存）、翻译模型 `huihui_ai/qwen2.5-abliterate:14b`（纯翻译器）、两段迭代（素体自检迭代 `-IterateRounds` 3 轮 + 最终出图按「迭代次数」连出 N 张取最高分）、五类降级路径（探活失败跳过 / 无视觉模型给 pull 提示 / 指定模型不在本机自动回退 / 质检持续无分出满 N 张并弹多选 / 枚举不到模型点出 `OLLAMA_MODELS`）、全部相关参数表与两条 `ollama pull` 命令；同时明确 **A 档不走本地评估**（A 档质检 = 执行模型自己 `read_image` 看图）。

## 0.9.6（写实二次元配方回填 + 首次使用先拉起 SD 再弹表单 + 图片选择框白屏修复 + 手部质检）

- **写实二次元（半写实/2.5D）十轮迭代实测配方回填**（技能全文、`sd_models` qualityHint、`sd-inject.ps1` 画风联动与自动切模型四处同步）：
  - **首选路径**：AWPainting（动漫底子，不切模型）+ `<lora:semirealisticanime:0.6>` + `(modern anime style:1.25), (semi-realistic:1.1), delicate refined anime face, (big detailed anime eyes:1.25), youthful face, detailed skin shading, soft cinematic lighting`；负向 `(old anime style:1.2), retro anime, flat color, cel shading, (photorealistic:1.3), (mature female face:1.3)`。
  - **LoRA 权重 0.6 是平衡点**：0.45 脸崩（眼距开/五官挤）、0.8 御姐化跑真人照片——实测结论写进技能与脚本注释。
  - **SemiRealMix 降为备选**：只在半写实 LoRA 缺失时自动退回（实测它做底容易出 3D 娃娃脸或直接跑成照片）；`sd-inject.ps1` 的「写实二次元 → 自动切 SemiRealMix」改为「有 LoRA 就不切模型」。
  - hires 参数经验：scale 1.5 / denoising 0.55；0.4 会洗糊细节、restoreFaces 同样洗脸，配方里注明别开。
- **资源清单扩充**（install-sd.ps1）：模型加 `semirealmix`（robotjung/SemiRealMix，sha256 `385ea18e…`）、LoRA 加 `semireal`（NoneIQalt/semirealisticanime，sha256 `ffce3323…`），默认 `-Models 'awpainting,semirealmix'`、`-Loras 'add_detail,semireal,easynegative,badhandv4'`。sha256 均经 HF raw 端点 LFS 指针核对（tree API 的 40 位 oid 是 git sha1、xet-cas URL 哈希不是标准 sha256，均不可用——真机下载后 Get-FileHash 逐一比对通过）。
- **C 档首次使用先拉起 SD 再弹表单**（sd-inject.ps1 0a 段）：探活失败时用 `sd-direct.ps1 -StartOnly` 预热（自带 Write-Progress 进度条 + mm:ss 运行时间），就绪后再拉 LoRA/模型列表弹表单，列表不再空；预热失败不阻断（照常弹表单）。`sd-direct.ps1` 新增 `-StartOnly`（只拉起 API 到就绪即退、不出图），`$Prompt` 去必填；等待循环从「每 15 秒一行文本」改为进度条（注意顶部 `$ProgressPreference='SilentlyContinue'` 会吞 Write-Progress，画条前临时切回 Continue）。
- **C 档画风词进表单**：新增 `Get-StylePrompt`（画风→正/负向词映射），画风下拉切换时**幂等注入**两个提示词框（先剥上次注入的词再进新词，用户手写内容不受影响）；主流程删除表单确认后的二次追加，杜绝重复。
- **图片选择框白屏修复**（Show-ImagePicker）：ListView+ImageList 缩略图加载失败即整框白屏（异常被空 catch 吞）→ 改 CheckedListBox（纯文本文件名+勾选，绝不白屏）+ 右侧 PictureBox 预览（加载失败只显灰底占位）。
- **手部细节纳入质检（A 档 + C 档）**：C 档 VLM 问句从「只查脸」改为「脸+手综合打分」（五指齐全/多指/少指/并指粘连/关节错位都扣分），输出一律「脸/手质检得分」；A 档三个生图工具的 selfCheck 与技能「出图自检」把**手部列为第一优先检查项**并给出救手手段（`(bad hands:1.4), (extra fingers:1.4)` 加重、badhandv4 嵌入、换 seed）。
- 测试：test-install-catalog 断言更新（模型/LoRA 键清单 + 两条新 sha256 + 默认值正则）；smoke/settings 全绿；三处 .ps1 UTF-8 BOM 与 PS5.1 Parser 复核通过（编辑工具会剥 BOM，每次改完必须补回——坑13/19 再次踩中）。

## 0.9.5（GitHub Issues #1/#2/#4 回填：编码死锁/308句柄泄漏/hires 500/默认值收敛）

对照 `savinglighting/dsh-sd-bridge-guard` 三个 issue 逐项核对当前 0.9.4 版并修复仍存在的缺陷：

- **Issue #1 缺陷 1（pip 约束编码）**：`writePipConstraints()` 注释改为**纯 ASCII**——中文 Windows 上 pip 用 gbk 读无 BOM 约束文件会 `UnicodeDecodeError`，torch 还没装就炸。另按 Issue #4 坑 5 补钉 `pandas==2.1.4` 断开解析器病态回溯。
- **Issue #1 缺陷 2 / Issue #4 坑 6（HF 自举死锁）**：`buildHfEnv()` 改为 `HF_ENDPOINT` **无条件**指向镜像，只把离线开关留给「有缓存」的情形——缓存为空时不给镜像 = 只能去连被墙的 huggingface.co = 缓存永远填不上（死锁）。
- **Issue #4 坑 2（PEP 517 构建隔离）**：`buildFreshEnv()` 新增 `PIP_NO_BUILD_ISOLATION=1`——pip ≥ 24 上 `PIP_CONSTRAINT` 进不了构建隔离，隔离环境拉最新 setuptools 移除 `pkg_resources` → CLIP 构建失败；禁用隔离后直接用 venv 里钉死的 `setuptools==69.5.1` 构建。
- **Issue #2 bug 1/2（install-sd.ps1 308 不跟随 + 句柄泄漏）**：新增 `Resolve-HfRedirect` 手动跟 301/302/303/307/308 跳转链；分段 worker 改写 `.partnew` + 长度校验后原子改名（不再产生半成品分片）、`finally` 显式释放句柄、HEAD 与单流前先跟跳转；分段全挂自动降级单流重试；`.part*` 清理逐项 `try/catch`（Issue #1 缺陷 3 同根：被占文件 `Remove-Item` 不再掀翻整个脚本）。
- **Issue #2 bug 3（hires 500）**：`sd_txt2img` hires 分支补 `denoising_strength`（默认 0.5，新增 `hiresDenoising` 参数暴露），A1111 v1.10.1 拿 None 与 int 比较会 TypeError。
- **Issue #2 bug 4/5（默认值收敛）**：`sd-direct.ps1` 默认负面词与 `sd-bridge.js` 对齐（补 `extra fingers, fewer digits, malformed limbs, signature, jpeg artifacts`）、尺寸/步数对齐 `512×768/22`；`sd_script`/`sd_script_b` 脚本生成命令的默认值同步收敛；inpaint 默认重绘幅度改读配置 `inpaintDenoising`（默认 0.6），不再硬编码。

## 0.9.4（出图参数表单：确认提示词后弹五项参数，最终出图走图生图 + 质检迭代）

背景：用户要求在确认提示词之后再弹 5 个参数框——「迭代次数：」（默认=素体迭代测出的最佳次数，可改）、「Denoising：」（默认 0.7，可改）、「比例：」（默认 9:16，常见比例下拉可选）、「画风：」（默认二次元，图生图默认保持画风，下拉可选）、「画质：」（默认 480p，常见档位下拉可选）。

- **参数表单（Show-ParamForm，WinForms）**：五行固定布局——迭代次数（可编辑下拉 1-5，默认 = `$baseWin.RoundsUsed` 素体迭代实际用掉的最佳轮数，非法输入回落）、Denoising（可编辑下拉 0.4-0.9，默认 0.7；无素体成品时灰掉）、比例（只读下拉 9:16 / 1:1 / 3:4 / 4:3 / 16:9 / 2:3 / 3:2 / 21:9，默认 9:16）、画风（只读下拉 保持画风 / 二次元 / 国风 / 赛博朋克 / 写实 / 厚涂 / 水彩 / 像素风，图生图默认「保持画风」、文生图默认「二次元」）、画质（只读下拉 480p / 640p / 768p / 1024p / 1280p，默认 480p）。
- **尺寸映射（Get-SizeFor）**：画质档定短边、比例定形状，8 的倍数向下取整、下限 256（如 9:16+480p → 264x480，21:9+1280p → 1280x544）。`-Width/-Height` 参数不再用于最终出图，只当素体迭代的初始形状。
- **最终出图（Invoke-FinalIterate）**：按表单参数连出 N 张（换 seed、第 2 张起带 `-RestoreFaces`），每张过 VLM 脸部质检，**取最高分那张**打开收尾；质检挂了（-1）不再烧轮数、直接采纳当前轮。有素体成品 → **图生图**（`-InitImage` 素体 winning 图 + `-Denoising` 表单值）：追加内容画上去的同时构图与过关的脸保得住；无素体成品 → 文生图。
- **画风只进负面**（替换词红线不破）：写实/厚涂/水彩/像素风映射到对应的负面词（如写实 → `anime, cartoon, illustration, painting`），**正向一个字都不加**；「保持画风」「二次元」「国风」「赛博朋克」不动负面。
- **追加为空的快捷收尾**：只在「无追加 + 有素体成品 + 表单全默认形态」（比例 9:16、画质 480p、画风保持画风/二次元、迭代次数=素体轮数）时保留——用户调了任何参数都会真出图，参数表单不再被绕过。
- 测试：pwsh7 + PS5.1 Parser 0 错误、UTF-8 with BOM、`SKILL SMOKE OK`；表单五项静态断言全过、尺寸映射 6 组用例全对；真机端到端：素体图 + 追加（银发/蓝裙/花园）denoising=0.7 图生图 → 脸部 100/100、尺寸 480x720 正确。

## 0.9.3（素体自检迭代：基底图自己迭代到脸部过关，追加内容仍由用户手动决定）

背景：用户要求 C 档（sd-inject.ps1）的素体出图也要自我迭代到最好效果，但**绝不**往提示词里加任何词（包括违规词的「替换词」）——追加什么由插件用户在弹框里手动输入，保留参与感；同时全身图脸部容易崩，也要迭代救回来。

- **素体自检迭代（sd-inject.ps1，默认开）**：弹追加框**之前**，先用 `-BasePrompt` 只跑基底：每轮换 seed（`-Seed -1`）、第 2 轮起带面部修复，每轮产物交给**本地视觉模型**（默认 `qwen3-vl:8b`，`-VlmModel` 可换；自动按 vl/vision 优先挑候选，embed/rerank 排除）做脸部质检——只问「眼睛/五官/脸部结构是否崩坏」，只回 0-100 整数分；**≥75 过关即停**，上限 `-IterateRounds`（默认 3）轮。质检只改 seed 与面部修复，**不改提示词一个字**。`-NoIterate` 恢复老行为（直接出一张）。视觉模型不可用 / 没有视觉模型 / 连续低分且已开修复（判定质检模型不可靠）→ 自动降级为「出一张就收」，绝不卡死。
- **VLM 预热 + 超时放宽**：实测 8B 视觉模型首问要冷启动加载进显存（>120s 超时返回 -1），迭代前先发一条纯文本空问预热（300s），带图质检超时放宽到 180s。
- **seed 捕获与锚定**：`sd-direct.ps1` 出图后多打两行机器可解析的 `SEEDFILE:` / `SEEDVALUE:`（真实 seed，img2img/inpaint 一样有效）；迭代捕获每轮真实 seed。**追加为空** → 迭代产物就是最终图（不再重复出一张，直接打开收尾）；**有追加** → 最终出图用 winning seed 锚定（构图与过关的脸保得住，追加内容叠上去）。迭代期间统一 `-NoOpen`，最终那张才弹看图器。
- **面部修复开关（sd-direct.ps1）**：新增 `-RestoreFaces`（`restore_faces=true`）与 `-CodeFormerWeight`（默认 0.5）。A1111 的修复强度不在 txt2img 请求体里，走 `/sdapi/v1/options` 设 `code_former_weight_factor`，`face_restoration_model` 为空时补 `CodeFormer`；设置失败降级为服务端默认继续，不阻断出图。
- **同步**：包内、工作区根、插件安装副本三处 sd-inject.ps1 / sd-direct.ps1 已更新（UTF-8 with BOM；PS5.1 + pwsh7 Parser 0 错误；`SKILL SMOKE OK`、INSTALL RECORD OK、SETTINGS SMOKE OK）。真机端到端验证：真实 SD 出图 → qwen3-vl 质检 95 分 → seed 捕获 4229936936，脸部健康。`test-install-catalog.mjs` 在 DSH 沙箱内因 `spawnSync` 拿不到子进程退出码（恒 null）而无法通过，属沙箱边界（改动前后同样失败，该测试只覆盖 install-sd.ps1，本次未动），需沙箱外复跑。
- 已知限制：DSH 沙箱为低完整性级别，对 `D:\SD.4.8` 的写入被硬拒（deny-only Administrators）——SD 目录那份 sd-direct.ps1 便利副本本次同步不上，插件下次运行 `syncDirectInto()` 会自动补齐。

## 0.9.2（坑22：C 档命令改由 sd_inject 调用时生成，不再把图存到 profile 目录）

背景：0.9.1 之后用户再次实测，走 C 档本地注入命令出的图**仍然**存到 `C:\Users\zhang\.dsh\profiles\desktop\SD-Picture`。这次是 0.9.1 没修干净的那一半。

- **根因**：0.9.1 只改了「`-OutDir` 交给脚本按 `$PSScriptRoot` 解析」，但**命令里的脚本路径本身还是错的**。技能全文是 `skills.register()` **全局注册**的，apply 时拿不到会话 exec，`docLabels(exec)` 里的 `sessionCwd(exec)` 只能退到 `process.cwd()`——也就是 DSH 宿主进程目录（profile 目录）。于是技能里的 `%DIRECT_INJECT%` 被永久固化成 `C:\Users\zhang\.dsh\profiles\desktop\sd-inject.ps1`（本次实测：模型拿到的技能全文里就是这条路径），用户跑它时 `$PSScriptRoot` = profile 目录 → 默认 `-OutDir` = `profile\SD-Picture`。
- **修法（命令改为调用时生成）**：新增工具 **`sd_inject`**（C 档专用，**不碰 SD、不出图**，只返回命令字符串）。它在 `execute(args, exec)` 里用 `sessionCwd(exec)`（会话工作区）算路径，返回的命令同时带上：
  - `-File "<会话工作区>\sd-inject.ps1"`（并先 `directPathFor()` 把脚本同步进工作区）；
  - `-OutDir "<会话工作区>\SD-Picture"`（**显式注入**，即使误跑了别处的脚本副本也存不回 profile）。
  技能文本不再出现任何固化绝对路径：C 档那一段改成「调 `sd_inject` → 把返回的 `command` 逐字贴出」，并删掉 0.9.1 那条「不要传 `-OutDir`」（现在反向要求：不要改/删插件注入的 `-OutDir`）。`docLabels` 里的 `%DIRECT_INJECT%` 标签一并删除（连同它的 `injectAbs` 计算）。
- **`apply()` 不再 `syncDirectScripts(process.cwd())`**：往宿主进程目录同步脚本，只会制造一份「看起来就是命令要用的」profile 副本并误导用户。apply 时只做 `syncDirectInto()`——把 `sd-direct.ps1` 同步进 **SD 目录**（保住「SD 目录那份与包内一致」的老承诺）；工作区那份留到命令生成时由 `directPathFor(会话工作区)` 现场同步。`syncDirectScripts` 顺手重构成 `syncScriptFile(file, target)`，避免 root 与 sdDir 相同时重复写。
- **顺带修**：`sd_inpaint` 之前没进 `applyDocsToTools()` 的注入名单，描述里的 `%OUT%` / `%REF%` 是字面量；现在 `sd_inpaint` 与 `sd_inject` 一起注入。
- **C 档本地注入的界面文案改成人话**（用户指定）：冷启动那行改为「插件附件拉起中（首次拉起加载约1-3分钟）」、**隐藏**「可执行: <ollama 路径>」那行、接口就绪那行改为「提示词优化中」、真正调审查模型那行改为「生成最终提示词（第N/M次）」（不再打印端点与模型名）。提权/换模型/超时等排查信息一律保留。
- **确认环节可反复改最终提示词**（用户要求，机会不限）：`=== 最终提示词 ===` 之后的确认提示为「按 Enter 确认并出图，**输入 e 修改提示词**，输入 q 退出」。输入 `e`/`E`/`修改` 弹出两个预填当前值的输入框（正向、负向；**留空 = 保持不变**，不会把提示词清空），改完重新打印最终提示词并**继续提供 e**——想改几次改几次，Enter 才出图，`q` 退出行为不变。（最初版本是「只有一次机会」，按用户要求放开。）
  - 逻辑测试：`tmp\test-inject-confirm.ps1`（mock 掉 `Read-Host` / `Read-InputBox`）实跑 5 个场景——Enter 直出、改正向、改负向、**连改两轮（3 轮提示 / 4 次弹框 / 最终取 P2）**、q 退出，全通过。
- **删掉非 JSON 重试时的刷屏句**（用户要求）：`模型 '…' 返回的不是合法 JSON（可能是专用模型不肯接这活）—— 重试 N/M` 整句删除，重试分支只留诊断用的「  原始回复：<模型原话>」；最终失败的「已重试 N 次，换下一个模型」保留（换模型的原因要说清楚）。smoke 加两条断言：该句不得再出现、`原始回复` 必须保留。
- **加权反 NSFW 拦截（用户实测反馈：只删词不够，有概率出违规图）**。背景：A 档把违规词删掉后，SD 会顺着残留上下文（睡衣/床/私密场景/挑逗构图）脑补，实测仍可能出违规图；用户同时反馈末尾「违禁提示词」只列了几个词、也不带权重。
  - **机制**：① 正向补合规反向词 `fully clothed, modest outfit, sfw, safe for work`（可按需加权 1.2-1.4）；② **剔除的违规标签按 `(tag:1.4~1.6)` 加权追加进 `negativePrompt`**；③ 场景/姿势/氛围类边缘词按 `(tag:1.1~1.3)` 也进负向。**权重档位**写进技能：主体级 1.5-1.7 / 场景氛围 1.2-1.4 / 边缘暗示 1.1-1.2，**上限约 1.7**（再高 CFG 失衡、画面发糊畸形）。
  - **插件兜底**：新增常量 `SAFETY_NEGATIVE`，`DEFAULTS.defaultNegative`、`sd_inject` 的 `INJECT_BASE_NEGATIVE`、`sd-inject.ps1` 的 `$BaseNegative` 默认值三处同步带上加权安全底噪 `(nsfw:1.6), (nudity:1.5), (nude:1.5), (explicit sexual content:1.4), (sexual content:1.4), (suggestive:1.2)`（画质底线保持在前，命令形态不变）。`sd_txt2img` / `sd_img2img` / `sd_inpaint` 的 `negativePrompt` 参数说明也写清加权要求。
  - **本地注入脚本的模型退回「纯翻译器」**（用户要求：只翻译并填入，不做任何其他事）：`$sysPrompt` 里那四条加权要求**全部撤掉**，改为明确约束——只做中→英标签翻译填空；**不要增/删/改写/合并/「优化」标签**，不要补质量词/画风词/人物特征/服装/场景/光影；**不要加权重**；**不要加安全或合规类标签**（权重与安全底噪一律由脚本处理）；没给的那段填空字符串；除 JSON 外一个字符都不输出。脚本自己的加权 `$BaseNegative` 底噪不受影响（拦截仍在，只是不由模型插手）。脚本里「审查模型」字样统一改为**「翻译模型」**（含回退提示语）。smoke 断言随之改为反向锁定（不得再出现 `1.5-1.7` / `权重上限约 1.7` / `审查模型`）。
- **坑24：PS5.1 调 Ollama 的双向编码坑（实调发现）**。改完纯翻译 prompt 后真机一测：模型回的全是「å°å¥³」式乱码 / 干脆不翻译只回模板——**根因不在 prompt，在编码**：PS5.1 的 `Invoke-RestMethod` 收到**字符串 body** 会按 Latin-1(28591) 发送，中文到了模型那边全是乱码，模型看不懂只能瞎猜；反过来 Ollama 的**响应头不带 charset**，PS5.1 又按 Latin-1 解码 UTF-8 正文。修法两头堵：
  - 请求侧：`$body` 显式 `[System.Text.Encoding]::UTF8.GetBytes()` 后发送，`Content-Type` 补 `charset=utf-8`；
  - 响应侧：新增 `Repair-Utf8Mojibake`（检测到 Latin-1 扩展字符就按原字节还原一次，纯 ASCII 原样返回）。
  实测：修复前模型回复 852 字符的「解释 + JSON 模板」且 positive 全是乱码；修复后同样输入回 105 字符的纯 JSON。
- **坑25：小模型偶尔把中文词原样抄回（实测「少女」）**。system prompt 加两条硬约束（出现任何汉字都算失败 + 常见词映射示例 少女→girl / 樱花→cherry blossoms / 下雨→rain）和 **两组 few-shot 对话**（assistant 轮示范「正负都译成英文标签、没给就空串」——比讲道理有效得多）；解析后新增兜底：字段里检测到汉字先**重试**，重试到底仍不译全就 `Strip-Cjk` 把未翻译的中文标签整条丢掉（英文标签原样保留），保证最终提示词全英文。真机回归 3 组样例全过：纯翻译、零权重括号、零质量词/合规词、无中文残留。
  - **末尾回执只有「违禁提示词」这行动了**（用户明确：建议替换词那行暂时不动）：违禁提示词要求按**五类**自查列全（① 裸露/衣着状态 ② 性行为/自慰类动作 ③ 性器官/体液 ④ 道具/场景 ⑤ 姿势/氛围暗示），不再只列最露骨的两三个；②③ 只写类别占位。建议替换词**保持原样式**（「合规替代方向，如 clothed、fully clothed、sfw、portrait 等」，没有合适替代词就留空）。同时写明权限边界：加重负向只在 A 档做，**C 档绝不加**；C 档命令里的 `-BaseNegative` 是插件固定常量、与本次请求无关，不算泄露。
  - **验证**：真机跑 `sd-direct.ps1` 带全套加权负向（1.4-1.6）——exit 0、3.5s、画面正常不发糊（`SD-Picture\weightcheck_001.png`）；smoke 新增 18 条断言（三处底噪一致、档位/上限文案、五类自查、**建议替换词保持原样**、C 档边界）；`acceptance.mjs` 加 `-BaseNegative` 带底噪断言。
- **坑23：PS5.1 把 CJK 字母也算变量名字符**。用户实测「生成最终提示词（第1/4次）」打印成「（第1/）」——`"…$QwenRetries次…"` 被解析成变量 `$QwenRetries次`（未定义 → 空值），`次` 跟着一起消失。改为 `"…${QwenRetries}次…"`（花括号划清名字边界），并加一条全包回归断言：`sd-inject.ps1` / `sd-direct.ps1` / `install-sd.ps1` 里**任何**「`$变量` 紧跟非 ASCII 字母」都算违规（扫描时跳过整行注释里的反例示例）。实测：PS7 不吞、**PS5.1 吞**（所以只能在 `powershell.exe` 下验），修后 PS5.1 打印 `生成最终提示词（第1/4次）` / `（第3/4次）` 均正确。
- 坑13 复查：编辑 `.ps1` 后 BOM 两次被编辑工具剥掉，均已补回 UTF-8 with BOM，Parser 0 错误；`sd-inject.ps1` 已同步到 `D:\DSWorkPlace\sd-inject.ps1`。
- **实机/测试**：`smoke-skill.mjs` 里原来那条断言的其实是**反例**——它把技能里的脚本路径断言成"存在即可"，而那个路径正是 `process.cwd()`（跑测试时= 仓库目录，恰好有同名文件）所以一直是绿的；现已改成正面回归：用**临时工作区**当会话 cwd 调 `sd_inject`，断言命令里的脚本路径与 `-OutDir` 都落在该工作区、且命令不含 `profiles`；同时断言技能文本里不得残留真实机器路径、不得再出现「不要传 -OutDir」。`acceptance.mjs` 工具清单与 C 档用例同步更新。

## 0.9.1（产物落点修复：C 档命令不再把图存到 profile 目录）

背景：用户实测发现，走 C 档本地注入命令出的图存到了 `C:\Users\zhang\.dsh\profiles\desktop\SD-Picture`，而不是会话工作区 `D:\DSWorkPlace\SD-Picture`。

- **根因**：两条路径算的不是同一个目录。工具调用走 `resolveOutputDir(exec)` → `sessionCwd(exec)`（会话工作区，正确）；而 C 档命令文本是技能注册时**一次性**把 `%OUT_ABS%` 替换进去的，`docLabels()` 当时用的是 `process.cwd()`——也就是 DSH 宿主进程的工作目录（`C:\Users\zhang\.dsh\profiles\desktop`）。技能是全局注册、apply 时拿不到会话 exec，所以这个值被永久固化成了 profile 目录。
- **修法（不靠进程 cwd）**：C 档命令**不再传 `-OutDir`**，改由 `sd-inject.ps1` 自己解析——其默认 `-OutDir` 从 `Get-Location`（随用户运行目录漂移）改为 **`$PSScriptRoot\SD-Picture`**（脚本所在目录）。而 `syncDirectScripts` 早已把 `sd-inject.ps1` 同步到会话工作区，于是无论从哪个目录运行命令，产物都落回工作区，与生图工具落点一致。
- `docLabels(exec)` 仍改为优先用会话工作区（拿得到 exec 时更准），`applyDocTokens` / `applyDocsToTools` / `mapStringsDeep` 一并透传 `exec`；`%OUT_ABS%` 标签保留但技能命令块已不再使用。
- 技能文本补一条硬性说明：**不要传 `-OutDir`**，传了反而可能指到别处。
- **实机验证**：把命令的 cwd 设成 `C:\Users\zhang\.dsh\profiles\desktop` 运行，`-OutDir` 仍解析为 `D:\DSWorkPlace\SD-Picture`（脚本所在目录），不再漂移。
- 测试：`smoke-skill.mjs` 断言改为「命令块内不得出现 `-OutDir`」+「技能必须写明不要传 `-OutDir`」+「`sd-inject.ps1` 默认 OutDir 必须是 `$PSScriptRoot` 且不得用 `Get-Location`」。
- 坑13 复查：编辑后 BOM 被剥，已补回 UTF-8 with BOM，Parser 0 错误。

## 0.9.0（sd-inject.ps1：审查模型每个多重试 + 真机拉通验证）

- **每个模型内部再重试 `$QwenRetries` 次（默认 4）**：模型回绝、返回非 JSON、或两个字段都空，先在**同一个模型**上再试，只有同一模型 4 次都不成才换下一个候选。原来「一次不行就换模型」，遇到概率性回绝（abliterate 系尤其如此）会把好模型白白跳过。
- **重试时略抬 temperature**：`0.2 + 0.15 × (attempt-1)`，完全确定性时容易反复撞同一句回绝。
- **404 直接换模型**：模型不在本机（404）是确定性失败，重试没意义，直接 `break` 到下一个候选。
- **重试间隔 1 秒**（`Start-Sleep -Seconds 1`），避免把本地服务打得太急。
- **进度可见**：每次调用打印 `(第 N/4 次)`，成功时若 `attempt -gt 1` 补一句「第 N 次尝试成功」。
- **说人话**：全部失败时报「试了 3 个模型、每个最多 4 次」+ 拉取提示 + `-QwenRetries` 可调。
- **真机验证**：`huihui_ai/qwen2.5-abliterate:14b`（9.0 GB）已拉通——默认模型首次调用即成功，中文正确拆成 `silver hair, red ribbon, school uniform`。另外用 mock Ollama 实跑 3 个场景：前 3 次回绝第 4 次成功、同模型 4 次全拒后换下一个、3 个模型全拒后报错退出。
- 坑13 复查：编辑后 BOM 被剥，已补回 UTF-8 with BOM，Parser 0 错误。
- 测试：`smoke-skill.mjs` 新增 5 条断言（`$QwenRetries` 默认 4、`for ($attempt...)` 循环、temperature 递推、404 短路、重试间隔）。
- 拉取提醒：该模型在 Ollama 仓库里**只有带命名空间的全名** `huihui_ai/qwen2.5-abliterate:14b`（裸名 404），脚本默认值已用全名。

## 0.8.9（sd-inject.ps1：审查模型重试 + 专用模型排最后）

背景：用户实跑 C 档注入命令，截图里两件事同时炸——① `qwen2.5-abliterate:14b` 不在本机，回退逻辑挑了**第一个** qwen，正好是 `qwen2.5-coder:7b`；② 代码模型直接回绝 `I'm sorry, but I can't assist with that request.`，脚本判「不是合法 JSON」后 `exit 1` 整单崩掉。

- **候选模型排序**（`Rank-QwenModels`）：按名字识别 `coder|code|vl|vision|embed|math|ocr|rerank` 等**专用模型**并排到最后，`instruct|chat|abliterate|latest` 等通用对话模型优先。本机实测排序：`qwen3.5:latest` → `qwen2.5-coder:7b` → `qwen3-vl:8b`。
- **逐个候选重试**（`Get-QwenCandidates` + `foreach ($cand in $order)`）：模型不在本机（404）、调用失败、返回不是合法 JSON、或 JSON 里两个字段都空——四种情况都**换下一个候选**再试，最多 3 个，不再让一个专用模型把整单带崩。候选列表枚举一次后缓存，重试不反复打接口。
- **容忍模型裹话**：解析前截取第一个 `{` 到最后一个 `}` 之间的内容，兼容「好的，这是结果：{...}」这类回复。
- **`-QwenModel` 显式指定**的排到最前（用户点名先试），仍失败才走自动排序。
- **说人话**：全部失败时报出试过哪些模型、提示 `ollama pull qwen2.5-abliterate:14b` 或 `-QwenModel qwen3.5:latest`；成功但从默认值回退时，也说明白是哪个模型接的活。
- 坑13 复查：编辑后 BOM 被工具剥掉导致 PS 解析报 3 个错，已补回 UTF-8 with BOM，Parser 0 错误。
- 测试：`smoke-skill.mjs` 新增 7 条断言（默认模型名、`Rank-QwenModels`、`Get-QwenCandidates`、`foreach ($cand in $order)` 重试、3 次上限、专用模型压底、JSON 主体截取）；并用 mock Ollama 实跑 5 个场景全通过——默认模型缺失回退、专用模型回绝后重试、全部候选失败、`-QwenModel` 显式指定优先、留空输入不调模型。
- **本机注意**：`huihui_ai/qwen2.5-abliterate:14b` 首次拉取要用**带命名空间的全名**——裸名 `qwen2.5-abliterate:14b` 在 Ollama 仓库里不存在（registry 404：`pull model manifest: file does not exist`），只有 `huihui_ai/qwen2.5-abliterate` 这个仓库提供该模型。脚本默认值已同步改为全名。

## 0.8.8（sd-inject.ps1：审查模型换成 qwen2.5-abliterate:14b）

- **`-QwenModel` 默认值改为 `qwen2.5-abliterate:14b`**：C 档本地注入流程最后一步唤起的审查模型由「自动挑第一个 qwen」改为显式指定这个 14b 模型。
- **保留自动兜底**：模型不在 `ollama list` 里时仍自动回退到第一个 qwen 系模型并提示一句（不阻断），同时打印 `ollama pull qwen2.5-abliterate:14b` 拉取命令；调用失败时也提示同一条命令。
- **显式传 `-QwenModel ""`** = 回到 0.8.7 的「自动挑第一个 qwen 系模型」行为。
- 文案同步：脚本头注释、`调用本地审查模型：...` 提示、README 第 102 行。
- 坑13 复查：编辑后已恢复 UTF-8 with BOM（PS5.1 无 BOM 会按 GBK 读），PS Parser 无语法错误；`smoke-skill.mjs` / `acceptance.mjs` 全绿。
- 已同步生效路径：`D:\DSWorkPlace\dsh-sd-bridge-guard\`、`C:\Users\zhang\.dsh\profiles\desktop\sd-inject.ps1`（C 档命令实际引用的那份）、`C:\Users\zhang\.dsh\profiles\desktop\node_modules\dsh-sd-bridge-guard\sd-inject.ps1`（插件安装副本）、`D:\DSWorkPlace\sd-inject.ps1`（工作区同步副本）。
- 注意：本机 Ollama 目前只有 `qwen2.5-coder:7b` / `qwen3.5:latest` / `qwen3-vl:8b`，**尚未安装** `qwen2.5-abliterate:14b`——首次跑会自动回退到第一个 qwen 系模型；要真正用上它先执行 `ollama pull qwen2.5-abliterate:14b`（约 9GB）。

## 0.8.7（sd-inject.ps1：Qwen 冷启动 + 模型自动挑）

背景：用户实跑 C 档的本地注入命令，一输入中文就报 `Qwen 调用失败：无法连接到远程服务器`。

- **根因是两个问题叠在一起**：① `ollama serve` 本来就没在跑；② `-QwenModel` 默认值 `qwen2.5:14b` 是**写死的猜测值**——本机 Ollama 实际只有 `qwen2.5-coder:7b` / `qwen3.5:latest` / `qwen3-vl:8b`。服务没起 + 模型不存在，最后只甩出一个看不懂的连接错误。
- **冷启动**（对齐 `sd-direct.ps1` 拉起 SD 的同一套姿势）：新增 `Test-QwenApi` 探活 → `Start-QwenApi` 没起就 `Start-Process ollama serve` 后台拉起（句柄重定向到 `%TEMP%\dsh-sd-inject-qwen.log*`，不继承控制台管道）→ 轮询到就绪。`-NoQwenStart` 关闭、`-QwenStartTimeout`（默认 300s）调超时；超时/找不到 `ollama.exe` 都只报一条错 + 一行提示就退出。自举只认 Ollama，vLLM / LM Studio 端点请用户自己先起。
- **模型自动挑**：`-QwenModel` 默认改为空 = 自动选本机第一个 qwen 系模型；显式指定但 `ollama list` 里没有时，自动回退到第一个可用模型并提示一句（不阻断）。枚举顺序：OpenAI 兼容 `/models` → Ollama 原生 `/api/tags` → `ollama list` CLI 兜底。
- **说人话**：一个模型都枚举不到时，直接把 `OLLAMA_MODELS` 这个最常见根因打出来（本机就是它指向空目录、模型实际在别处），不再让用户面对一个 400 Bad Request 猜。
- 技能文本与三个生图工具描述同步补一句「脚本会自己冷启动本地模型服务，首次约 1-3 分钟」。
- 测试：`smoke-skill.mjs` 新增冷启动断言（三个函数存在、有输入时必须先冷启动再解析模型、必须拉 `serve`、有超时/可关闭开关、必须点 `OLLAMA_MODELS`、**不得使用 PS7 专有的 `??` 运算符**——本次真踩中，PS5.1 直接语法错）。
- **实机验证通过**：冷启动拉起 `ollama serve` → 自动挑到 `qwen2.5-coder:7b` → 中文拆成英文标签 → 基底 + 追加拼接 → 确认出图，产物 `SD-Picture\inject_001.png`（512x768，正常）。留空 / 仅负向输入 / 全空格三种输入的 `hasInput` 判定也都验证过。

## 0.8.6
- B 档并入 C 档：C 档完全覆盖原 B 档行为。
- C 档输出命令新增 -BasePrompt / -BaseNegative 素体基底。
- sd-inject.ps1 弹框输入改为追加：基底 + 用户输入，拼接后出图；留空直接跑基底。
- smoke-skill.mjs 新增 C 档、基底、追加模式断言。
- 本次改动落在生效路径 D:\DSWorkPlace\dsh-sd-bridge-guard\。

## 0.8.5（坑21：安装记录写失败不得判安装失败）

背景：`test-install-catalog.mjs` 的干跑段一直报 `dry run must exit 0, got null`，曾被认为是「沙箱问题、既有、不在范围内」——实际是真 bug。

- **根因**：`install-sd.ps1` 收尾处 `[System.IO.File]::WriteAllText($env:USERPROFILE\.dsh-sd-bridge.json, ...)` 是**裸调用、没有 try/catch**，而脚本设了 `$ErrorActionPreference = 'Stop'`。于是记录写不进去（只读 HOME、沙箱拦、企业策略）时一次 `UnauthorizedAccessException` 就把**整次安装**打成非 0 退出——而 WebUI、模型、VAE、`config.json` 全都已经落盘成功。用户看到的是一次「失败的安装」，其实东西都装好了，只是少了一条路径记录。
- **修复**：记录写入包 `try/catch`，失败只报一条错 + 一行提示（指向 `DSH_SD_DIR` / `cordis.patch.yml` 两条兜底路径），**不再 exit 1**；完成横幅多打一行「记录没写成功 → 重启前先设 `DSH_SD_DIR=<Target>`，否则插件探测不到」。BOM 校验逻辑原样保留（坑10 不回归）。
- **记录路径可覆盖**：新增 `-StateFile` 参数与 `DSH_SD_STATE_FILE` 环境变量，留空仍是 `~/.dsh-sd-bridge.json`。优先级：`-StateFile` > `DSH_SD_STATE_FILE` > `$env:USERPROFILE`。
- **测试不再依赖 HOME 可写**：干跑段改为把记录改道到临时目录（`-StateFile`），断言 exit 0、`record.sdDir` 指向 `-Target`、记录首字节是 `{`（无 BOM）。新增 6b) 节**专项验坑21**：故意把记录指到一个不存在目录 → 断言仍 exit 0、有「安装记录写入失败（不影响已装好的 SD）」提示、且能到达 `== 完成 ==` 横幅。另加静态断言：`-StateFile` 参数存在、认 `DSH_SD_STATE_FILE`、写入在 try/catch 里、记录失败不 exit 1。
- 实测两种路径：可写 → exit 0 + `已记录安装位置 ... (BOM=False)`；不可写 → exit 0 + 一条非致命提示 + 兜底说明。四条不出图测试（smoke / record / settings / catalog）全过。
- 坑13/坑19 回归防护：改完 `.ps1` 仍必须补回 UTF-8 BOM + CRLF（本次改动用 Node 补 BOM，未走 PowerShell 重写，避免二次编码损坏）。

## 0.8.3（`sd_script_b` 外部词表透传：-TermFile）
- **`sd_script_b` 新增 `termFile` 参数**：占位符映射表 JSON 路径。插件只**透传路径**（命令追加 `-TermFile "<path>"`），不读取、不写入、不解析词表内容，也不对 `prompt` / `negativePrompt` 做任何替换——占位符原样写进命令。留空时插件生成一个输出目录下的建议路径（`terms_<时间戳>.json`）。
- **`buildCommand` 新增 `-TermFile` 分支**（放在 `-Name` 之后）：其余参数拼接、`psQuote` 转义、`commandBlock` / `alignTwoVersionTags` 行为一律不动。
- **`sd-direct.ps1` 新增 `$TermFile` 参数与替换逻辑**：在 `Start-SdApiIfNeeded` 之后、构造 `$body` 之前读词表（`ConvertFrom-Json` 后逐键 `$Prompt.Replace($key, $val)` / `$Negative.Replace($key, $val)`）。脚本不生成、不推断任何映射；词表不存在或解析失败时**静默跳过**，原样执行，不阻断、不报错。
- **输出 schema 新增 `termFile` 字段**，工具描述与参数说明同步；`smoke-skill.mjs` 新增断言：命令必须含 `-TermFile`、占位符（`__TERM_A__`）必须原样进命令、输出必须带 `termFile` 路径（默认落在输出目录下且命名为 `terms_<时间戳>.json`）、显式传入时原样使用；`sd-direct.ps1` 必须定义 `$TermFile` 并含 `.Replace($key, $val)`。
- README 新增「外部词表（-TermFile）」小节。不出图三条测试（smoke / record / settings）全过；`test-install-catalog` 的沙箱失败为既有问题，不在本次范围内。
- **顺带修复 `sd-direct.ps1` 编码回归（坑13）**：工作区副本此前被写成 UTF-8 **无 BOM**，PS5.1 会按 GBK 解码 → 中文注释/字符串变乱码 → 语法错误（`[System.Management.Automation.Language.Parser]` 实测 10 处 parse error；补 BOM 后 0 处）。已重存为 UTF-8 **with BOM**，内容逐字节不变；`smoke-skill.mjs` 新增 BOM 断言（源文件 + 同步进工作区的那一份）防止再回归。

## 0.8.2（`sd_script_b` 自动提取原始输入作为位置对齐基准）

背景：`originalPrompt` 原本是必填，但调用方（模型分流改写后）常常拿不到「用户最早那一版」的原文，只能提供处理后的 `prompt`——位置对齐缺了基准就退化成单版透传，双版本对齐形同虚设。

- **新增 `extractOriginalInput(exec)`**（放在 `sessionCwd` 附近的工具公共件区）：从会话上下文提取最近一条用户消息原文。路径优先级 `session.messages`（倒序查找 `role === 'user'`，取 `content` 或 `text`）→ `session.header.originalInput`（兼容 `originalPrompt`）→ 空字符串。**纯字段读取**：无词表、无正则、不做内容判定，任何形状异常（非数组 messages、null/数字元素、缺 header）都静默返回 `''`，绝不抛异常。
- **`originalPrompt` 改为可选**：`scriptBTool.execute` 里显式传入时 `originalSource = 'explicit'`；留空且提取成功时用提取值作基准、`originalSource = 'extracted'`；两处都拿不到才 `originalSource = 'fallback'` 并维持原行为（退化为全部保留正向）。直接透传 `args.originalPrompt` / `args.prompt`，**无调用前交换、无参数名映射错误**。
- **输出 schema 新增 `originalSource`**（`enum: ['explicit', 'extracted', 'fallback']`），标记基准来源便于排查；工具描述与参数说明同步说明兜底规则。
- 测试：`smoke-skill.mjs` 新增断言——`extractOriginalInput` 在模拟 exec 上取到最后一条 user 消息、回落到 `header.originalInput`、无历史/异常形状返回 `''`；`originalSource` 字段存在且三态可枚举；`required` 从 `['originalPrompt', 'prompt']` 改为 `['prompt']`；extracted / fallback 两条端到端用例。三条不出图测试（smoke / record / settings）全过。

## 0.8.1（`sd_script_b` 对齐方向反转 + B 档指向统一）

背景：0.8.0 的对齐方向写反了。脚本要复现的是「用当前版本（`prompt`）生成的那张图」，正向必须与生成时一致；原来把 `originalPrompt` 的词留在正向、`prompt` 的差异词送负向，脚本跑出来反而是「原始版本」的图，与会话里那张对不上。

- **反转 `alignTwoVersionTags` 方向**（sd-bridge.js）：② 两版同位都非空且不等时改为 **`prompt[i]`（当前版本）进正向原位、`originalPrompt[i]`（原始版本）进负向**；① 相等时保留正向、③ 仅 original 非空进正向、④ 仅 prompt 非空保留正向四条规则不变。`positivePrompt` / `negativePrompt` 返回字段与蒙版、denoising 逻辑不动。
- **B 档指向统一到 `sd_script_b`**：`sd_txt2img` / `sd_img2img` / `sd_inpaint` 三个工具描述里「明显违规 → 改调 sd_script」的措辞改为 `sd_script_b`；`sd_script` 描述保持原样（A 档/单版透传专用，末尾已注明「需要双版本对齐改用 sd_script_b」）。
- **蒙版模式 denoising 保留 0.7**，不与 `sd_inpaint` 的 0.6 对齐（`sd_script_b` 传的是当前版本参数，默认 0.7；修瑕补全请显式传 0.40-0.55）。
- **技能文本同步**：B 档第 3 步的双版本说明改为「prompt 的词留在正向原位、original 的词进负向（被替换掉的旧标签进负向）」；源码头注释、`sd_script_b` 工具描述与参数说明同步反转。
- 测试：`smoke-skill.mjs` / `acceptance.mjs` 的对齐断言反转（positivePrompt = 当前版本、negativePrompt = original 差异词 + negativePrompt），蒙版用例断言同步；三条不出图测试（smoke / record / settings）全过。
- **回归排查（本轮复查「B 档正向未含原始输入」）**：逐项核对四个怀疑点——① 技能 B 档第 3 步已指向 `sd_script_b`（不是 `sd_script`）；② `sd_txt2img` / `sd_img2img` / `sd_inpaint` 描述里的 B 档措辞已全部为 `sd_script_b`；③ `alignTwoVersionTags` 方向已是「prompt 进正向、originalPrompt 差异词进负向」；④ `scriptBTool.execute` 直接透传 `args.originalPrompt` / `args.prompt`，无参数名映射错误、无调用前交换。据此补充 smoke 断言：`assert.ok(skill.content.includes('sd_script_b'))` + B 档第 3 步必须显式「调 `sd_script_b`」+ 遮掉 `sd_script_b` 后，技能文本与三个生图工具描述里不得再出现裸 `sd_script` 的 B 档指向。

## 0.8.0（`sd_script_b` 双版本对齐：脚本复现与会话出图对齐）

背景：`sd_script` 直接透传 `prompt` / `negativePrompt`，而模型分流改写时常常顺手**重排或替换**正向标签——脚本原样吃下改写版，跑出来的图与会话里那张对不上（SD 的提示词顺序参与条件，换序＝换图）。

- **新增第七个工具 `sd_script_b`（B 档专用，只生成命令、不碰 SD、不出图）**：参数 `originalPrompt`（必填）、`prompt`（必填）、`negativePrompt`、`initImage`、`mask`、`maskBox`、`maskBlur`、`inpaintingFill`、`maskInvert`、`inpaintFullRes`、`inpaintFullResPadding`、`denoising`（默认 **0.7**）、`width`、`height`、`steps`、`seed`、`name`。
- **位置对齐逻辑（纯位置比较，无词表、无正则、不做内容审查）**：两版按逗号切分、逐位置对比——① 相等 → 保留正向；② 两版都非空且不等 → 当前版本（`prompt`）进**正向原位**、原始版本（`originalPrompt`）进**负向**（0.8.1 起的方向：复现的是当前版本生成的那张图）；③ 仅 `originalPrompt` 非空 → 进正向；④ 仅 `prompt` 非空 → 保留正向；`negativePrompt` 追加到负向末尾。返回新增 `positivePrompt` / `negativePrompt` / `mask` 便于核对。
- **注册**：`apply()` 的工具数组（含文档占位符注入列表 `applyDocsToTools`）加入 `scriptBTool`，工具键顺序为 `sd_txt2img / sd_img2img / sd_inpaint / sd_script / sd_script_b / sd_models / sd_server`。
- **技能文本**：B 档第 3 步改调 `sd_script_b`（说明同时传 `originalPrompt` + `prompt`、顺序一一对应，差异词进负向）；回复骨架、工作流、图生图参考图三处 B 档指向同步；`sd_script` 描述末尾加「本工具只透传一版提示词；需要双版本对齐改用 `sd_script_b`」。
- **不动**：`sd_txt2img` / `sd_img2img` / `sd_inpaint` 一行未改——A 档走生图工具自带的 `script`，提示词由插件从本次出图参数逐字带出，天然不受改写影响。
- **语义（写进了工具描述与 README）**：`originalPrompt` = 用户最早那一版输入（位置基准），`prompt` = 当前模型处理后的输出；插件**只认位置差异、不做内容审查**（内容审查是模型层的事，插件不替模型下判定）。对齐依赖调用方同时传两版且顺序对应；只传 `prompt`（`originalPrompt` 留空）则退化为全部保留正向。
- **蒙版重绘支持（与 `sd_inpaint` 对齐）**：新增 `mask`（白色/不透明 = 重绘区，优先）与 `maskBox`（"x,y,w,h"，插件现场造黑底白块蒙版存进 `ref/`），加 `maskBlur`（默认 4）/ `inpaintingFill` / `maskInvert` / `inpaintFullRes` / `inpaintFullResPadding`（默认 32）；给了 mask/maskBox 即 `mode = 蒙版重绘`（必须同时给 `initImage`），尺寸与 maskBox 坐标换算沿用 `sd_inpaint` 同一套规则（尺寸默认跟随底图），返回新增 `mask` 路径。`denoising` 默认仍 0.7（`sd_inpaint` 是 0.6，修瑕补全请显式传 0.40-0.55）。技能「蒙版重绘」一节的 B 档指向、`sd_inpaint` 之外的 B 档措辞同步；`sd_inpaint` 本体按不变量一行未动。
- 测试：`smoke-skill.mjs` 工具注册断言更新为七个，并新增对齐规则断言（差异词进负向、单版退化、仅 original 非空的补位、`denoising` 默认 0.7、mask/maskBox 走【蒙版重绘】且缺 `initImage` 报错）；`acceptance.mjs` 工具清单同步为七个 + `sd_script_b` 纯命令回归（含 maskBox 造蒙版）。

## 0.7.0（设置入口 + 环境预检 + 资源清单化拉取）

对着评论区反馈做的四件事：设置里找不到配置项、装机环境缺东西、模型拉取对象过时、缺常见 LoRA。

- **设置面板配置入口（修「设置里没有这个插件设置内容」）**：`sd-bridge.js` 新增 `registerSettings`——运行时动态 `import('@deepseek-ai/schemastery')` 构造 schema（零静态依赖，schemastery 缺失则跳过注册、工具照常可用），`settings.register('sd-bridge', schema)` 注册到 **设置 → 插件 → sd-bridge**，`DEFAULTS` 全部 13 个字段可编辑（每个带中文说明）。`scope.watch` 实时并回 `cfg`，工具调用现读 `cfg`，**改完下一个调用即生效、无需重启**。优先级：DEFAULTS < 设置面板 < `cordis.patch.yml` 显式覆盖（patch 层指定的键被冻结，面板不覆盖）。
- **环境预检段 `Test-Prereqs`（缺啥补啥，先于一切下载）**：磁盘 ≥15GB 提前拦 → 镜像探活（失败提示换 `-Mirror ""`）→ git（缺则自举 MinGit）→ Python 3.10（占位符则静默装 3.10.6）→ **VC++ 2015-2022 x64 运行库**（查注册表 `VC\Runtimes\x64`，缺则下官方 `vc_redist.x64.exe` 静默装；torch/A1111 硬依赖，缺了首轮启动报错极迷惑）。每项失败只报一条错 + 一行提示即 `exit 1`，最后打一张「✓ 就绪清单」。`-NoPrereq` / `-SkipVC` / `-SkipDiskCheck` 可分别跳过。
- **模型/VAE 拉取对象换成本机实测组合（清单化）**：`-Models` 逗号多选（`awpainting` 默认 / `revanimated` / `anythingv5` / `majicmix` / `darksushi`），`-Vaes`（`mse` 默认 / `animevae`）。**全部 5 个 checkpoint + 2 个 VAE 的 sha256 已与本机出图正常的文件逐字节比对**（HF lfs oid = sha256：AWPainting `3d1b3c42…`、ReVAnimated v1.1 `d725be5d…`、anything-v5 `7f96a1a9…`、majicMIX v7 `7c819b6d…`、dark sushi brighterPruned `099e0754…`、animevae `f921fb3f…`）。清单键写错会列出全部可用键。
- **常见 LoRA/Embedding 拉取**：`-Loras` 默认 `add_detail,easynegative,badhandv4`（细节增强 LoRA 38MB + 负面嵌入 24KB + 手部修复嵌入 18KB，均 HF 镜像直链 + sha256 校验）；LoRA 落 `models\Lora`、Embedding 落 `models\embeddings`（A1111 各自扫描目录）。`-SkipLora` 跳过、`none` 清空。**你本地那批国内站 LoRA（国风山水/赛博朋克/电商摄影等）不进清单**——直链不稳，README 写了手动放置说明。
- **`-Upgrade` 升级复验**：已存在文件做 sha 复验，不符就重拉；清单条目带 `Supersedes`（如 ReVAnimated v10 → v1.1）时旧版在、新版缺就补拉新版（**旧版保留**）。
- **资源清单汇总**：跑完打印「[类型] 文件 — ✓ 已下载 / ✓ 已存在 / ✗ 原因」一张表，失败项提示重跑自动续传。
- **文档去旧插件化**：README/`cordis.patch.yml`/源码头注释删除「替换原 `dsh-sd-bridge`」「与原插件同 id」等声明（原版从未发布）；`package.json` 仓库地址从 `YOUR-USER` 占位改为 `savinglighting`。
- **踩坑新增：编辑 `.ps1` 会丢 UTF-8 BOM**（PS5.1 无 BOM 按 GBK 读 → 语法错），改完必须补回 `EF BB BF`——本次实测踩中，靠 `[Parser]::ParseFile` 检查抓出。
- **踩坑新增：符号链接插件裸 import 依赖会落空**——插件以 profile node_modules 符号链接指向工作区时，Node 按 realpath 解析依赖，`import('@deepseek-ai/schemastery')` 必然失败 → 设置注册被静默跳过（「注册了但面板还是没有」的隐藏根因）。`tryLoadConfigSchema` 增加途径②：扫 `~/.dsh/profiles/*/node_modules/@deepseek-ai/schemastery/lib/index.mjs` 按绝对路径导入。
- 新增 `test-settings.mjs`：schema 注册（ns = `sd-bridge`、13 字段全在 `dict` 上）+ 面板改动实时并回 `cfg` + **patch 显式键不被面板覆盖** + 越界钳制（denoising 0-1、idleStop ≥0、startupTimeout ≥30s）。
- 新增 `test-install-catalog.mjs`：BOM 断言 + 三张清单（键/sha256/HF 源，含 AWPainting 与 animevae 的已验证哈希）+ 预检五项与单条退出 + `-Models`/`-Loras` 默认值 + 临时目录干跑（预检打印、记录无 BOM）+ 非法键 exit 1 并列出可用键。
- **发布整理**：README 与源码头注释的工具计数从「五件套」更正为「六件套」并补上 `sd_inpaint`（0.6.0 新增蒙版重绘后文案未同步）；README 示例图与 LICENSE 徽章改用绝对地址，在 npm 包页面同样能渲染；`package.json` 的 `files` 补 `CHANGELOG.md`，新增 `scripts`（`npm test` = 四条不出图检查，`npm run acceptance` = 真实出图验收）；`sd-direct.ps1` / `install-sd.ps1` 行尾统一为 CRLF（与 `.gitattributes` 的 `*.ps1 text eol=crlf` 声明一致），UTF-8 BOM 保持不变、`[Parser]::ParseFile` 复核 SYNTAX OK。

## 0.6.0（几个坑回填 + 脚本跑完自动开图）

从「点安装 → 新会话跑通」踩的 12 个坑全部回填进插件与安装脚本；可复现脚本新增「跑完打开这张图」。

- **脚本跑完自动打开那张图**：`sd-direct.ps1` 保存成功后用系统默认看图器打开产物，`-NoOpen` 关闭；工具描述、`sd-paint` 技能与 `asMarkdown` 头部同步说明。
- **脚本自带服务托管 + 单条报错（坑15，别人电脑实测）**：SD API 没开时脚本按 `-SdDir` > `DSH_SD_DIR` > `~/.dsh-sd-bridge.json` > 各盘常见安装名**自己拉起**并轮询就绪（`-NoStart` 关闭、`-StartTimeout` 调超时、日志 `%TEMP%\dsh-sd-direct-launch.log*`）；端口被占、目录/解释器缺失、API 调用失败、结果无图——统一 `Fail` **只报一条错误 + 一行提示就 `exit 1`**，不再出现「连不上 → 空数组 → 空值写盘 → 空 JSON」连炸 4 条。
- **坑10 · BOM（唯一影响所有会话的根因）**：安装记录读取改为「剥 BOM → JSON 解析 → 失败按字段兜底 → **大声记日志**」，读到 BOM 就**就地自愈重写**为无 BOM UTF-8；`install-sd.ps1` 写记录改用无 BOM UTF-8 并回读校验 `BOM=False`。
- **坑11 · 离线 tokenizer 失败**：只有 `<SD>\.cache\huggingface` 真有 `models--*` 才接管 `HF_HOME` 并开离线；缓存为空则不接管、保持联网（`DSH_SD_HF_ONLINE=1` 强制联网）。
- **坑6 · Blackwell**：全新安装时探测 `compute_cap ≥ 12` → 自动 `TORCH_COMMAND` 换 torch 2.7.0 + torchvision 0.22.0（cu128，本机 RTX 5060 实测 CUDA 可用）；已设 `TORCH_*` 则完全尊重。
- **坑7/8 · pip**：`PIP_CONSTRAINT` 钉 `setuptools==69.5.1`、`numpy==1.26.2`、`opencv-python==4.11.0.86`（作用到含 PEP 517 构建隔离在内的每次 pip），另设 `PIP_RETRIES=10` / `PIP_TIMEOUT=60`；`DSH_SD_PIP_CONSTRAINT=0` 可关。
- **坑9 · 上游删库**：本地缺 `repositories/stable-diffusion-stability-ai` 时自动把 `STABLE_DIFFUSION_REPO` 指向 camenduru fork（保留同一 commit `cf1d67a6…`，签名 verified）。
- **坑2 · 无 git**：`install-sd.ps1` 自动自举 MinGit 便携版——资源带 `digest` 先校验 sha256、再 `git --version` 实测，装完写入用户 PATH（保留注册表 ExpandString 类型）。
- **坑4 · 商店占位 Python**：自动静默装官方 Python 3.10.6（用户级 `PrependPath`），`pythonDir` 记进安装记录，插件 `resolvePython` 在 SD 自带 python/venv 之后兜底使用。
- **坑5 · 大文件断流**：`Get-SegmentedFile` 8 段并行 Range 下载 + 断点续传 + 长度/可选 sha256 校验（实测与单流逐字节一致）。
- **坑13（本次新发现）**：`.ps1` 固定存 **UTF-8 with BOM**——PS5.1 对无 BOM 文件按 GBK 读，中文多字节会吞掉后面的 `)` `"` 直接语法错（与坑10 的 JSON 记录恰好相反：JSON 必须无 BOM）。
- **坑14（本次新发现）**：`sd-direct.ps1` 的 `-Seed` 由 `[int]` 改为 `[long]`——SD 的 seed 是 uint32，`3845143617` 这类种子在 `[int]` 上直接参数转换失败。
- **坑16 · 新装 SD 画质差（本次新发现，根因＝模型）**：`install-sd.ps1` 默认模型从 2022 年的 SD1.5 base 换成 **AWPainting v1.2**（远端 sha256 `3d1b3c42ec…` 与本机出图正常的文件**逐字节一致**），补下 **`vae-ft-mse-840000`**（`735e4c3a…`，实测 4 段下载 + 哈希通过），并合并写入 `config.json` 的 `sd_model_checkpoint` / `sd_vae` / `CLIP_stop_at_last_layers=2`——只改点名键、保留其余键、写回不带 BOM、非 UTF-8 老文件按原编码读写、`-NoConfig` 关闭；`sd_models` 发现只有 base 模型时返回 `qualityHint` 给出升级路径。
- **坑17 · 脚本拉起的 SD 启动卡几分钟（本次新发现）**：`sd-direct.ps1` 启动前按插件同一规则设 HF 环境（缓存命中 → `HF_HOME` + 离线加载；未命中 → 保持联网走 `hf-mirror`；`DSH_SD_HF_ONLINE=1` 强制联网），修掉「去连 huggingface.co 重试 5 次×10s×多文件」——实测 HF 重试 0 次、冷启动到出图 28 秒。
- **坑18 · stderr 刷「找不到驱动器 E:」（本次新发现）**：扫盘先 `Test-Path` 跳过不存在的盘符，候选路径再包 `try/catch`。
- **句柄彻底脱离**：启动 SD 时 stdin/stdout/stderr 三者都显式重定向到文件，避免继承宿主管道导致「脚本跑完了宿主却一直挂着不返回」。
- **画质默认值（本机与所有机器生效）**：`defaultSampler: 'DPM++ 2M'`（同步数下比 A1111 默认的 Euler a 更干净）、`defaultNegative`（调用方没传负面词时补质量底线）、`img2imgDenoising: 0.55`（更贴参考图）；`sd-direct.ps1` 新增 `-Sampler`（默认同为 DPM++ 2M）并写进可复现命令，**复现结果与会话里一致**。
- **出图自检 → 优化循环（违不违规都要做）**：两个生图工具返回新增 `selfCheck` 提醒，技能正文新增「出图自检 → 优化循环」与「图生图画风一致」两节，回复骨架 / 工作流 / 工具描述同步——出图后用 `read_image` 自己看，肢体/水印/构图/风格不合格最多再改 2 轮（每轮只改 1-2 个变量、保留 seed、逐轮贴图）；**图生图**并排对照参考图，按「同源模型 + 风格词入提示词 + denoising 0.30-0.50 + 同尺寸」四步锁画风；**A 档若仍残留违规内容立即重画**，B 档照旧不出图。
- **新增 `sd_inpaint` 蒙版重绘**：只重画画面里一块，字段名逐个对照本机 A1111 源码（`mask` / `mask_blur` / `inpainting_fill` / `inpaint_full_res` / `inpaint_full_res_padding` / `inpainting_mask_invert`）。蒙版二选一：`mask` 蒙版图，或 `maskBox: "x,y,w,h"`——没有蒙版图时**插件手写 PNG 编码器**（zlib + CRC32，零第三方依赖）现场造黑底白块蒙版存进 `ref/`；返回【蒙版重绘】可复现脚本与「接缝/色差/边缘重复/越界误改」自检；`sd-direct.ps1` 新增 `-Mask / -MaskBlur / -InpaintFill / -MaskInvert / -NoFullRes / -InpaintPadding`；技能新增「蒙版重绘」章节（含 A 档可只把违规那块蒙版重画、B 档照旧不出图）。**修复**：`readImageBase64` 恒返回 Promise，漏 `await` 会让 `init_images` 变 `[null]` → 服务端 `'NoneType' has no attribute startswith` 500。
- 新增 `test-install-record.mjs`（BOM 读取 + 自愈专项，不出图、毫秒级）；`acceptance.mjs` 新增第 8 步**真跑一遍脚本**（powershell.exe PS5.1 执行 + uint32 seed 回归）与第 10 步**真实蒙版重绘**（maskBox 造蒙版 → 出图 → 断言脚本带 `-Mask`、蒙版 PNG 合法）；README 补「14 坑排查表」与「必须**新开会话**复验」的验收方法。

## 0.5.0 (portable release)

跨机器可移植发布版——别人安装插件即可使用，无需任何本地适配。

- **SD 目录自动探测**：`sdDir` 默认留空，按「配置 > `DSH_SD_DIR` 环境变量 > `~/.dsh-sd-bridge.json` 自举记录 > 扫盘候选」查找本机 SD WebUI；找不到时工具返回可读的安装指引而不是崩溃。
- **一键自举安装**：新增 `install-sd.ps1`（克隆 WebUI + 下载模型 + 记录安装位置）。
- **工作区化**：`outputDir`/`refDir` 默认改为相对路径（`SD-Picture` / `ref`），解析到会话工作区；`sd-direct.ps1` 同步到「工作区根目录 + SD 目录」，命令注入 `-OutDir`，脚本与插件保存同一目录。
- **文案模板化**：工具描述与 `sd-paint` 技能全文不再写死盘符，注册时按本机配置注入实际路径。
- **全新安装兼容**：venv 尚未创建时不跳过依赖准备、不禁用联网（首次启动可在线安装 torch 等依赖）。
- 测试去硬编码：`smoke-skill.mjs` / `acceptance.mjs` 走自动探测 + 临时工作区，新增可移植性断言。
- `sd-direct.ps1` 的 `-OutDir` 默认改为「当前目录\SD-Picture」（插件生成命令时会显式注入）。

## 0.4.0

- 图生图参考图固化：工作区外的聊天附件自动复制到 `ref/`（按内容哈希命名），脚本引用稳定副本。
- `sd_script` 与生图工具共用同一套固化逻辑。

## 0.3.0

- 违规分流协议（A 档删词出图 / B 档不出图只给合规素体脚本 / 末尾英文违规词清单）与 `sd-paint` 技能。
- `sd_script` 工具：只生成可复现脚本，不调 SD、不出图。
