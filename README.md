# dsh-sd-bridge-guard

[![npm](https://img.shields.io/npm/v/dsh-sd-bridge-guard.svg)](https://www.npmjs.com/package/dsh-sd-bridge-guard)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

**DeepSeek Harness 插件 · 本机 Stable Diffusion 生图五件套 + 违规分流协议 · 跨机器零适配**

让 DeepSeek Harness 直接调用你电脑里的 Stable Diffusion WebUI 生图：不用提前打开 SD（首次调用自动以纯 API 模式拉起）、不用改任何路径——装上插件就能用。

| 文生图 | 图生图 |
| --- | --- |
| ![txt2img demo](docs/assets/demo-txt2img.jpg) | ![img2img demo](docs/assets/demo-img2img.jpg) |

## 特性

- **零本地适配**：SD 安装目录自动探测（配置 > 环境变量 `DSH_SD_DIR` > 自举安装记录 > 扫盘候选）；产物、参考图、可复现脚本全部自动落在**当前会话工作区**（`SD-Picture/`、`ref/`、`sd-direct.ps1`）。
- **没装 SD 也能用**：插件找不到 SD 时返回一条可直接运行的安装命令（包内 `install-sd.ps1`），一键装好 WebUI + 模型并把路径记进 `~/.dsh-sd-bridge.json`，重启即用。
- **五个工具**：`sd_txt2img` 文生图、`sd_img2img` 图生图、`sd_script` 只生成可复现脚本不出图、`sd_models` 模型清单、`sd_server` 服务管理。
- **违规分流协议**（`sd-paint` 技能内置）：轻微违规删词后照常出图并附可复现脚本；明显违规不出图、只给合规素体的可复现脚本；回复最末尾列出被剔除的违规提示词英文。
- **可复现**：每次出图返回单行 powershell 脚本（提示词高亮），用户复制整行即可在 PowerShell/cmd 复跑同一张图。
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

> 本包**替换**原 `dsh-sd-bridge`（工具名相同，不可并存）。装过原版先卸载：`dsh plugin remove dsh-sd-bridge`。
> DSH 插件暂不支持自动更新：升级需先卸载再安装新版。

## 首次使用

- **已装 SD WebUI**：什么都不用做。插件启动时自动探测（也认 `DSH_SD_DIR` 环境变量与 `cordis.patch.yml` 的 `sdDir` 覆盖）。
- **没装 SD**：让 Harness 帮你画张图，它会返回安装指引；或自己在 PowerShell 跑：

```powershell
powershell -ExecutionPolicy Bypass -File "插件目录\install-sd.ps1"
```

装完重启 DSH。首次生图会在线安装 Python/torch 依赖。

## 提供的工具

| 工具 | 作用 |
| --- | --- |
| `sd_txt2img` | 文生图：提示词、负面词、尺寸/步数/CFG/采样器/seed、批次 1-4、临时换 checkpoint、LoRA、hires fix、styles、summary；返回 `script`（【文生图】脚本） |
| `sd_img2img` | 图生图：本地图片路径 + `denoisingStrength` 重绘；工作区外的参考图自动固化到 `ref/`；返回 `script`（【图生图】脚本） |
| `sd_script` | **只生成可复现脚本，不调 SD、不出图**（`generatesImage` 恒为 false）——明显违规分流专用 |
| `sd_models` | 列出 checkpoints / LoRA / 采样器 / VAE / 当前选项 |
| `sd_server` | `status` / `start` / `stop`；找不到 SD 时 `status` 返回安装指引 |

### 保存与命名

- 产物目录：**会话工作区下的 `SD-Picture/`**（可用 `outputDir` 改成绝对路径）
- 文件名 = **提示词总结_三位序号.png**；`summary` 参数决定文件名，序号自动递增
- 返回 `paths`（绝对路径）、`fileNames`、`savedDir`、`replyImages`（Markdown，贴进回复即全尺寸展示）、`script`（可复现脚本）

## 违规分流协议（`sd-paint` 技能全文内置）

判定标准 = 模型自己会拒绝执行的尺度，不依赖固定词表。需求里只要有一部分违规就触发分流，不整单拒绝：

- **A 档 · 轻微违规**（删几个词后完全正常）→ 剔除违规片段、照常出图存盘、说明剔除、附脚本、回复最末尾英文违规词清单。
- **B 档 · 明显违规**（露骨/整体性质）→ **一张图都不生成**，只给合规素体的可复现脚本（`sd_script`），末尾同样列英文违规词。

## 配置（`cordis.patch.yml` 中按 id `sd-bridge` 覆盖）

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
| `enabled` | `true` | 关掉即不注册工具 |

## 测试

```powershell
node smoke-skill.mjs    # 注册冒烟 + 双分支协议要点 + 可移植性断言（不出图）
node acceptance.mjs     # 真实出图验收：命名、序号、脚本字段、ref 固化（需本机 SD）
```

环境变量：`DSH_SD_DIR` 指定 SD 目录；`ACCEPTANCE_WS` 指定验收工作区（默认临时目录）。

## 常见问题

- **首次启动很慢？** 加载 checkpoint 约 1-3 分钟（可调大 `startupTimeoutMs`）；全新安装还要先在线装依赖。
- **模型放哪？** `<SD 目录>\models\Stable-diffusion\`；LoRA 放 `models\Lora\`。名字用 `sd_models` 查。
- **换机器/换盘符？** 不用改任何配置——重新装插件即可，探测与工作区逻辑自动适配。

---

# English

A [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) plugin that drives your local **Stable Diffusion WebUI** (AUTOMATIC1111 API) with five tools — txt2img, img2img, script-only (no image), model listing, server management — plus a built-in **content-guard protocol** (mild violations: draw the safe part + reproducible script; explicit requests: no image, compliant-baseline script only).

**Zero local setup**: the SD install directory is auto-detected (`sdDir` config > `DSH_SD_DIR` env > `~/.dsh-sd-bridge.json` install record > drive scan); outputs, reference images and the reproducible script always land in your **session workspace**. No SD installed? The plugin returns a one-line command that runs the bundled `install-sd.ps1` bootstrap (WebUI + model + path registration).

**Install**: paste `github:savinglighting/dsh-sd-bridge-guard` (or the npm name `dsh-sd-bridge-guard`) into DSH *Settings → Plugins*, then restart. Replaces `dsh-sd-bridge` (uninstall it first).

Configuration lives in `cordis.patch.yml` under id `sd-bridge` — see the table above; every default is portable.

## License

MIT
