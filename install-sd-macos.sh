#!/usr/bin/env bash
# install-sd-macos.sh —— dsh-sd-bridge-guard 的 macOS（Apple Silicon）自举安装
#
# 与 install-sd.ps1 同职责、同清单、同 sha256 校验，只把平台层换成 macOS 原生：
#   环境预检 → 用 python3.10 建 venv → clone A1111 WebUI → 让 A1111 自己装依赖（torch/MPS）
#   → 按清单拉 模型/VAE/LoRA/Embedding（逐个 sha256 复验）→ 写 config.json 质量默认
#   → 把安装位置记进 ~/.dsh-sd-bridge.json（无 BOM UTF-8，插件下次启动直接读到）
#
# 用法：
#   bash install-sd-macos.sh                                   # 默认装到 ~/stable-diffusion-webui
#   bash install-sd-macos.sh -Target "/Volumes/盘/stable-diffusion-webui"
#   bash install-sd-macos.sh -Models "awpainting,majicmix" -Vaes mse -Loras add_detail
#   bash install-sd-macos.sh -SkipClone -SkipDeps              # 只补资源清单
#   bash install-sd-macos.sh -NoServe                          # 装完不把 API 拉起来
#   bash install-sd-macos.sh -PypiIndex ""                     # 用官方 PyPI（默认阿里云镜像）
#   bash install-sd-macos.sh -NoPrereq                         # 跳过环境预检
#   bash install-sd-macos.sh -Git /Library/Developer/CommandLineTools/usr/bin/git   # 手动指定可用的 git
#
# 清单键：
#   模型  awpainting(默认) | revanimated | anythingv5 | majicmix | darksushi   （none = 不拉）
#   VAE   mse(默认) | animevae
#   LoRA  add_detail | easynegative(默认) | badhandv4(默认)
# 全部 sha256 与 install-sd.ps1 一致（HF lfs oid = sha256），逐项复验，不符即报错退出。
#
# 每项失败只报一条错误就退出（不级联刷屏）；全过程同时写进日志文件（-Log）。

set -uo pipefail

# --------------------------------------------------------------------------- 参数
TARGET="${DSH_SD_INSTALL_DIR:-$HOME/stable-diffusion-webui}"
REPO_URL="${DSH_SD_WEBUI_REPO:-https://github.com/AUTOMATIC1111/stable-diffusion-webui.git}"
# 坑9：上游 Stability-AI/stablediffusion 已被删除（GitHub 对已删仓库要求认证 → 克隆停滞）。
# A1111 需要的同一 commit cf1d67a6… 在 camenduru fork 里还在，签名 verified。
SD_SUBREPO="${STABLE_DIFFUSION_REPO:-https://github.com/camenduru/stablediffusion.git}"
HF_MIRROR="${DSH_SD_HF_MIRROR:-https://hf-mirror.com}"
PYPI_INDEX="${DSH_SD_PYPI_INDEX:-https://mirrors.aliyun.com/pypi/simple/}"
MODELS="awpainting"
VAES="mse,animevae"
LORAS="add_detail,easynegative,badhandv4"
PORT=7860
LOG=""
SERVE=1
NO_CONFIG=0
SKIP_CLONE=0
SKIP_DEPS=0
SKIP_MODEL=0
SKIP_VAE=0
SKIP_LORA=0
SKIP_PREREQ=0
FORCE_PYTHON="${DSH_SD_PYTHON:-}"
PYTHON_FALLBACK="${DSH_SD_NO_TORCH_FALLBACK:+0}"; PYTHON_FALLBACK="${PYTHON_FALLBACK:-1}"   # 依赖装挂了就用已知可用的 arm64 torch 重试

while [[ $# -gt 0 ]]; do
  case "$1" in
    -Target|--target)        TARGET="${2:?}"; shift 2 ;;
    -Repo|--repo)            REPO_URL="${2:?}"; shift 2 ;;
    -Mirror|--mirror)        HF_MIRROR="${2:?}"; shift 2 ;;
    -PypiIndex|--pypi-index) PYPI_INDEX="${2:?}"; shift 2 ;;
    -Python|--python)        FORCE_PYTHON="${2:?}"; shift 2 ;;
    -Models|--models)        MODELS="${2:?}"; shift 2 ;;
    -Vaes|--vaes)            VAES="${2:?}"; shift 2 ;;
    -Loras|--loras)          LORAS="${2:?}"; shift 2 ;;
    -Port|--port)            PORT="${2:?}"; shift 2 ;;
    -Log|--log)              LOG="${2:?}"; shift 2 ;;
    -NoServe|--no-serve)     SERVE=0; shift ;;
    -NoConfig|--no-config)   NO_CONFIG=1; shift ;;
    -SkipClone|--skip-clone) SKIP_CLONE=1; shift ;;
    -SkipDeps|--skip-deps)   SKIP_DEPS=1; shift ;;
    -SkipModel|--skip-model) SKIP_MODEL=1; shift ;;
    -SkipVae|--skip-vae)     SKIP_VAE=1; shift ;;
    -SkipLora|--skip-lora)   SKIP_LORA=1; shift ;;
    -NoPrereq|--no-prereq)   SKIP_PREREQ=1; shift ;;
    -Upgrade|--upgrade)      UPGRADE=1; shift ;;
    -Git|--git)              GIT_BIN="${2:?-Git 后面要跟 git 的可执行文件路径}"; shift 2 ;;
    -h|--help)               sed -n '/^# 用法：/,/^# 每项失败/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（-h 看用法）" >&2; exit 1 ;;
  esac
done

# 本脚本所在目录：同包里还有 fix-macho-zerofill.py（③.7 要用）
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"

TARGET="${TARGET%/}"
SD="$TARGET"
[ -z "$LOG" ] && LOG="$SD/install-sd-macos.log"
UPGRADE="${UPGRADE:-0}"

# ★ macOS（Apple Silicon）跑 launch.py 必需的参数组：与上游 webui-macos-env.sh 的 COMMANDLINE_ARGS 一致。
#   直接 spawn python launch.py 会**绕过 webui.sh**，拿不到那组默认值：
#   --skip-torch-cuda-test  mac 没有 CUDA，缺了它 prepare_environment 直接 RuntimeError（本机实测踩过）
#   --upcast-sampling / --no-half-vae  避开 MPS fp16 溢出导致的花图/黑图
#   --use-cpu interrogate   图像反推（interrogate）走 CPU，MPS 上那条路径不稳
MAC_ARGS=(--skip-torch-cuda-test --upcast-sampling --no-half-vae --use-cpu interrogate)
export PYTORCH_ENABLE_MPS_FALLBACK=1

