# Changelog

> **验证范围（0.7.0-mac.1）**：仅在一台机器验证 —— Apple M4（`Mac16,10`）/ 16 GB 统一内存 /
> macOS 27.0.1（build `26A434`，arm64）/ Python 3.10.22 / torch 2.3.1（MPS 可用）/ Node v22.22.3。
> 未验证：Intel Mac、其它 macOS 版本与芯片（M1/M2/M3/M5）、其它 DSH 版本、
> `sd-auto-mask.py` / `sd-mask-qa.py` 支线、MPS 显存自愈（macOS 上跳过显存门槛判断）。


## 0.7.0-mac.1（macOS / Apple Silicon 移植）

上游 0.7.0 只能跑 Windows；本 fork 把**平台层**整体重做，六个工具的参数、返回结构、贴图/附件链路一字不改。
后端选择 A1111-compatible WebUI（`/sdapi/v1/*`），因为六个工具与它 1:1 对应，ComfyUI/stable-diffusion.cpp 都需要重写调用层。

- **目录探测跨平台**：`STATE_FILE` 改用 `os.homedir()`（原来读 `USERPROFILE`，POSIX 下为空 → 永远读不到自举安装记录）；`detectSdDir` 的固定候选加 `$HOME/{Desktop,Documents,Downloads}`、`Library/Application Support/dsh-sd-bridge/webui`、`/opt`、`/usr/local`，并把「逐盘符 C:–Z: 扫描」换成 `platformRoots()`——macOS 枚举 `/Volumes/*` 外接卷（本机 SD 就在外置盘），Linux 退化 `/opt`、`/srv`、`/media/*`、`/mnt/*`。
- **解释器解析**：`venv/bin/python` → `venv/bin/python3` → `.py310/bin/python` → 安装记录 `pythonBin`/`pythonDir`（POSIX 试 `bin/python3`、`bin/python`）→ PATH 上的 `python3`（现代 macOS 没有 `python`，原来的 `return 'python'` 必然 ENOENT）。`statePythonDir` 现在返回**可执行文件全路径**并优先用记录里的 `pythonBin`。
- **Apple Silicon 启动参数（真机实测的硬坎）**：直接 spawn `launch.py` 会绕过 `webui.sh`，拿不到 `webui-macos-env.sh` 的 `COMMANDLINE_ARGS`，`prepare_environment` 在 `assert torch.cuda.is_available()` 处 RuntimeError。新增 `macLaunchArgs()` 补齐 `--skip-torch-cuda-test --upcast-sampling --no-half-vae --use-cpu interrogate`（用户 `extraArgs` 里写过的同名项不重复注入），`buildLaunchEnv` 注入 `PYTORCH_ENABLE_MPS_FALLBACK=1`，`buildFreshEnv` 在 arm64 预置 `TORCH_COMMAND="pip install torch==2.3.1 torchvision==0.18.1"`。
- **`isBlackwellGpu` 非 Windows 直接短路**：以前靠 `nvidia-smi` ENOENT 掉进 catch 才返回 false，代价是每次全新安装白等一次 5 秒超时。
- **坑7 的真因修正**：上游注释说 `PIP_CONSTRAINT` 会作用到 PEP 517 隔离构建那次——**macOS 实测不成立**（CLIP 仍 `No module named 'pkg_resources'`）。新增 `PIP_NO_BUILD_ISOLATION=1` / `PIP_BUILD_ISOLATION=0` 两种写法兜底，真正有效的做法在 `install-sd-macos.sh` 里：**显式 `--no-build-isolation` 预装 clip / open_clip**，借 A1111 的 `is_installed()` 护栏跳过隔离构建。
- **可复现脚本改成 bash**：新增随包 `sd-direct.sh`（参数名与 `.ps1` **完全一致**：`-Prompt/-Negative/-InitImage/-Mask/-MaskBlur/-InpaintFill/-MaskInvert/-NoFullRes/-InpaintPadding/-Denoising/-Width/-Height/-Steps/-Sampler/-Cfg/-Seed/-OutDir/-Name/-ApiBase/-SdDir/-StartTimeout/-NoStart/-NoOpen`，大小写不敏感）；`syncDirectScripts` 按平台选文件、POSIX 剥 BOM + `chmod 755`；`buildCommand` POSIX 前缀 `bash '<绝对路径>'`；`commandBlock` 用 ```bash 围栏 + 「复制到终端」文案；`docLabels` 的 `%DIRECT%` 跟着换成 `sd-direct.sh`。
- **`shQuote`（新）**：单引号方案，`'` → `'\''`、换行/回车/制表符 → `'$'\n''` 片段拼接，保证**命令恒为单行**且 `$`/反引号/`\`/`(x:y)`/中文都能原样还原。首版写错成「每个片段各套一层引号」，被 `test-mac.mjs` 的假脚本回读抓出来（引号奇偶错位后 `(x:y)` 掉到引号外被当子 shell）。
- **模型可见文案全部去 Windows 化**：`installGuidance` 指向 `bash install-sd-macos.sh`、6 个工具描述、`sd_models` 的 `qualityHint`（`<SD>\models\...` → `<SD>/models/...`）、设置项 `sdDir` 说明、`sd-paint` 技能里的 `powershell` → `bash`、`%DIRECT%` 等 31 处。
- **`pathToFileURL` 修 POSIX 动态导入**：`await import('file:///' + hit)` 换成 `pathToFileURL(hit).href`——这是 0.7.0 设置面板在符号链接安装下降级的主因之一（含空格/中文的 profile 路径拼出来的 URL 不合法）。
- **新增 `install-sd-macos.sh`**：与 `install-sd.ps1` 同一张资源清单（**同样的键名与同样的 sha256**），七段式：预检（Darwin / git / arch / `df` ≥15GB / 镜像探活 / 解析 Python 3.10：现成 → homebrew → `conda create -p <Target>/.py310 python=3.10`）→ 克隆（非空目录合并）→ venv + 依赖（`PIP_CONSTRAINT` 只钉 `setuptools==69.5.1` + `numpy==1.26.2`，**不再钉 opencv**，避免与 A1111 自己的版本文件撞成 `ResolutionImpossible`；`--exit-after-start` 让 A1111 自己装 torch 后退出，失败用 arm64 torch 组合重试一次）→ 资源下载（逐文件 `shasum -a 256` 校验）→ `config.json` 质量默认值 → 写 `~/.dsh-sd-bridge.json`（**无 BOM**，多带 `pythonBin` 与 `platform`）→ 拉起 API 并轮询就绪。重跑天然续传：已存在文件只做 sha 复验。
- **git 两连坑（安装脚本 + 插件同时修）**：① `xcode-select` 指向 Xcode 时 `/usr/bin/git` 是 shim，没同意许可就**任何命令 rc=69**（连 `git init` 都不行），症状是「所有镜像一起失败」而手动 clone 正常——`install-sd-macos.sh` 新增 `resolve_git()` 逐个候选试跑 `git --version`，选中后 **`export GIT=<绝对路径>`**（`launch_utils.py` 第 24 行 `git = os.environ.get('GIT', "git")`，A1111 自己 clone 也走它），并支持 `-Git <路径>`；插件侧同款 `resolveGit()` 注入 `env.GIT`。② GitHub 的 HTTP/2 被掐断 → `Couldn't clone Stable Diffusion.`：用 git 2.31+ 的 `GIT_CONFIG_COUNT/KEY_n/VALUE_n` 强制 `http.version=HTTP/1.1`（对派生 git 进程同样生效），并新增「按 commit 预克隆 5 个子仓库」段——URL 与 commit **从本机 `modules/launch_utils.py` 解析**（不写死，上游改了自动跟上），`--depth 1` 精准 fetch → 失败退回整仓克隆 → 镜像顺序 直连/gitclone.com/ghfast.top；`git_clone` 见目录已存在且 HEAD 命中即不再联网。
- **GitHub 直连不通的兜底（本机实测：`github.com:443` 黑洞丢包，hf-mirror / 阿里云 PyPI 正常）**：新增 `gh_fetch()` 把 A1111 唯一需要现场构建的两个包（CLIP / open_clip 的 GitHub zip）**先下到 `<SD>/.cache/dsh/github/` 再 `pip install <本地文件>`**，前缀顺序 直连 → ghfast.top → gh-proxy.com → ghproxy.net → mirror.ghproxy.com（实测 ghfast.top 连 `fetch --depth 1 <sha>` 这种 smart-HTTP 都能代理）；子仓库预克隆用同一串镜像。压掉 pip 的白等：`PIP_RETRIES=2 PIP_TIMEOUT=30`（默认可覆盖）。
- **`with_timeout()` 自带看门狗**：macOS 没有 `timeout`/`gtimeout`，git 又没有 `connect-timeout` 配置项，直连卡住就是 curl 默认 300 秒 —— 现在 `ls-remote`(25s)/`fetch`(60s)/`clone`(240s) 超时即算失败并换下一个镜像（rc=143）。预检的 GitHub 探活也从「curl HTML 页面」改成 `git ls-remote`（页面被限速不代表 git 协议不通，本机实测反向也一样）。
- **bash 3.2 变量紧邻中文：`$GIT_BIN（` 这类写法在非 UTF-8 locale 下把多字节首字节算进变量名 → `set -u` 报 `GITï¼: unbound variable`，第一句就崩。已把两份脚本里 19+4 处改成 `${VAR}`，并新增 `check-sh-varquote.mjs` 静态拦回归（挂在 `npm run check`）。
- **`sd-direct.sh` 自动拉起时同样补齐 mac 参数**：`--skip-torch-cuda-test --upcast-sampling --no-half-vae --use-cpu interrogate` + `PYTORCH_ENABLE_MPS_FALLBACK=1`，并继承同一套 `GIT` / `GIT_CONFIG_*` 处理；`DSH_SD_EXTRA_ARGS` 可追加参数（与插件 `extraArgs` 等价）；收尾用 `open`（Linux 退 `xdg-open`）。
- **随包 `fix-macho-zerofill.py`（macOS 新版 dyld 的硬坎）**：dyld 现在要求零填充段（`S_ZEROFILL=0x01`/`S_THREAD_LOCAL_ZEROFILL=0x12`）的 `offset` 字段为 0，而 PyPI 上老工具链构建的 wheel 在该字段留了垃圾值 → 依赖装完、torch 也能 import，WebUI 却崩在 `import pytorch_lightning → torchmetrics → import scipy.signal`（`dlopen … section '__DATA/__thread_bss' has a zero-fill section type, but offset field is not zero`；本机 scipy 1.15.3 里 32 个 .so 中招）。修复器纯 stdlib：解析 `section_64`（`offset@48`、`flags@64`）把该字段写回 0，再 `codesign --force --sign -` 重签（arm64 上改一个字节不重签就被 SIGKILL）；默认 dry-run，`--apply` 才动手，退出码 1 = 有待修项。注意 `0x02` 是 `S_CSTRING_LITERALS`（**有真实内容，动它就毁二进制**），第一版就把这两个常量记错过。
- **依赖阶段改成「装 → 修 → 自检」的收敛循环**：A1111 的 `main()` 在 `--exit-after-start` 退出前还要 `import webui`，也就是说**依赖装完了那一轮照样以 import 崩溃收场**——原来一见非零返回码就重试/报错，会把成功的安装误判成失败。现在 `run_deps_pass()` 不看返回码下结论，先 `macho_fix()`（含 `import scipy.signal, pytorch_lightning, torchmetrics, cv2, omegaconf` 自检，两轮），仍然不行才换 torch 组合重试，最后才 `fail` 并留完整日志。`-SkipDeps` 也会单独跑一遍自检（老 venv 被新 dyld 拦住的情况）。
- **GitHub 兜底**：`gh_fetch()` + `with_timeout()` + `PIP_RETRIES=2/PIP_TIMEOUT=30`（详见上面两条），预检的 GitHub 探活改成 `git ls-remote`（curl 的 HTML 页面通不通不代表 git 协议）。
- **macOS 上插件不做「从零装依赖」**：`macPrepareBeforeLaunch()` 发现 `<SD>` 里没有 venv / `python` / `.py310` 时直接抛安装指引（`installGuidance()`），不再让 A1111 拿 PATH 上的 `python3` 一路 pip 到底 —— 那条路既污染系统环境，又必然在半路撞上 dyld 的零填充校验（依赖装完才第一次 import，插件插不进修复循环）。首次安装归 `install-sd-macos.sh`（它有 `run_deps_pass()` + `macho_fix()` 收敛循环），插件负责「已装好」之后的一切。`prepared` 判定同时抽成 `sdPrepared()`，`spawnServer` 与前置检查共用。
- **GitPython 那一层（M9 的第二道坎）**：修好 `export GIT` 之后 SD 仍然「一启动就自己退出」，因为 `modules/gitpython_hack.py` → `import git` 时 GitPython **不读 `GIT` 变量**，它在 PATH 里找 `git` 跑 `git version`（`exit code(69) … Xcode license`）。现在三处同款兜底：`GIT_PYTHON_GIT_EXECUTABLE=<绝对路径>` + `<SD>/.dsh-bin/git` 软链接前置 PATH（只软链 `git`，不整目录前置）。安装脚本、`sd-direct.sh`、插件 `gitShimEnv()` 各自都会建/复用这个软链接。
- **HF 缓存与镜像对齐（M15）**：`install-sd-macos.sh` 的启动段补上 `HF_HOME=<SD>/.cache/huggingface`、`HF_ENDPOINT=hf-mirror.com`，并且**只有缓存里已有 `models--*` 时**才设 `HF_HUB_OFFLINE=1/TRANSFORMERS_OFFLINE=1`（空缓存离线 = 首次下载直接被拒）。判据与插件 `buildHfEnv` 一致，两边共用一份缓存。本机实测：改之前 `Retrying in 8s [Retry 5/5]` 卡好几分钟，改之后 **⑦ 段 6 秒就绪**。
- **bash 3.2 空数组**：`"${CATALOG_ROWS[@]}"` 在 `set -u` 下遇到空数组直接 `unbound variable`（`-SkipModel -SkipVae -SkipLora` 全开必然触发）→ 换成标准绕法 `${ARR[@]+"${ARR[@]}"}`。
- **启动等待与耗时文案按平台分叉**：`startupTimeoutMs` 在 macOS 默认 **900000（15 分钟）**（checkpoint 可能在外接盘 + torch 首次现编译 MPS 内核），`sd-direct.sh` 的 `-StartTimeout` 默认也从 300s 抬到 900s；`sd_txt2img`/`sd_img2img` 描述与 `sd-paint` 技能里的耗时说明改成「API 秒级响应、出图按机器性能计时（Apple Silicon MPS 实测 512×768·22 步约 20-60 秒/张）」，不再承诺「之后秒级响应」。
- **`sd-direct.sh` 启动失败时给可执行指引**：等待循环发现进程提前退出且日志里出现 `zero-fill section type`，就直接打印 `python3 <同步到工作区的 fix-macho-zerofill.py> <SD>/venv/lib/python3.*/site-packages --apply`，而不是只丢一句 dyld 报错。
- **插件随包同步多个文件**：`syncDirectScripts` 从「只同步 `sd-direct.sh`」改成清单化（POSIX 下额外同步 `fix-macho-zerofill.py` 到工作区与 SD 目录，同样剥 BOM 只管 `.sh`、同样每次对齐 755），主脚本缺失才报错、附属文件缺失静默跳过。
- **`npm run test:e2e`（真实出图端到端）**：假 ctx 加载 fork → `sd_server start` 真拉起 SD → `sd_models` → `sd_txt2img`（校验 PNG 魔数、`summary_序号.png` 命名、落进 `SD-Picture/`、`replyImages` 形态、seed 回传）→ `sd_img2img`（`-InitImage`/`-Denoising`、参考图固化）→ `sd_inpaint`（`maskBox` 生成的蒙版落盘可读）→ 最后**把 `asMarkdown` 里那条命令交给 `/bin/bash -c` 真跑一遍**，确认用户复制的那一行在 macOS 上确实出图。
- **测试**：新增 `test-mac.mjs`（29 项：目录探测 / 假 ctx 注册 6 工具 + 技能 + 设置 / 文案不含 powershell·`.ps1`·反斜杠路径 / `sd-direct.sh` 同步无 BOM 且 755 / 命令单行 / 转义交给 `/bin/bash` 真跑回读）与 `test-mac-smoke.mjs`（图生图与文生图命令形态、`-NoOpen`、无效 `sdDir` 的回退不误报、guidance 指向 mac 脚本）。`npm test` = `node test-mac.mjs`，`npm run check` = 三份文件语法检查。

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
