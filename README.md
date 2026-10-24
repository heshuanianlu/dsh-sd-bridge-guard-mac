# dsh-sd-bridge-guard

[![npm](https://img.shields.io/npm/v/dsh-sd-bridge-guard.svg)](https://www.npmjs.com/package/dsh-sd-bridge-guard)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/savinglighting/dsh-sd-bridge-guard/blob/main/LICENSE)

**DeepSeek Harness 插件 · 本机 Stable Diffusion 生图六件套 · macOS 移植版（0.7.0 → 0.7.0-mac.1）**

> 本目录是 npm 包 `dsh-sd-bridge-guard@0.7.0`（Windows 向）的 **macOS 移植 fork**：六个工具的参数、返回结构、贴图与附件链路完全不变，只重做平台层（目录探测、venv 解释器、Apple Silicon 启动参数、可复现脚本改成 `sd-direct.sh` + bash）。Windows 分支代码保留在同一个文件里，用 `IS_POSIX` / `IS_MAC` 判据分叉。
> 下面标 🍎 的段落是本 fork 相对上游的差异；其余文档与上游一致（个别路径已改成 POSIX 写法）。

让 DeepSeek Harness 直接调用你电脑里的 Stable Diffusion WebUI 生图：不用提前打开 SD（首次调用自动以纯 API 模式拉起）、不用改任何路径——装上插件就能用。

| 文生图 | 图生图 |
| --- | --- |
| ![txt2img demo](https://raw.githubusercontent.com/savinglighting/dsh-sd-bridge-guard/main/docs/assets/demo-txt2img.jpg) | ![img2img demo](https://raw.githubusercontent.com/savinglighting/dsh-sd-bridge-guard/main/docs/assets/demo-img2img.jpg) |

## 特性

- **零本地适配**：SD 安装目录自动探测（配置 > 环境变量 `DSH_SD_DIR` > 自举安装记录 > 扫盘候选）；产物、参考图、可复现脚本全部自动落在**当前会话工作区**（`SD-Picture/`、`ref/`、`sd-direct.ps1`）。
- **没装 SD 也能用**：插件找不到 SD 时返回一条可直接运行的安装命令（Windows 用包内 `install-sd.ps1`，macOS 用 `install-sd-macos.sh`），一键装好 WebUI + **AWPainting v1.2 模型 + `vae-ft-mse-840000` VAE + 质量默认配置**并把路径记进 `~/.dsh-sd-bridge.json`，重启即用（模型/VAE 都带 sha256 校验，哈希与画质已验证的本机文件一致）。
- **六个工具**：`sd_txt2img` 文生图、`sd_img2img` 图生图、`sd_inpaint` 蒙版重绘、`sd_script` 只生成可复现脚本不出图、`sd_models` 模型清单、`sd_server` 服务管理。
- **违规分流协议**（`sd-paint` 技能内置）：轻微违规删词后照常出图并附可复现脚本；明显违规不出图、只给合规素体的可复现脚本；回复最末尾列出被剔除的违规提示词英文。
- **可复现**：每次出图返回单行 powershell 脚本（提示词高亮），用户复制整行即可在 PowerShell/cmd 复跑同一张图；脚本**自带服务托管**——SD 没开它自己拉起（首次含模型加载 1-3 分钟）、**跑完自动打开这张图**（`-NoOpen` 关闭）、**任何失败只报一条错误就退出**。
- **服务托管**：SD 没开也能生图——插件自动以 `--api --nowebui` 拉起、复用、可选空闲自动关闭。

## 安装

三种方式任选其一（装完重启 DeepSeek Harness）：

```text
# 1) 在 DSH「设置 → 插件」里粘贴 Git 安装源
github:savinglighting/dsh-sd-bridge-guard

# 2) 或粘贴 npm 包名
dsh-sd-bridge-guard

# 3) 或本地目录（开发者 / 🍎 本 fork 的装法）
dsh plugin add link:/Volumes/大神的拓展/AIcoding/dpsk-hans/dsh-sd-bridge-guard-mac
```

> DSH 插件暂不支持自动更新：升级需先卸载再安装新版。

## 首次使用

- **已装 SD WebUI**：什么都不用做。插件启动时自动探测（也认 `DSH_SD_DIR` 环境变量与 `cordis.patch.yml` 的 `sdDir` 覆盖）。
- **没装 SD**：让 Harness 帮你画张图，它会返回安装指引；或自己跑一条命令。

🍎 **macOS**（本 fork）——建议把 WebUI 装到外置盘（系统盘吃紧），一条命令跑完「预检 → 克隆 → Python 3.10 venv → MPS 版 torch → Mach-O 零填充段修复 → 模型/VAE/LoRA（sha256 校验）→ config 质量默认值 → 写安装记录 → 拉起 API 并等就绪」：

> GitHub 直连不通时脚本会自动换 gh 代理前缀（见 M12）；本机有科学上网就先 `export HTTPS_PROXY=http://127.0.0.1:7890` 再跑。
> ⚠️ 别把说明写进代码块里 —— `\` 续行会让后面整段变成注释，这条命令就是抄给别人用的。

```bash
bash "/Volumes/大神的拓展/AIcoding/dpsk-hans/dsh-sd-bridge-guard-mac/install-sd-macos.sh" \
  -Target "/Volumes/大神的拓展/stable-diffusion-webui" \
  -Mirror "https://hf-mirror.com" \
  -PypiIndex "https://mirrors.aliyun.com/pypi/simple/" \
  -Models awpainting -Vaes mse,animevae -Loras add_detail,easynegative,badhandv4
```

Windows 用户请用 registry 版 `dsh-sd-bridge-guard`（0.7.0，包内带 `install-sd.ps1`）——**本 fork 是 macOS 专用移植，没有打包 `.ps1`**：

```powershell
powershell -ExecutionPolicy Bypass -File "插件目录\install-sd.ps1"
```

装完重启 DSH。Apple Silicon 出图走 MPS，512×768 · 22 步实测约 20-60 秒/张（首次含模型加载 1-3 分钟）。

### 🍎 macOS 上的分工（谁负责哪一段）

| 谁负责 | 做什么 |
| --- | --- |
| `install-sd-macos.sh` | **首次安装**：克隆、conda 建 python3.10、venv 与依赖（含「装 → 修 Mach-O → 自检」收敛循环）、按 commit 预克隆子仓库、模型/VAE/LoRA 校验下载、config.json、安装记录、⑦ 自检启动 |
| `sd-bridge.js`（插件本体） | **日常使用**：目录/venv 探测、带 mac 参数与 git 兜底拉起 API、启动前补扫 Mach-O（只在 `site-packages` 比 `<SD>/.dsh-macho-zerofill.ok` 新时才扫）、六个 `sd_*` 工具、可复现命令 |
| `sd-direct.sh` | 用户**手跑**同一条命令（不经过 Harness）；启动失败且日志里有 dyld 报错时，直接打印可执行的修复命令 |

插件在 macOS 上**不会**替用户从零装依赖（没有 venv 就抛安装指引，见 M16）：那条路既会把包pip 进系统/conda 环境，又必然在半路撞上 dyld 的零填充校验 —— 依赖装完才第一次 import，插件插不进修复循环，而安装脚本插得进。

### 🍎 install-sd-macos.sh 参数（本 fork）

与 ps1 版同一套资源清单（同样的键名、同样的 sha256），但按 macOS 的现实重写了前置步骤：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Target` | `$HOME/stable-diffusion-webui`（或 `DSH_SD_INSTALL_DIR`） | 安装目录；**外置盘请传绝对路径**，需 ≥15GB |
| `-Python` | 自动 | 指定 Python 3.10 解释器；找不到就 `conda create -p <Target>/.py310 python=3.10`，再退到 brew |
| `-Mirror` | `https://hf-mirror.com` | HuggingFace 源，传 `""` 用官方 |
| `-PypiIndex` | `https://mirrors.aliyun.com/pypi/simple/` | pip 源，传 `""` 用官方 PyPI |
| `-Models` / `-Vaes` / `-Loras` | `awpainting` / `mse,animevae` / `add_detail,easynegative,badhandv4` | 与 ps1 版同一张清单；`none` 清空，键错会列出可用键 |
| `-Port` | `7860` | API 端口（写进安装记录，插件与脚本都读） |
| `-Git` | 自动探测 | 手动指定可用的 git 绝对路径（Xcode 许可未同意时 `/usr/bin/git` 全命令 rc=69，脚本会自动绕到 CLT 那份） |
| `-SkipClone` / `-SkipDeps` / `-SkipModel` / `-SkipVae` / `-SkipLora` / `-NoPrereq` | 关 | 分段跳过（重跑天然续传：已存在文件只做 sha 复验；`-SkipDeps` 也会跑一遍 Mach-O 自检） |
| `-NoConfig` | 关 | 不写 `config.json` 质量默认值（checkpoint / VAE / CLIP skip 2） |
| `-NoServe` | 关 | 装完不自动拉起 API（默认会拉起并轮询就绪，日志 `<Target>/.dsh-run/api.log`） |
| `-Log` | `<Target>/install-sd-macos.log` | 汇总日志 |

> 网络前提：**huggingface 走 `hf-mirror.com`、PyPI 走阿里云镜像**（脚本默认已带上），GitHub 部分机器直连不通——脚本会自动改用 `ghfast.top` 等 gh 代理前缀；如果你本机有代理，先 `export HTTPS_PROXY=http://127.0.0.1:7890` 再跑最省事。
>
> 装之前先扫一眼 git：`xcode-select -p` 指向 Xcode 而没同意过许可时，`/usr/bin/git` 会**任何命令都 rc=69**（连 `git init` 都不行）。脚本会自动绕到 Command Line Tools 那份并 `export GIT=…`；你也可以 `-Git /path/to/git` 手动指定。详见下面「macOS 移植新增踩坑」M9。

另外会在 `<SD>/.dsh-bin/git` 留一个软链接（指向探测到的可用 git）并前置到 PATH —— GitPython 只认 PATH，不认 `GIT` 变量（见 M9b）。

装完写 `~/.dsh-sd-bridge.json`（**无 BOM**）：`{sdDir, pythonDir, pythonBin, port, platform:"darwin", installer, installedAt}`，插件与 `sd-direct.sh` 都按它定位。

### install-sd.ps1 参数（registry 版对照用，本 fork 未打包该脚本）

脚本先跑**环境预检**（磁盘 ≥15GB → 镜像探活 → git → Python 3.10 → VC++ 运行库，缺啥补啥、每项失败只报一条错即退出，最后打一张就绪清单），再克隆 WebUI、按清单拉资源：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Models` | `awpainting` | 模型清单，逗号多选：`awpainting` / `revanimated` / `anythingv5` / `majicmix` / `darksushi`（`none` = 不拉） |
| `-Vaes` | `mse,animevae` | VAE 清单：`mse`（写进 config 默认）/ `animevae` |
| `-Loras` | `add_detail,easynegative,badhandv4` | 常见资源：细节增强 LoRA + 负面嵌入 + 手部修复嵌入（`none` = 不拉） |
| `-Upgrade` | 关 | 已存在文件做 sha 复验、不符重拉；旧版本命中 `Supersedes` 时补拉新版（旧版保留） |
| `-Mirror` | `https://hf-mirror.com` | 填 `""` 用官方源 |
| `-SkipModel` / `-SkipVae` / `-SkipLora` | 关 | 跳过对应类别的下载 |
| `-NoPrereq` / `-SkipVC` / `-SkipDiskCheck` / `-SkipGit` / `-SkipPython` | 关 | 跳过环境预检的全部或某一项 |
| `-NoConfig` | 关 | 不写 `config.json` 质量默认值 |

清单里**每个条目的 sha256 都与本机出图正常的文件逐字节比对过**（HF lfs oid = sha256）；键写错会打印全部可用键。跑完会输出一张「资源清单汇总」表（已下载 / 已存在 / 失败原因）。

> **自己的 LoRA 怎么装**：国内站资源（国风山水、赛博朋克、电商摄影这类）直链不稳，不进默认清单——手动把 `.safetensors` 放进 `<SD目录>\models\Lora\`（Embedding 放 `models\embeddings\`）即可，`sd_models` 能列出来。

## 提供的工具

| 工具 | 作用 |
| --- | --- |
| `sd_txt2img` | 文生图：提示词、负面词、尺寸/步数/CFG/采样器/seed、批次 1-4、临时换 checkpoint、LoRA、hires fix、styles、summary；返回 `script`（【文生图】脚本） |
| `sd_img2img` | 图生图：本地图片路径 + `denoisingStrength` 重绘；工作区外的参考图自动固化到 `ref/`；返回 `script`（【图生图】脚本） |
| `sd_inpaint` | **蒙版重绘（inpaint）**：只改画面里一块（补手/去杂物/局部改色/换背景）。蒙版给 `mask`（白/不透明 = 重绘区）或 `maskBox: "x,y,w,h"`（插件手写 PNG 现场造蒙版存进 `ref/`）；`maskBlur`/`inpaintingFill`/`maskInvert`/`inpaintFullRes+padding` 全可调；返回 `script`（【蒙版重绘】脚本，带 `-Mask`）与接缝自检 `selfCheck` |
| `sd_script` | **只生成可复现脚本，不调 SD、不出图**（`generatesImage` 恒为 false）——明显违规分流专用 |
| `sd_models` | 列出 checkpoints / LoRA / 采样器 / VAE / 当前选项 |
| `sd_server` | `status` / `start` / `stop`；找不到 SD 时 `status` 返回安装指引 |

### 保存与命名

- 产物目录：**会话工作区下的 `SD-Picture/`**（可用 `outputDir` 改成绝对路径）
- 文件名 = **提示词总结_三位序号.png**；`summary` 参数决定文件名，序号自动递增永不覆盖
- 返回 `paths`（绝对路径）、`fileNames`、`savedDir`、`replyImages`（Markdown，贴进回复即全尺寸展示）、`script`（可复现脚本）
- 用户手跑 `sd-direct.ps1` 时，图保存成功后脚本会**自动打开它**；批量跑加 `-NoOpen`

## 违规分流协议（`sd-paint` 技能全文内置）

判定标准 = 模型自己会拒绝执行的尺度，不依赖固定词表。需求里只要有一部分违规就触发分流，不整单拒绝：

- **A 档 · 轻微违规**（删几个词后完全正常）→ 剔除违规片段、照常出图存盘、说明剔除、附脚本、回复最末尾英文违规词清单。
- **B 档 · 明显违规**（露骨/整体性质）→ **一张图都不生成**，只给合规素体的可复现脚本（`sd_script`），末尾同样列英文违规词。

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
| `enabled` | `true` | 关掉即不注册工具 |

## 测试

🍎 本 fork 自带的两条不出图检查（CI/本地都能跑，不需要 SD 在跑）：

```bash
node test-mac.mjs        # 平台层：目录探测 / 6 工具注册 / sd-direct.sh 同步（无 BOM + 755）/ bash 转义真跑一遍
node test-mac-smoke.mjs  # 冒烟：假 ctx 加载插件 → 生成【文生图】【图生图】命令 → 参数交给假脚本回读
node test-mac-e2e.mjs    # 🍎 端到端（**真的出图**，2-4 分钟）：拉起 SD → sd_models → txt2img → img2img → inpaint → 再把 asMarkdown 里的命令交给 /bin/bash 真跑一遍
                         #    覆盖 macLaunchArgs / gitShimEnv / Mach-O 自检 / HF 缓存离线 / 落盘与 replyImages
node check-sh-varquote.mjs    # 静态扫两份 sh：$VAR 紧跟非 ASCII（bash 3.2 会当成变量名的一部分）
python3 fix-macho-zerofill.py <SD>/venv/lib/python3.10/site-packages          # 只报告有多少零填充段 offset 非零
python3 fix-macho-zerofill.py <SD>/venv/lib/python3.10/site-packages --apply  # 真修 + 重签名
npm run check                 # = check-sh-varquote.mjs（bash 3.2 变量紧贴中文回归检查）+ 两份 sh 的 bash -n + sd-bridge.js 语法
```

`test-mac.mjs` 里的转义检查不是正则比对：它把命令开头的脚本路径换成一个「按 `\0` 打印全部参数」的假脚本，整条命令交给 `/bin/bash -c` 跑，再从 argv 里取回 `-Prompt` 的值逐字节比对——`$` / 反引号 / 单引号 / 反斜杠 / `(x:y)` / 中文 / 换行都能还原，才算过。

上游的 Windows 检查：

```powershell
npm test                      # = 下面四条不出图的检查（CI 可跑，不需要本机 SD）
node smoke-skill.mjs          # 注册冒烟 + 双分支协议要点 + 可移植性断言（不出图）
node test-install-record.mjs  # 安装记录专项：BOM 读取 + 就地自愈（不出图、毫秒级）
node test-settings.mjs        # 设置面板专项：schema 注册 13 字段 + 面板实时生效 + patch 优先（不出图）
node test-install-catalog.mjs # 安装清单专项：三张清单 sha/源 + 环境预检 + 干跑 + 非法键（不出图）
npm run acceptance            # 真实出图验收：命名、序号、脚本字段、ref 固化（需本机 SD 在跑）
```

环境变量：`DSH_SD_DIR` 指定 SD 目录；`ACCEPTANCE_WS` 指定验收工作区（默认临时目录）。

**验收方法（重要）**：改完插件后**新开一个会话**再画一张图复验——旧会话带着旧工具描述/旧上下文，跑通了也不代表新会话没问题，建议自己多试试。

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
| 13 | `.ps1` 一跑就语法错（本次新发现） | `.ps1` 存成 **UTF-8 无 BOM**，Windows PowerShell 5.1 按 GBK 读 → 中文多字节把后面的 `)` `"` 吞掉 | `sd-direct.ps1` / `install-sd.ps1` 固定存 **UTF-8 with BOM**（PS7 也认 BOM）；注意 JSON 记录恰好相反——**JSON 必须无 BOM** |
| 14 | 脚本报 `Cannot convert value "3845143617" to type System.Int32`（本次新发现） | SD 的 seed 是 **uint32**（可到 4294967295），脚本参数写成 `[int]$Seed`，超过 2147483647 就参数转换失败 | `sd-direct.ps1` 的 `-Seed` 改为 `[long]`；`acceptance.mjs` 新增第 8 步：**真跑一遍脚本**（PS5.1 执行 + uint32 seed），BOM/类型问题都会被它拦下 |
| 15 | 别人电脑上跑脚本：`Invoke-RestMethod 无法连接到远程服务器` 之后**连炸 4 条**（本次新发现） | ① 对方机器 SD API 没在跑，而脚本只会连、不会拉起；② 连接失败后没有短路，`$result.images[0]` 空数组 → `WriteAllBytes` 空值 → `ConvertFrom-Json` 空值逐级炸 | `sd-direct.ps1` 先探测 API：**没开就自己把它拉起**（目录按 `-SdDir` > `DSH_SD_DIR` > `~/.dsh-sd-bridge.json` > 各盘常见安装名扫描查找，轮询到就绪，`-NoStart` 关闭、`-StartTimeout` 调超时、日志在 `%TEMP%\dsh-sd-direct-launch.log*`）；端口被别的服务占用、目录/解释器找不到、调用失败、结果没图——**统一走 `Fail` 只报一条错误 + 一行提示就 `exit 1`** |
| 16 | **新拉取 SD 出图质量非常差**（本次新发现） | ① 新装默认模型是 2022 年的 **SD1.5 base**（`v1-5-pruned-emaonly`）+ 默认 VAE + CLIP skip 1，而这台画质好的机器是 **AWPainting v1.2 + `vae-ft-mse-840000` + CLIP skip 2**；② 没有专用 VAE 时画面发灰 | `install-sd.ps1` 默认模型换成 **AWPainting v1.2**（远端 sha256 `3d1b3c42ec…` 与本机出图正常文件**逐字节一致**），补下 mse VAE（`735e4c3a…`），并合并写入 `config.json` 的 `sd_model_checkpoint` / `sd_vae` / `CLIP_stop_at_last_layers=2`（只改点名键、保留其他键、去 BOM、非 UTF-8 老文件按原编码读写、`-NoConfig` 可关）；`sd_models` 检测到只有 base 模型时返回 `qualityHint` 提示升级 |
| 17 | 脚本拉起的 SD 启动卡几分钟（本次新发现） | 脚本没带 `HF_HOME`，transformers 去 `%USERPROFILE%\.cache\huggingface` 找 clip tokenizer，而 SD 缓存在 `<SD>\.cache\huggingface` → 找不到就连 huggingface.co **重试 5 次 × 10s × 多个文件** | `sd-direct.ps1` 启动前按插件同一套规则设 HF 环境：**缓存命中 → `HF_HOME` + 离线加载；未命中 → 保持联网并走 `hf-mirror` 镜像**（`DSH_SD_HF_ONLINE=1` 可强制联网）。实测修复后 **HF 重试 0 次、冷启动到出图 28 秒** |
| 18 | stderr 刷 `Join-Path 找不到驱动器 E:`（本次新发现） | 扫盘时对不存在的盘符也去拼路径 | 先 `Test-Path "E:\"` 跳过不存在的盘；候选路径再包一层 `try/catch`（非法路径跳过不报错） |
| 19 | 改完 `.ps1` 突然全文件语法错（本次新发现） | **编辑工具写回时丢掉 UTF-8 BOM**（PS5.1 无 BOM 按 GBK 读，中文多字节吞掉 `)` `"`） | 改完 `.ps1` 立刻补回 BOM（读首三字节 `EF BB BF`，不是就前插 3 字节），再用 `[Parser]::ParseFile` 解析一遍确认 `SYNTAX OK` |
| 20 | 设置面板没有 sd-bridge 分组（注册代码看着没问题） | 插件以**符号链接**装进 profile node_modules 时，Node 按 realpath 解析依赖 → 裸 `import('@deepseek-ai/schemastery')` 落空，注册被静默跳过 | `tryLoadConfigSchema` 两条途径：裸 import 失败后扫 `~/.dsh/profiles/*/node_modules/.../schemastery/lib/index.mjs` 按绝对路径导入；`test-settings.mjs` 覆盖 |


### 🍎 macOS 移植新增踩坑（本机 M4 / macOS 27 / 外置盘实测）

| # | 现象 | 根因 | 解法（现状） |
| --- | --- | --- | --- |
| M1 | 依赖永远装不完，日志末尾 `RuntimeError: Torch is not able to use GPU; add --skip-torch-cuda-test to COMMANDLINE_ARGS` | 插件/脚本是**直接 spawn `python launch.py`**，绕过了 `webui.sh`，也就拿不到 `webui-macos-env.sh` 里那组 mac 必需参数；`prepare_environment` 走到 `assert torch.cuda.is_available()` 必炸（Mac 没有 CUDA） | `spawnServer` 与 `install-sd-macos.sh` 都自动补齐 `--skip-torch-cuda-test --upcast-sampling --no-half-vae --use-cpu interrogate`（逐字对齐上游 `webui-macos-env.sh`），并注入 `PYTORCH_ENABLE_MPS_FALLBACK=1`；用户在 `extraArgs` 里写过的同名参数不重复注入 |
| M2 | `ERROR: Failed to build 'https://github.com/openai/CLIP/archive/….zip' … ModuleNotFoundError: No module named 'pkg_resources'` | CLIP 只有 zip、没有 wheel，必须现场构建；PEP 517 **隔离**构建环境会单独解析一份最新 setuptools（81+ 删了 `pkg_resources`）。上游 v0.6 注释里「`PIP_CONSTRAINT` 会作用到隔离构建那次」**在实测中不成立** | 安装脚本先用 **显式 `--no-build-isolation`** 预装 `clip` / `open_clip`（URL 与 `launch_utils.py` 默认值逐字一致），A1111 自带 `if not is_installed("clip")` 护栏 → 装过就跳过隔离构建；`PIP_NO_BUILD_ISOLATION` / `PIP_BUILD_ISOLATION` 两种写法仍一并注入，兜住别的源码构建 |
| M3 | 启动 SD 报 `spawnSync python ENOENT` | 现代 macOS 只有 `python3`，没有 `python` 这个命令 | `resolvePython` 顺序改为 `venv/bin/python` → `venv/bin/python3` → `.py310/bin/python` → 安装记录 `pythonBin`/`pythonDir`（POSIX 下试 `bin/python3`、`bin/python`）→ PATH 上的 `python3` |
| M4 | WebUI 装在外置盘，插件却说没找到 | Windows 版靠扫盘符 C:–Z:；macOS 没有盘符，外接卷在 `/Volumes/<卷名>/` | 新增 `platformRoots()`：POSIX 下枚举 `/Volumes/*`（上限 24 个根，只做 `statSync`，不拖慢启动），Linux 退化为 `/opt`、`/usr/local`、`/srv`、`/media/*`、`/mnt/*` |
| M5 | `sd-direct.sh: line 135: API_BASE�: unbound variable` | macOS 自带 **bash 3.2**，locale 非 UTF-8 时 `$VAR` 紧跟中文会把多字节首字节算进变量名，`set -u` 当场炸 | 所有紧邻中文的变量一律写 `${VAR}`（19 处）；`-h` 与失败路径都过 `bash -n` + 实跑复验 |
| M6 | 脚本一跑就 `bad interpreter` / `Permission denied` | `.sh` **绝不能带 BOM**（shebang 前有 BOM 就认不出解释器），且需要执行位；这与 `.ps1` 恰好相反（PS5.1 无 BOM 按 GBK 读会语法错） | `syncDirectScripts` 按平台分叉：POSIX 复制时剥 BOM + `chmod 755`，Windows 保持包内 BOM 原样；同步失败只记日志不影响工具 |
| M7 | 提示词里有换行 → 生成的「单行命令」变成多行，用户复制不全 | 单引号字符串里换行**没有字面量写法**，直接写进去就是真换行 | `shQuote` 把换行/回车/制表符写成 `'$'\n''` 这种「闭合→`$'…'`→重开」片段：命令本体保持一行，bash 解析后仍还原成真换行（`test-mac.mjs` 用假脚本按 `\0` 回读参数逐字节验证） |
| M8 | 设置 → 插件里没有 `sd-bridge` 分组（上游 0.7.0 才加的面板） | 插件以 **符号链接**（`link:` 安装）进 profile 时，Node 按 realpath 解析依赖，裸 `import('@deepseek-ai/schemastery')` 落空；本机 schemastery 只在 app.asar 里，`~/.dsh/profiles/*` 下没有 | 上游已有途径②（扫 profile 绝对路径）；确实拿不到时按设计降级——**只跳过面板注册，六个工具照常可用**，配置改 `cordis.patch.yml` |
| M9 | 预克隆子仓库时**所有镜像一起失败**，但手动 `git clone` 是好的 | `xcode-select -p` 指向 `/Applications/Xcode.app` 时 `/usr/bin/git` 只是 Xcode 的 shim：没跑过 `sudo xcodebuild -license` 就**任何命令都 rc=69**（`git init` 也不例外），报错内容跟网络无关，极易误判成 GitHub 挂了。同机的 Command Line Tools 那份 git 不需要许可 | 安装脚本新增 `resolve_git()`：逐个候选（`git` → CLT → homebrew → /usr/local → Xcode）跑 `git --version` 取第一个能用的，并 **`export GIT=<绝对路径>`**——`launch_utils.py` 第一行就是 `git = os.environ.get('GIT', "git")`，A1111 自己 clone 也走这份；`-Git <路径>` 可手动指定。插件侧同款 `resolveGit()` 注入 `env.GIT`。全局解法（脚本不替用户动系统设置）：`sudo xcodebuild -license accept` 或 `sudo xcode-select -s /Library/Developer/CommandLineTools` |
| M9b | 依赖全装好、`venv/bin/python launch.py` 手动也起得来，但 SD **一启动就自己退出**：`ImportError: Failed to initialize: Cmd('git') failed due to: exit code(69) … You have not agreed to the Xcode license` | M9 的第一层修的是 `GIT` 变量（`launch_utils.py` 读它），可 A1111 启动时还要 `import git`（**GitPython**，`modules/gitpython_hack.py`），而 GitPython **不读 `GIT`**，它自己在 PATH 里找 `git` 并跑一次 `git version` 做初始化 → 又撞回那个 rc=69 的 Xcode shim | 两道一起上：`GIT_PYTHON_GIT_EXECUTABLE=<可用的 git 绝对路径>`（GitPython 官方认的变量）+ 在 `<SD>/.dsh-bin/` 里放一个**只指向那份 git 的软链接并前置到 PATH**（只软链 `git` 这一个命令，不整目录前置，免得盖掉用户自己的工具）。安装脚本、`sd-direct.sh`、插件 `gitShimEnv()` 三处同款 |
| M10 | git 能跑但克隆报 `Error in the HTTP2 framing layer` → `RuntimeError: Couldn't clone Stable Diffusion.` | GitHub + 国内网络下 HTTP/2 易被中间设备掐断；A1111 是自己 spawn git，插不进 `-c http.version=HTTP/1.1` | 用 git 2.31+ 的 `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_n` / `GIT_CONFIG_VALUE_n` 环境变量强制 HTTP/1.1 + 低速断开（对**派生的所有 git** 生效）；安装脚本另加「按 commit 预克隆」段：URL/commit 都从本机 `modules/launch_utils.py` 解析（不写死），`--depth 1` 精准 fetch 失败再退回整仓克隆，镜像顺序 直连 → gitclone.com → ghfast.top。`git_clone` 见目录已存在且 HEAD 命中就**不再联网** |
| M11 | 脚本第一行就 `install-sd-macos.sh: line 123: GIT_BIN？: unbound variable` | macOS 自带 **bash 3.2**，`locale` 不是 UTF-8 时（脚本被 Node/DSH spawn 出来常常就是这种环境）`$VAR` 紧跟中文会把多字节**首字节算进变量名**，`set -u` 当场炸 | 紧邻非 ASCII 的变量一律写 `${VAR}`；新增 `check-sh-varquote.mjs` 静态扫两份脚本拦回归（`npm run check` 已串上） |
| M12 | `git ls-remote` / `pip install <GitHub zip>` **整段挂住**（不是报错，是 60s 连接超时 ×10 次重试），而 `curl https://hf-mirror.com` 明明很快 | 这台机器到 `github.com:443` 是**黑洞丢包**（TCP 连不上），只有走 gh 代理前缀才通；huggingface 镜像与阿里云 PyPI 不受影响 | 安装脚本新增 `gh_fetch()`：GitHub 的文件（CLIP / open_clip 的 zip）先落地到 `<SD>/.cache/dsh/github/` 再 `pip install <本地文件>`，前缀顺序 直连 → `ghfast.top` → `gh-proxy.com` → `ghproxy.net` → `mirror.ghproxy.com`；`preclone_repo()` 的 git 镜像同套（gh 代理前缀**也支持 smart-HTTP**，实测能 `fetch --depth 1 <sha>`）。有本地代理就 `export HTTPS_PROXY=http://127.0.0.1:7890` 再跑，全部工具都会走它 |
| M13 | 明明在“装依赖”，日志静默 10 分钟不动 | pip 默认 `--retries 10 --timeout 60`，一个连不通的 GitHub 地址就要白等 ~10 分钟；macOS 还**没有** `timeout`/`gtimeout` 可以兜底 | 安装脚本 `export PIP_RETRIES=2 PIP_TIMEOUT=30`（可覆盖）；自带 `with_timeout()`（后台跑 + `sleep` 看门狗 `kill -TERM`，rc=143 记为失败）套住 `ls-remote`(25s) / `fetch`(60s) / `clone`(240s)，超时就换下一个镜像而不是干等 |
| M14 | 依赖明明装完了（`site-packages` 272 个包、torch 能 import），WebUI 一启动就崩：`ImportError: dlopen(.../scipy/sparse/linalg/_propack/_spropack.cpython-310-darwin.so): (section '__DATA/__thread_bss' has a zero-fill section type, but offset field is not zero)` | **新版 macOS 的 dyld 开始严格校验**：section 类型是零填充（`S_ZEROFILL=0x01` / `S_THREAD_LOCAL_ZEROFILL=0x12`）时 `offset` 字段必须为 0；PyPI 上按老工具链（ld64 / Xcode 14 那批 CI 镜像）构建的 wheel 在这个字段里留了「下一个可用偏移」的垃圾值。本机 scipy 1.15.3（Python 3.10 能装到的最后一版）里 **32 个 .so 中招**，链路是 `initialize.imports()` → `import pytorch_lightning` → `torchmetrics` → `import scipy.signal` | 随包发布 `fix-macho-zerofill.py`（纯 stdlib）：解析 `section_64`（`offset@48`、`flags@64`，段表在 `LC_SEGMENT_64` 里），把零填充段的 `offset` 写回 0，然后**必须** `codesign --force --sign -` 重新 ad-hoc 签名（arm64 签名覆盖文件内容，改一个字节就会被 SIGKILL）。安装脚本 `macho_fix()` 在依赖阶段调它并做 `import scipy.signal, pytorch_lightning, torchmetrics, cv2, omegaconf` 自检，通过才写 `<SD>/.dsh-macho-zerofill.ok` |
| M15 | API 端口迟迟不通；`api.log` 里连着 `Retrying in 8s [Retry 5/5]` + `HTTPSConnectionPool(host='huggingface.co' … special_tokens_map.json` | A1111 首次加载要从 HF 拉 `openai/clip-vit-large-patch14` 的 tokenizer 等零碎文件，国内直连的表现不是报错而是**每个文件重试 5 次、递增退避**，一次启动能耗几分钟；而默认缓存写在 `~/.cache/huggingface`，插件用的是 `<SD>/.cache/huggingface` —— 两边不对齐就得下两遍 | `install-sd-macos.sh` 与插件 `buildHfEnv` 用同一套判据：`HF_HOME=<SD>/.cache/huggingface` 对齐缓存位置、`HF_ENDPOINT` 默认 `hf-mirror.com`；**缓存里已经有 `models--*` 才**设 `HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1`（空缓存绝不能离线，否则首次下载直接被拒）。修好后本机 ⑦ 段 **6 秒就绪** |
| M16 | macOS 上「SD 目录有了、但还没装依赖」时，插件**主动拒绝**替用户跑首次依赖安装 | 两个原因：① 没有 venv 时插件只能拿 PATH 上的 `python3` 直接 pip 进系统/conda 环境，污染不可控；② A1111 一路装到底才第一次 import，而新版 dyld 那条零填充校验（M14）正好卡在这一步 —— 依赖全装完了进程却崩在 `import scipy.signal`，插件在半路插不进「装 → 修 → 自检」的收敛循环，用户看到的就是「折腾半天还是起不来」 | `macPrepareBeforeLaunch()` 在 `!sdPrepared()` 时直接抛 `installGuidance()`（就是那条 `bash install-sd-macos.sh …`）。安装脚本里有 `run_deps_pass()` + `macho_fix()` 的循环，这条路由它负责；插件只负责「已经装好」之后的启动、修复位与出图 |

## 常见问题

- **新装的 SD 出图很差 / 发灰 / 不像样？** 是模型与 VAE，不是提示词：跑一遍 `install-sd.ps1`（会补装 **AWPainting v1.2** + `vae-ft-mse-840000` 并写质量默认配置，已装过 SD 也只会补缺的那部分），或先调 `sd_models`——它检测到只有新装默认的 SD1.5 base 会返回 `qualityHint`；动漫模型记得 CLIP skip = 2。
- **设置里找不到插件配置？** 0.7.0 起在 **设置 → 插件 → `sd-bridge`** 注册了配置面板（13 个字段全可视化、带中文说明）；旧版只能改 `cordis.patch.yml`。若面板没有该项，说明还在跑旧版插件，重装最新版后新开会话。
- **想多装几个模型 / 常见 LoRA？** `install-sd.ps1 -Models "awpainting,majicmix" -Loras "add_detail,easynegative,badhandv4"`，键见上文参数表；已有文件会跳过，`-Upgrade` 做 sha 复验并补拉新版。
- **安装时报缺 git / Python / VC++？** 不用手动补——0.7.0 起脚本先跑环境预检，缺啥自举啥（MinGit 便携版、官方 Python 3.10.6、vc_redist），每项失败只报一条错；也可 `-NoPrereq` 跳过整个预检。
- **首次启动很慢？** 加载 checkpoint 约 1-3 分钟（可调大 `startupTimeoutMs`）；全新安装还要先在线装依赖。脚本自己拉起 SD 时会带 HF 缓存/镜像环境，tokenizer 不会去连 huggingface.co 反复重试。
- **模型放哪？** 🍎 `<SD 目录>/models/Stable-diffusion/`，LoRA 放 `models/Lora/`，VAE 放 `models/VAE/`，Embedding 放 `models/embeddings/`（Windows 是 `<SD 目录>\models\Stable-diffusion\`）。名字用 `sd_models` 查。
- **换机器/换盘符？** 不用改任何配置——重新装插件即可，探测与工作区逻辑自动适配。

---

# English

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) plugin that drives your local **Stable Diffusion WebUI** (AUTOMATIC1111 API) with six tools — txt2img, img2img, inpaint (mask redraw), script-only (no image), model listing, server management — plus a built-in **content-guard protocol** (mild violations: draw the safe part + reproducible script; explicit requests: no image, compliant-baseline script only).

**Zero local setup**: the SD install directory is auto-detected (`sdDir` config > `DSH_SD_DIR` env > `~/.dsh-sd-bridge.json` install record > drive scan); outputs, reference images and the reproducible script always land in your **session workspace**. No SD installed? The plugin returns a one-line command that runs the bundled `install-sd.ps1` bootstrap — it runs an **environment preflight first** (disk, mirror reachability, git, Python 3.10, VC++ runtime; each missing piece is bootstrapped automatically), then clones WebUI and pulls the selected **model/VAE/LoRA catalog** (`-Models`, `-Vaes`, `-Loras`, `-Upgrade`), every file verified by sha256.

**Install**: paste `github:savinglighting/dsh-sd-bridge-guard` (or the npm name `dsh-sd-bridge-guard`) into DSH *Settings → Plugins*, then restart.

Configuration lives in **Settings → Plugins → `sd-bridge`** (editable live, applied on the next tool call); `cordis.patch.yml` overrides under id `sd-bridge` keep the highest priority — see the table above.

## License

MIT
