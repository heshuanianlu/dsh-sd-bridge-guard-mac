#!/usr/bin/env bash
# sd-direct.sh —— 直连本机 SD API，独立出图，不经会话页面（macOS / Linux 版，等价于 sd-direct.ps1）
# 用法示例:
#   bash sd-direct.sh -Prompt "1girl, silver hair, masterpiece" -Negative "lowres, watermark"
#   bash sd-direct.sh -Prompt "..." -InitImage "/path/ref.jpg" -Denoising 0.65
#   bash sd-direct.sh -Prompt "flower crown" -InitImage "/path/a.png" -Mask "/path/a_mask.png" -Denoising 0.6
#   bash sd-direct.sh -Prompt "..." -Width 640 -Height 960 -Steps 24 -Seed 12345
#   bash sd-direct.sh -Prompt "..." -SdDir "/Volumes/盘/stable-diffusion-webui"
#   bash sd-direct.sh -Prompt "..." -NoStart                 # SD 没开时不自动拉起，直接报错退出
# 跨机器说明（别人拿到这条命令直接就能跑）:
#   - -OutDir 不传时默认存到「当前目录/SD-Picture」；插件生成命令时会显式注入 -OutDir。
#   - SD API 没在跑时本脚本**自己把它拉起来**：目录按 -SdDir > 环境变量 DSH_SD_DIR >
#     ~/.dsh-sd-bridge.json 自举记录 > $HOME 与 /Volumes/* 下常见安装名扫描查找，
#     启动后轮询到就绪为止（首次含模型加载约 1-3 分钟，日志在 $TMPDIR/dsh-sd-direct-launch.log*）。
#   - 任何一步失败都**只报一条明确错误并 exit 1**，绝不往下级联报错。
#   - 依赖：curl（必需）+ jq 或 python3（解析响应，二选一）；其余全用 bash 内建。
# 跑完行为：保存成功后自动用默认看图器 **open** 这张图；不想要就加 -NoOpen。

set -uo pipefail

PROMPT=""; NEGATIVE="lowres, bad anatomy, bad hands, watermark, text, worst quality"
INIT_IMAGE=""; MASK=""; MASK_BLUR=4; INPAINT_FILL=0; MASK_INVERT=0; NO_FULL_RES=0; INPAINT_PADDING=32
DENOISING="0.55"; WIDTH=640; HEIGHT=960; STEPS=24; SAMPLER="DPM++ 2M"; CFG="7"; SEED="-1"
OUT_DIR=""; NAME="direct"; API_BASE="http://127.0.0.1:7860"; SD_DIR=""
START_TIMEOUT=300; NO_START=0; NO_OPEN=0

fail() { echo ""; echo "错误：$1"; [ -n "${2:-}" ] && echo "$2"; exit 1; }
need_val() { [ $# -ge 2 ] && [ -n "$2" ] || fail "参数 $1 缺少取值" "用法见文件头注释（bash sd-direct.sh -h）。"; }

# 旗标名大小写不敏感，兼容 -Foo / --foo 两种写法（与 PowerShell 版同一套参数名）
while [ $# -gt 0 ]; do
  key="${1#-}"; key="${key#-}"; key="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  shift
  case "$key" in
    prompt)                PROMPT="${1:?}"; shift ;;
    negative|negativeprompt) NEGATIVE="${1:?}"; shift ;;
    initimage)             INIT_IMAGE="${1:?}"; shift ;;
    mask)                  MASK="${1:?}"; shift ;;
    maskblur)              MASK_BLUR="${1:?}"; shift ;;
    inpaintfill)           INPAINT_FILL="${1:?}"; shift ;;
    maskinvert)            MASK_INVERT=1 ;;
    nofullres)             NO_FULL_RES=1 ;;
    inpaintpadding)        INPAINT_PADDING="${1:?}"; shift ;;
    denoising|denoisingstrength) DENOISING="${1:?}"; shift ;;
    width)                 WIDTH="${1:?}"; shift ;;
    height)                HEIGHT="${1:?}"; shift ;;
    steps)                 STEPS="${1:?}"; shift ;;
    sampler)               SAMPLER="${1:?}"; shift ;;
    cfg)                   CFG="${1:?}"; shift ;;
    seed)                  SEED="${1:?}"; shift ;;
    outdir)                OUT_DIR="${1:?}"; shift ;;
    name)                  NAME="${1:?}"; shift ;;
    apibase)               API_BASE="${1:?}"; shift ;;
    sddir)                 SD_DIR="${1:?}"; shift ;;
    starttimeout)          START_TIMEOUT="${1:?}"; shift ;;
    nostart)               NO_START=1 ;;
    noopen)                NO_OPEN=1 ;;
    h|help)                sed -n '2,20p' "$0"; exit 0 ;;
    *) fail "未知参数：-$key" "bash sd-direct.sh -h 看用法"; ;;
  esac