# --------------------------------------------------------------------------- 输出与工具
fail()  { echo ""; echo "❌ $*" >&2; exit 1; }
step()  { echo "▶ [$SECONDS s] $*"; }
note()  { echo "   $*"; }
say()   { echo "$*"; }

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
if command -v tee >/dev/null 2>&1; then exec > >(tee -a "$LOG") 2>&1; fi
say "== dsh-sd-bridge-guard · macOS 自举安装 =="
say "目标目录: $SD"
say "日志:     $LOG"

sha_of()    { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
has_cmd()   { command -v "$1" >/dev/null 2>&1; }

# 断点续传 + 重试（坑5：单连接被限速掐断）；下完必校验 sha256
fetch() { # fetch <url> <dst> <expect_sha>
  local url="$1" dst="$2" want="$3" part="$2.part" i rc
  if [ -f "$dst" ]; then
    if [ -n "$want" ] && [ "$(sha_of "$dst")" = "$want" ]; then note "已存在且 sha 一致，跳过：$(basename "$dst")"; return 0; fi
    if [ -z "$want" ] && [ "$UPGRADE" != "1" ]; then note "已存在（无校验值），跳过：$(basename "$dst")"; return 0; fi
  fi
  for i in 1 2 3 4 5; do
    curl -fsSL -C - --retry 3 --retry-delay 5 --max-time 7200 -o "$part" "$url"
    rc=$?
    [ $rc -eq 0 ] || [ $rc -eq 33 ] || { note "第 $i 次下载失败 rc=${rc}，重试"; sleep 5; continue; }
    [ -f "$part" ] && mv -f "$part" "$dst" && break
  done
  [ -f "$dst" ] || fail "下载失败：$url"
  if [ -n "$want" ]; then
    local got; got="$(sha_of "$dst")"
    [ "$got" = "$want" ] || fail "sha256 不符：$(basename "$dst")
   期望 $want
   实际 $got   （文件损坏或镜像不一致，已拒绝使用；可加 -Mirror \"\" 换官方源重试）"
    note "sha256 校验通过 $(basename "$dst")"
  fi
  return 0
}

hf_url() { # hf_url <repo> <file>
  local url="https://huggingface.co/$1/resolve/main/$2"
  [ -n "$HF_MIRROR" ] && url="${url/https:\/\/huggingface.co/$HF_MIRROR}"
  echo "$url"
}

# 从 GitHub 拉文件（zip / raw 都走这里）。本机实测：github.com 直连**时好时坏**——
# 一会儿 ls-remote 通、一会儿 pip 的 HTTPS 连接 60s 超时并重试 10 次（白等 10 分钟）。
# 所以先把文件落到本地缓存，pip/curl 就不再参与重试风暴；失败依次换 4 个 gh 代理前缀。
# macOS **没有** timeout/gtimeout（brew 才装得到），而 git 又没有 connect-timeout 这个配置项：
# github.com 被黑洞丢包时 `git ls-remote` 会一路挂到 curl 默认的 300 秒。所以自带一个看门狗，
# 超时算失败（rc=143 = SIGTERM），让预克隆能立刻换下一个镜像而不是干等。
with_timeout() { # with_timeout <秒> <命令…>
  local t="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$t"; kill -TERM "$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid"
  local rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  return $rc
}

gh_fetch() { # gh_fetch <完整 URL> <落地路径>
  local url="$1" dst="$2" cache pre rel
  cache="$(dirname "$dst")"; mkdir -p "$cache"
  if [ -s "$dst" ]; then
    note "已缓存 $(basename "$dst")（$(du -h "$dst" | awk '{print $1}')）"
    return 0
  fi
  rel="${url#https://github.com/}"
  for pre in "" "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/" "https://mirror.ghproxy.com/"; do
    if [ -z "$pre" ]; then
      note "下载 $(basename "$dst") ← 直连"
    else
      note "下载 $(basename "$dst") ← 镜像 ${pre}"
    fi
    if curl -fL --connect-timeout 10 --retry 1 --max-time 300 -o "$dst.part" "${pre}${url}" 2>/dev/null; then
      mv -f "$dst.part" "$dst"
      return 0
    fi
    rm -f "$dst.part"
  done
  return 1
}

# --------------------------------------------------------------------------- 资源清单（与 install-sd.ps1 同源、同 sha）
# 目录约定：checkpoint → models/Stable-diffusion，VAE → models/VAE，LoRA → models/Lora，Embedding → models/embeddings
CATALOG_ROWS=()   # "kind|subdir|name|repo|file|sha|tag"
add_row() { CATALOG_ROWS+=("$1"); }

model_row() {
  case "$1" in
    awpainting)  add_row "model|Stable-diffusion|AWPainting_v1.2.safetensors|sam749/AWPainting-v1-2|awpainting_v12.safetensors|3d1b3c42ec704f3397d9e2968e3e544eda111741e10793afd78faa8148b36e12|默认·通用（官方推荐 CLIP skip 2）";;
    revanimated) add_row "model|Stable-diffusion|revAnimated_v11.safetensors|hanafuusen2001/ReVAnimated|revAnimated_v11.safetensors|d725be5d187c172fbabfb2d35cf6bff2237367a8c1cf743d03c1c0e57f0e43fa|动漫综合";;
    anythingv5)  add_row "model|Stable-diffusion|AnythingV5V3_v5PrtRE.safetensors|ckpt/anything-v5.0|AnythingV5V3_v5PrtRE.safetensors|7f96a1a9ca9b3a3242a9ae95d19284f0d2da8d5282b42d2d974398bf7663a252|动漫 anything v5";;
    majicmix)    add_row "model|Stable-diffusion|majicmixRealistic_v7.safetensors|digiplay/majicMIX_realistic_v7|majicmixRealistic_v7.safetensors|7c819b6d13663ed720c2254f4fe18373107dfef2448d337913c8fc545640881e|写实（麦橘写实 v7）";;
    darksushi)   add_row "model|Stable-diffusion|darkSushiMixMix_brighterPruned.safetensors|mdl-mirror/dark-sushi-mix|darkSushiMixMix_brighterPruned.safetensors|099e07547a45dc501a96a7b613e5bfe502be9477199172ca29821882dd8350a1|二次元·大颗寿司";;
    none) :;;
    *) echo "清单里没有模型键 '$1'。可用：awpainting / revanimated / anythingv5 / majicmix / darksushi / none" >&2; exit 1;;
  esac
}
vae_row() {
  case "$1" in
    mse)      add_row "vae|VAE|vae-ft-mse-840000-ema-pruned.safetensors|stabilityai/sd-vae-ft-mse-original|vae-ft-mse-840000-ema-pruned.safetensors|735e4c3a447a3255760d7f86845f09f937809baa529c17370d83e4c3758f3c75|通用·不发灰（写进 config 默认）";;
    animevae) add_row "vae|VAE|animevae.pt|akibanzu/animevae|animevae.pt|f921fb3f29891d2a77a6571e56b8b5052420d2884129517a333c60b1b4816cdf|动漫·anything 系专用";;
    none) :;;
    *) echo "清单里没有 VAE 键 '$1'。可用：mse / animevae / none" >&2; exit 1;;
  esac
}
lora_row() {
  case "$1" in
    add_detail)   add_row "lora|Lora|add_detail.safetensors|OedoSoldier/detail-tweaker-lora|add_detail.safetensors|47aaaf0d2945ca937151d61304946dd229b3f072140b85484bc93e38f2a6e2f7|细节增强 LoRA";;
    easynegative) add_row "emb|embeddings|EasyNegative.safetensors|embed/EasyNegative|EasyNegative.safetensors|c74b4e810b030f6b75fde959e2db678c268d07115b85356d3c0138ba5eb42340|负面嵌入·通用质量底线";;
    badhandv4)    add_row "emb|embeddings|badhandv4.safetensors|Eugeoter/badhandv4|badhandv4.safetensors|6836f178cc41a5436730afded6cbe2bdcef61663b1ad2d2f83ad028019a0ff98|手部修复嵌入";;
    none) :;;
    *) echo "清单里没有 LoRA 键 '$1'。可用：add_detail / easynegative / badhandv4 / none" >&2; exit 1;;
  esac
}

