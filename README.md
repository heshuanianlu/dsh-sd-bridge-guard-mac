# dsh-sd-bridge-guard

[![npm](https://img.shields.io/npm/v/dsh-sd-bridge-guard.svg)](https://www.npmjs.com/package/dsh-sd-bridge-guard)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/savinglighting/dsh-sd-bridge-guard/blob/main/LICENSE)

**DeepSeek Harness 插件 · 本机 Stable Diffusion 生图八件套 + 违规分流协议（A 档 / C 档）· 跨机器零适配**

让 DeepSeek Harness 直接调用你电脑里的 Stable Diffusion WebUI 生图：不用提前打开 SD（首次调用自动以纯 API 模式拉起）、不用改任何路径——装上插件就能用。

---

## 🆕 版本更新内容（v0.9.8 · 2026-10-15）

本次是**修 bug**版本，只动 C 档参数表单里那个「看得到、改不了」的 Denoising：

- **问题**：C 档 `sd-inject.ps1` 参数表的 **Denoising 一栏永远是灰的**（禁用），既下拉不动也手填不了；就算填了也不生效。
- **根因（三段全废）**：① 表单在素体自检迭代**之前**弹出，那时 `-HasBaseImage` 传参恒为 `$false`，旧代码据此把控件 `Enabled = $false` → 每次都灰；② 解析段在同一条件下直接 `$den = 0`；③ 最终出图硬编码 `-InitImage "" -Denoising 0`。
- **修复后怎么用**：表单里 Denoising **恒可编辑**（下拉或手填 0-0.95）：
  - `0（文生图·不用底图）`（默认）= 现在的行为，走文生图，不动默认出图链路；
  - `0.3-0.5` = 拿**素体迭代的 winning 图**当底图微调（贴底图、保构图）；`≥0.7` = 基本重画；
  - 选了 `>0` 就真的走图生图，日志会写明 `最终出图走图生图：底图 = 素体成品（seed=…），denoising = …`。
- 详情见 [CHANGELOG.md](CHANGELOG.md#098c-档参数表单-denoising-解锁从看得到改不了变成改了就生效)。

---

## 版本更新内容（v0.9.7 · 2026-10-15）

本次是「整理打包」版本，重点是**让用户一句话就能改参数重出图**，并把本机全部权重资源整理成可复现清单：

- **新增「C 档选项表」（A 档出图后自动罗列）**：`sd_txt2img` / `sd_img2img` / `sd_inpaint` 三个出图工具都新增返回字段 `quickOptions`——一张 Markdown 表，把 C 档参数表单里的 **画风 / 模型 / LoRA / 比例 / 画质 / 迭代 / Denoising** 全量可选项一次列全。**A 档每次出图后，这张表会自动贴到图片下方**，用户直接回一句「4 号画风 + majicMIX + 3:4 + 1024p，再来一张」即可快速重出图，不用自己回忆参数名。
- **用户自调画风进入 C 档画风选项（`sd-inject.ps1` 参数表单）**：
  - **★ 写实二次元·东亚脸**（2026-10-15 实测配方）：在「写实二次元」基础上把五官往东亚脸收——窄脸型、杏仁眼 + 虹膜高光、眼神光、正面偏侧柔光 + 发丝轮廓光；负向压掉宽脸/宽眼距/西方面孔/过曝/真人照片。沿用「动漫底子 + `<lora:semirealisticanime:0.6>` 不切模型」路径。
  - **★ 釉彩调色盘**（用户本机 LoRA 画风）：`<lora:釉彩·麻袋调色盘_v1.0:0.8>` + 釉面质感/粗布调色盘色域词。
  - 加上原有的 **★ 彩色哥特**，C 档选项表里现在有 **3 个 ★ 用户自调画风**（编号 4 / 5 / 6）。
- **触发话术写进技能与本文档**：新对话第一句说「**打开SD插件**」、出图要求前加「**用SD插件绘制**」，能明显提高插件与生图工具被命中的成功率（详见下节）。
- **新增 `docs/models-loras.md`**：本机全部 checkpoint / VAE / LoRA / 嵌入的清单，**每条都带 HF 镜像直链（`hf-mirror.com`）+ sha256**，另附国内自调 LoRA 的来源站点与落盘位置。
- **新增实拍图**：C 档参数表单截图 + 5 张本次随机测试实出图（见下「效果图」）。
- 测试：`npm test` 全绿；`smoke-skill.mjs` 新增 15 条断言（quickOptions 字段、C 档选项表章节、★ 自调画风、触发话术、表单画风项）；随机测试 6 张图全部通过自检（样例与 seed 见文末）。

> 历史版本看 [CHANGELOG.md](https://github.com/savinglighting/dsh-sd-bridge-guard/blob/main/CHANGELOG.md)。**DSH 插件暂不支持自动更新：升级需先卸载再安装新版。**

---

## ⭐ 这样用成功率最高（用户须知）

| 做法 | 效果 |
| --- | --- |
| 新对话**第一句**先说 **`打开SD插件`** | 让模型先读 `sd-paint` 技能、把生图工具挂上来，后面出图更稳 |
| 出图要求**前面加上** **`用SD插件绘制`**（例：`用SD插件绘制：银发少女站在樱花树下`） | 明确点名走本机 SD，不跑偏到别的方式 |
| 想改画风/模型/比例 | 出图后**直接按下方「C 档选项表」回编号**（如「4 号画风，3:4」） |
| 想检查装没装好 | 说一句「打开SD插件」后问「SD 能出图吗」，或让它调 `sd_models` / `sd_server status` |

---

## 效果图（本次随机测试实出图，非示意图）

**A 档出图**（正常需求，图直接出在聊天窗 + 可复现脚本）：

| 文生图（动漫 · AWPainting） | 写实二次元·东亚脸（★用户自调） |
| --- | --- |
| ![anime](docs/assets/demo-txt2img-anime.jpg) | ![dongya](docs/assets/demo-style-dongya-face.jpg) |

| 国风山水 LoRA | 赛博朋克场景 LoRA |
| --- | --- |
| ![guofeng](docs/assets/demo-style-guofeng.jpg) | ![cyberpunk](docs/assets/demo-style-cyberpunk.jpg) |

| 釉彩调色盘 LoRA（★用户自调） | 写实人像（majicMIX v7） |
| --- | --- |
| ![youcai](docs/assets/demo-style-youcai.jpg) | ![realistic](docs/assets/demo-style-realistic.jpg) |

**C 档参数表单**（脚本在你本机弹出的那个框——`sd-inject.ps1`，画风下拉里就有 ★ 用户自调画风）：

![C 档参数表单](docs/assets/demo-c-paramform.jpg)

| 图生图（参考图重绘） | 蒙版重绘（只改一块） |
| --- | --- |
| ![img2img demo](docs/assets/demo-img2img.jpg) | ![txt2img demo](docs/assets/demo-txt2img.jpg) |

---

## 两个档位怎么用（本插件核心）

判定标准 = **模型自己会拒绝执行的尺度**，不依赖固定词表。**A 档只适用于完全不违规的需求**；一旦涉及任何违规内容（哪怕只有一个词）一律走 C 档。

### A 档 · 完全不违规 → 照常出图

1. 直接说要求（建议加「用SD插件绘制」前缀）。
2. 插件出图 → 图片**贴在聊天窗**（点开是大图）→ 附**可复现脚本**（复制整行到 PowerShell 就能复跑同一张，脚本会自己拉起 SD、跑完自动打开图）。
3. **图片下方自动附「C 档选项表」**：想换画风/模型/LoRA/比例/画质，回一句编号或名字即可，模型会照你说的改参数重出图。
4. 出图后模型会**自己看图自检**（手部/手指/面部/水印/构图），不合格最多再改 2 轮——每轮都会把图贴给你并说明改了什么。

用到的工具：`sd_txt2img`（文生图）、`sd_img2img`（图生图，按参考图重绘）、`sd_inpaint`（蒙版重绘，只改画面里一块）。

### C 档 · 涉及任何违规内容 → 一张图都不生成，只给本地注入命令

1. 插件**不生成任何图片**，也不输出与违规部分相关的任何内容。
2. 只调 `sd_inject`（`run: true`）→ 在**你本机**拉起独立 PowerShell 窗口，**C 档参数表单自动弹出**（就是上图那个框）。
3. **追加什么由你自己在框里填**：留空 = 直接用素体基底跑；填中文 = 用本地模型（默认 `huihui_ai/qwen2.5-abliterate:14b`，纯翻译器，只译不增删）译成英文标签后拼接出图。
4. **本机自动评估选优**：素体阶段先迭代到脸/手过关，最终按表单「迭代次数」连出 N 张、**逐张交本地视觉模型 `qwen3-vl:8b` 打分（脸+手 0-100，≥75 过关）取最高分那张**；模型不可用则降级为出满 N 张让你自己勾选（详见下节「本地模型评估链」）。
5. 回复末尾给两行回执：`违禁提示词：` / `建议替换词：`。
5. **没有「删掉违规词继续出图」这条中间路线。**

> 表单里的可选项：正向/负向提示词、迭代次数、Denoising（**恒可编辑**：默认 `0（文生图·不用底图）`，填 0.3-0.95 就改用素体成品做底图走图生图）、比例、**画风（含 ★ 用户自调）**、画质、LoRA、模型、命名；切换画风会**幂等写入**对应的正/负向画风词（你手写的词不受影响）。

---

## 本地模型评估链（Ollama · 全程本机运行）

C 档不是「点一下就出一张糊图」——`sd-inject.ps1` 会用**本机 Ollama 上的两个本地模型**给图打分、挑出最好的一张。**SD 与两个评估模型都在你本机，不上传任何图片。**

### 两个模型的分工

| 角色 | 默认模型 | 参数 | 干什么 |
| --- | --- | --- | --- |
| **视觉质检模型** | `qwen3-vl:8b` | `-VlmModel`（留空 = 自动挑本机 `vl`/`vision` 模型；专挑 `llava`/`moondream`/`minicpm-v`/`internvl` 系） | 看每轮候选图，给 **脸 + 手** 一个 **0-100** 整数分 |
| **翻译模型** | `huihui_ai/qwen2.5-abliterate:14b` | `-QwenModel` | 把你在表单里填的中文**逐条译成英文标签**（纯翻译器：不增删、不改写、不补质量词/画风词、不加权、不加安全类标签） |

两个模型共用 Ollama 的 OpenAI 兼容端点 `-QwenBase`（默认 `http://127.0.0.1:11434/v1`，`-QwenApiKey` 任意非空即可）。

### 质检怎么打分（原文问句，只问结构不问内容）

把候选图以 base64 data URI 发给视觉模型，`temperature=0.1`、超时 180s，问句固定为：

> 这张图里的人物脸部与手部结构健康吗？只检查两点：① 脸部：眼睛是否对称/无多余、五官是否扭曲错位、脸部是否畸形融化；② 手部：每只手是否五根手指齐全、有无多余或缺失的手指、手指是否扭曲粘连、手部是否畸形。脸部或手部任一处崩坏都要相应扣分。只回复一个 0-100 的整数分（100=完全健康，0=严重崩坏），除此之外一个字符都不要输出。

判定线：**≥ 75 过关**；解析不到分数返回 `-1`（当作"质检没工作"）。提问前会先发一条**纯文本空问预热**（超时 300s），把 8B 模型先加载进显存——否则首轮带图质检会撞冷启动超时（实测 >120s）。

### 两段迭代（都不改你的提示词一个字）

1. **素体自检迭代**（默认开，`-IterateRounds` 默认 3、`-NoIterate` 关闭）：先只跑素体基底，每轮 **换 seed**，逐轮质检；`< 75` 继续下一轮，`≥ 75` 立即停；**新最高分立即增量落盘**（中途关窗口也不丢当前最优成品）。若连续低分（`< 45` 且已到第 2 轮）→ 判定"这个视觉模型不会看图"，采用本轮结果、不再烧轮数。
2. **最终出图迭代**：按表单里的「迭代次数」连出 N 张（**Denoising > 0 且素体迭代有成品才走图生图 `-InitImage` + Denoising；默认 0 = 文生图**），逐张质检，**取最高分那张**；`≥ 75` 提前停。

### 质检模型不可用时的降级（不阻塞出图）

| 情况 | 行为 |
| --- | --- |
| `Test-VlmApi` 探活失败（Ollama 没起） | 跳过素体迭代，直接出一张（`-NoIterate` 是显式关闭，这里是自动降级） |
| 本机没有视觉模型 | 打印提示 `ollama pull qwen3-vl:8b` 后照常出图 |
| `-VlmModel` 指定的模型不在本机 | 自动回退到本机第一个 `vl`/`vision` 模型并提示 |
| 质检连续返回 `-1` | 后续轮**不再质检**，改为出满 N 张并弹出多选对话框（纯文本勾选 + 右侧预览，**绝不白屏**）让你自己留几张 |
| 一个模型都枚举不到 | 直接点出最常见根因 `OLLAMA_MODELS` 指向空目录（本机实测就是这个坑） |

### 相关参数（`sd-inject.ps1`）

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-QwenBase` | `http://127.0.0.1:11434/v1` | Ollama OpenAI 兼容端点（质检与翻译共用） |
| `-VlmModel` | `qwen3-vl:8b` | 脸/手质检的视觉模型 |
| `-IterateRounds` | `3` | 素体自检迭代轮数上限 |
| `-NoIterate` | 关 | 跳过素体自检迭代，直接出一张 |
| `-FaceBoostTags` | `detailed face, beautiful detailed eyes, perfect face, detailed skin` | 自动追加进正向的脸部细节词（传 `""` 关闭；**这是唯一会被自动写进提示词的内容**） |
| `-QwenModel` / `-NoQwenStart` / `-QwenStartTimeout` / `-QwenRetries` | 见上文 | 翻译模型选择 / 冷启动开关 / 超时 / 重试次数 |

> **A 档没有这一步**：A 档出图的质检是**执行模型（我）自己用 `read_image` 看图**——按技能「出图自检 → 优化循环」查手部/面部/水印/构图，不合格最多再改 2 轮。本地视觉模型的自动打分只存在于 C 档的 `sd-inject.ps1` 流程里。
>
> 拉模型：`ollama pull qwen3-vl:8b` 与 `ollama pull huihui_ai/qwen2.5-abliterate:14b`。

---

## C 档选项表（A 档出图后自动罗列到你眼前）

插件每次 A 档出图后会把下面这张表**原样贴到图片下方**（工具的 `quickOptions` 字段）。它就是 C 档参数表单的全部可选项：

| 类别 | 可选项 |
| --- | --- |
| **画风** | 1 保持画风（图生图默认） · 2 二次元（默认） · 3 写实二次元 · **4 写实二次元·东亚脸 ★用户自调** · **5 彩色哥特 ★用户自调** · **6 釉彩调色盘 ★用户自调（本机 LoRA）** · 7 国风 · 8 赛博朋克 · 9 写实 · 10 厚涂 · 11 水彩 · 12 像素风 |
| **模型** | AWPainting_v1.2（动漫默认） · majicMIX realistic v7（写实） · SemiRealMix（彩色哥特/半写实备选） · anything-v5 · dark sushi mix · ReVAnimated |
| **LoRA** | semirealisticanime（半写实 0.6） · add_detail（细节 0.6-0.8） · 国风山水_v1.0 · 赛博朋克_v1.0 · 赛博朋克场景_v1.0 · 自然美妆场景_v1.0 · 釉彩·麻袋调色盘_v1.0 · 39_v1.0 |
| **负面嵌入** | EasyNegative · EasyNegativeV2 · badhandv4（手崩优先用它） |
| **比例** | 9:16（竖屏默认） · 1:1 · 3:4 · 4:3 · 16:9 · 2:3 · 3:2 · 21:9 |
| **画质** | 480p · 640p · 768p · 1024p · 1280p · 2160p（4K） |
| **迭代** | 1 / 2 / 3 / 4 / 5 / 8 / 12 / 16 / 24 / 32（越高越慢越精细；C 档这里是**出图张数**——逐张过本地视觉模型质检、取最高分那张） |
| **Denoising** | **0（默认，表单里选「0（文生图·不用底图）」）= 文生图** · 0.3-0.5 贴素体底图微调 · 0.6-0.7 明显改动 · 0.8-0.9 基本重画（表单里恒可编辑：下拉选或手填 0-0.95；填 >0 就走图生图，底图 = 素体自检迭代的 winning 图） |

> 用法：回一句「**4 号画风 + majicMIX + 3:4 + 1024p，再来一张**」，或「保持这个画风，只换成赛博朋克场景 LoRA」。★ = 用户自己调出来的画风。完整模型/LoRA 名单随时可用 `sd_models` 查（名称以本机实际文件为准）。

---

## 模型 / LoRA 镜像清单

完整清单（含 **sha256 校验值**、每条 HF 镜像直链、本机文件大小、用途）见 **[docs/models-loras.md](docs/models-loras.md)**。摘要：

| 类别 | 条目 | 镜像站 |
| --- | --- | --- |
| Checkpoint | AWPainting v1.2（默认）、ReVAnimated v1.1、anything-v5、majicMIX realistic v7、SemiRealMix、dark sushi mix | HF 国内镜像 `https://hf-mirror.com`（`install-sd.ps1 -Mirror` 默认值） |
| VAE | `vae-ft-mse-840000`（默认·不发灰）、`animevae` | 同上 |
| LoRA / 嵌入 | `add_detail`、`semirealisticanime`、`EasyNegative`、`badhandv4` | 同上 |
| 国内自调 LoRA | 釉彩·麻袋调色盘、国风山水、赛博朋克、赛博朋克场景、自然美妆场景、39、EasyNegativeV2 | [LiblibAI](https://www.liblib.art) / [Civitai](https://civitai.com)（手动放 `<SD>\models\Lora\`） |

一键拉取（走镜像 + sha256 校验 + 8 段并行下载 + 断点续传）：

```powershell
powershell -ExecutionPolicy Bypass -File "插件目录\install-sd.ps1" -Models "awpainting,semirealmix,majicmix" -Vaes "mse,animevae" -Loras "add_detail,semireal,easynegative,badhandv4"
```

---

## 特性

- **零本地适配**：SD 安装目录自动探测（配置 > 环境变量 `DSH_SD_DIR` > 自举安装记录 > 扫盘候选）；产物、参考图、可复现脚本全部自动落在**当前会话工作区**（`SD-Picture/`、`ref/`、`sd-direct.ps1`）。
- **没装 SD 也能用**：插件找不到 SD 时返回一条可直接运行的安装命令（包内 `install-sd.ps1`），一键装好 WebUI + **AWPainting v1.2 模型 + `vae-ft-mse-840000` VAE + 质量默认配置**并把路径记进 `~/.dsh-sd-bridge.json`，重启即用（模型/VAE 都带 sha256 校验，哈希与画质已验证的本机文件一致）。
- **八个工具**：`sd_txt2img` 文生图、`sd_img2img` 图生图、`sd_inpaint` 蒙版重绘、`sd_script` 只生成可复现脚本不出图、`sd_script_b` 双版本对齐的可复现脚本、`sd_inject` C 档专用本地注入命令生成器（不生图）、`sd_models` 模型清单、`sd_server` 服务管理。
- **C 档选项表**：出图工具返回 `quickOptions`（画风/模型/LoRA/比例/画质/迭代/Denoising），A 档出图后自动贴到图片下方，用户一句话即可改参数重出图。
- **本地模型评估链（C 档自动质检选优）**：`sd-inject.ps1` 全程调用本机 Ollama——视觉模型 `qwen3-vl:8b` 给每轮候选图的**脸+手**打分（0-100，≥75 过关），素体阶段迭代到过关、最终出图取最高分那张；翻译模型 `qwen2.5-abliterate:14b` 只做中文→英文标签直译。**SD 与评估模型都在本机，图片不出机器**；模型不可用自动降级（跳过质检 / 出满 N 张让你勾选），绝不卡死。详见「本地模型评估链」。
- **违规分流协议**（`sd-paint` 技能内置，用户红线 2026-10-14）：**A 档仅适用于完全不违规的需求**，照常出图并附可复现脚本；**一旦涉及任何违规内容（哪怕一个词）一律 C 档**：一张图都不生成、不提供与请求相关的任何内容，也没有「删掉违规词继续出图」的中间路线，只调 `sd_inject` 生成 `sd-inject.ps1` 的本地注入命令（命令自带素体基底 `-BasePrompt` / `-BaseNegative`，并显式带上**当前会话工作区**的 `-OutDir`），用户本地弹框追加后出图；回复最末尾在「已剔除的违规提示词（不能加进脚本、不能给别人使用）」标题下给两行——`违禁提示词：` 与 `建议替换词：`，均一行排开、逗号分隔。
- **加权反 NSFW 安全底噪（A 档出图路径）**：插件默认负向自带加权安全底噪 `(nsfw:1.6), (nudity:1.5), (nude:1.5), (explicit sexual content:1.4), (sexual content:1.4), (suggestive:1.2)`，权重上限约 1.7（再高 CFG 失衡、画面发糊畸形）。注意：这只属于 A 档正常出图的默认负向；**C 档的 `-BaseNegative` 与本地注入脚本的 `$BaseNegative` 默认值只含画质底线、绝不夹带违禁/安全类标签**（用户红线）。
- **可复现**：每次出图返回单行 powershell 脚本（提示词高亮），用户复制整行即可在 PowerShell/cmd 复跑同一张图；脚本**自带服务托管**——SD 没开它自己拉起（首次含模型加载 1-3 分钟）、**跑完自动打开这张图**（`-NoOpen` 关闭）、**任何失败只报一条错误就退出**。
- **服务托管**：SD 没开也能生图——插件自动以 `--api --nowebui` 拉起、复用、可选空闲自动关闭。

## 安装

三种方式任选其一（装完重启 DeepSeek Harness）：

```text
# 1) 在 DSH「设置 → 插件」里粘贴 Git 安装源
github:savinglighting/dsh-sd-bridge-guard

# 2) 或粘贴 npm 包名
dsh-sd-bridge-guard

# 3) 或本地目录（开发者）
dsh plugin add link:D:\path\to\dsh-sd-bridge-guard
```

> DSH 插件暂不支持自动更新：升级需先卸载再安装新版。

## 首次使用

- **已装 SD WebUI**：什么都不用做。插件启动时自动探测（也认 `DSH_SD_DIR` 环境变量与 `cordis.patch.yml` 的 `sdDir` 覆盖）。
- **没装 SD**：让 Harness 帮你画张图，它会返回安装指引；或自己在 PowerShell 跑：

```powershell
powershell -ExecutionPolicy Bypass -File "插件目录\install-sd.ps1"
```

装完重启 DSH。首次生图会在线安装 Python/torch 依赖（10-30 分钟）。

### install-sd.ps1 参数

脚本先跑**环境预检**（磁盘 ≥15GB → 镜像探活 → git → Python 3.10 → VC++ 运行库，缺啥补啥、每项失败只报一条错即退出，最后打一张就绪清单），再克隆 WebUI、按清单拉资源：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Models` | `awpainting,semirealmix` | 模型清单，逗号多选：`awpainting` / `revanimated` / `anythingv5` / `majicmix` / `semirealmix` / `darksushi`（`none` = 不拉） |
| `-Vaes` | `mse,animevae` | VAE 清单：`mse`（写进 config 默认）/ `animevae` |
| `-Loras` | `add_detail,semireal,easynegative,badhandv4` | 常见资源：细节增强 LoRA + 半写实 LoRA + 负面嵌入 + 手部修复嵌入（`none` = 不拉） |
| `-Upgrade` | 关 | 已存在文件做 sha 复验、不符重拉；旧版本命中 `Supersedes` 时补拉新版（旧版保留） |
| `-Mirror` | `https://hf-mirror.com` | 填 `""` 用官方源 |
| `-SkipModel` / `-SkipVae` / `-SkipLora` | 关 | 跳过对应类别的下载 |
| `-NoPrereq` / `-SkipVC` / `-SkipDiskCheck` / `-SkipGit` / `-SkipPython` | 关 | 跳过环境预检的全部或某一项 |
| `-NoConfig` | 关 | 不写 `config.json` 质量默认值 |

清单里**每个条目的 sha256 都与本机出图正常的文件逐字节比对过**（HF lfs oid = sha256）；键写错会打印全部可用键。跑完会输出一张「资源清单汇总」表（已下载 / 已存在 / 失败原因）。

> **自己的 LoRA 怎么装**：国内站资源（釉彩调色盘、国风山水、赛博朋克、自然美妆场景这类）直链不稳，不进默认清单——手动把 `.safetensors` 放进 `<SD目录>\models\Lora\`（Embedding 放 `models\embeddings\` 或 `embeddings\`）即可，`sd_models` 能列出来。来源站点见 [docs/models-loras.md](docs/models-loras.md)。

## 提供的工具

| 工具 | 作用 |
| --- | --- |
| `sd_txt2img` | 文生图：提示词、负面词、尺寸/步数/CFG/采样器/seed、批次 1-4、临时换 checkpoint、LoRA、hires fix、styles、summary；返回 `script`（【文生图】脚本）+ `quickOptions`（C 档选项表） |
| `sd_img2img` | 图生图：本地图片路径 + `denoisingStrength` 重绘；工作区外的参考图自动固化到 `ref/`；返回 `script`（【图生图】脚本）+ `quickOptions` |
| `sd_inpaint` | **蒙版重绘（inpaint）**：只改画面里一块（补手/去杂物/局部改色/换背景）。蒙版给 `mask`（白/不透明 = 重绘区）或 `maskBox: "x,y,w,h"`（插件手写 PNG 现场造蒙版存进 `ref/`）；`maskBlur`/`inpaintingFill`/`maskInvert`/`inpaintFullRes+padding` 全可调；返回 `script`（【蒙版重绘】脚本，带 `-Mask`）、接缝自检 `selfCheck` 与 `quickOptions` |
| `sd_script` | **只生成可复现脚本，不调 SD、不出图**（`generatesImage` 恒为 false）——单版透传 |
| `sd_script_b` | **双版本对齐的可复现脚本**：`originalPrompt`（用户最早那版输入，位置基准，**可选**）+ `prompt`（当前模型处理后的输出，必填），逐位置对比——同位不同处 `prompt` 留在**正向原位**、`originalPrompt` 的词进**负向**（被替换掉的旧标签进负向，正向与生成时完全一致）；`originalPrompt` 留空时插件自动从会话上下文提取最近一条用户消息原文兜底（`originalSource` 标记 `explicit` / `extracted` / `fallback`），仍取不到才退化为全部保留正向；给 `mask` / `maskBox` + `initImage` 就是【蒙版重绘】（参数与 `sd_inpaint` 同一套，`denoising` 默认仍 0.7）；`termFile` 传外部词表路径（只透传路径，见下节）；返回 `positivePrompt` / `negativePrompt` / `mask` / `termFile` 供核对；同样不调 SD、不出图。**原「明显违规」档已并入 C 档，C 档直接输出 `sd-inject.ps1` 本地注入命令，不再调用本工具** |
| `sd_inject` | **C 档专用**：只生成 `sd-inject.ps1` 的本地调用命令并（`run: true` 时）在你本机拉起脚本窗口，**绝不生成图片**（`generatesImage` 恒为 false） |
| `sd_models` | 列出 checkpoints / LoRA / 采样器 / VAE / 当前选项 |
| `sd_server` | `status` / `start` / `stop`；找不到 SD 时 `status` 返回安装指引 |

### 保存与命名

- 产物目录：**会话工作区下的 `SD-Picture/`**（可用 `outputDir` 改成绝对路径）
- 文件名 = **提示词总结_三位序号.png**；`summary` 参数决定文件名，序号自动递增永不覆盖
- 返回 `paths`（绝对路径）、`fileNames`、`savedDir`、`replyImages`（Markdown，贴进回复即全尺寸展示）、`script`（可复现脚本）、`quickOptions`（C 档选项表）
- 用户手跑 `sd-direct.ps1` 时，图保存成功后脚本会**自动打开它**；批量跑加 `-NoOpen`

## 违规分流协议（`sd-paint` 技能全文内置）

判定标准 = 模型自己会拒绝执行的尺度，不依赖固定词表。**涉及任何违规内容一律 C 档，A 档只适用于完全不违规的需求**：

- **A 档 · 完全不违规** → 照常出图存盘、附脚本、**图片下方附 C 档选项表**，无违规提示行与末尾清单。
- **C 档 · 涉及任何违规内容**（哪怕一个词，不得生成）→ 不生成、不提供与请求相关的任何内容，只输出 `sd-inject.ps1` 的本地调用命令，命令自带素体基底（`-BasePrompt` 只含主体必要要素 / `-BaseNegative` 只含画质底线），用户本地弹框追加后出图，末尾给「违禁提示词：」+「建议替换词：」两行（一行排开、逗号分隔）。

本地注入命令（C 档唯一输出，格式固定）：

```powershell
powershell -ExecutionPolicy Bypass -File "%DIRECT_INJECT%" -BasePrompt "<素体主体>" -BaseNegative "lowres, bad anatomy, bad hands, extra fingers, fewer digits, watermark, text, signature, jpeg artifacts, worst quality, low quality" -Width 512 -Height 768 -Steps 24 -OutDir "%OUT%" -Name "inject"
```

`sd-inject.ps1` 行为：弹框输入改为**追加**（正向/负向都可留空）——**留空直接跑素体基底、不调用翻译模型**；有输入则**冷启动本地模型服务**（接口没起来就自己拉起 `ollama serve` 并轮询就绪，首次含模型加载约 1-3 分钟；`-NoQwenStart` 关闭、`-QwenStartTimeout` 调超时），默认用 `huihui_ai/qwen2.5-abliterate:14b` 作**翻译模型**（`-QwenModel` 可显式指定，点名的排最前）。该模型被约束为**纯翻译器**：只把中文逐条译成英文标签填进 JSON——不许增删改写/合并标签，不许补质量词、画风词、人物特征或场景，**不许加权**，**不许加安全/合规类标签**（权重与安全底噪一律由脚本处理），输出必须全英文（system prompt 带常见词映射 + few-shot 示例钉行为），除 JSON 外不输出任何字符。**编码坑已内置**（PS5.1 的 `Invoke-RestMethod` 字符串 body 会按 Latin-1 发送、Ollama 响应头无 charset 会按 Latin-1 解码——脚本统一 UTF-8 字节发送 + `Repair-Utf8Mojibake` 修复响应）；返回里残留中文时先重试、重试到底仍未译全就丢掉未翻译的中文标签（英文标签保留），保证最终提示词全英文。**两级重试**：模型回绝、返回非 JSON、或 JSON 两个字段都空时，先在同一个模型上重试最多 `$QwenRetries` 次（默认 4，每次略抬 temperature 避开同一句回绝、间隔 1 秒），同一模型 4 次都不成才换下一个候选模型（最多 3 个）——`coder` / `vl` / `embed` 等专用模型会被排到最后（它们会直接回绝这类任务），通用对话模型优先；404（模型不在本机）这类确定性失败不重试、直接换。全部失败才退出并给出 `ollama pull` 提示。拿到结果后与基底拼接（`基底 + 追加`），显示结果、按 Enter 确认出图。

### C 档参数表单（sd-inject.ps1 弹出）

| 字段 | 说明 |
| --- | --- |
| 正向/负向提示词 | 基底已预填、可直接改；**切换画风会幂等写入对应的画风词**（先剥上次注入的词再进新词，你手写的词不受影响） |
| 迭代次数 | 默认 3（上限 32），素体自检迭代轮数 |
| Denoising | 默认 0.7；图生图/重绘幅度 |
| 比例 | 9:16 / 1:1 / 3:4 / 4:3 / 16:9 / 2:3 / 3:2 / 21:9 |
| **画风** | 保持画风 / 二次元 / 写实二次元 / **写实二次元·东亚脸 ★** / 彩色哥特 ★ / **釉彩调色盘 ★** / 国风 / 赛博朋克 / 写实 / 厚涂 / 水彩 / 像素风 |
| 画质 | 480p / 640p / 768p / 1024p / 1280p / 2160p（4K） |
| LoRA | 从本机 SD 实时拉取（不用 LoRA = 留空） |
| 模型 | 从本机 SD 实时拉取（当前模型 = 不切） |
| 命名 | 留空 = 自动总结提示词命名 |

> **拉取翻译模型要用全名**：`ollama pull huihui_ai/qwen2.5-abliterate:14b`。裸名 `qwen2.5-abliterate:14b` 在 Ollama 仓库里不存在，会报 `pull model manifest: file does not exist`。

### 双版本对齐（`sd_script_b`）

`sd_script` 直接透传 `prompt` / `negativePrompt`——模型分流改写时顺手**重排或替换**的标签会原样进脚本，脚本复现出来的图就与会话里那张不一致。`sd_script_b` 改为**同时吃两版**、逐位置对齐（按逗号切分后做纯位置比较，**无词表、无正则、不做内容审查**）：`originalPrompt` = 用户最早那版输入（位置基准），`prompt` = 当前模型处理后的输出。方向以**当前版本**为准——正向 = `prompt`（复现会话里那张图），`originalPrompt` 的差异词（被替换掉的旧标签）进负向。

| 两版在同一位置 | 输出 |
| --- | --- |
| 相同 | 保留在正向 |
| 都非空且不同 | `prompt[i]` 留在**正向原位**，`originalPrompt[i]` 进**负向** |
| 只有 `originalPrompt` 有 | 进正向 |
| 只有 `prompt` 有 | 保留正向 |

`negativePrompt`（可选）追加到负向末尾；返回 `positivePrompt` / `negativePrompt` / `mask` 方便核对。**前提**：调用方同时传两版且顺序一一对应；只传 `prompt` 则插件自动从会话上下文提取最近一条用户消息原文兜底（`session.messages` 倒序找 `role === 'user'` → `session.header.originalInput`，提取不到才退化为全部保留正向）。A 档走生图工具自带的 `script`（提示词由插件从本次出图参数逐字带出），天然不受改写影响。

**蒙版重绘**：给 `mask`（白色/不透明 = 重绘区）或 `maskBox: "x,y,w,h"` + `initImage` 就是【蒙版重绘】，`maskBlur` / `inpaintingFill` / `maskInvert` / `inpaintFullRes` / `inpaintFullResPadding` 与 `sd_inpaint` 同一套（尺寸默认跟随底图）；`denoising` 默认仍 0.7，修瑕补全请显式传 0.40-0.55。

### 外部词表（-TermFile）

`sd_script_b` 生成的命令支持 `-TermFile <path>` 参数，指向一个 JSON 映射表。
脚本在执行前读取该文件，对 `-Prompt` 与 `-Negative` 做字符串替换。
映射表由用户在执行前提供，插件不读取、不写入、不生成任何映射内容。
格式：`{ "占位符": "替换值" }`。文件不存在时静默跳过。

## 配置

**推荐：设置 → 插件 → `sd-bridge`**（0.7.0 起注册了配置 schema，全部字段可视化编辑、带中文说明，改完下一个工具调用即生效）。也可在 `cordis.patch.yml` 中按 id `sd-bridge` 覆盖——**patch 层显式指定的键优先级最高，设置面板不会覆盖它们**。

优先级：默认值 < 设置面板 < `cordis.patch.yml`。

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `sdDir` | `''`（自动探测） | SD WebUI 安装目录；探测顺序：此配置 > `DSH_SD_DIR` > `~/.dsh-sd-bridge.json` > 扫盘候选 |
| `port` | `7860` | API 端口 |
| `autoStart` | `true` | 探测不到 API 时自动启动 |
| `startupTimeoutMs` | `420000` | 等待 SD 就绪的上限（含模型加载） |
| `requestTimeoutMs` | `600000` | 单次生图上限 |
| `idleStopMinutes` | `0` | 空闲 N 分钟后自动关闭插件拉起的 SD（0 = 不关） |
| `extraArgs` | `[]` | 追加给 `launch.py` 的参数（如 `["--medvram"]`） |
| `outputDir` | `'SD-Picture'` | 产物目录；相对路径解析到会话工作区 |
| `refDir` | `'ref'` | 参考图固化目录；相对路径解析到会话工作区 |
| `defaultSampler` | `'DPM++ 2M'` | 未指定采样器时的默认（同步数下比 A1111 默认的 Euler a 更干净）；留空 = 用 SD 默认 |
| `defaultNegative` | 质量底线负面词 | 未传 `negativePrompt` 时自动补上（肢体/水印/低画质）；留空 = 不补 |
| `img2imgDenoising` | `0.55` | 图生图默认重绘幅度，越小越贴参考图（保画风建议显式传 0.30-0.50） |
| `inpaintDenoising` | `0.6` | 蒙版重绘默认重绘幅度（修瑕补全 0.40-0.55、换内容 0.65-0.80） |
| `enabled` | `true` | 关掉即不注册工具 |

## 测试

```powershell
npm test                      # = 下面四条不出图的检查（CI 可跑，不需要本机 SD）
node smoke-skill.mjs          # 注册冒烟 + 双分支协议要点 + C 档选项表 + 用户自调画风 + 可移植性断言（不出图）
node test-install-record.mjs  # 安装记录专项：BOM 读取 + 就地自愈（不出图、毫秒级）
node test-settings.mjs        # 设置面板专项：schema 注册字段 + 面板实时生效 + patch 优先（不出图）
node test-install-catalog.mjs # 安装清单专项：模型/LoRA 清单 sha/源 + 环境预检 + 干跑 + 非法键（不出图）
npm run acceptance            # 真实出图验收：命名、序号、脚本字段、ref 固化（需本机 SD 在跑）
```

环境变量：`DSH_SD_DIR` 指定 SD 目录；`ACCEPTANCE_WS` 指定验收工作区（默认临时目录）。

**验收方法（重要）**：改完插件后**新开一个会话**再画一张图复验——旧会话带着旧工具描述/旧上下文，跑通了也不代表新会话没问题，建议自己多试试。

### 本次「整理打包」随机测试记录（2026-10-15）

| # | 出图 | 模型 / LoRA | seed | 自检结论 |
| --- | --- | --- | --- | --- |
| 1 | 银发少女樱花 | AWPainting v1.2 | 386163131 | 无手部入镜、面部干净、构图完整 ✅ |
| 2 | 写实二次元·东亚脸 | AWPainting + semirealisticanime 0.6 | 4060256059 | 半写实东亚脸到位、无多指、光影通透 ✅ |
| 3 | 国风山水 | AWPainting + 国风山水_v1.0 0.8 | 797728627 | 水墨风达标、手部无畸形 ✅ |
| 4 | 赛博朋克场景 | AWPainting + 赛博朋克场景_v1.0 0.8 | 2316348413 | 霓虹雨夜层次正常、无水印 ✅ |
| 5 | 釉彩调色盘 | AWPainting + 釉彩·麻袋调色盘_v1.0 0.8 | 3531660722 → 588228372 | 第 1 轮手部偏糊 → 第 2 轮加重手部负向（(bad hands:1.5) 等）+ 手不入镜，通过 ✅ |
| 6 | 写实人像 | majicMIX realistic v7 | 2161574874 | 皮肤质感真实、五官自然、无 AI 水印 ✅ |

对照图见上方「效果图」。复跑任意一张：把出图时返回的脚本整行贴进 PowerShell 即可（改 `-Seed -1` 可换一张）。

## 踩坑排查表

| # | 现象 | 根因 | 解法（现状） |
| --- | --- | --- | --- |
| 1 | 写工作区被拒 `grantWrite` | Windows 对工作区目录缺当前用户完全控制权 | 宿主侧 ACL 问题，用 `diagnose-windows-sandbox-acl` 技能一条命令诊断并修复（非插件 bug） |
| 2 | GUI 装插件失败 | 本机无 `git`，`install-sd.ps1` 与部分包管理都要 git | `install-sd.ps1` 自动下 **MinGit 便携版**：GitHub 资源带 `digest` 就先校验 sha256、再 `git --version` 实测，装完写入用户 PATH |
| 3 | `run_in_background` / `timeoutMs` 报错 | **宿主 bug**：数字与布尔被强制转成字符串 | 这两个参数干脆不传，靠 120 秒超时自动转后台 |
| 4 | 无独立 Python | 只有 WindowsApps 商店占位符（本机另有 3.13，而 A1111 在 Windows 只认 3.10） | `install-sd.ps1` 静默装官方 **Python 3.10.6**（用户级 `PrependPath`，sha256 记录），并把 `pythonDir` 写进安装记录，插件 `resolvePython` 兜底用它 |
| 5 | 大文件下载反复停滞/断流 | 网络对单连接限速掐断（单流 ~300KB/s） | `Get-SegmentedFile`：**8 段并行 Range 下载** + 断点续传 + 长度/可选 sha256 校验（实测 4 段下载与单流逐字节一致） |
| 6 | RTX 5060 跑不起来 | Blackwell（sm_120）不支持 A1111 默认 `torch==2.1.2+cu121` | 插件全新安装时探测 `compute_cap ≥ 12` → 自动设 `TORCH_COMMAND`（torch 2.7.0 + torchvision 0.22.0，cu128，本机实测 CUDA 可用） |
| 7 | CLIP 源码构建失败 | 新版 setuptools 移除了 `pkg_resources` | `PIP_CONSTRAINT` 钉 `setuptools==69.5.1`——约束作用到**每一次** pip（含 PEP 517 构建隔离里那次），等于预装 + 免隔离双保险 |
| 8 | pip 在 opencv 上卡死 | 解析器版本回溯（4.14→4.13.0.92→…）反复重下 | `PIP_CONSTRAINT` 钉 `numpy==1.26.2` + `opencv-python==4.11.0.86` 断开回溯，另设 `PIP_RETRIES=10` / `PIP_TIMEOUT=60`；`DSH_SD_PIP_CONSTRAINT=0` 可关 |
| 9 | 环境准备克隆停滞 | `Stability-AI/stablediffusion` **仓库已删除**（GitHub 对已删仓库要求认证） | 本地还没克隆该仓库时自动设 `STABLE_DIFFUSION_REPO` → **camenduru fork**（保留同一 commit `cf1d67a6…`，签名 verified） |
| 10 | 插件读不到 SD 目录、HTTP 500、反复指引重复安装 | 安装记录带 **UTF-8 BOM 头**，裸 `JSON.parse` 遇 BOM 抛错被静默吞掉 → `sdDir` 为空 | 读侧剥 BOM + 字段兜底提取 + **大声记日志** + 读到 BOM 就**就地重写自愈**；写侧用无 BOM UTF-8 并回读校验 `BOM=False`；`test-install-record.mjs` 专项覆盖。**这是唯一影响所有会话的根因** |
| 11 | 离线模式 tokenizer 加载失败 | 插件指向空的 `<SD>\.cache\huggingface` 还强开离线开关；transformers 4.30 与新版 hub 离线查找不兼容 | 只有该缓存**真有 `models--*` 模型**才接管 `HF_HOME` 并离线；缓存为空则不接管、保持联网（`DSH_SD_HF_ONLINE=1` 强制联网） |
| 12 | （测试方法） | 只查文件内容没查字节编码 = 漏判 | 三层测试：`smoke-skill`（不出图）→ `test-install-record`（BOM 专项）→ `acceptance`（真实出图），且**必须新开会话复验** |
| 13 | `.ps1` 一跑就语法错 | `.ps1` 存成 **UTF-8 无 BOM**，Windows PowerShell 5.1 按 GBK 读 → 中文多字节把后面的 `)` `"` 吞掉 | `sd-direct.ps1` / `sd-inject.ps1` / `install-sd.ps1` 固定存 **UTF-8 with BOM**（PS7 也认 BOM）；注意 JSON 记录恰好相反——**JSON 必须无 BOM** |
| 14 | 脚本报 `Cannot convert value "3845143617" to type System.Int32` | SD 的 seed 是 **uint32**（可到 4294967295），脚本参数写成 `[int]$Seed`，超过 2147483647 就参数转换失败 | `sd-direct.ps1` 的 `-Seed` 改为 `[long]`；`acceptance.mjs` 新增第 8 步：**真跑一遍脚本**（PS5.1 执行 + uint32 seed），BOM/类型问题都会被它拦下 |
| 15 | 别人电脑上跑脚本：`Invoke-RestMethod 无法连接到远程服务器` 之后**连炸 4 条** | ① 对方机器 SD API 没在跑，而脚本只会连、不会拉起；② 连接失败后没有短路，`$result.images[0]` 空数组 → `WriteAllBytes` 空值 → `ConvertFrom-Json` 空值逐级炸 | `sd-direct.ps1` 先探测 API：**没开就自己把它拉起**（目录按 `-SdDir` > `DSH_SD_DIR` > `~/.dsh-sd-bridge.json` > 各盘常见安装名扫描查找，轮询到就绪，`-NoStart` 关闭、`-StartTimeout` 调超时、日志在 `%TEMP%\dsh-sd-direct-launch.log*`）；端口被别的服务占用、目录/解释器找不到、调用失败、结果没图——**统一走 `Fail` 只报一条错误 + 一行提示就 `exit 1`** |
| 16 | **新拉取 SD 出图质量非常差** | ① 新装默认模型是 2022 年的 **SD1.5 base**（`v1-5-pruned-emaonly`）+ 默认 VAE + CLIP skip 1，而这台画质好的机器是 **AWPainting v1.2 + `vae-ft-mse-840000` + CLIP skip 2**；② 没有专用 VAE 时画面发灰 | `install-sd.ps1` 默认模型换成 **AWPainting v1.2**（远端 sha256 `3d1b3c42ec…` 与本机出图正常文件**逐字节一致**），补下 mse VAE（`735e4c3a…`），并合并写入 `config.json` 的 `sd_model_checkpoint` / `sd_vae` / `CLIP_stop_at_last_layers=2`（只改点名键、保留其他键、去 BOM、非 UTF-8 老文件按原编码读写、`-NoConfig` 可关）；`sd_models` 检测到只有 base 模型时返回 `qualityHint` 提示升级 |
| 17 | 脚本拉起的 SD 启动卡几分钟 | 脚本没带 `HF_HOME`，transformers 去 `%USERPROFILE%\.cache\huggingface` 找 clip tokenizer，而 SD 缓存在 `<SD>\.cache\huggingface` → 找不到就连 huggingface.co **重试 5 次 × 10s × 多个文件** | `sd-direct.ps1` 启动前按插件同一套规则设 HF 环境：**缓存命中 → `HF_HOME` + 离线加载；未命中 → 保持联网并走 `hf-mirror` 镜像**（`DSH_SD_HF_ONLINE=1` 可强制联网）。实测修复后 **HF 重试 0 次、冷启动到出图 28 秒** |
| 18 | stderr 刷 `Join-Path 找不到驱动器 E:` | 扫盘时对不存在的盘符也去拼路径 | 先 `Test-Path "E:\"` 跳过不存在的盘；候选路径再包一层 `try/catch`（非法路径跳过不报错） |
| 19 | 改完 `.ps1` 突然全文件语法错 | **编辑工具写回时丢掉 UTF-8 BOM**（PS5.1 无 BOM 按 GBK 读，中文多字节吞掉 `)` `"`） | 改完 `.ps1` 立刻补回 BOM（读首三字节 `EF BB BF`，不是就前插 3 字节），再用 `[Parser]::ParseFile` 解析一遍确认 `SYNTAX OK`（本次 v0.9.7 又踩中一次，已按此流程修回） |
| 20 | 设置面板没有 sd-bridge 分组（注册代码看着没问题） | 插件以**符号链接**装进 profile node_modules 时，Node 按 realpath 解析依赖 → 裸 `import('@deepseek-ai/schemastery')` 落空，注册被静默跳过 | `tryLoadConfigSchema` 两条途径：裸 import 失败后扫 `~/.dsh/profiles/*/node_modules/.../schemastery/lib/index.mjs` 按绝对路径导入；`test-settings.mjs` 覆盖 |
| 21 | `install-sd.ps1` 明明装完了，`test-install-catalog` 却报 `dry run must exit 0, got null` | 安装记录**写失败被当成安装失败**：`[System.IO.File]::WriteAllText(...)` 是**裸调用、无 try/catch**，而 `$ErrorActionPreference = 'Stop'` 让一次 `UnauthorizedAccessException`（只读 HOME / 沙箱拦 / 企业策略）直接把整次安装打成非 0 退出 | 记录写入包 `try/catch`：失败只报一条错 + 一行提示（`DSH_SD_DIR` / `cordis.patch.yml` 两条兜底路径），**不再 exit 1**；记录路径可用 `-StateFile` 或 `DSH_SD_STATE_FILE` 覆盖；测试改为 `-StateFile` 改道到临时目录 |
| 22 | `sd-inject.ps1` 一输入中文就 `Qwen 调用失败：无法连接到远程服务器` | 默认模型名 `qwen2.5:14b` 是**写死的猜测值**：本机 Ollama 只有别的模型，且 `ollama serve` 本来就没在跑 | ① **冷启动** `ollama serve` + 轮询就绪；② **模型自动挑**（`-QwenModel` 留空 = 选本机第一个 qwen 系模型）；③ 一个模型都枚举不到时直接点出 `OLLAMA_MODELS` 这个最常见根因 |
| 23 | 中文 Windows 首次依赖准备 `RuntimeError: Couldn't install torch`（pip 退出码 2） | 约束文件含**中文注释**，pip 的 `auto_decode()` 只在文件带 UTF-8 BOM 时才按 utf-8 读，否则回退 locale 编码（中文 Windows 是 gbk）→ 第一个中文字节即 `UnicodeDecodeError` | `writePipConstraints()` 的注释一律**纯 ASCII**；另补钉 `pandas==2.1.4` 断开 pandas 病态回溯 |
| 24 | pip ≥ 24 上 `Installing clip` 报 `No module named 'pkg_resources'` | `PIP_CONSTRAINT` 在 pip 26 上进不了 **PEP 517 构建隔离**那一次，隔离环境照样拉最新 setuptools | 全新安装时设 `PIP_NO_BUILD_ISOLATION=1`：CLIP 这类源码包直接用 venv 里已钉死的 `setuptools==69.5.1` 构建 |
| 25 | A 档出图后用户不知道还能改什么参数（本次新增） | 出图工具只回图片与脚本，参数可选项要用户自己猜（或去翻本文档） | 三个出图工具新增 `quickOptions` 字段，技能要求**出图后原样贴到图片下方**——用户回一句编号就能改参数重出图 |

## 常见问题

- **新装的 SD 出图很差 / 发灰 / 不像样？** 是模型与 VAE，不是提示词：跑一遍 `install-sd.ps1`（会补装 **AWPainting v1.2** + `vae-ft-mse-840000` 并写质量默认配置，已装过 SD 也只会补缺的那部分），或先调 `sd_models`——它检测到只有新装默认的 SD1.5 base 会返回 `qualityHint`；动漫模型记得 CLIP skip = 2。
- **设置里找不到插件配置？** 0.7.0 起在 **设置 → 插件 → `sd-bridge`** 注册了配置面板（字段全可视化、带中文说明）；旧版只能改 `cordis.patch.yml`。若面板没有该项，说明还在跑旧版插件，重装最新版后新开会话。
- **想多装几个模型 / 常见 LoRA？** `install-sd.ps1 -Models "awpainting,majicmix" -Loras "add_detail,semireal,easynegative,badhandv4"`，键见上文参数表与 [docs/models-loras.md](docs/models-loras.md)；已有文件会跳过，`-Upgrade` 做 sha 复验并补拉新版。
- **安装时报缺 git / Python / VC++？** 不用手动补——0.7.0 起脚本先跑环境预检，缺啥自举啥（MinGit 便携版、官方 Python 3.10.6、vc_redist），每项失败只报一条错；也可 `-NoPrereq` 跳过整个预检。
- **首次启动很慢？** 加载 checkpoint 约 1-3 分钟（可调大 `startupTimeoutMs`）；全新安装还要先在线装依赖。脚本自己拉起 SD 时会带 HF 缓存/镜像环境，tokenizer 不会去连 huggingface.co 反复重试。
- **模型放哪？** `<SD 目录>\models\Stable-diffusion\`；LoRA 放 `models\Lora\`。名字用 `sd_models` 查。
- **换机器/换盘符？** 不用改任何配置——重新装插件即可，探测与工作区逻辑自动适配。

---

# English

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) plugin that drives your local **Stable Diffusion WebUI** (AUTOMATIC1111 API) with eight tools — txt2img, img2img, inpaint (mask redraw), script-only (no image), dual-version script, C-tier local-inject command builder (no image), model listing, server management — plus a built-in **two-tier content-routing protocol**:

- **Tier A (fully compliant requests only)** → generate normally, show the image, the reproducible PowerShell script, and a **「C 档选项表」 quick-pick table** (styles — including the user's own tuned ones — models, LoRAs, ratios, quality, steps, denoising) right below the picture, so a single reply like "style #4 + majicMIX + 3:4" re-generates with the new parameters.
- **Tier C (any non-compliant content, even a single word)** → no image, no content related to the request; the plugin only emits the local-inject command for `sd-inject.ps1`, which pops the **C-tier parameter form** on your machine (style dropdown includes the ★ user-tuned styles). The user appends their own text there.

**Tip for best results**: start a new conversation with `打开SD插件` and prefix your request with `用SD插件绘制` (e.g. `用SD插件绘制：a silver-haired girl under cherry blossoms`).

**Zero local setup**: the SD install directory is auto-detected (`sdDir` config > `DSH_SD_DIR` env > `~/.dsh-sd-bridge.json` install record > drive scan); outputs, reference images and the reproducible script always land in your **session workspace**. No SD installed? The plugin returns a one-line command that runs the bundled `install-sd.ps1` bootstrap — it runs an **environment preflight first** (disk, mirror reachability, git, Python 3.10, VC++ runtime; each missing piece is bootstrapped automatically), then clones WebUI and pulls the selected **model/VAE/LoRA catalog** (`-Models`, `-Vaes`, `-Loras`, `-Upgrade`), every file verified by sha256. Full weight catalog with **hf-mirror.com** links and checksums: [docs/models-loras.md](docs/models-loras.md).

**Install**: paste `github:savinglighting/dsh-sd-bridge-guard` (or the npm name `dsh-sd-bridge-guard`) into DSH *Settings → Plugins*, then restart.

Configuration lives in **Settings → Plugins → `sd-bridge`** (editable live, applied on the next tool call); `cordis.patch.yml` overrides under id `sd-bridge` keep the highest priority — see the table above.

## License

MIT