done
[ -n "$PROMPT" ] || fail "缺少必填参数 -Prompt" "例如：bash sd-direct.sh -Prompt \"1girl, silver hair, masterpiece\""

command -v curl >/dev/null 2>&1 || fail "本机没有 curl" "brew install curl，或改用插件的 sd_* 工具出图。"
if command -v jq >/dev/null 2>&1; then JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then JSON_TOOL=python3
else fail "既没有 jq 也没有 python3，无法解析 SD 的 JSON 响应" "brew install jq"; fi

[ -z "$OUT_DIR" ] && OUT_DIR="$(pwd)/SD-Picture"
API_BASE="${API_BASE%/}"
PORT="${API_BASE##*:}"; PORT="${PORT%%/*}"
case "$PORT" in ''|*[!0-9]*) PORT=7860 ;; esac
TMP="${TMPDIR:-/tmp}"
LAUNCH_LOG="$TMP/dsh-sd-direct-launch.log"
LAUNCH_LOG_ERR="$TMP/dsh-sd-direct-launch.log.err"
STATE_FILE="$HOME/.dsh-sd-bridge.json"

# macOS 冷启动比 Windows 慢（checkpoint 可能在外接盘上、torch 首次要现编译 MPS 内核），
# 默认的 300s 容易在「其实再等一会儿就好」的时候误报超时 → 没被显式指定时抬到 900s。
if [ "$(uname -s)" = "Darwin" ] && [ "$START_TIMEOUT" = "300" ]; then
  START_TIMEOUT=900
fi

api_ready() { [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$API_BASE/sdapi/v1/options" 2>/dev/null)" = "200" ]; }
port_busy_other() { [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$API_BASE/" 2>/dev/null)" != "000" ]; }
record_field() { # 从自举记录里取字段（无 BOM JSON）；没有就返回空
  [ -f "$STATE_FILE" ] || return 0
  if [ "$JSON_TOOL" = "jq" ]; then jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE" 2>/dev/null
  else python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8-sig")); v=d.get(sys.argv[2]); print(v if isinstance(v,str) else "")' "$STATE_FILE" "$1" 2>/dev/null; fi
}