split_keys() { # 逗号多选 → 逐行
  local IFS=','; local k
  for k in $1; do k="$(printf '%s' "$k" | tr -d '[:space:]')"; [ -n "$k" ] && echo "$k"; done
}

# ★ 两个 git 坎（都在本机实测踩到，缺一不可）：
#
#   ① **Xcode 许可未同意 → /usr/bin/git 直接 rc=69**
#      `xcode-select -p` 指向 /Applications/Xcode.app 时，`/usr/bin/git` 是 Xcode 的 shim，
#      没跑过 `sudo xcodebuild -license` 就一律拒绝执行（连 `git init` 都不行），
#      而同机装的 Command Line Tools 里那份 git **不需要许可**。所以这里逐个试、选一个能跑的，
#      并 `export GIT=<绝对路径>` —— launch_utils.py 第一行就是
#      `git = os.environ.get('GIT', "git")`，A1111 自己 clone 子仓库时会用同一份 ✔。
#      （没有 sudo 权限改不了全局：`sudo xcode-select -s /Library/Developer/CommandLineTools`
#        或 `sudo xcodebuild -license accept` 是另外的解法，但脚本不该替你动系统设置。）
#   ② **HTTP/2 掐断**：GitHub 走 HTTP/2 时常见 `Error in the HTTP2 framing layer` →
#      `RuntimeError: Couldn't clone Stable Diffusion.`。加 `-c http.version=HTTP/1.1` 就正常，
#      但 A1111 是自己 spawn git、插不进参数 —— 用 git 2.31+ 的 GIT_CONFIG_COUNT/KEY_n/VALUE_n
#      环境变量，它对**本进程派生的所有 git**生效（launch.py 继承本脚本环境 → 它调的 git 也继承）。
resolve_git() {
  local c
  if command -v git >/dev/null 2>&1 && git --version >/dev/null 2>&1; then command -v git; return 0; fi
  for c in /Library/Developer/CommandLineTools/usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git \
           /Applications/Xcode.app/Contents/Developer/usr/bin/git; do
    [ -x "$c" ] && "$c" --version >/dev/null 2>&1 && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}
GIT_BIN="${GIT_BIN:-${GIT:-$(resolve_git || true)}}"
[ -n "$GIT_BIN" ] || fail "找不到能用的 git。
  常见原因：xcode-select 指向 Xcode 但没同意许可 —— 在终端跑一次
    sudo xcodebuild -license accept
  或装不需要许可的 Command Line Tools：xcode-select --install
  已有可用 git 的话直接指定：install-sd-macos.sh -Git /path/to/git"
export GIT="$GIT_BIN"
# ★ 光 export GIT 还不够（本机实测的第二层）：A1111 启动时要 `import git`（GitPython，
#   modules/gitpython_hack.py），而 GitPython **不看 GIT 变量**，它自己在 PATH 里找 `git`
#   并跑一次 `git version` 做初始化 —— 于是又撞上 /usr/bin/git 那个 rc=69 的 Xcode shim：
#     ImportError: Failed to initialize: Cmd('git') failed due to: exit code(69)
#   两个办法一起上：
#     1) GIT_PYTHON_GIT_EXECUTABLE —— GitPython 官方认的变量，指到我们选中的那份；
#     2) 在 SD 目录下建一个只放 `git` 软链接的小 bin 目录并**前置到 PATH**，
#        这样连「自己 fork 一个 git 但既不读 GIT 也不读上面变量」的扩展/脚本也一并救到
#        （只软链 git，不整目录前置，免得 CLT 里的别的工具盖掉用户自己的）。
export GIT_PYTHON_GIT_EXECUTABLE="$GIT_BIN"
GIT_SHIM_DIR="$SD/.dsh-bin"
mkdir -p "$GIT_SHIM_DIR" 2>/dev/null
if [ -x "$GIT_BIN" ]; then
  ln -sf "$GIT_BIN" "$GIT_SHIM_DIR/git" && export PATH="$GIT_SHIM_DIR:$PATH" \
    && note "git 兜底：${GIT_SHIM_DIR}/git → ${GIT_BIN}（已前置到 PATH，GitPython/扩展都吃这颗药）"
fi
note "git 就绪：$("$GIT_BIN" --version | awk '{print $3}') → ${GIT_BIN}"
[ "$GIT_BIN" != "$(command -v git 2>/dev/null || echo -)" ] && note "  默认那份 git 不可用（多半是 Xcode 许可未同意），已绕开"

export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0='http.version'        GIT_CONFIG_VALUE_0='HTTP/1.1'
export GIT_CONFIG_KEY_1='http.lowSpeedLimit'  GIT_CONFIG_VALUE_1='1000'
export GIT_CONFIG_KEY_2='http.lowSpeedTime'   GIT_CONFIG_VALUE_2='20'



