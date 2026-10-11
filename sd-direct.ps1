# sd-direct.ps1 —— 直连本机 SD API，独立出图，不经会话页面
# 用法示例:
#   .\sd-direct.ps1 -Prompt "1girl, silver hair, masterpiece" -Negative "lowres, watermark"
#   .\sd-direct.ps1 -Prompt "..." -InitImage "D:\path\ref.jpg" -Denoising 0.65
#   .\sd-direct.ps1 -Prompt "..." -Width 640 -Height 960 -Steps 24 -Seed 12345
# 跨机器说明：-OutDir 不传时默认存到「当前目录\SD-Picture」；插件生成命令时会显式注入
# -OutDir，保证脚本与插件保存到同一个目录，任何机器无需本地适配。

param(
    [Parameter(Mandatory=$true)][string]$Prompt,
    [Alias('NegativePrompt')][string]$Negative = "lowres, bad anatomy, bad hands, watermark, text, worst quality",
    [string]$InitImage = "",        # 给了就走 img2img，留空走 txt2img
    [Alias('DenoisingStrength')][double]$Denoising = 0.65,
    [int]$Width = 640,
    [int]$Height = 960,
    [int]$Steps = 24,
    [double]$Cfg = 7,
    [int]$Seed = -1,
    [string]$OutDir = "",           # 留空 = 当前目录下的 SD-Picture（插件会显式注入）
    [string]$Name = "direct",       # 输出文件名前缀，序号自动递增
    [string]$ApiBase = "http://127.0.0.1:7860"
)

if ($OutDir -eq "") { $OutDir = Join-Path (Get-Location).Path "SD-Picture" }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

function Invoke-SdApi {
    param([string]$Endpoint, [hashtable]$Body)
    $json = $Body | ConvertTo-Json -Depth 8
    return Invoke-RestMethod -Uri "$ApiBase$Endpoint" -Method Post -Body $json `
        -ContentType "application/json" -TimeoutSec 600
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# 自动递增文件名
$idx = 1
do {
    $fileName = "{0}_{1:D3}.png" -f $Name, $idx
    $outPath  = Join-Path $OutDir $fileName
    $idx++
} while (Test-Path $outPath)

$sw = [System.Diagnostics.Stopwatch]::StartNew()

if ($InitImage -ne "") {
    if (-not (Test-Path -LiteralPath $InitImage)) {
        Write-Host "错误：参考图不存在：$InitImage" -ForegroundColor Red
        exit 1
    }
    # img2img
    $initBytes = [System.IO.File]::ReadAllBytes($InitImage)
    $initB64   = [Convert]::ToBase64String($initBytes)
    $body = @{
        init_images  = @($initB64)
        prompt       = $Prompt
        negative_prompt = $Negative
        denoising_strength = $Denoising
        width = $Width; height = $Height
        steps = $Steps; cfg_scale = $Cfg; seed = $Seed
    }
    $result = Invoke-SdApi "/sdapi/v1/img2img" $body
} else {
    # txt2img
    $body = @{
        prompt = $Prompt
        negative_prompt = $Negative
        width = $Width; height = $Height
        steps = $Steps; cfg_scale = $Cfg; seed = $Seed
    }
    $result = Invoke-SdApi "/sdapi/v1/txt2img" $body
}

$imgBytes = [Convert]::FromBase64String($result.images[0])
[System.IO.File]::WriteAllBytes($outPath, $imgBytes)
$sw.Stop()

# 读回 seed 便于复现
$actualSeed = $result.info | ConvertFrom-Json | Select-Object -ExpandProperty seed

Write-Host "已保存: $outPath"
Write-Host "Seed:   $actualSeed   耗时: $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
Write-Host ("模式:   " + $(if ($InitImage -ne "") { "img2img (denoising=$Denoising)" } else { "txt2img" }))