# SD WebUI 目录：-SdDir > DSH_SD_DIR > 自举记录 > $HOME 常见名 > /Volumes/* 常见名
find_sd_dir() {
  local c n names="stable-diffusion-webui stable-diffusion-webui-master sd-webui sd.webui webui a1111 SD sd"
  local cands=()
  [ -n "$SD_DIR" ] && cands+=("$SD_DIR")
  [ -n "${DSH_SD_DIR:-}" ] && cands+=("$DSH_SD_DIR")
  local rec; rec="$(record_field sdDir)"; [ -n "$rec" ] && cands+=("$rec")
  for n in stable-diffusion-webui sd-webui sd.webui webui a1111 SD sd; do
    cands+=("$HOME/$n" "$HOME/Desktop/$n" "$HOME/Downloads/$n" "/opt/$n" "/usr/local/$n")
  done
  if [ -d /Volumes ]; then
    for c in /Volumes/*; do
      [ -d "$c" ] || continue
      for n in $names; do cands+=("$c/$n"); done
    done
  fi
  for c in "${cands[@]}"; do
    [ -n "$c" ] || continue
    [ -f "$c/launch.py" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 0
}

# 解释器：SD 自带 venv > 自举记录 > PATH
find_python() { # find_python <sd_dir>
  local sd="$1" c rec
  for c in "$sd/venv/bin/python" "$sd/venv/bin/python3" "$sd/python/bin/python3" "$sd/python3.10/bin/python"; do
    [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  rec="$(record_field pythonBin)"; [ -n "$rec" ] && [ -x "$rec" ] && { printf '%s\n' "$rec"; return 0; }
  rec="$(record_field pythonDir)"; [ -n "$rec" ] && [ -x "$rec/python3" ] && { printf '%s\n' "$rec/python3"; return 0; }
  [ -n "$rec" ] && [ -x "$rec/python" ] && { printf '%s\n' "$rec/python"; return 0; }
  command -v python3 >/dev/null 2>&1 && { command -v python3; return 0; }
  return 0
}

hf_cache_has_models() { # 命中 <sd>/.cache/huggingface 里的 models--* 才走离线（与插件同判据）
  local hf="$1/.cache/huggingface" d
  for d in "$hf/hub" "$hf"; do
    [ -d "$d" ] || continue
    ls -d "$d"/models--* >/dev/null 2>&1 && return 0
  done
  return 1
}

start_sd_api_if_needed() {
  api_ready && return 0
  port_busy_other && fail "端口 $PORT 已被其它服务占用，而且它不是 SD API" \
    "换一个端口（-ApiBase http://127.0.0.1:<新端口>），或先关掉占用该端口的程序。"
  [ "$NO_START" = "1" ] && fail "SD API 未运行（${API_BASE}），且指定了 -NoStart" \
    "先手动启动 SD 的 API 模式，或去掉 -NoStart 让脚本自动拉起。"

  local sd; sd="$(find_sd_dir)"
  [ -n "$sd" ] || fail "本机找不到 SD WebUI 目录（需要含 launch.py）" \
    "用 -SdDir \"/你的/SD目录\" 指定，或设环境变量 DSH_SD_DIR，或跑插件自带的 install-sd-macos.sh 安装。"
  local py; py="$(find_python "$sd")"
  [ -n "$py" ] || fail "在 $sd 下找不到 venv/bin/python，PATH 里也没有 python3" \
    "跑 install-sd-macos.sh 让它自举（Python 3.10 + venv + torch/MPS）。"
  [ -f "$sd/launch.py" ] || fail "$sd/launch.py 不存在"

  local prepared=0 args=()
  if [ -d "$sd/venv" ] || [ -d "$sd/python" ] || [ -d "$sd/.py310" ]; then prepared=1; fi
  args=("$sd/launch.py" --api --nowebui --port "$PORT")
  [ "$prepared" = "1" ] && args+=(--skip-prepare-environment)
  args+=(--skip-version-check)
  # macOS 必需参数（对齐上游 webui-macos-env.sh 的 COMMANDLINE_ARGS）：本脚本直接 spawn
  # python launch.py，**绕过了 webui.sh**，少了这组就会在 prepare_environment 里
  # `RuntimeError: Torch is not able to use GPU; add --skip-torch-cuda-test`（本机实测踩过）。
  # --upcast-sampling / --no-half-vae 避开 MPS fp16 溢出（花图/黑图）；interrogate 走 CPU 更稳。
  if [ "$(uname -s)" = "Darwin" ]; then
    args+=(--skip-torch-cuda-test --upcast-sampling --no-half-vae --use-cpu interrogate)
    export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"
  fi
  # DSH_SD_EXTRA_ARGS：空格分隔的追加参数（与插件设置里的 extraArgs 等价，例如 "--medvram"）
  if [ -n "${DSH_SD_EXTRA_ARGS:-}" ]; then
    for _a in $DSH_SD_EXTRA_ARGS; do args+=("$_a"); done
  fi

  # HF 环境（与插件一致）：缓存命中就离线加载，避免连 huggingface.co 每文件重试 5×10s 卡死；
  # 缓存为空则保持联网并走镜像。DSH_SD_HF_ONLINE=1 可强制联网。
  export GRADIO_ANALYTICS_ENABLED=False
  [ -n "${HF_ENDPOINT:-}" ] || export HF_ENDPOINT="https://hf-mirror.com"
  if [ "${DSH_SD_HF_ONLINE:-}" != "1" ] && hf_cache_has_models "$sd"; then
    export HF_HOME="$sd/.cache/huggingface" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
    echo "  HF 环境: ${HF_HOME}（缓存命中 → 离线加载，不联网重试）"
  else
    echo "  HF 环境: 缓存未命中 → 保持联网，走镜像 $HF_ENDPOINT"
  fi

  echo "SD API 未运行，正在后台启动（首次含模型加载约 1-3 分钟）..."
  echo "  目录: $sd"
  echo "  日志: $LAUNCH_LOG"
  mkdir -p "$(dirname "$LAUNCH_LOG")" 2>/dev/null
  # git 环境（A1111 的 prepare_environment / 扩展更新会用到），两条都是本机实测坑：
  #   ① xcode-select 指向 Xcode 时 /usr/bin/git 只是 shim，没跑过 `sudo xcodebuild -license`
  #      就**任何命令都 rc=69**（连 git init 都不行）→ 挨个试，选一个能跑的塞进 GIT，
  #      launch_utils.py 里是 `git = os.environ.get('GIT', "git")`，会走我们选中的这份。
  #   ② GitHub 走 HTTP/2 常报 `Error in the HTTP2 framing layer` → 用 git 2.31+ 的
  #      GIT_CONFIG_COUNT 强制 HTTP/1.1（对派生的 git 子进程同样生效）。
  if [ -z "${GIT:-}" ]; then
    for _g in "$(command -v git 2>/dev/null)" /Library/Developer/CommandLineTools/usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do
      [ -n "${_g}" ] && [ -x "${_g}" ] && "${_g}" --version >/dev/null 2>&1 && { export GIT="${_g}"; break; }
    done
  fi
  # GitPython（A1111 启动时 import git）**不读 GIT 变量**，它在 PATH 里找 git 并跑 `git version`；
  # Xcode 的 /usr/bin/git 没同意许可时 rc=69，症状是「SD 一启动就自己退出」。
  # 两道一起上：① GIT_PYTHON_GIT_EXECUTABLE（GitPython 官方认）；② 在 SD 目录下放一个只指向
  # 那份 git 的软链接并前置到 PATH（只软链 git，不整目录前置，免得盖掉用户自己的工具）。
  if [ -n "${GIT}" ]; then
    export GIT_PYTHON_GIT_EXECUTABLE="${GIT}"
    shim_dir="$sd/.dsh-bin"
    if mkdir -p "$shim_dir" 2>/dev/null && ln -sf "$GIT" "$shim_dir/git" 2>/dev/null; then
      export PATH="$shim_dir:$PATH"
      echo "  git 兜底: $shim_dir/git → $GIT"
    fi
  fi
  if [ -z "${GIT_CONFIG_COUNT:-}" ]; then
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='http.version' GIT_CONFIG_VALUE_0='HTTP/1.1'
  fi

  nohup "$py" "${args[@]}" </dev/null >"$LAUNCH_LOG" 2>"$LAUNCH_LOG_ERR" &
  local srv=$!
  kill -0 "$srv" 2>/dev/null || fail "启动 SD 失败（进程立刻退出）" "看 $LAUNCH_LOG / $LAUNCH_LOG_ERR"

  local waited=0 last_print=0
  while [ "$waited" -lt "$START_TIMEOUT" ]; do
    if ! kill -0 "$srv" 2>/dev/null; then
      local tail_text; tail_text="$(tail -20 "$LAUNCH_LOG_ERR" "$LAUNCH_LOG" 2>/dev/null)"
      # 新版 macOS 的 dyld 会拒载「零填充段 offset 非零」的老工具链 wheel（scipy 之类），
      # 症状就是依赖明明装完了、WebUI 一启动就 ImportError: dlopen(...zero-fill section type...)。
      # 随包同步过来的 fix-macho-zerofill.py 能就地修（改字段 + 重签名），所以直接给命令。
      local zerofill_hint=""
      case "$tail_text" in
        *"zero-fill section type"*)
          local fixer=""
          for cand in "$(dirname "${BASH_SOURCE[0]:-$0}")/fix-macho-zerofill.py" "$sd/fix-macho-zerofill.py"; do
            [ -f "$cand" ] && { fixer="$cand"; break; }
          done
          if [ -n "$fixer" ]; then
            zerofill_hint="
   这是 macOS 的 dyld 校验（不是你的 SD 坏了）：跑一次就好，它会把这些 .so 的
   零填充段 offset 归零并重新 ad-hoc 签名：
     python3 \"$fixer\" \"$sd\"/venv/lib/python3.*/site-packages --apply"
          else
            zerofill_hint="
   这是 macOS 的 dyld 校验（不是你的 SD 坏了）：用插件包里的 fix-macho-zerofill.py 跑一遍
   <SD>/venv/lib/python3.*/site-packages --apply 即可（把零填充段 offset 归零 + 重签名）。"
          fi
          ;;
      esac
      fail "SD 启动进程提前退出" "启动日志 $LAUNCH_LOG :
$tail_text$zerofill_hint"
    fi
    api_ready && { echo "SD API 已就绪：$API_BASE"; return 0; }
    sleep 2; waited=$((waited + 2))
    if [ $((waited - last_print)) -ge 15 ]; then echo "  等待就绪... ${waited}s"; last_print=$waited; fi
  done
  fail "等待 SD API 就绪超时（${START_TIMEOUT}s）" "看启动日志排查：$LAUNCH_LOG / ${LAUNCH_LOG_ERR}；也可调大 -StartTimeout。"
}