# macOS 专用：修 Mach-O 零填充段并自检关键依赖（定义要在依赖阶段调用之前，故放这里）
macho_fix() {   # 返回 0 = 关键依赖能 import；1 = 仍不行
  local fixer="$SELF_DIR/fix-macho-zerofill.py" sp="" py3="$VENV_PY" round
  if [ ! -f "$fixer" ]; then
    note "警告：没找到 ${fixer}（要和 install-sd-macos.sh 一起保留），跳过 Mach-O 修复"
  else
    for d in "$SD"/venv/lib/python*/site-packages; do [ -d "$d" ] && sp="$d"; done
    if [ -n "$sp" ]; then
      command -v python3 >/dev/null 2>&1 && py3="$(command -v python3)"   # 纯 stdlib，系统 python3 就够
      "$py3" "$fixer" "$sp" --apply 2>&1 | tail -3
      touch "$SD/.dsh-macho-zerofill.ok"
    else
      note "警告：找不到 venv 的 site-packages，跳过 Mach-O 修复"
    fi
  fi
  for round in 1 2; do
    if "$VENV_PY" -c "import scipy.signal, pytorch_lightning, torchmetrics, cv2, omegaconf" >/dev/null 2>&1; then
      [ "$round" = "1" ] && note "关键依赖导入自检通过（scipy / pytorch_lightning / torchmetrics / cv2 / omegaconf）" \
        || note "第 2 轮自检通过"
      return 0
    fi
    [ "$round" = "1" ] && note "自检未过，再扫一遍 Mach-O（有些 .so 是首次 import 才走到的路径）"
    [ -f "$fixer" ] && "$py3" "$fixer" "${sp:-$SD/venv}" --apply >/dev/null 2>&1
  done
  return 1
}


# ★ HuggingFace 环境：必须在**启动**阶段就带上（判据与插件 buildHfEnv 完全一致，两边共用一份缓存）
#   1. A1111 首次加载要从 HF 拉 openai/clip-vit-large-patch14 的 tokenizer 等零碎文件。
#      国内直连 huggingface.co 的表现不是「报错」而是**每个文件重试 5 次、递增退避**：
#      实测日志里连着 `Retrying in 8s [Retry 5/5]`，一次启动能拖好几分钟，
#      生图请求就在这段时间里一直不返回 → 看起来像「插件超时 bug」，其实是 HF 卡住。
#   2. 默认缓存写 ~/.cache/huggingface，而插件用的是 <SD>/.cache/huggingface ——
#      不对齐的话安装时下过的东西启动时还得再下一遍（换机器/删 SD 目录时也容易掉）。
#   3. 缓存里已经有模型 → 直接离线（HF_HUB_OFFLINE/TRANSFORMERS_OFFLINE），
#      彻底断掉那些重试；空缓存就老老实实走镜像在线下载，别误入离线模式。
export HF_ENDPOINT="${HF_ENDPOINT:-${HF_MIRROR:-https://hf-mirror.com}}"
export HF_HOME="${HF_HOME:-$SD/.cache/huggingface}"
if ls -d "$HF_HOME"/hub/models--* >/dev/null 2>&1 || ls -d "$HF_HOME"/models--* >/dev/null 2>&1; then
  export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
  note "HF 缓存命中（${HF_HOME}）→ 离线模式，不再连 huggingface.co"
else
  note "HF 缓存为空 → 保持在线，走镜像 ${HF_ENDPOINT}（tokenizer 之类的首次下载会落进 ${HF_HOME}）"
fi

# --------------------------------------------------------------------------- ① 环境预检
if [ "$SKIP_PREREQ" != "1" ]; then
  step "① 环境预检"
  [ "$(uname -s)" = "Darwin" ] || fail "本脚本只用于 macOS（Windows 请用 install-sd.ps1）"

  ARCH="$(uname -m)"; note "架构 $ARCH"; [ "$ARCH" = "arm64" ] || note "⚠️ 非 Apple Silicon（${ARCH}），A1111 的 MPS 优化不可用，出图会明显慢"

  FREE_GB="$(df -g "$SD" 2>/dev/null | tail -1 | awk '{print $4}')"
  [ -n "$FREE_GB" ] || FREE_GB="$(df -g / | tail -1 | awk '{print $4}')"
  [ "${FREE_GB:-0}" -ge 15 ] || fail "磁盘可用只有 ${FREE_GB}GB，装 WebUI+依赖+模型至少需要 15GB。换个 -Target（例如外置盘）再来"
  note "磁盘可用 ${FREE_GB}GB"

  PROBE_OK=0
  # 只用 curl 探**下载源**（HF 镜像 / PyPI）；GitHub 归 git 自己探（下面那条），
  # 因为 github.com 的 HTML 页面被墙/被限速并不代表 git 协议不通（本机实测：curl 失败、ls-remote 成功）。
  for u in "$HF_MIRROR" "${PYPI_INDEX:-https://pypi.org/simple/}"; do
    if curl -fsS -o /dev/null -m 12 --head "$u" 2>/dev/null || curl -fsS -o /dev/null -m 12 "$u" 2>/dev/null; then
      note "探活 OK $u"; PROBE_OK=1
    else
      note "探活失败 $u"
    fi
  done
  if with_timeout 25 "$GIT_BIN" ls-remote "$REPO_URL" >/dev/null 2>&1; then
    note "探活 OK github.com（$("$GIT_BIN" --version | awk '{print $3}') + HTTP/1.1）"; PROBE_OK=1
  else
    note "探活失败 $REPO_URL —— 克隆多半要走代理：export HTTPS_PROXY=http://127.0.0.1:7890 后重跑（已存在的目标目录不受影响）"
  fi
  [ "$PROBE_OK" = "1" ] || fail "镜像源全部连不通（HF 镜像 / GitHub / PyPI），先解决网络（代理？）再来"

  # —— Python 3.10：A1111 官方只认 3.10，3.11+/3.13 装依赖会炸
  PY=""
  py_ok() { [ -x "$1" ] && "$1" -c 'import sys; sys.exit(0 if sys.version_info[:2]==(3,10) else 1)' 2>/dev/null; }
  if [ -n "$FORCE_PYTHON" ]; then
    py_ok "$FORCE_PYTHON" && PY="$FORCE_PYTHON" || fail "-Python 指定的解释器不是 3.10：$FORCE_PYTHON"
  else
    for c in python3.10 /opt/homebrew/opt/python@3.10/bin/python3.10 /usr/local/opt/python@3.10/bin/python3.10 /Library/Frameworks/Python.framework/Versions/3.10/bin/python3.10; do
      p="$(command -v "$c" 2>/dev/null || echo "$c")"
      py_ok "$p" && { PY="$p"; break; }
    done
  fi
  if [ -z "$PY" ] && has_cmd conda; then
    note "本机没有现成 python3.10，用 conda 建一个（只建环境，不动你的 base）"
    mkdir -p "$SD" || fail "无法创建目录 ${SD}（外置盘没挂载？）"
    conda env list | grep -q "$SD/.py310" || conda create -y -p "$SD/.py310" python=3.10 >/dev/null 2>&1
    py_ok "$SD/.py310/bin/python" && PY="$SD/.py310/bin/python"
  fi
  if [ -z "$PY" ] && has_cmd brew; then
    note "尝试 brew install python@3.10"
    brew install python@3.10 >/dev/null 2>&1 && py_ok /opt/homebrew/opt/python@3.10/bin/python3.10 && PY=/opt/homebrew/opt/python@3.10/bin/python3.10
  fi
  [ -n "$PY" ] || fail "找不到 Python 3.10。三条路任选：① 装 conda（本脚本会自动 conda create -p $SD/.py310 python=3.10）② brew install python@3.10 ③ pyenv install 3.10.16。装好再用 -Python /path/to/python3.10 重跑"
  note "python 3.10 → $PY ($("$PY" -V 2>&1))"
  export PY
