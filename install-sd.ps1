# install-sd.ps1 —— 一键自举安装 Stable Diffusion WebUI（dsh-sd-bridge-guard 配套）
# 装完把路径记进 ~/.dsh-sd-bridge.json，插件下次启动自动读到，零配置可用。
# 用法:
#   powershell -ExecutionPolicy Bypass -File install-sd.ps1
#   powershell -ExecutionPolicy Bypass -File install-sd.ps1 -Target "E:\sd" -SkipModel
#   powershell -ExecutionPolicy Bypass -File install-sd.ps1 -Mirror ""        # 用官方源
# 说明:
#   - WebUI 本体约 2GB（git clone），模型约 4GB（可 -SkipModel 跳过，之后自己放 models\Stable-diffusion）
#   - 首次由插件启动时还会在线安装 Python/torch 依赖（约 10-30 分钟，之后每次启动秒级）

param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'dsh-sd-bridge\webui'),
    [string]$Repo = 'https://github.com/AUTOMATIC1111/stable-diffusion-webui.git',
    [string]$ModelName = 'v1-5-pruned-emaonly.safetensors',
    [string]$ModelUrl = 'https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors',
    [string]$Mirror = 'https://hf-mirror.com',   # 填 "" 用官方源
    [switch]$SkipModel
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

Write-Host "== dsh-sd-bridge-guard 自举安装 ==" -ForegroundColor Cyan
Write-Host "目标目录: $Target"

# 1) git
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Host "错误：未找到 git。请先安装 Git for Windows（https://git-scm.com/download/win）后重跑本脚本。" -ForegroundColor Red
    exit 1
}

# 2) clone WebUI（已存在则跳过）
$launchPy = Join-Path $Target 'launch.py'
if (Test-Path $launchPy) {
    Write-Host "WebUI 已存在，跳过克隆：$Target" -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    Write-Host "克隆 Stable Diffusion WebUI（约 2GB，请耐心等待）..."
    & git clone --depth 1 $Repo $Target
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $launchPy)) {
        Write-Host "错误：克隆失败。可换 -Repo 指定镜像仓库后重试。" -ForegroundColor Red
        exit 1
    }
}

# 3) 模型（可跳过）
$modelDir = Join-Path $Target 'models\Stable-diffusion'
$modelPath = Join-Path $modelDir $ModelName
if ($SkipModel) {
    Write-Host "已跳过模型下载（-SkipModel）。请自行把 .safetensors 放进 $modelDir" -ForegroundColor Yellow
} elseif (Test-Path $modelPath) {
    Write-Host "模型已存在，跳过下载：$ModelName" -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
    $url = $ModelUrl
    if ($Mirror -ne '' -and $url -like '*huggingface.co*') {
        $url = $url -replace 'https://huggingface.co', $Mirror
    }
    Write-Host "下载模型 $ModelName（约 4GB）：$url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $modelPath -UseBasicParsing
    } catch {
        Write-Host "模型下载失败（$($_.Exception.Message)）。可 -SkipModel 跳过，或手动下载后放入 $modelDir" -ForegroundColor Yellow
        if (Test-Path $modelPath) { Remove-Item $modelPath -Force }
    }
}

# 4) 记录安装位置，插件下次启动自动读到（~/.dsh-sd-bridge.json）
$stateFile = Join-Path $env:USERPROFILE '.dsh-sd-bridge.json'
@{ sdDir = $Target } | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
Write-Host "已记录安装位置 -> $stateFile" -ForegroundColor Green

Write-Host ""
Write-Host "== 完成 ==" -ForegroundColor Cyan
Write-Host "1. 重启 DeepSeek Harness（插件会重新探测 SD 目录）"
Write-Host "2. 直接让它画一张图即可；首次启动会在线安装 Python/torch 依赖（10-30 分钟），之后秒级"
Write-Host "3. 想换安装位置：设环境变量 DSH_SD_DIR，或在 cordis.patch.yml 按 id sd-bridge 覆盖 sdDir"