# 把响应 JSON 里的图片 base64 取出来（jq 主路，python3 兜底）
resp_images_first() { # stdin: 响应 JSON
  if [ "$JSON_TOOL" = "jq" ]; then jq -r '(.images // [])[0] // empty'
  else python3 -c 'import json,sys
d=json.load(sys.stdin)
imgs=d.get("images") or []
print(imgs[0] if imgs else "",end="")'
  fi
}
resp_seed() { # stdin: 响应 JSON → 实际 seed（info 是 JSON 字符串）
  if [ "$JSON_TOOL" = "jq" ]; then jq -r 'try ((.info | fromjson) | .seed) catch empty'
  else python3 -c 'import json,sys
d=json.load(sys.stdin)
info=d.get("info")
if isinstance(info,str):
    try: info=json.loads(info)
    except Exception: info={}
print((info or {}).get("seed",""),end="")'
  fi
}
resp_error() {
  if [ "$JSON_TOOL" = "jq" ]; then jq -r '(.error // .detail // empty) | tostring' 2>/dev/null
  else python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("error") or d.get("detail") or "",end="")'
  fi
}

# JSON 字符串转义（纯 bash，不依赖 jq）
json_escape() {
  local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}
b64_file() { base64 < "$1" | tr -d '\n'; }
b64_decode_to() { # b64_decode_to <file> 从 stdin 解码（BSD/GNU base64 都兼容）
  if base64 -d -o "$1" >/dev/null 2>&1; then :
  else base64 -D -o "$1" >/dev/null 2>&1 || openssl base64 -d -A -o "$1" >/dev/null 2>&1 || return 1; fi
}