fi

# --------------------------------------------------------------------------- ② WebUI 本体
if [ "$SKIP_CLONE" != "1" ]; then
  step "② 获取 A1111 stable-diffusion-webui"
  if [ -f "$SD/launch.py" ]; then
    note "已存在，跳过克隆：$SD"
  else
    mkdir -p "$(dirname "$SD")" || fail "无法创建父目录：$(dirname "$SD")（外置盘没挂载？）"
    [ -e "$SD" ] && [ ! -d "$SD" ] && fail "$SD 是个文件，不是目录"
    if [ -d "$SD" ] && [ -n "$(ls -A "$SD" 2>/dev/null)" ]; then
      note "目录非空但没有 launch.py，克隆到临时目录再合并"
      tmp="$(mktemp -d)"; "$GIT_BIN" clone --depth 1 "$REPO_URL" "$tmp/webui" || fail "git clone 失败：$REPO_URL"
      cp -R "$tmp/webui/." "$SD/" && rm -rf "$tmp"
    else
      mkdir -p "$SD" && "$GIT_BIN" clone --depth 1 "$REPO_URL" "$SD" || fail "git clone 失败：$REPO_URL"
    fi
    note "commit $(cd "$SD" && "$GIT_BIN" rev-parse --short HEAD 2>/dev/null || echo '-')"
  fi
fi
[ -f "$SD/launch.py" ] || fail "$SD 里没有 launch.py，不是 A1111 WebUI 目录"

# --------------------------------------------------------------------------- ③ venv + 依赖（torch/MPS 交给 A1111 自己按平台装）
if [ "$SKIP_DEPS" != "1" ]; then
  step "③ 建 venv 并装依赖（首次约 10-30 分钟，取决于带宽）"
  [ -n "${PY:-}" ] || PY="$SD/.py310/bin/python"
  [ -x "$PY" ] || fail "找不到可用的 Python 3.10（${PY}）。去掉 -NoPrereq 重跑让它自动准备，或 -Python 指一个 3.10"
  [ -d "$SD/venv" ] || "$PY" -m venv "$SD/venv" || fail "建 venv 失败（目标盘不支持符号链接？换个 -Target 再来）"
  VENV_PY="$SD/venv/bin/python"
  [ -x "$VENV_PY" ] || fail "venv 里没有 bin/python：$VENV_PY"
  note "venv python $("$VENV_PY" -V 2>&1)"

  # 坑7：新版 setuptools 移除了 pkg_resources → A1111 构建 CLIP 源码必失败。
  #   ⚠️ 本机实测：上游 install-sd.ps1 注释里「PIP_CONSTRAINT 会作用到 PEP 517 隔离构建那次」
  #   **并不成立**——pip 给构建环境单独解析 setuptools，照样是最新的（81+ 已删 pkg_resources），
  #   于是 `Failed to build '…/openai/CLIP/archive/….zip' … No module named 'pkg_resources'`。
  #   真正有效的杠杆是关掉构建隔离，让 pip 直接用 venv 里钉好的 setuptools==69.5.1。
  # 坑8：numpy 2.x 与 A1111 不兼容（np.float_ 等已删）。钉住这两项就够，
  #       不再钉 opencv（A1111 自己有版本文件，钉重了 pip 会 ResolutionImpossible）。
  CONSTRAINTS="${TMPDIR:-/tmp}/dsh-sd-bridge-pip-constraints.txt"
  cat > "$CONSTRAINTS" <<'EOF'
