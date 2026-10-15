# sd-direct.ps1 —— 直连本机 SD API，独立出图，不经会话页面
# 用法示例:
#   .\sd-direct.ps1 -Prompt "1girl, silver hair, masterpiece" -Negative "lowres, watermark"
#   .\sd-direct.ps1 -Prompt "..." -InitImage "D:\path\ref.jpg" -Denoising 0.65
#   .\sd-direct.ps1 -Prompt "flower crown" -InitImage "D:\a.png" -Mask "D:\a_mask.png" -Denoising 0.6   # 蒙版重绘
#   .\sd-direct.ps1 -Prompt "..." -Width 640 -Height 960 -Steps 24 -Seed 12345
#   .\sd-direct.ps1 -Prompt "..." -SdDir "D:\SD.4.8"      # 显式指定 SD 目录
#   .\sd-direct.ps1 -Prompt "..." -NoStart                # SD 没开时不自动拉起，直接报错退出
# 跨机器说明（别人拿到这条命令直接就能跑）:
#   - -OutDir 不传时默认存到「当前目录\SD-Picture」；插件生成命令时会显式注入 -OutDir。
#   - SD API 没在跑时本脚本**自己把它拉起来**：目录按 -SdDir > 环境变量 DSH_SD_DIR >
#     ~/.dsh-sd-bridge.json 自举记录 > 各盘常见安装名扫描查找，启动后轮询到就绪为止
#     （首次启动含模型加载约 1-3 分钟，日志在 %TEMP%\dsh-sd-direct-launch.log*）。
#   - 任何一步失败都**只报一条明确错误并 exit 1**，绝不往下级联报错（历史故障：
#     API 连不上 → $result.images[0] 空数组 → WriteAllBytes 空值 → ConvertFrom-Json 空值，连炸 4 条）。
# 跑完行为：保存成功后自动用默认看图器**打开这张图**；不想要就加 -NoOpen。

param(
    [string]$Prompt = "",            # 提示词；留空 = 仅拉起 SD API 到就绪即退出（不占端口、不出图，供调用方预热用）
    [Alias('NegativePrompt')][string]$Negative = "lowres, bad anatomy, bad hands, extra fingers, fewer digits, malformed limbs, watermark, text, signature, jpeg artifacts, worst quality, low quality",
    [string]$InitImage = "",        # 给了就走 img2img，留空走 txt2img
    [string]$Mask = "",             # 蒙版图路径（白/不透明 = 重绘区）；给了就是蒙版重绘，必须同时给 -InitImage
    [int]$MaskBlur = 4,             # 蒙版边缘羽化 px（接缝明显就调 8-16）
    [int]$InpaintFill = 0,          # 蒙版区底色：0=填充 1=保留原图 2=噪声 3=空潜空间（换新内容用 2）
    [switch]$MaskInvert,            # 反转蒙版（改为重绘蒙版以外的区域）
    [switch]$NoFullRes,             # 关掉「只在蒙版区按原分辨率重绘」
    [int]$InpaintPadding = 32,      # 蒙版区域外扩像素，越大边缘越自然
    [Alias('DenoisingStrength')][double]$Denoising = 0.55,   # 与插件默认一致（越小越贴参考图；保画风用 0.30-0.50）
    [int]$Width = 512,
    [int]$Height = 768,
    [int]$Steps = 22,
    [string]$Sampler = "DPM++ 2M",    # 采样器：与插件默认一致（比 Euler a 更干净、同步数噪点更少）
    [string]$Checkpoint = "",       # 临时切换的 checkpoint（title，如 "AWPainting_v1.2.safetensors [3d1b3c42ec]"）；留空用当前模型
    [double]$Cfg = 7,
    [long]$Seed = -1,          # 必须 64 位：SD 的 seed 是 uint32（可到 4294967295），[int] 在 >2147483647 时报参数转换错误
    [string]$OutDir = "",           # 留空 = 当前目录下的 SD-Picture（插件会显式注入）
    [string]$Name = "direct",       # 输出文件名前缀，序号自动递增
    [string]$ApiBase = "http://127.0.0.1:7860",
    [string]$SdDir = "",            # SD WebUI 目录（含 launch.py）；留空自动查找
    [switch]$RestoreFaces,          # 开启面部修复（CodeFormer/GFPGAN）——全身图脸小易崩，修复能救回来
    [double]$CodeFormerWeight = 0.5, # 面部修复强度：0=最强修复 1=最贴近原图（默认 0.5 折中）
    [switch]$NoHires,               # 关闭 Hires Fix（默认开）：txt2img 二次采样放大，脸部/服装/手脚细节翻倍
    [double]$HiresScale = 2,        # Hires 放大倍率（输出 = 原尺寸 × 此值；2 即 512x768 → 1024x1536）
    [double]$HiresDenoising = 0.55, # Hires 二次采样重绘幅度（0.4-0.6 保构图补细节，过高会改构图）
    [int]$StartTimeout = 300,       # 自动拉起后等待就绪的秒数（首次含模型加载给足余量）
    [switch]$NoStart,               # SD 没开时不自动拉起，直接报错退出
    [switch]$NoOpen,                # 加 -NoOpen 则跑完不自动打开这张图
    [string]$TermFile = "",         # 占位符映射表路径（JSON），脚本读取后做字符串替换
    [switch]$StartOnly               # 只拉起 SD API 到就绪后退出（预热用，不出图、不校验 Prompt）
)