# ---- 1) 保证 API 可用（没开就自己拉起） ----
start_sd_api_if_needed

# ---- 2) 输出目录与文件名（序号自动递增，永不覆盖） ----
mkdir -p "$OUT_DIR" || fail "无法创建输出目录：$OUT_DIR"
idx=1
while :; do
  file_name="$(printf '%s_%03d.png' "$NAME" "$idx")"
  out_path="$OUT_DIR/$file_name"
  [ -e "$out_path" ] || break
  idx=$((idx + 1))
done

# ---- 3) 出图 ----
if [ -n "$MASK" ] && [ -z "$INIT_IMAGE" ]; then
  fail "给了 -Mask 就必须同时给 -InitImage（蒙版重绘需要底图）" \
    "例如：-InitImage \"/path/a.png\" -Mask \"/path/a_mask.png\"，或先让插件用 maskBox 生成蒙版。"
fi
[ -n "$INIT_IMAGE" ] && { [ -f "$INIT_IMAGE" ] || fail "参考图不存在：$INIT_IMAGE"; }
[ -n "$MASK" ] && { [ -f "$MASK" ] || fail "蒙版不存在：$MASK"; }

endpoint="/sdapi/v1/txt2img"
body="{\"prompt\":\"$(json_escape "$PROMPT")\",\"negative_prompt\":\"$(json_escape "$NEGATIVE")\",\"width\":$WIDTH,\"height\":$HEIGHT,\"steps\":$STEPS,\"cfg_scale\":$CFG,\"seed\":$SEED,\"n_iter\":1,\"batch_size\":1,\"save_images\":false"
sampler_trimmed="$(printf '%s' "$SAMPLER" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[ -n "$sampler_trimmed" ] && body="$body,\"sampler_name\":\"$(json_escape "$sampler_trimmed")\""