# dsh-sd-bridge-guard (macOS) 生成的 pip 约束
setuptools==69.5.1
numpy==1.26.2
EOF
  export PIP_CONSTRAINT="$CONSTRAINTS"
  # 关掉 PEP 517 构建隔离的两种写法（pip 的 dest 是 build_isolation，配置键两种都能匹配上；
  # 本机实测单靠环境变量**没能**挡住 CLIP 的隔离构建，所以下面还要显式预装，这里只作兜底）
  export PIP_NO_BUILD_ISOLATION="${PIP_NO_BUILD_ISOLATION:-1}"
  export PIP_BUILD_ISOLATION="${PIP_BUILD_ISOLATION:-0}"
  # pip 默认「10 次重试 × 60s 连接超时」：GitHub 不通时一个包能白等 10 分钟（本机实测）。
  # 压到 2 次 × 30s，失败早点出声；镜像源（阿里云/ustc）本来也快，不需要长重试。
  export PIP_RETRIES="${PIP_RETRIES:-2}" PIP_TIMEOUT="${PIP_TIMEOUT:-30}"
  export GRADIO_ANALYTICS_ENABLED=False
  [ -n "$PYPI_INDEX" ] && export PIP_INDEX_URL="$PYPI_INDEX" && note "pip 源 $PYPI_INDEX"
  [ -z "$PYPI_INDEX" ] && note "pip 源 PyPI 官方"

  "$VENV_PY" -m pip install -q -U pip wheel "setuptools==69.5.1" || fail "pip 自身升级失败（检查网络/代理，或 -PypiIndex '' 换官方源）"
  "$VENV_PY" -m pip install -q "numpy==1.26.2" || fail "预装 numpy 1.26.2 失败"

  # 坑9：上游 Stability-AI/stablediffusion 已删 → 指给同 commit 的 fork
  export STABLE_DIFFUSION_REPO="$SD_SUBREPO"
  note "子仓库替换 STABLE_DIFFUSION_REPO=$SD_SUBREPO"

  # ★ macOS 必需参数（对齐上游 webui-macos-env.sh 的 COMMANDLINE_ARGS，见文件头 MAC 参数说明）：
  #   直接跑 launch.py 会**绕过 webui.sh**，拿不到这组默认值。实测后果：
  #   prepare_environment 走到 `assert torch.cuda.is_available()` → RuntimeError
  #   "Torch is not able to use GPU; add --skip-torch-cuda-test to COMMANDLINE_ARGS"，依赖永远装不完。
  # Apple Silicon 用上游 mac 默认的 torch 组合（venv 里已有 torch 时 prepare_environment 会跳过这步）
  if [ -z "${TORCH_COMMAND:-}" ]; then
    if [ "$(uname -m)" = "arm64" ]; then export TORCH_COMMAND="pip install torch==2.3.1 torchvision==0.18.1"
    else export TORCH_COMMAND="pip install torch==2.1.2 torchvision==0.16.2"; fi
    note "TORCH_COMMAND=${TORCH_COMMAND}"
  fi

  # ★ CLIP / open_clip 必须**我们自己**先装（本机实测的第二道坎）：
  #   A1111 用 `pip install <GitHub zip>` 装它们，zip 没有预置 wheel → 必须现场构建；
  #   PEP 517 隔离构建环境会**单独**解析一份最新的 setuptools（81+ 删了 pkg_resources），
  #   于是 `Failed to build '…/openai/CLIP/archive/….zip' … ModuleNotFoundError: pkg_resources`，
  #   而且 PIP_CONSTRAINT / PIP_NO_BUILD_ISOLATION 都挡不住它（隔离环境不受 constraint 管辖）。
  #   解法：用 venv 里钉死的 setuptools==69.5.1、**显式加 --no-build-isolation** 先装好；
  #   A1111 的安装带 `if not is_installed("clip")` 护栏，装过就跳过，不会再走隔离构建。
  #   URL 与 launch_utils.py 的默认值逐字一致（同一 commit），可用 CLIP_PACKAGE/OPENCLIP_PACKAGE 覆盖。
  CLIP_ZIP="${CLIP_PACKAGE:-https://github.com/openai/CLIP/archive/d50d76daa670286dd6cacf3bcd80b5e4823fc8e1.zip}"
  OPENCLIP_ZIP="${OPENCLIP_PACKAGE:-https://github.com/mlfoundations/open_clip/archive/bb6e834e9c70d9c27d0dc3ecedeebeaeb1ffad6b.zip}"
  GH_CACHE="$SD/.cache/dsh/github"
  for _pkg in "$CLIP_ZIP" "$OPENCLIP_ZIP"; do
    _dst="$GH_CACHE/$(basename "${_pkg%%\?*}")"
    gh_fetch "$_pkg" "$_dst" \
      || fail "下载 $_pkg 失败：直连和 4 个 gh 镜像前缀都不通。
     挂代理重跑（export HTTPS_PROXY=http://127.0.0.1:7890），或把包名指到可用地址：
       CLIP_PACKAGE="https://…/CLIP/archive/d50d76da….zip" bash install-sd-macos.sh …"
    if ! "$VENV_PY" -m pip install --no-build-isolation -q "$_dst"; then
      fail "预装 $_dst 失败（pip 输出见上；这是 A1111 依赖里唯一需要现场构建的两个包）"
    fi
  done
  note "clip / open_clip 预装完成（A1111 的 is_installed 护栏会跳过隔离构建）"

  # ★ 子仓库**我们自己先克隆**（本机实测的第三道坎）：
  #   A1111 用 `git clone "https://github.com/…"` 拉 5 个子仓库，GitHub 在部分网络下会
  #   `fatal: unable to access …: Error in the HTTP2 framing layer` → `RuntimeError: Couldn't clone
  #   Stable Diffusion.`，整轮依赖安装白跑（实测踩到）。而 launch_utils 的 git_clone 是
  #   「目录已存在 **且** HEAD == 目标 commit 就 return」，所以提前按 commit 精准 fetch 好，
  #   它就不再联网。commit/URL 都**从本机 launch_utils.py 里读**（不写死，上游改了自动跟上）：
  #   有效 URL = 同名环境变量覆盖值 ?? 文件里的默认值（STABLE_DIFFUSION_REPO 已被上游删库，
  #   上面 export 的 camenduru fork 会在这里生效）。每个仓库：直连 → gitclone.com → ghfast.top，
  #   全部 HTTP/1.1 + 低速断开；先 --depth 1 按 SHA 精准 fetch，服务端不收就退回整仓克隆。
  step "③.5 按 commit 预克隆子仓库（URL/commit 取自 launch_utils.py）"
  LU="$SD/modules/launch_utils.py"
  [ -f "$LU" ] || fail "找不到 ${LU}，无法解析子仓库 commit（-SkipClone 后重跑）"

  lu_default() {   # $1 = 环境变量名，取 launch_utils.py 里 os.environ.get('X', "默认值") 的默认值
    LC_ALL=C python3 -c '
import re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
m = re.search(chr(39) + sys.argv[2] + chr(39) + r"\s*,\s*[\x22\x27]([^\x22\x27]+)[\x22\x27]", txt)
print(m.group(1) if m else "")
' "$LU" "$1"
  }

  preclone_repo() {   # $1=repositories 下的目录名  $2=仓库 URL  $3=目标 commit
    local dir="$SD/repositories/$1" url="$2" sha="$3" slug mirrors m
    [ -n "$url" ] && [ -n "$sha" ] || { note "跳过 $1（launch_utils.py 里没解析到 URL/commit，交给 A1111 自己克隆）"; return 0; }
    if [ -d "$dir/.git" ] && [ "$("$GIT_BIN" -C "$dir" rev-parse HEAD 2>/dev/null || echo -)" = "$sha" ]; then
      note "已就位 $1"
      return 0
    fi
    [ -d "$dir" ] && { note "清掉不完整的 $1 再重克隆"; rm -rf "$dir"; }
    mirrors="$url"
    case "$url" in
      https://github.com/*) slug="${url#https://github.com/}"
        mirrors="$url https://ghfast.top/https://github.com/$slug https://gh-proxy.com/https://github.com/$slug https://ghproxy.net/https://github.com/$slug https://gitclone.com/github.com/$slug" ;;
    esac
    for m in $mirrors; do
      if "$GIT_BIN" init -q "$dir" 2>/dev/null \
         && with_timeout 60 "$GIT_BIN" -C "$dir" fetch -q --depth 1 "$m" "$sha" 2>/dev/null \
         && "$GIT_BIN" -C "$dir" checkout -q FETCH_HEAD 2>/dev/null; then
        "$GIT_BIN" -C "$dir" remote add origin "$m" 2>/dev/null || "$GIT_BIN" -C "$dir" remote set-url origin "$m"
        "$GIT_BIN" -C "$dir" config core.filemode false
        note "预克隆 $1（精准 fetch ${sha}）← $m"
        return 0
      fi
      rm -rf "$dir"
      if with_timeout 240 "$GIT_BIN" clone -q --config core.filemode=false "$m" "$dir" 2>/dev/null \
         && "$GIT_BIN" -C "$dir" checkout -q "$sha" 2>/dev/null; then
        note "预克隆 $1（整仓克隆后 checkout ${sha}）← $m"
        return 0
      fi
      rm -rf "$dir"
    done
    return 1
  }

  preclone_from_lu() {   # $1=目录名 $2=REPO 环境变量名 $3=COMMIT_HASH 环境变量名
    local name="$1" renv="$2" cenv="$3" url sha
    url="${!renv:-$(lu_default "$renv")}"     # 环境变量覆盖优先（例如被删库的 STABLE_DIFFUSION_REPO）
    sha="$(lu_default "$cenv")"
    preclone_repo "$name" "$url" "$sha" \
      || fail "预克隆 $name 失败：$url @ $sha
     挂代理后重跑本脚本，或手动执行：
       git clone $url $SD/repositories/$name && git -C $SD/repositories/$name checkout $sha"
  }

  mkdir -p "$SD/repositories"
  preclone_from_lu "stable-diffusion-stability-ai"  "STABLE_DIFFUSION_REPO"      "STABLE_DIFFUSION_COMMIT_HASH"
  preclone_from_lu "generative-models"              "STABLE_DIFFUSION_XL_REPO"   "STABLE_DIFFUSION_XL_COMMIT_HASH"
  preclone_from_lu "k-diffusion"                    "K_DIFFUSION_REPO"           "K_DIFFUSION_COMMIT_HASH"
  preclone_from_lu "BLIP"                            "BLIP_REPO"                 "BLIP_COMMIT_HASH"
  preclone_from_lu "stable-diffusion-webui-assets"  "ASSETS_REPO"                "ASSETS_COMMIT_HASH"

  # --exit-after-start = 跑完 prepare_environment（装 torch/依赖）后退出。
  #   注意：A1111 的 main() 在退出前**还要 import webui**，而新版 macOS 的 dyld 会在
  #   `import pytorch_lightning → torchmetrics → import scipy.signal` 处拒载老 wheel（见 ③.7）。
  #   也就是说：**依赖其实装完了，只是这一轮以 import 崩溃收场**。所以这里不能一见到非零返回码
  #   就重试/放弃 —— 先修 Mach-O 再自检，仍然不行才换 torch 组合重试，最后才报错。
  DEPS_LOG="$SD/.dsh-deps-install.log"
  run_deps_pass() {   # 跑一轮 A1111 的依赖安装，返回它的退出码（不 fail，交给上层判断）
    "$VENV_PY" "$SD/launch.py" --skip-calltest --exit-after-start --api --nowebui --skip-version-check \
      --listen 127.0.0.1 --port "$PORT" "${MAC_ARGS[@]}" > "$DEPS_LOG" 2>&1
  }

  run_deps_pass || note "（A1111 这一轮以非零码结束，先按 ③.7 修 Mach-O 再判断，别急着认定失败）"
  if macho_fix; then
    note "依赖就绪"
  else
    note "修完仍不行，看 $DEPS_LOG 末尾："
    tail -15 "$DEPS_LOG" | sed 's/^/     /'
    if [ "$PYTHON_FALLBACK" = "1" ]; then
      note "改用已知可用的 arm64 MPS torch 组合（2.3.1/0.18.1）重试一次"
      "$VENV_PY" -m pip install -q torch==2.3.1 torchvision==0.18.1 || fail "重试装 torch 失败（详见 ${DEPS_LOG}）"
      run_deps_pass || true
      macho_fix || fail "依赖装不下来，完整日志：${DEPS_LOG}"
    else
      # 非 arm64（Intel）或用户自己指定过 TORCH_COMMAND：直接重试一次原路径
      note "重试一轮依赖安装"
      run_deps_pass || true
      macho_fix || fail "依赖装不下来，完整日志：${DEPS_LOG}（可加 -Target 换盘、或 -PypiIndex '' 换源后重跑本脚本）"
    fi
  fi
