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
    [Parameter(Mandatory=$true)][string]$Prompt,
    [Alias('NegativePrompt')][string]$Negative = "lowres, bad anatomy, bad hands, watermark, text, worst quality",
    [string]$InitImage = "",        # 给了就走 img2img，留空走 txt2img
    [string]$Mask = "",             # 蒙版图路径（白/不透明 = 重绘区）；给了就是蒙版重绘，必须同时给 -InitImage
    [int]$MaskBlur = 4,             # 蒙版边缘羽化 px（接缝明显就调 8-16）
    [int]$InpaintFill = 0,          # 蒙版区底色：0=填充 1=保留原图 2=噪声 3=空潜空间（换新内容用 2）
    [switch]$MaskInvert,            # 反转蒙版（改为重绘蒙版以外的区域）
    [switch]$NoFullRes,             # 关掉「只在蒙版区按原分辨率重绘」
    [int]$InpaintPadding = 32,      # 蒙版区域外扩像素，越大边缘越自然
    [Alias('DenoisingStrength')][double]$Denoising = 0.55,   # 与插件默认一致（越小越贴参考图；保画风用 0.30-0.50）
    [int]$Width = 640,
    [int]$Height = 960,
    [int]$Steps = 24,
    [string]$Sampler = "DPM++ 2M",    # 采样器：与插件默认一致（比 Euler a 更干净、同步数噪点更少）
    [double]$Cfg = 7,
    [long]$Seed = -1,          # 必须 64 位：SD 的 seed 是 uint32（可到 4294967295），[int] 在 >2147483647 时报参数转换错误
    [string]$OutDir = "",           # 留空 = 当前目录下的 SD-Picture（插件会显式注入）
    [string]$Name = "direct",       # 输出文件名前缀，序号自动递增
    [string]$ApiBase = "http://127.0.0.1:7860",
    [string]$SdDir = "",            # SD WebUI 目录（含 launch.py）；留空自动查找
    [int]$StartTimeout = 300,       # 自动拉起后等待就绪的秒数（首次含模型加载给足余量）
    [switch]$NoStart,               # SD 没开时不自动拉起，直接报错退出
    [switch]$NoOpen                 # 加 -NoOpen 则跑完不自动打开这张图
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
            Write-Host "SD API 已就绪：$ApiBase" -ForegroundColor Green
            return
        }
        $elapsed = [int]((Get-Date) - $deadline.AddSeconds(-$StartTimeout)).TotalSeconds
        if ($elapsed - $lastPrint -ge 15) { Write-Host "  等待就绪... ${elapsed}s" -ForegroundColor DarkGray; $lastPrint = $elapsed }
        Start-Sleep -Seconds 2
    }
    Fail "等待 SD API 就绪超时（${StartTimeout}s）" "看启动日志排查：$launchLog / $launchLogErr；也可调大 -StartTimeout。"
}

function Invoke-SdApi {
    param([string]$Endpoint, [hashtable]$Body)
    $json = $Body | ConvertTo-Json -Depth 8
    try {
        return Invoke-RestMethod -Uri "$ApiBase$Endpoint" -Method Post -Body $json `
            -ContentType "application/json" -TimeoutSec 600
    } catch {
        Fail "SD API 调用失败 $Endpoint（$($_.Exception.Message)）" "服务地址 $ApiBase；SD 若刚被拉起可稍候重试，或看 $launchLog。"
    }
}

# ---- 1) 保证 API 可用（没开就自己拉起） ----
Start-SdApiIfNeeded

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
Write-Host ("模式:   " + $(
    if ($Mask -ne "") { "蒙版重绘 inpaint (denoising=$Denoising, maskBlur=$MaskBlur, fill=$InpaintFill, padding=$InpaintPadding$(if ($MaskInvert) { ', invert' })$(if ($NoFullRes) { ', 全图分辨率' }))" }
    elseif ($InitImage -ne "") { "img2img (denoising=$Denoising)" }
    else { "txt2img" }
))

# ---- 5) 出图跑完 → 用系统默认看图器打开这张图（批量跑/不想弹窗就加 -NoOpen） ----
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