if ($OutDir -eq "") { $OutDir = Join-Path (Get-Location).Path "SD-Picture" }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$port = 7860
try { $port = ([Uri]$ApiBase).Port } catch { }
$launchLog    = Join-Path $env:TEMP 'dsh-sd-direct-launch.log'
$launchLogErr = Join-Path $env:TEMP 'dsh-sd-direct-launch.log.err'

# 统一失败出口：只报一条错误 + 一行提示，然后退出（杜绝级联报错）
function Fail {
    param([string]$Message, [string]$Hint = '')
    Write-Host ""
    Write-Host "错误：$Message" -ForegroundColor Red
    if ($Hint) { Write-Host $Hint -ForegroundColor Yellow }
    exit 1
}

# 等待过程中的进度条：用原生 Write-Progress 画一条会前进的条 + 已运行时间（mm:ss）。
# $Percent ∈ 0..100，$Seconds = 已运行秒数（>= 0）。
# 注意：脚本顶部为压制下载进度设了 $ProgressPreference='SilentlyContinue'，那会连 Write-Progress
# 一起吞掉——这里临时切回 'Continue' 才画得出来。
function Show-WaitProgress {
    param([int]$Percent, [double]$Seconds)
    if ($ProgressPreference -ne 'Continue') { $ProgressPreference = 'Continue' }
    $pct = [Math]::Max(0, [Math]::Min(100, $Percent))
    $bar = '#' * [int]($pct / 4) + '-' * (25 - [int]($pct / 4))
    $elapsed = '{0:D2}:{1:D2}' -f [int]([Math]::Floor($Seconds / 60)), [int]([Math]::Floor($Seconds % 60))
    Write-Progress -Id 1 -Activity "正在拉起 Stable Diffusion API" -Status "$bar  $($pct)%   已运行 $elapsed" -PercentComplete $pct
}