fi
VENV_PY="$SD/venv/bin/python"
[ -x "$VENV_PY" ] || fail "venv 不可用：${VENV_PY}（去掉 -SkipDeps 重跑）"

# -SkipDeps 也要过一遍 Mach-O 检查（依赖早就装好、只是被新版 dyld 拦住的机器）
if [ "$SKIP_DEPS" = "1" ]; then
  step "③.7 修 Mach-O 零填充段（-SkipDeps 下单独自检）"
  macho_fix || fail "关键依赖 import 不过，去掉 -SkipDeps 重跑本脚本"
fi

# --------------------------------------------------------------------------- 关于 ③.7（Mach-O 零填充段）
# macho_fix() 的定义在上面的「工具函数区」—— bash 自上而下执行，依赖阶段（③）就要调用它，
# 所以必须先定义；这里只留这份说明，方便后来人查到这条坑。
# 新版 macOS 的 dyld 会**拒绝加载**「零填充段（__bss / __thread_bss）的 offset 字段非零」的
# Mach-O —— 而 PyPI 上按老工具链（ld64 / Xcode 14 那批 CI 镜像）构建的 wheel 正带着这个垃圾值。
# 本机实测：scipy 1.15.3（Python 3.10 能装到的最后一版）里 32 个 .so 中招 ——
# 依赖明明装完了，WebUI 一启动就崩在 initialize.imports()：
#   import pytorch_lightning → torchmetrics → import scipy.signal
#   ImportError: dlopen(..._spropack.cpython-310-darwin.so):
#     (section '__DATA/__thread_bss' has a zero-fill section type, but offset field is not zero)
# 这个字段对零填充段本来就没有语义（dyld 只看 addr/size，内容全零），置 0 即可；
# 但 arm64 的签名覆盖文件内容，改完**必须**重新 ad-hoc 签名，否则进程会被 SIGKILL。
# 实现与逐段说明见同包 fix-macho-zerofill.py（纯 stdlib，不依赖第三方包）。

# --------------------------------------------------------------------------- ④ 资源清单（模型 / VAE / LoRA / Embedding）
step "④ 资源清单下载"
[ "$SKIP_MODEL" = "1" ] && MODELS="" ; [ "$SKIP_VAE" = "1" ] && VAES="" ; [ "$SKIP_LORA" = "1" ] && LORAS=""
for k in $(split_keys "$MODELS"); do model_row "$k"; done
for k in $(split_keys "$VAES");   do vae_row "$k";   done
for k in $(split_keys "$LORAS");  do lora_row "$k";  done

SUMMARY=()
if [ "${#CATALOG_ROWS[@]}" -gt 0 ]; then
  for row in "${CATALOG_ROWS[@]}"; do
    IFS='|' read -r kind sub name repo file sha tag <<< "$row"
    dst="$SD/models/$sub/$name"
    mkdir -p "$SD/models/$sub" || fail "无法创建 $SD/models/${sub}（挂载是只读？）"
    url="$(hf_url "$repo" "$file")"
    step "拉 $kind · ${name}（${tag}）"
    note "$url"
    before="$(sha_of "$dst" 2>/dev/null)"
    fetch "$url" "$dst" "$sha"
    after="$(sha_of "$dst")"
    if [ "$before" = "$after" ] && [ -n "$before" ]; then SUMMARY+=("$name|$sub|已存在"); else SUMMARY+=("$name|$sub|已下载/校验通过"); fi
  done