if [ -n "$INIT_IMAGE" ]; then
  endpoint="/sdapi/v1/img2img"
  body="$body,\"init_images\":[\"$(b64_file "$INIT_IMAGE")\"],\"denoising_strength\":$DENOISING,\"resize_mode\":0"
  if [ -n "$MASK" ]; then
    # 蒙版重绘：字段名与 A1111 的 StableDiffusionProcessingImg2Img dataclass 一致
    body="$body,\"mask\":\"$(b64_file "$MASK")\",\"mask_blur\":$MASK_BLUR,\"inpainting_fill\":$INPAINT_FILL,\"inpaint_full_res\":$([ "$NO_FULL_RES" = "1" ] && echo false || echo true),\"inpaint_full_res_padding\":$INPAINT_PADDING,\"inpainting_mask_invert\":$([ "$MASK_INVERT" = "1" ] && echo 1 || echo 0)"
  fi
fi
body="$body}"

start_ts=$(date +%s)
resp_file="$TMP/dsh-sd-direct-resp.$$.json"
body_file="$TMP/dsh-sd-direct-body.$$.json"
err_file="$TMP/dsh-sd-direct-curl.$$.err"
# 请求体可能几 MB（图生图/蒙版重绘里塞了 base64），走临时文件而不是命令行参数（避开 ARG_MAX）
printf '%s' "$body" > "$body_file" || fail "写请求体失败：$body_file"
http_code="$(curl -sS -o "$resp_file" -w '%{http_code}' -m 600 -X POST \
  -H 'Content-Type: application/json' --data-binary "@$body_file" "$API_BASE$endpoint" 2>"$err_file")" \
  || { fail "SD API 调用失败 ${endpoint}（curl 退出）" "$(head -5 "$err_file" 2>/dev/null)；服务地址 ${API_BASE}；日志 $LAUNCH_LOG"; }
rm -f "$body_file" 2>/dev/null
[ "$http_code" = "200" ] || fail "SD API 返回 HTTP ${http_code}（${endpoint}）" "$(head -c 400 "$resp_file" 2>/dev/null)"

# ---- 4) 结果校验（失败只报这一条，不再级联） ----
b64="$(resp_images_first < "$resp_file")"
if [ -z "$b64" ]; then
  detail="$(resp_error < "$resp_file" 2>/dev/null)"
  fail "SD 没有返回图像${detail:+：$detail}" "SD 可能正忙或已退出，重跑一次；持续失败看 ${LAUNCH_LOG}。"
fi
# 读回实际 seed（A1111 的 info 是 JSON 字符串；取不到就用请求时的 seed）
actual_seed="$(resp_seed < "$resp_file" 2>/dev/null)"
[ -n "$actual_seed" ] || actual_seed="$SEED"
printf '%s' "$b64" | b64_decode_to "$out_path" || fail "图像落盘失败：$out_path" "base64 解码不可用（试过 base64 -d / -D / openssl）。"
[ -s "$out_path" ] || fail "图像落盘为空：$out_path"
rm -f "$resp_file" "$err_file" 2>/dev/null
elapsed=$(( $(date +%s) - start_ts ))

echo "已保存: $out_path"
echo "Seed:   $actual_seed   采样: ${SAMPLER:-SD 默认}   耗时: ${elapsed}s"
if [ -n "$MASK" ]; then
  echo "模式:   蒙版重绘 inpaint (denoising=$DENOISING, maskBlur=$MASK_BLUR, fill=$INPAINT_FILL, padding=$INPAINT_PADDING$([ "$MASK_INVERT" = 1 ] && echo ', invert')$([ "$NO_FULL_RES" = 1 ] && echo ', 全图分辨率'))"
elif [ -n "$INIT_IMAGE" ]; then
  echo "模式:   img2img (denoising=$DENOISING)"
else
  echo "模式:   txt2img"
fi

# ---- 5) 跑完 → 用系统默认看图器打开这张图（批量跑/不想弹窗就加 -NoOpen） ----
if [ "$NO_OPEN" = "1" ]; then
  echo "已跳过自动打开（-NoOpen）：$out_path"
else
  if command -v open >/dev/null 2>&1; then open "$out_path" && echo "已打开: $out_path"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$out_path" && echo "已打开: $out_path"
  else echo "没有 open/xdg-open，可手动打开：$out_path"; fi
fi