# SD API 是否就绪（能回 200 才算）
function Test-SdApi {
    try {
        $r = Invoke-WebRequest -Uri "$ApiBase/sdapi/v1/options" -Method Get -TimeoutSec 5 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

# 端口上是否有「别的」服务占着（连得上但不是 SD API）
function Test-PortOccupiedByOther {
    try {
        Invoke-WebRequest -Uri "$ApiBase/" -Method Get -TimeoutSec 5 -UseBasicParsing | Out-Null
        return $true
    } catch {
        if ($_.Exception.Response) { return $true }   # 有 HTTP 响应 = 端口被占且不是 SD API
        return $false                                  # 连不上 = 没人占用
    }
}

# 找 SD WebUI 目录：-SdDir > DSH_SD_DIR > ~/.dsh-sd-bridge.json 自举记录 > 各盘常见安装名
function Find-SdDir {
    $candidates = @()
    if ($SdDir) { $candidates += $SdDir }
    if ($env:DSH_SD_DIR) { $candidates += $env:DSH_SD_DIR }
    $stateFile = Join-Path $env:USERPROFILE '.dsh-sd-bridge.json'
    if (Test-Path $stateFile) {
        try {
            $rec = [System.IO.File]::ReadAllText($stateFile) | ConvertFrom-Json   # ReadAllText 会自动剥 BOM
            if ($rec.sdDir) { $candidates += $rec.sdDir }
        } catch { }
    }
    foreach ($root in @('C:', 'D:', 'E:', 'F:', 'G:')) {
        if (-not (Test-Path -LiteralPath "$root\")) { continue }   # 没这个盘就跳过，否则报「找不到驱动器」刷屏
        foreach ($n in @('SD.4.8', 'SD', 'sd', 'stable-diffusion-webui', 'stable-diffusion-webui-master', 'sd.webui', 'webui', 'a1111', 'sd-webui')) {
            $candidates += (Join-Path "$root\" $n)
        }
    }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        try {
            if (Test-Path -LiteralPath (Join-Path $c 'launch.py')) { return $c }
        } catch { }   # 非法路径 / 盘符中途消失 → 跳过继续找
    }
    return ''
}

# 找解释器：SD 自带 python/venv > 自举记录里的 pythonDir > PATH（排除 WindowsApps 占位符）
function Find-Python {
    param([string]$Dir)
    foreach ($c in @(
        (Join-Path $Dir 'python\python.exe'),
        (Join-Path $Dir 'venv\Scripts\python.exe'),
        (Join-Path $Dir 'venv\bin\python')
    )) { if (Test-Path -LiteralPath $c) { return $c } }
    $stateFile = Join-Path $env:USERPROFILE '.dsh-sd-bridge.json'
    if (Test-Path $stateFile) {
        try {
            $rec = [System.IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
            if ($rec.pythonDir) {
                $exe = Join-Path $rec.pythonDir 'python.exe'
                if (Test-Path -LiteralPath $exe) { return $exe }
            }
        } catch { }
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and "$($cmd.Source)" -notlike '*\WindowsApps\*') { return $cmd.Source }
    return ''
}

# SD API 没跑就自己拉起来，并轮询到就绪
function Start-SdApiIfNeeded {
    if (Test-SdApi) { return }
    if (Test-PortOccupiedByOther) {
        Fail "端口 $port 已被其它服务占用，而且它不是 SD API" "换一个端口（-ApiBase http://127.0.0.1:<新端口>），或先关掉占用该端口的程序。"
    }
    if ($NoStart) {
        Fail "SD API 未运行（$ApiBase），且指定了 -NoStart" "先手动启动 SD 的 API 模式，或去掉 -NoStart 让脚本自动拉起。"
    }

    $sd = Find-SdDir
    if (-not $sd) {
        Fail "本机找不到 SD WebUI 目录（需要含 launch.py）" "用 -SdDir ""D:\你的SD目录"" 指定，或设环境变量 DSH_SD_DIR，或跑插件自带的 install-sd.ps1 安装。"
    }
    $py = Find-Python $sd
    if (-not $py) {
        Fail "在 $sd 下找不到 python/venv，PATH 里也没有可用的 python" "装 Python 3.10.6（A1111 在 Windows 只认 3.10），或跑 install-sd.ps1 让它自举。"
    }

    $launchPy = Join-Path $sd 'launch.py'
    $prepared = (Test-Path (Join-Path $sd 'venv')) -or (Test-Path (Join-Path $sd 'python'))
    $argString = "`"$launchPy`" --api --nowebui --port $port"
    if ($prepared) { $argString += ' --skip-prepare-environment' }
    $argString += ' --skip-version-check'

    # 与插件完全一致的 HF 环境（画质/启动时间的关键一环）：不带 HF_HOME 启动时，transformers 会去
    # %USERPROFILE%\.cache\huggingface 找 clip tokenizer，而 SD 的缓存在 <SD>\.cache\huggingface——
    # 找不到就连 huggingface.co 重试「5 次 × 10s」× 好几个文件，模型加载卡几分钟甚至失败；
    # tokenizer 走到异常路径时，出图质量也会跟着崩。这里先看缓存：命中就离线加载，没命中就走镜像。
    $hfHome = Join-Path $sd '.cache\huggingface'
    $hasCache = $false
    foreach ($d in @((Join-Path $hfHome 'hub'), $hfHome)) {
        if (Test-Path -LiteralPath $d) {
            if (Get-ChildItem -LiteralPath $d -Directory -Filter 'models--*' -ErrorAction SilentlyContinue | Select-Object -First 1) { $hasCache = $true; break }
        }
    }
    $env:GRADIO_ANALYTICS_ENABLED = 'False'
    if ($hasCache -and $env:DSH_SD_HF_ONLINE -ne '1') {
        $env:HF_HOME = $hfHome
        $env:HF_HUB_OFFLINE = '1'
        $env:TRANSFORMERS_OFFLINE = '1'
        if (-not $env:HF_ENDPOINT) { $env:HF_ENDPOINT = 'https://hf-mirror.com' }
        Write-Host "  HF 环境: $hfHome（缓存命中 → 离线加载，不联网重试）"
    } else {
        if (-not $env:HF_ENDPOINT) { $env:HF_ENDPOINT = 'https://hf-mirror.com' }
        Write-Host "  HF 环境: 缓存未命中 → 保持联网，走镜像 $env:HF_ENDPOINT"
    }

    Write-Host "SD API 未运行，正在后台启动（首次含模型加载约 1-3 分钟）..." -ForegroundColor Cyan
    Write-Host "  目录: $sd"
    Write-Host "  日志: $launchLog"
    # 三个句柄全部显式接管：SD 若继承了本控制台的管道，脚本明明跑完了、宿主却还在等句柄关闭
    #（测试 / CI 里表现为「命令一直挂着不返回」）。
    $inFile = Join-Path $env:TEMP 'dsh-sd-direct-launch.in'
    if (-not (Test-Path -LiteralPath $inFile)) { New-Item -ItemType File -Path $inFile | Out-Null }
    try {
        $proc = Start-Process -FilePath $py -ArgumentList $argString -WorkingDirectory $sd `
            -WindowStyle Hidden -RedirectStandardInput $inFile -RedirectStandardOutput $launchLog -RedirectStandardError $launchLogErr -PassThru
    } catch {
        Fail "启动 SD 失败：$($_.Exception.Message)" "可手动启动 SD，或用 -SdDir/-NoStart 调整行为。"
    }

    $deadline = (Get-Date).AddSeconds($StartTimeout)
    $lastPrint = 0
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) {
            # 进程退出也要把进度条关掉，避免残留半截条
            Write-Progress -Id 1 -Activity "正在拉起 Stable Diffusion API" -Completed
            $tail = ''
            foreach ($f in @($launchLogErr, $launchLog)) {
                if (Test-Path $f) {
                    $tail = ((Get-Content -LiteralPath $f -Tail 20 -ErrorAction SilentlyContinue) -join "`n")
                    if ($tail.Trim()) { break }
                }
            }
            Fail "SD 启动进程提前退出（退出码 $($proc.ExitCode)）" "启动日志 $launchLog :`n$tail"
        }
        if (Test-SdApi) {
            Write-Progress -Id 1 -Activity "正在拉起 Stable Diffusion API" -Completed
            Write-Host "SD API 已就绪：$ApiBase" -ForegroundColor Green
            return
        }
        # 进度条：启动等待通常 1-3 分钟（首次含模型加载），按剩余时间线性推进到 95%，
        # 到点仍未就绪则由外层超时报错并关条；已运行时间实时刷新。
        $elapsed = [int]((Get-Date) - $deadline.AddSeconds(-$StartTimeout)).TotalSeconds
        $progressPct = [Math]::Min(95, [int]($elapsed / [Math]::Max(1, $StartTimeout) * 100))
        Show-WaitProgress -Percent $progressPct -Seconds $elapsed
        if ($elapsed - $lastPrint -ge 15) { $lastPrint = $elapsed }
        Start-Sleep -Seconds 2
    }
    Write-Progress -Id 1 -Activity "正在拉起 Stable Diffusion API" -Completed
    Fail "等待 SD API 就绪超时（${StartTimeout}s）" "看启动日志排查：$launchLog / $launchLogErr；也可调大 -StartTimeout。"
}

function Invoke-SdApi {
    param([string]$Endpoint, [hashtable]$Body)
    $json = $Body | ConvertTo-Json -Depth 8
    $maxTry = 2
    for ($try = 1; $try -le $maxTry; $try++) {
        try {
            # 必须显式发 UTF-8 字节体：PS5.1 的 Invoke-RestMethod 拿 string Body 时按 Latin-1 编码，
            # 中文 checkpoint 名（写实：majicMIX…）会变成 åå®ï¼… 乱码 → SD 报 model not found（500）。
            $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            return Invoke-RestMethod -Uri "$ApiBase$Endpoint" -Method Post -Body $jsonBytes `
                -ContentType "application/json; charset=utf-8" -TimeoutSec 600
        } catch {
            # 把 SD 塞在 4xx 响应体里的真实报错挖出来（默认异常 Message 只有一句「错误的请求」）
            $detail = ""
            try {
                $respStream = $_.Exception.Response.GetResponseStream()
                if ($respStream) {
                    $reader = New-Object System.IO.StreamReader($respStream, [System.Text.Encoding]::UTF8)
                    $detail = $reader.ReadToEnd()
                }
            } catch { }
            if (-not $detail) { try { $detail = [string]$_.ErrorDetails.Message } catch { } }
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            # 400/500/503 且还有重试机会 → 等 5 秒重试一次（常见于切模型后加载中、显存刚被占满）
            if ($try -lt $maxTry -and $code -in @(400, 500, 503)) {
                Write-Host "SD 返回 $code（$(if ($detail) { $detail.Substring(0, [Math]::Min(160, $detail.Length)) } else { '无详情' })）—— 5 秒后重试 $try/$maxTry" -ForegroundColor Yellow
                Start-Sleep -Seconds 5
                continue
            }
            $hint = "服务地址 $ApiBase；SD 若刚被拉起可稍候重试，或看 $launchLog。"
            if ($detail) { $hint = "SD 报错详情：$detail" }
            Fail "SD API 调用失败 $Endpoint（远程服务器返回错误: $code）" $hint
        }
    }
}

# ---- 1) 保证 API 可用（没开就自己拉起） ----
Start-SdApiIfNeeded

# ---- 1x) 预热模式：只拉起 API 到就绪即退出（不出图、不校验 Prompt），供 sd-inject 弹表单前预热 ----
if ($StartOnly) {
    Write-Host "SD API 已就绪（预热完成）：$ApiBase" -ForegroundColor Green
    exit 0
}

# ---- 1a) 临时切换 checkpoint：记录原模型 → 仅在当前模型 ≠ 目标时切换 → 出图后还原 ----
# （迭代场景每轮都会带同一个 -Checkpoint：目标已生效时跳过切换/还原，避免反复加载模型）
$script:OrigCheckpoint = ""
$script:CheckpointSwitched = $false
if ($Checkpoint -and $Checkpoint.Trim()) {
    try {
        $optsNow = Invoke-RestMethod -Uri "$ApiBase/sdapi/v1/options" -Method Get -TimeoutSec 10 -UseBasicParsing
        $script:OrigCheckpoint = [string]$optsNow.sd_model_checkpoint
        if ($script:OrigCheckpoint -ne $Checkpoint.Trim()) {
            # 中文模型名必须走 UTF-8 字节体（见 Invoke-SdApi 注释），否则 SD 收到乱码报 model not found
            $switchJson = [System.Text.Encoding]::UTF8.GetBytes((@{ sd_model_checkpoint = $Checkpoint.Trim() } | ConvertTo-Json))
            $null = Invoke-RestMethod -Uri "$ApiBase/sdapi/v1/options" -Method Post `
                -Body $switchJson -ContentType "application/json; charset=utf-8" -TimeoutSec 120
            $script:CheckpointSwitched = $true
            Write-Host "已临时切换模型: $($Checkpoint.Trim())（出图后还原为 $($script:OrigCheckpoint)）"
            # 切模型是异步加载：等 /sdapi/v1/options 里的 sd_model_checkpoint 真正变过来再继续，
            # 否则紧跟着的 img2img/txt2img 会撞「模型加载中」的 400/503（实测偶发）
            $swLoad = [System.Diagnostics.Stopwatch]::StartNew()
            while ($swLoad.Elapsed.TotalSeconds -lt 120) {
                try {
                    $optsChk = Invoke-RestMethod -Uri "$ApiBase/sdapi/v1/options" -Method Get -TimeoutSec 10 -UseBasicParsing
                    if ([string]$optsChk.sd_model_checkpoint -eq $Checkpoint.Trim()) { break }
                } catch { }
                Start-Sleep -Seconds 2
            }
        }
    } catch {
        Write-Host "切换模型失败（$($_.Exception.Message)），按当前模型继续" -ForegroundColor Yellow
    }
}

# ---- 1b) 占位符替换：从外部 JSON 读取映射表，对 Prompt / Negative 做字符串替换 ----
# 映射表由用户在执行前提供；脚本不生成、不推断任何映射内容。
# 文件不存在或解析失败 → 静默跳过，原样执行，不阻断、不报错。
if ($TermFile -and (Test-Path -LiteralPath $TermFile)) {
    try {
        $terms = [System.IO.File]::ReadAllText($TermFile) | ConvertFrom-Json
        foreach ($prop in $terms.PSObject.Properties) {
            $key = [string]$prop.Name
            $val = [string]$prop.Value
            if ($key) {
                $Prompt = $Prompt.Replace($key, $val)
                $Negative = $Negative.Replace($key, $val)
            }
        }
        Write-Host "词表已应用: $TermFile"
    } catch {
        # 词表读取或解析失败 → 静默跳过，原样执行
    }
}

# ---- 2) 输出目录与文件名 ----
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$idx = 1
do {
    $fileName = "{0}_{1:D3}.png" -f $Name, $idx
    $outPath  = Join-Path $OutDir $fileName
    $idx++
} while (Test-Path -LiteralPath $outPath)

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---- 3) 出图 ----
if ($Mask -ne "" -and $InitImage -eq "") {
    Fail "给了 -Mask 就必须同时给 -InitImage（蒙版重绘需要底图）" "例如：-InitImage `"D:\a.png`" -Mask `"D:\a_mask.png`" 或先让插件用 maskBox 生成蒙版。"
}
if ($Mask -ne "" -and $InitImage -ne "" -and -not (Test-Path -LiteralPath $InitImage)) {
    Fail "底图不存在：$InitImage"
}
if ($InitImage -ne "") {
    if (-not (Test-Path -LiteralPath $InitImage)) {
        Fail "参考图不存在：$InitImage"
    }
    try {
        $initBytes = [System.IO.File]::ReadAllBytes($InitImage)
    } catch {
        Fail "参考图读取失败：$InitImage（$($_.Exception.Message)）"
    }
    $body = @{
        init_images         = @([Convert]::ToBase64String($initBytes))
        prompt              = $Prompt
        negative_prompt     = $Negative
        denoising_strength  = $Denoising
        width               = $Width; height = $Height
        steps               = $Steps; cfg_scale = $Cfg; seed = $Seed
    }
    if ($Sampler -and $Sampler.Trim()) { $body['sampler_name'] = $Sampler.Trim() }
    if ($Mask -ne "") {
        # 蒙版重绘：字段名与 A1111 的 StableDiffusionProcessingImg2Img dataclass 一致
        if (-not (Test-Path -LiteralPath $Mask)) { Fail "蒙版不存在：$Mask" }
        try {
            $maskBytes = [System.IO.File]::ReadAllBytes($Mask)
        } catch {
            Fail "蒙版读取失败：$Mask（$($_.Exception.Message)）"
        }
        $body['mask'] = [Convert]::ToBase64String($maskBytes)
        $body['mask_blur'] = $MaskBlur
        $body['inpainting_fill'] = $InpaintFill
        $body['inpaint_full_res'] = (-not $NoFullRes)
        $body['inpaint_full_res_padding'] = $InpaintPadding
        $body['inpainting_mask_invert'] = $(if ($MaskInvert) { 1 } else { 0 })
    }
    $result = Invoke-SdApi "/sdapi/v1/img2img" $body
} else {
    $body = @{
        prompt          = $Prompt
        negative_prompt = $Negative
        width           = $Width; height = $Height
        steps           = $Steps; cfg_scale = $Cfg; seed = $Seed
    }
    if ($Sampler -and $Sampler.Trim()) { $body['sampler_name'] = $Sampler.Trim() }
    if (-not $NoHires) {
        # Hires Fix（默认开）：512x768 直接出全身图脸只有 40-60px，SD1.5 画不出细节；
        # 二次采样放大后脸部/服装/手脚细节量翻倍（实测同 seed 对照：29KB → 1.6MB）。
        # denoising_strength 必须显式给：缺省时 A1111 用 None 参与比较会 500（TypeError）。
        $body['enable_hr'] = $true
        $body['hr_scale'] = [math]::Max(1, [math]::Min(4, $HiresScale))
        $body['hr_upscaler'] = 'Latent'
        $body['hr_second_pass_steps'] = [math]::Max(1, [int]($Steps * 0.5))
        $body['denoising_strength'] = [math]::Max(0.1, [math]::Min(0.9, $HiresDenoising))
    }
    if ($RestoreFaces) {
        # A1111 的面部修复强度不在 txt2img 请求体里，要走 /sdapi/v1/options；
        # face_restoration_model 为空时 restore_faces=true 会直接报错，所以这里一并补上。
        try {
            $opts = Invoke-RestMethod -Uri "$ApiBase/sdapi/v1/options" -Method Get -TimeoutSec 10 -UseBasicParsing
            $optBody = @{}
            if (-not $opts.face_restoration_model) { $optBody['face_restoration_model'] = 'CodeFormer' }
            if ($null -ne $CodeFormerWeight) { $optBody['code_former_weight_factor'] = [math]::Min(1, [math]::Max(0, $CodeFormerWeight)) }
            if ($optBody.Count -gt 0) {
                $optBytes = [System.Text.Encoding]::UTF8.GetBytes(($optBody | ConvertTo-Json))
                $null = Invoke-RestMethod -Uri "$ApiBase/sdapi/v1/options" -Method Post -Body $optBytes -ContentType "application/json; charset=utf-8" -TimeoutSec 30
            }
        } catch {
            Write-Host "面部修复参数设置失败（$($_.Exception.Message)），按服务端默认继续" -ForegroundColor Yellow
        }
        $body['restore_faces'] = $true
    }
    $result = Invoke-SdApi "/sdapi/v1/txt2img" $body
}

# ---- 4) 结果校验（失败只报这一条，不再级联） ----
if (-not $result -or -not $result.images -or @($result.images).Count -eq 0) {
    $detail = ''
    try { if ($result.error) { $detail = [string]$result.error } elseif ($result.detail) { $detail = [string]$result.detail } } catch { }
    Fail "SD 没有返回图像$(if ($detail) { "：$detail" })" "SD 可能正忙或已退出，重跑一次；持续失败看 $launchLog。"
}

try {
    $imgBytes = [Convert]::FromBase64String($result.images[0])
    [System.IO.File]::WriteAllBytes($outPath, $imgBytes)
} catch {
    Fail "图像落盘失败：$outPath（$($_.Exception.Message)）"
}
$sw.Stop()

# 读回 seed 便于复现（info 可能是 JSON 字符串、也可能缺失——缺失不致命）
$actualSeed = $Seed
try {
    $info = $result.info
    if ($info -is [string] -and $info) { $info = $info | ConvertFrom-Json }
    if ($info -and $null -ne $info.seed) { $actualSeed = $info.seed }
} catch { }

Write-Host "已保存: $outPath"
Write-Host "Seed:   $actualSeed   采样: $(if ($Sampler) { $Sampler } else { 'SD 默认' })   耗时: $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
# 供父脚本（如 sd-inject.ps1 素体迭代）解析 winning seed 用；人类看着是重复信息，机器靠它做锚定
Write-Host "SEEDFILE: $outPath"
Write-Host "SEEDVALUE: $actualSeed"
Write-Host ("模式:   " + $(
    if ($Mask -ne "") { "蒙版重绘 inpaint (denoising=$Denoising, maskBlur=$MaskBlur, fill=$InpaintFill, padding=$InpaintPadding$(if ($MaskInvert) { ', invert' })$(if ($NoFullRes) { ', 全图分辨率' }))" }
    elseif ($InitImage -ne "") { "img2img (denoising=$Denoising)" }
    else { "txt2img$(if ($RestoreFaces) { ' + 面部修复' })$(if (-not $NoHires) { " + Hires x$HiresScale" })" }
))

# ---- 5) 出图跑完 → 用系统默认看图器打开这张图（批量跑/不想弹窗就加 -NoOpen） ----
# 临时切换过的 checkpoint 在这里还原（放最后：成功/失败路径都走到脚本尾部才执行）
if ($script:CheckpointSwitched) {
    try {
        $restoreJson = [System.Text.Encoding]::UTF8.GetBytes((@{ sd_model_checkpoint = $script:OrigCheckpoint } | ConvertTo-Json))
        $null = Invoke-RestMethod -Uri "$ApiBase/sdapi/v1/options" -Method Post `
            -Body $restoreJson -ContentType "application/json; charset=utf-8" -TimeoutSec 120
        Write-Host "已还原模型: $($script:OrigCheckpoint)"
    } catch {
        Write-Host "模型还原失败（$($_.Exception.Message)），SD 当前用的是 $($Checkpoint.Trim())" -ForegroundColor Yellow
    }
}
if ($NoOpen) {
    Write-Host "已跳过自动打开（-NoOpen）：$outPath"
} else {
    try {
        Start-Process -FilePath $outPath
        Write-Host "已打开: $outPath"
    } catch {
        Write-Host "自动打开失败（$($_.Exception.Message)），可手动打开：$outPath" -ForegroundColor Yellow
    }
}