else
  note "清单为空（-SkipModel/-SkipVae/-SkipLora 或 none），跳过"
fi

# --------------------------------------------------------------------------- ⑤ config.json 质量默认（“新装出图很差”的两个根因）
if [ "$NO_CONFIG" != "1" ]; then
  step "⑤ 写 config.json 质量默认"
  # ⚠️ bash 3.2（macOS 自带那个）+ set -u 下，**空数组**写 "${ARR[@]}" 会直接报
  #   `CATALOG_ROWS[@]: unbound variable`（-SkipModel -SkipVae -SkipLora 全开时必然触发，实测踩过）。
  #   标准绕法：${ARR[@]+"${ARR[@]}"} —— 数组没元素时整段展开为空，有元素时保持逐项引用。
  FIRST_MODEL="$(printf '%s\n' ${CATALOG_ROWS[@]+"${CATALOG_ROWS[@]}"} | awk -F'|' '$1=="model"{print $3; exit}')"
  FIRST_VAE="$(printf '%s\n' ${CATALOG_ROWS[@]+"${CATALOG_ROWS[@]}"} | awk -F'|' '$1=="vae"{print $3; exit}')"
  CFG="$SD/config.json" "$VENV_PY" - "$FIRST_MODEL" "$FIRST_VAE" <<'PYEOF'
import json, os, sys
cfg_path = os.environ["CFG"]
model, vae = (sys.argv[1] if len(sys.argv) > 1 else ""), (sys.argv[2] if len(sys.argv) > 2 else "")
data = {}
if os.path.exists(cfg_path):
    try:
        data = json.load(open(cfg_path, encoding="utf-8"))
    except Exception:
        data = {}
sd = data.setdefault("sd_model_checkpoint", "")
if model:
    data["sd_model_checkpoint"] = model
if vae:
    data["sd_vae"] = vae
data["CLIP_stop_at_last_layers"] = data.get("CLIP_stop_at_last_layers") or 2
data["samples_filename_pattern"] = data.get("samples_filename_pattern") or ""
json.dump(data, open(cfg_path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print("   config.json: checkpoint=%s vae=%s clip_skip=%s" % (data.get("sd_model_checkpoint"), data.get("sd_vae"), data.get("CLIP_stop_at_last_layers")))
PYEOF
  note "AWPainting 官方推荐 CLIP skip 2；SD1.5 base + 自带 VAE 是「糊、灰」的主要来源"
fi

# --------------------------------------------------------------------------- ⑥ 安装记录（插件零配置读到；必须无 BOM）
step "⑥ 写安装记录 ~/.dsh-sd-bridge.json"
REC="${HOME}/.dsh-sd-bridge.json"
VENV_PY="$SD/venv/bin/python" "$VENV_PY" - "$SD" "$SD/venv/bin" "$PORT" <<'PYEOF' || fail "写安装记录失败：$REC"
import datetime, json, os, sys
sd, pydir, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
path = os.path.join(os.path.expanduser("~"), ".dsh-sd-bridge.json")
old = {}
if os.path.exists(path):
    try:
        old = json.load(open(path, encoding="utf-8"))
    except Exception:
        old = {}
old.update({"sdDir": sd, "pythonDir": pydir, "pythonBin": pydir + "/python", "port": port,
            "platform": "darwin",
            "installer": "install-sd-macos.sh",
            "installedAt": datetime.datetime.now().isoformat(timespec="seconds")})
with open(path, "w", encoding="utf-8") as f:      # 无 BOM（坑10）
    f.write(json.dumps(old, indent=2, ensure_ascii=False) + "\n")
print("   " + path + " → " + sd)
PYEOF

# --------------------------------------------------------------------------- ⑦ 拉起 API 供自检
if [ "$SERVE" = "1" ]; then
  step "⑦ 启动 SD API（纯后台、不开浏览器）并等待就绪"
  mkdir -p "$SD/.dsh-run"
  # 再声明一遍（上面的导出对**本脚本**生效，这里只是把话写在建日志旁边，方便人读）：
  # 启动必须带上 GIT / GIT_PYTHON_GIT_EXECUTABLE / PATH 三件套，缺一个就是 rc=69 的 Xcode 许可坑。
  note "启动环境：GIT=${GIT_BIN} · HF_ENDPOINT=${HF_ENDPOINT} · HF_HOME=${HF_HOME} · 离线=${HF_HUB_OFFLINE:-0}"
  nohup "$VENV_PY" "$SD/launch.py" --api --nowebui --skip-prepare-environment --skip-version-check --port "$PORT" \
    "${MAC_ARGS[@]}" > "$SD/.dsh-run/api.log" 2>&1 &
  SRV=$!
  note "pid ${SRV}，日志 $SD/.dsh-run/api.log"
  READY=0
  for i in $(seq 1 80); do
    sleep 6
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PORT/sdapi/v1/options" || echo 000)"
    if [ "$code" = "200" ]; then READY=1; note "API 就绪（第 $i 次探测，累计约 $((i * 6)) 秒）"; break; fi
    kill -0 $SRV 2>/dev/null || { tail -20 "$SD/.dsh-run/api.log" | sed 's/^/     /'; fail "SD 进程已退出，见 $SD/.dsh-run/api.log"; }
  done
  [ "$READY" = "1" ] || { tail -20 "$SD/.dsh-run/api.log" | sed 's/^/     /'; fail "等了 480 秒 API 还没就绪（首次加载模型可能更久），日志：$SD/.dsh-run/api.log"; }
fi

# --------------------------------------------------------------------------- 汇总
say ""
say "================ 资源清单汇总 ================"
printf '%-44s %-18s %s\n' "文件" "目录" "状态"
for s in ${SUMMARY[@]+"${SUMMARY[@]}"}; do
  IFS='|' read -r n d st <<< "$s"
  printf '%-44s %-18s %s\n' "${n:--}" "${d:--}" "${st:--}"
done
say "=============================================="
say "WebUI 目录 : $SD"
say "venv python: $SD/venv/bin/python"
say "API        : http://127.0.0.1:$PORT （$([ "$SERVE" = 1 ] && echo '已在跑' || echo '未启动，插件首次生图时会自己拉起')）"
say ""
say "下一步：重启 DeepSeek Harness（或让 Harness 直接生一张图），插件会自动读到上面的记录，零配置可用。"
