# sd-inject.ps1 —— 本地提示词注入脚本（素体自检迭代 + 素体基底 + 参数表单）
# 流程：素体自检迭代（只跑基底，换 seed + 面部修复重试到脸/手不崩；正向自动追加脸部细节词）
#   → 出图参数表单（一次填完）：正向/负向提示词[基底已预填，多行文本框可直接改] / 迭代次数[默认32] / Denoising[可编辑，默认 0 = 文生图；填 0.3-0.9 = 图生图重绘幅度] / 底图[留空=素体成品，「最近」=输出目录最新一张，或填路径/点浏览选图] / 比例[默认9:16] / 画风[默认二次元，图生图默认保持画风] / 画质[默认480p，最高2160p（4K）] / LoRA[可选，从 SD 拉取列表] / 取消退出
#   → 最终出图：拿到底图 + Denoising>0 → 图生图（-InitImage 底图 + -Denoising）；否则文生图。
#     底图优先级：表单「底图」栏 > 素体自检迭代的 winning 图 > 现场补一张素体底图（质检不可用时素体也会出这一张）。
#     最终图同样按迭代次数做脸/手质检迭代（质检不可用时出满 N 张让你自选），取最高分那张
# 迭代产物写在「可写的迭代根」下的独立子目录（默认 <OutDir 的父目录>\.sd-inject-iter\iter-<随机>，
# 可用 -IterDir 指定，见 坑34）：以前固定写系统 temp，在 DSH workspace-write 沙箱下会被 ACL 拒写，
# 出图落盘失败 → 脚本提前退出 → 工作区一张成品都没有。工作区优先即天然可写。
# 最终只把脸/手最高分的一张复制进 -OutDir；脚本退出（含取消/失败）时删除本次迭代子目录——工作区里只留成品。
# 全程本地运行（SD 与脸/手质检的视觉模型都在本机）。
# 用法：
#   .\sd-inject.ps1                                    # 基底 + 表单直接跑
#   .\sd-inject.ps1 -BasePrompt "1girl, solo, portrait" -Width 512 -Height 768 -Name "inject" -NoOpen
# 跨机器说明：
#   - 脸/手质检走本地视觉模型（-VlmModel，默认 qwen3-vl:8b，Ollama OpenAI 兼容端点 -QwenBase）；
#     接口没起来时质检自动跳过，不阻塞出图。
#   - 脸部细节词（-FaceBoostTags）自动追加进正向提示词，提升脸部质量；不想加传 ""。
#   - LoRA 在表单里选（SD 在跑时自动拉取本机列表）；只作用于最终出图（素体迭代先于表单）。
#   - -SdDirect 不传时取本脚本同目录的 sd-direct.ps1；-OutDir 不传时存到「脚本所在目录\SD-Picture」
#     （不受运行时的当前目录影响，保证与 sd-bridge 工具的落点一致）。
#   - 素体自检迭代（默认开）：出图前先用基底提示词试跑，换 seed 重试 + 面部修复，直到脸/手质检过关
#     （本地视觉模型打分）或到轮数上限；期间**只改 seed / 面部修复 / 脸部细节词，不改用户提示词**。
#     `-NoIterate` 关闭（直接出一张，老行为）；`-IterateRounds N` 调轮数（默认 3）。

param(
    [string]$BasePrompt = "1girl, solo",
    [string]$BaseNegative = "lowres, bad anatomy, bad hands, extra fingers, fewer digits, watermark, text, signature, jpeg artifacts, worst quality, low quality",
    [string]$FaceBoostTags = "detailed face, beautiful detailed eyes, perfect face, detailed skin",   # 脸部细节词：自动追加进正向（用户要求）
    [string]$QwenBase = "http://127.0.0.1:11434/v1",   # 本地视觉质检接口（OpenAI 兼容）
    [string]$QwenApiKey = "ollama",                    # API Key（Ollama 任意非空即可）
    [int]$IterateRounds = 3,                           # 素体自检迭代轮数上限（每轮换 seed + 面部修复，脸部过关即停）
    [switch]$NoIterate,                                # 加 -NoIterate 则跳过素体自检迭代，直接出一张（老行为）
    [string]$VlmModel = "qwen3-vl:8b",                 # 脸部质检用的本地视觉模型（留空 "" = 自动挑本机 vl/vision 模型）
    [int]$SdPort = 7860,                               # SD API 端口（拉取 LoRA 列表用）
    [int]$Width = 512,
    [int]$Height = 768,
    [int]$Steps = 24,
    [double]$Cfg = 7,
    [string]$Sampler = "DPM++ 2M",
    [long]$Seed = -1,                                  # [long]：SD 的 seed 是 uint32（坑14）
    [string]$OutDir = "",
    [string]$Name = "inject",
    [string]$SdDirect = "",                            # sd-direct.ps1 路径；留空则取脚本同目录
    [string]$SdDir = "",
    [string]$InitImage = "",                           # 底图（图生图用）：预填进表单「底图」栏；留空 = 用素体成品
    [string]$IterDir = "",                             # 迭代中间图目录（必须可写）：留空 = <工作区>\.sd-inject-iter → 脚本目录 → 系统 temp
    [switch]$NoOpen                                   # 加 -NoOpen 则跑完不自动打开这张图
)

# 启动诊断日志已关闭（用户要求 2026-10-14）：不再写 sd-inject-start.log

# ---- 清除旧进程/卡死任务（脚本执行最前面，用户要求）----
# 1) 清空 SD 队列里卡死的 job（上次面部修复卡 100% 的残留会阻塞后续出图）
try {
    $null = Invoke-RestMethod -Uri "http://127.0.0.1:$SdPort/sdapi/v1/interrupt" -Method Post -TimeoutSec 5
    Write-Host "已清空 SD 卡死任务（interrupt）" -ForegroundColor DarkGray
} catch { }
# 2) 残留迭代目录的清理挪到「迭代根确定之后」（见下方 坑34 段）——旧版固定扫系统 temp，
#    现在迭代根优先落在工作区，得先知道根在哪才能扫对地方。

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# OutDir 默认 = 脚本所在目录下的 SD-Picture（与 sd-direct.ps1 / 工具落点保持一致，
# 不受用户运行时的当前目录影响）；用户显式传了 -OutDir 则照用。
if ($OutDir -eq "") { $OutDir = Join-Path $PSScriptRoot "SD-Picture" }
if ($SdDirect -eq "") {
    $SdDirect = Join-Path $PSScriptRoot "sd-direct.ps1"
}
if (-not (Test-Path -LiteralPath $SdDirect)) {
    Write-Host "错误：找不到 sd-direct.ps1：$SdDirect" -ForegroundColor Red
    exit 1
}

# ---- 迭代临时目录：**必须落在可写的地方**（坑34，外部用户实测反馈）----
# 旧行为：固定用 [System.IO.Path]::GetTempPath()。但 DSH 的 workspace-write 沙箱 ACL 只放行
# 「会话工作区」，而插件是用 cmd start 拉起**独立窗口**跑的（不经过会被改写 TMP/TEMP 的受限子进程），
# 于是 GetTempPath() 指向不可写的用户 temp → sd-direct.ps1 落盘被拒 → 非 0 退出 →
# sd-inject 直接 exit 1 → 三处 Copy-Item 全在迭代**之后**、永远执行不到 → 工作区一张成品都没有
# （只有 SD 自己的 outputs 目录里看得见）。现在改为「工作区优先 + 逐级兜底 + 全不可写就明确报错」。
function Test-DirWritable {
    # 真写一个探针文件再删：只看 Test-Path 会把「存在但被 ACL 拒写」当成可用（这正是坑34 的误判来源）
    param([string]$Path)
    if (-not $Path) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop }
        $probe = Join-Path $Path (".write-probe-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Resolve-IterRoot {
    # 按顺序挑第一个真的可写的候选目录；全不可写返回 ''（由调用方明确报错，不静默）
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        if (-not $c) { continue }
        if (Test-DirWritable $c) { return $c }
        Write-Host "迭代目录不可写，跳过：$c" -ForegroundColor DarkYellow
    }
    return ''
}

# OutDir 先探一次：不可写的话最后那几下 Copy-Item 必然失败，与其让用户等十几分钟才看到
# 「工作区什么都没有」，不如现在就把原因说清楚。
if (-not (Test-DirWritable $OutDir)) {
    Write-Host "错误：输出目录不可写：$OutDir" -ForegroundColor Red
    Write-Host "      DSH 的 workspace-write 沙箱只允许写会话工作区，请把 -OutDir 指到工作区内（例如 <工作区>\SD-Picture）。" -ForegroundColor Yellow
    exit 1
}

# 迭代根候选：① -IterDir 显式指定 ② <OutDir 的父目录>\.sd-inject-iter（正常就是会话工作区）
#             ③ $PSScriptRoot\.sd-inject-iter ④ 系统 temp（旧行为，最后兜底）
# 加固：系统 temp 用 try/catch + 多来源兜底求值——[System.IO.Path]::GetTempPath() 在个别受限宿主/
#       沙箱下会返回空字符串，直接喂给 Join-Path 会在 $ErrorActionPreference='Stop'（启动器就是 Stop）
#       下抛「参数 Path 为空」的致命异常，把整条兜底链打断。
$sysTemp = ''
try { $sysTemp = [System.IO.Path]::GetTempPath() } catch { }
if (-not $sysTemp) { try { $sysTemp = "$env:TEMP" } catch { } }
if (-not $sysTemp) { try { $sysTemp = "$env:TMP" } catch { } }
if (-not $sysTemp) { try { $sysTemp = "$env:USERPROFILE\AppData\Local\Temp" } catch { } }

$iterCandidates = @()
if ($IterDir) { $iterCandidates += $IterDir }
if ($OutDir) { try { $iterCandidates += (Join-Path (Split-Path -Parent $OutDir) '.sd-inject-iter') } catch { } }
if ($PSScriptRoot) { try { $iterCandidates += (Join-Path $PSScriptRoot '.sd-inject-iter') } catch { } }
if ($sysTemp) { try { $iterCandidates += (Join-Path $sysTemp 'sd-inject-iter') } catch { } }
$iterCandidates = @($iterCandidates | Where-Object { $_ } | Select-Object -Unique)

$script:IterRoot = Resolve-IterRoot -Candidates $iterCandidates
if (-not $script:IterRoot) {
    Write-Host "错误：找不到可写的迭代目录，已尝试：" -ForegroundColor Red
    foreach ($c in $iterCandidates) { Write-Host "      $c" -ForegroundColor DarkGray }
    Write-Host "      请把 -OutDir 指到会话工作区内，或用 -IterDir 指定一个可写目录。" -ForegroundColor Yellow
    exit 1
}
Write-Host "迭代目录：$($script:IterRoot)" -ForegroundColor DarkGray

# 清理上次中断残留的迭代目录（新根 + 旧版 temp 根都扫一遍，避免留垃圾）
# 加固：候选目录可能压根不存在（例如 -IterDir 给了个不可写的 Z:\ 候选）——先 Test-Path 再扫，
# 整段再包 try/catch，免得在 $ErrorActionPreference='Stop'（启动器里就是 Stop）下把清理失败升级成流程中断。
foreach ($root in $iterCandidates) {
    if (-not $root) { continue }
    try { if (-not (Test-Path -LiteralPath $root)) { continue } } catch { continue }
    foreach ($pat in @('iter-*', 'sd-inject-iter-*')) {
        try {
            Get-ChildItem -LiteralPath $root -Directory -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
        } catch { }
    }
}

# 每次运行一个独立子目录（所有中间图都写这里，退出时整体删除；根目录留着复用）
$script:IterTempDir = Join-Path $script:IterRoot ("iter-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $script:IterTempDir -Force
# 清理兜底：正常退出、Ctrl+C、进程被杀（ finally 由 exit 触发）都尽量删掉本次临时目录
$script:IterTempCleaned = $false
function Remove-IterTempDir {
    if ($script:IterTempCleaned) { return }
    $script:IterTempCleaned = $true
    if ($script:IterTempDir -and (Test-Path -LiteralPath $script:IterTempDir)) {
        try { Remove-Item -LiteralPath $script:IterTempDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    # 根目录空了就顺手收掉（工作区里不留空壳目录）
    if ($script:IterRoot -and (Test-Path -LiteralPath $script:IterRoot)) {
        try {
            if (@(Get-ChildItem -LiteralPath $script:IterRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item -LiteralPath $script:IterRoot -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

# 把表单「底图」栏的原始输入解析成真实图片路径：
#   空 → ''（交给上层决定用素体成品）；「最近/最新/上一张/last/latest」→ $OutDirPath 里最新的一张图；
#   其余当路径处理（相对路径先按当前目录、再按 $OutDirPath 解析）。解析不到返回 '' 并说明原因。
function Resolve-InitImagePath {
    param([string]$Raw, [string]$OutDirPath)
    $t = "$Raw"
    if (-not $t) { return '' }
    $t = $t.Trim().Trim('"')
    if (-not $t) { return '' }
    if ($t -match '^(最近|最新|上一张|前一张|上次|latest|last|recent|prev)$') {
        $hit = @(Get-ChildItem -LiteralPath $OutDirPath -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|webp|bmp)$' } |
            Sort-Object LastWriteTime -Descending) | Select-Object -First 1
        if ($hit) {
            Write-Host "底图 = 输出目录里最新一张：$($hit.FullName)" -ForegroundColor DarkGray
            return $hit.FullName
        }
        Write-Host "底图填了「$t」，但 $OutDirPath 里还没有可用图片 → 忽略底图" -ForegroundColor Yellow
        return ''
    }
    $cand = $t
    if (-not [System.IO.Path]::IsPathRooted($cand)) {
        foreach ($base in @((Get-Location).Path, $OutDirPath)) {
            $p2 = Join-Path $base $cand
            if (Test-Path -LiteralPath $p2) { $cand = $p2; break }
        }
    }
    if (Test-Path -LiteralPath $cand -PathType Leaf) {
        try { return (Resolve-Path -LiteralPath $cand).Path } catch { return $cand }
    }
    Write-Host "底图路径不存在：$t → 忽略底图" -ForegroundColor Yellow
    return ''
}

# 在工作区 $OutDir 里找一个「不覆盖已有文件」的落盘路径：按 <Name>_<序号:D3>.png 递增，
# 避免每次运行都从 inject_001 开始、用 -Force 覆盖上一次的成品（用户反馈：图片被覆盖）。
function Get-UniqueOutPath {
    param([string]$BaseName = "inject")
    if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Path $OutDir -Force }
    $idx = 1
    do {
        $cand = Join-Path $OutDir ("{0}_{1:D3}.png" -f $BaseName, $idx)
        $idx++
    } while (Test-Path -LiteralPath $cand)
    return $cand
}

# 从正向提示词总结一个简短文件名（取前几个英文标签，转成文件名安全的词）
function Summarize-PromptName {
    param([string]$Prompt)
    if (-not $Prompt) { return "inject" }
    # 去掉 LoRA 片段 <lora:...>、权重括号、特殊字符，取前 3 个词
    $clean = $Prompt -replace '<lora:[^>]+>', ''
    $clean = $clean -replace '[()\[\]:]', ' '
    $words = @($clean -split '[,\s]+' | Where-Object { $_ -and $_ -match '^[a-zA-Z0-9_-]+$' })
    if ($words.Count -eq 0) { return "inject" }
    $summary = ($words | Select-Object -First 3) -join '_'
    if ($summary.Length -gt 40) { $summary = $summary.Substring(0, 40) }
    return $summary
}

# 坑24：PS5.1 / .NET Framework 在响应头没写 charset 时按 Latin-1(28591) 解码 UTF-8 正文，
# UTF-8 的中文会变成「å°å¥³」这种双重编码文本。检测到 Latin-1 扩展字符就按原字节还原一次；
# 纯 ASCII（正常情况下的英文标签）原样返回，不做任何改动。
function Repair-Utf8Mojibake {
    param([string]$Text)
    if (-not $Text) { return $Text }
    if ($Text -notmatch '[\u0080-\u00FF]') { return $Text }
    try {
        $bytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($Text)
        $fixed = [System.Text.Encoding]::UTF8.GetString($bytes)
        return $fixed
    } catch {
        return $Text
    }
}

# SD API 是否就绪（能回 200 才算；弹表单前预热/拉列表都用它判）
function Test-SdApiReady {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$SdPort/sdapi/v1/options" -Method Get -TimeoutSec 5 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

# 从本机 SD API 拉取 LoRA 列表（SD 没开返回空数组，表单里显示「（无）」）
# 坑24：SD 的 API 响应头不带 charset，PS5.1 按 Latin-1 解码 → 中文 LoRA 名乱码，逐个修复
function Get-SdLoras {
    $loras = @()
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$SdPort/sdapi/v1/loras" -Method Get -TimeoutSec 5
        if ($r) { $loras = @($r | ForEach-Object { Repair-Utf8Mojibake ([string]$_.name) }) }
    } catch { }
    return $loras
}

# 从本机 SD API 拉取 checkpoint 列表（同样要修乱码）
function Get-SdCheckpoints {
    $cps = @()
    try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$SdPort/sdapi/v1/sd-models" -Method Get -TimeoutSec 5
        if ($r) { $cps = @($r | ForEach-Object { Repair-Utf8Mojibake ([string]$_.title) }) }
    } catch { }
    return $cps
}

# 当前加载的 checkpoint 名。
# 关键（2026-10-15 修「二次元画风画不出来」）：画风自动切模型是**持久**的——切过一次写实底
# （写实 → majicMIX、彩色哥特 → SemiRealMix），SD 里就一直停在写实底；之后再选「二次元」若
# 不显式切回来，出的还是写实/半写实图。这个函数让表单与画风规则都能看到真实的当前底子。
function Get-SdCurrentModel {
    try {
        $o = Invoke-RestMethod -Uri "http://127.0.0.1:$SdPort/sdapi/v1/options" -Method Get -TimeoutSec 5
        return (Repair-Utf8Mojibake ([string]$o.sd_model_checkpoint))
    } catch { return '' }
}

# 动漫底 checkpoint 选择：优先 AWPainting（本机动漫默认），其次 anything / ReVAnimated / dark sushi / 二次元 / 动漫 / anime。
# 用途：二次元画风强制切回动漫底；写实二次元在「当前底是写实向」时也先切回来（再靠半写实 LoRA 上脸）。
function Get-AnimeCheckpoint {
    param([string[]]$Checkpoints)
    $cps = @($Checkpoints | Where-Object { $_ })
    $first = @($cps | Where-Object { $_ -match 'AWPainting|awpainting' } | Select-Object -First 1)
    if ($first.Count -gt 0) { return [string]$first[0] }
    $second = @($cps | Where-Object { $_ -match 'anything|ReVAnimated|revanimated|dark\s*sushi|二次元|动漫|anime' } | Select-Object -First 1)
    if ($second.Count -gt 0) { return [string]$second[0] }
    return ''
}

# 写实向底子判定（写实 / 半写实 / 真人照片取向的 checkpoint）
function Test-RealisticCheckpoint {
    param([string]$Name)
    if (-not $Name) { return $false }
    return [bool]($Name -match 'majicMIX|majicmix|realistic|SemiReal|semireal|麦橘|写实|real')
}

# 画风词注入 / 剥离时的提示词净化（2026-10-15 修：反复切画风会把逗号越堆越多）。
# 现象：只做 Replace 的话，剥掉画风词会留下 ", " 尾巴，下一次注入再补一个 ", " → 实测连切三次
# 正向词就变成 "1girl, solo, silver hair,,, anime style, ..."（多余的 ",," 空标签）。
# 这两个函数把「连续逗号折叠成一个、开头逗号去掉、结尾不留空标签」集中处理。
function Add-StyleWords {
    param([string]$Text, [string]$Words)
    if (-not $Words) { return $Text }
    $t = "$Text"
    $t = ($t -replace '(\s*,\s*)+', ', ').Trim().TrimEnd(',')
    if (-not $t) { return $Words }
    return "$t, $Words"
}

function Remove-StyleWords {
    param([string]$Text, [string]$Words)
    $t = "$Text"
    if ($Words) { $t = $t.Replace($Words, '') }
    $t = $t -replace '(\s*,\s*)+', ', '   # 连续逗号折叠成一个
    $t = $t -replace '^\s*,\s*', ''       # 开头的逗号去掉
    return $t.Trim()
}

# ---- 参考图解析（决策 C-1：文生图 / 图生图·一致 / 图生图·替换）----
# 一致从哪里来？优先级：
#   ① 参考图自带 A1111 元数据（我们自己出的图）→ 直接拿到它的模型 + 原提示词/负向词，一致性最强；
#   ② A1111 反推（deepdanbooru / clip）→ 拿到主体标签（用户给的是照片/网图时走这条）；
#   ③ 本地视觉模型判画风（Ollama 在跑时才有）→ 拿到「二次元/写实/厚涂…」这类画风档位。
# 三条都不通也不报错：只按用户自己写的提示词出图，并明确打印「一致：未取到」。

# 读 PNG 里的 A1111 元数据（tEXt 关键字 parameters）→ @{ Model; Positive; Negative; Seed; Size }；读不到返回 $null。
# 注意：PNG 的 chunk 长度是**大端**，用 BitConverter（小端）会读成垃圾长度——这是第一次尝试踩的坑。
function Get-PngGenParams {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $b = $null
    try { $b = [System.IO.File]::ReadAllBytes($Path) } catch { return $null }
    if ($b.Length -lt 32 -or $b[0] -ne 0x89 -or $b[1] -ne 0x50 -or $b[2] -ne 0x4E -or $b[3] -ne 0x47) { return $null }
    $pos = 8
    while ($pos + 8 -le $b.Length) {
        $len = ([int]$b[$pos] -shl 24) -bor ([int]$b[$pos + 1] -shl 16) -bor ([int]$b[$pos + 2] -shl 8) -bor ([int]$b[$pos + 3])
        if ($len -lt 0 -or ($pos + 12 + $len) -gt $b.Length) { break }
        $type = [System.Text.Encoding]::ASCII.GetString($b, $pos + 4, 4)
        if ($type -eq 'tEXt' -or $type -eq 'iTXt') {
            $data = [System.Text.Encoding]::UTF8.GetString($b, $pos + 8, $len)
            if ($data.StartsWith('parameters')) {
                $txt = $data.Substring(10).TrimStart([char]0, ' ')
                $res = @{ Model = ''; Positive = ''; Negative = ''; Seed = ''; Size = '' }
                $m = [regex]::Match($txt, 'Model:\s*([^,\r\n]+)')
                if ($m.Success) { $res.Model = $m.Groups[1].Value.Trim() }
                $m = [regex]::Match($txt, 'Seed:\s*(\d+)')
                if ($m.Success) { $res.Seed = $m.Groups[1].Value }
                $m = [regex]::Match($txt, 'Size:\s*(\d+x\d+)')
                if ($m.Success) { $res.Size = $m.Groups[1].Value }
                $negIdx = $txt.IndexOf('Negative prompt:')
                if ($negIdx -ge 0) {
                    $res.Positive = $txt.Substring(0, $negIdx).Trim()
                    $negRest = $txt.Substring($negIdx + 16)
                    $stepsIdx = $negRest.IndexOf("`nSteps:")
                    if ($stepsIdx -lt 0) { $stepsIdx = $negRest.IndexOf('Steps:') }
                    if ($stepsIdx -ge 0) { $negRest = $negRest.Substring(0, $stepsIdx) }
                    $res.Negative = $negRest.Trim()
                } else {
                    $stepsIdx = $txt.IndexOf("`nSteps:")
                    if ($stepsIdx -ge 0) { $res.Positive = $txt.Substring(0, $stepsIdx).Trim() } else { $res.Positive = $txt.Trim() }
                }
                return $res
            }
        }
        if ($type -eq 'IEND') { break }
        $pos += 12 + $len
    }
    return $null
}

# A1111 反推提示词标签（deepdanbooru 适合动漫图、clip 适合照片）。$PreferClip = 参考图没有 A1111 元数据时用 clip。
function Get-ImageTags {
    param([string]$Path, [bool]$PreferClip = $false)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $b64 = $null
    try { $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) } catch { return '' }
    $order = @('deepdanbooru', 'clip')
    if ($PreferClip) { $order = @('clip', 'deepdanbooru') }
    foreach ($model in $order) {
        try {
            $body = @{ image = $b64; model = $model } | ConvertTo-Json -Compress
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$SdPort/sdapi/v1/interrogate" -Method Post `
                -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90
            $cap = Repair-Utf8Mojibake ([string]$resp.caption)
            if ($cap) {
                Write-Host "参考图反推（$model）：$($cap.Substring(0, [Math]::Min(110, $cap.Length)))…" -ForegroundColor DarkGray
                return $cap
            }
        } catch { }
    }
    return ''
}

# 本地视觉模型判画风（可选）：让 qwen3-vl 从我们的画风清单里挑一个；取不到返回 ''
function Get-ImageStyleByVlm {
    param([string]$Path)
    $styles = "保持画风/二次元/写实二次元/彩色哥特/国风/赛博朋克/写实/厚涂/水彩/像素风"
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    if (-not (Test-VlmApi)) { return '' }
    $b64 = $null
    try { $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) } catch { return '' }
    $ask = "这张图属于下面哪个画风？只能回答其中一个词，不要解释：$styles"
    try {
        $body = @{
            model = $VlmModel
            messages = @(@{ role = "user"; content = @(
                @{ type = "text"; text = $ask },
                @{ type = "image_url"; image_url = @{ url = "data:image/png;base64,$b64" } }
            ) })
            temperature = 0.1
            stream = $false
        }
        $resp = Invoke-RestMethod -Uri "$QwenBase/chat/completions" -Method Post `
            -Headers @{ "Content-Type" = "application/json; charset=utf-8"; "Authorization" = "Bearer $QwenApiKey" } `
            -Body ([System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8))) -TimeoutSec 120
        $raw = Repair-Utf8Mojibake ([string]$resp.choices[0].message.content)
        foreach ($s in @('写实二次元', '彩色哥特', '赛博朋克', '二次元', '国风', '厚涂', '水彩', '像素风', '写实')) {
            if ($raw -like "*$s*") { return $s }
        }
    } catch { }
    return ''
}

# 图片像素尺寸（生成区域蒙版要按原图尺寸画）
function Get-ImageSizePx {
    param([string]$Path)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $img = [System.Drawing.Image]::FromFile($Path)
        $r = @{ W = [int]$img.Width; H = [int]$img.Height }
        $img.Dispose()
        return $r
    } catch { return @{ W = 512; H = 768 } }
}

# 区域蒙版生成（白 = 重绘区，黑 = 保留区）。Spec 认不出的形状返回 ''。
# 支持：上半（脸）/ 下半（衣服）/ 中间 / 四周（背景），后缀「反选」= 取补集。
function New-RegionMask {
    param([string]$Spec, [int]$W, [int]$H, [string]$OutPath)
    $s = "$Spec"
    if (-not $s) { return '' }
    $invert = $false
    if ($s -match '反选|invert') { $invert = $true; $s = ($s -replace '反选', '') -replace 'invert', '' }
    $shape = ''
    if ($s -match '上半|脸|face|head') { $shape = 'upper' }
    elseif ($s -match '下半|衣服|服装|clothes|outfit|body') { $shape = 'lower' }
    elseif ($s -match '中间|主体|center|centre') { $shape = 'center' }
    elseif ($s -match '四周|背景|background|bg|边缘') { $shape = 'ring' }
    if (-not $shape) { return '' }

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
    $bmp = New-Object System.Drawing.Bitmap($W, $H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $black = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.Clear([System.Drawing.Color]::Black)
    $rects = @()
    switch ($shape) {
        # 区域框刻意收窄：铺满整幅会把背景/头发一起重画（实测那样出来的是糊块）
        'upper'  { $rects += @{ X = [int]($W * 0.25); Y = [int]($H * 0.04); Wd = [int]($W * 0.5); Ht = [int]($H * 0.32) } }
        'lower'  { $rects += @{ X = [int]($W * 0.2); Y = [int]($H * 0.45); Wd = [int]($W * 0.6); Ht = [int]($H * 0.5) } }
        'center' { $rects += @{ X = [int]($W * 0.22); Y = [int]($H * 0.18); Wd = [int]($W * 0.56); Ht = [int]($H * 0.66) } }
        'ring'   {
            $band = [int]($W * 0.18)
            $rects += @{ X = 0; Y = 0; Wd = $W; Ht = $band }
            $rects += @{ X = 0; Y = ($H - $band); Wd = $W; Ht = $band }
            $rects += @{ X = 0; Y = 0; Wd = $band; Ht = $H }
            $rects += @{ X = ($W - $band); Y = 0; Wd = $band; Ht = $H }
        }
    }
    if ($invert) {
        # 取补集：整张涂白，再把上面的形状画黑（比逐像素取反省事且边缘干净）
        $g.Clear([System.Drawing.Color]::White)
        foreach ($r in $rects) { $g.FillRectangle($black, $r.X, $r.Y, $r.Wd, $r.Ht) }
    } else {
        foreach ($r in $rects) { $g.FillRectangle($white, $r.X, $r.Y, $r.Wd, $r.Ht) }
    }
    $g.Dispose(); $black.Dispose(); $white.Dispose()
    try {
        $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return $OutPath
    } catch { $bmp.Dispose(); return '' }
}

# 从用户写的指令里判断「是不是替换动作」以及「替换的是哪一块」（决定默认蒙版区域）。
function Get-ReplaceTarget {
    param([string]$Text)
    $t = "$Text"
    if (-not $t) { return '' }
    $isReplace = ($t -match '换|替换|改成|改为|变成|变为|穿上|脱掉|replace|change|swap|put on|wearing now')
    if (-not $isReplace) { return '' }
    if ($t -match '衣服|服装|裙|上衣|衬衫|外套|内衣|泳装|制服|和服|汉服|dress|clothes|clothing|outfit|shirt|skirt|jacket|uniform|swimsuit|lingerie|bra|panties|kimono') { return '衣服' }
    if ($t -match '背景|场景|环境|background|scene|setting|backdrop') { return '背景' }
    if ($t -match '脸|五官|面容|表情|发型|头发|face|eyes|expression|hairstyle|bangs') { return '脸' }
    return '未指定'
}

# 一致模式：拿参考图的词当基底，剥掉与「替换目标」冲突的旧标签，用户新指令放最前。
# 目的就是用户要的效果：**换衣服但画风/主体不变**（旧衣服标签若留着会和用户的新指令打架）。
function Merge-ConsistencyPrompt {
    param([string]$UserPos, [string]$RefPos, [string]$Target)
    $conflict = ''
    switch ("$Target") {
        '衣服' { $conflict = 'dress|clothes|clothing|outfit|shirt|skirt|jacket|coat|uniform|swimsuit|bikini|lingerie|bra|panties|kimono|hanfu|sleeves|apron|socks|shoes|裙子|衣服|上衣|外套|内衣|泳装|制服|和服|汉服|鞋|袜' }
        '背景' { $conflict = 'background|sky|cloud|tree|forest|flower|blossom|room|city|street|beach|mountain|window|wall|室内|背景|天空|树|花|房间|城市|街|海|山|窗|墙' }
        '脸'   { $conflict = 'face|eyes|expression|mouth|bangs|hair style|表情|五官' }
    }
    $keep = @()
    if ($RefPos) {
        foreach ($tok in ($RefPos -split ',')) {
            $t = $tok.Trim()
            if (-not $t) { continue }
            if ($conflict -and ($t -match $conflict)) { continue }
            $keep += $t
        }
    }
    $merged = "$UserPos"
    if ($keep.Count -gt 0) { $merged = (($merged.TrimEnd(',', ' ') + ', ' + ($keep -join ', '))) }
    if ($conflict) { Write-Host "一致：已剔除参考图里与「$Target」冲突的标签 $($keep.Count) 个保留 / 原 $((($RefPos -split ',').Count)) 个" -ForegroundColor DarkGray }
    return ($merged -replace '(\s*,\s*)+', ', ').Trim()
}

# LoRA 片段：<lora:名称:权重>；名称带 .safetensors 后缀时保留原样（SD 两种都认）
function Format-LoraFragment {
    param([string]$LoraName, [double]$Weight)
    if (-not $LoraName) { return "" }
    return "<lora:$LoraName`:$Weight>"
}

# 画风 → 正/负向提示词映射：返回 @{ Pos = 正向画风词; Neg = 负向画风词 }（均可能为空串）。
# 这是「写实二次元」等画风在 C 档弹表单时，写进两个提示词框的画风描述词（合规描述词，非违规词）。
function Get-StylePrompt {
    param([string]$Style)
    $pos = ""; $neg = ""
    switch ($Style) {
        '写实'     {
            $pos = "RAW photo, photorealistic, natural skin texture, skin pores, film grain, soft natural lighting, depth of field, shot on Canon EOS R5, 85mm f1.8, highly detailed, 8k uhd"
            $neg = "(cartoon, anime, 3d render, cgi, painting, illustration:1.3), (airbrushed, smooth skin, plastic skin, doll:1.2)"
        }
        '写实二次元' {
            # 半写实·现代 CG 插画脸（十轮迭代实测配方）：动漫底子往写实靠。
            # LoRA semirealisticanime 权重 0.6 是平衡点（0.45 脸崩、0.8 御姐化/跑真人照片）。
            # 立体感靠「体积光包」（第 11-13 轮实测：平光=纸片感），但**不锁金色**——
            # 光色交给场景词决定，负向压 golden hue/sepia，避免每张都金灿灿。
            # <lora:...> 直接写进正向，sd-direct/A1111 原生解析；表单 LoRA 栏就别再重复选它（会叠两层）。
            $pos = "<lora:semirealisticanime:0.6>, (modern anime style:1.25), (semi-realistic:1.1), delicate refined anime face, (big detailed anime eyes:1.25), youthful face, detailed skin shading, (volumetric lighting:1.2), (chiaroscuro:1.2), (subsurface scattering:1.2), translucent skin, soft rim light, atmospheric haze, airbrushed shading, soft gradients, three-dimensional body, natural light color"
            $neg = "(old anime style:1.2), retro anime, flat color, cel shading, (photorealistic:1.3), (mature female face:1.3), (flat lighting:1.3), (flat shading:1.2), (golden hue:1.3), (sepia:1.2), oversaturated"
        }
        '彩色哥特' {
            # 原「真人感半写实」（SemiRealMix 旧配方）演化：华丽哥特——巴洛克金饰、暗调室内、
            # 宝石色点缀（绯红/孔雀蓝）、戏剧性明暗。SemiRealMix 堆金、厚涂、高饱和的「毛病」
            # 在这套词里正好变成风格本体。
            $pos = "semi-realistic, gothic, dark baroque, ornate golden filigree, gold body jewelry, (crimson and teal accents:1.2), jewel tones, dramatic chiaroscuro, candle light, decadent atmosphere, detailed skin texture, beautiful detailed face"
            $neg = "flat color, cel shading, lineart, (cartoon:1.3), (photorealistic:1.2), (flat lighting:1.2), low detail, simple background"
        }
        '写实二次元·东亚脸' {
            # 用户自调画风（2026-10-15 本机实测配方，写实二次元·东亚脸眼细节验证版）：
            # 在「写实二次元」基础上把五官往东亚脸收——脸型收窄、杏仁眼 + 虹膜高光、眼神光、
            # 正面偏侧柔光 + 发丝轮廓光，负向压掉宽脸/宽眼距/西方面孔/过曝/真人照片。
            $pos = "<lora:semirealisticanime:0.6>, (modern anime style:1.25), (semi-realistic:1.1), delicate refined face, slender oval face, (beautiful detailed almond eyes:1.3), (detailed sparkling iris:1.2), luminous gradient eyes, long eyelashes, eye highlight, youthful face, detailed skin shading, (volumetric lighting:1.2), (chiaroscuro:1.2), (subsurface scattering:1.2), translucent skin, (soft front-side fill light:1.3), gentle rim light on hair, atmospheric haze, airbrushed shading, soft gradients, three-dimensional body, natural light color"
            $neg = "(old anime style:1.2), retro anime, flat color, cel shading, (photorealistic:1.3), real person, (mature female face:1.3), (flat lighting:1.3), (flat shading:1.2), (golden hue:1.3), (sepia:1.2), oversaturated, (overexposed:1.3), (wide-set eyes:1.4), (wide face:1.2), western features, bad face, deformed face, asymmetrical eyes"
        }
        '釉彩调色盘' {
            # 用户自调画风（本机 LoRA）：釉彩·麻袋调色盘_v1.0——釉面质感 + 麻袋粗布调色盘色域，
            # 只挂 LoRA（权重 0.8）+ 极简风格词，其余交给用户的提示词；LoRA 缺失时整段为空、表单照常可用。
            $pos = "<lora:釉彩·麻袋调色盘_v1.0:0.8>, glaze texture, matte burlap canvas palette, muted earthy tones"
            $neg = ""
        }
        '二次元'   {
            # 2026-10-15 修：这一档以前**完全没有映射**（switch 里没有 '二次元' 分支 → 返回空词），
            # 而它又是「无底图时」的默认档 —— 表现就是「选二次元什么都没有、画不出二次元」。
            # 正统二次元 = 线稿 + 赛璐璐平涂 + 动漫脸；负向压掉 3D/照片感。
            $pos = "anime style, (clean lineart:1.2), (cel shading:1.15), flat color, vibrant colors, (detailed anime eyes:1.2), beautiful detailed face, masterpiece, best quality"
            $neg = "(3d:1.2), (photorealistic:1.3), photo, (realistic skin texture:1.2), (realistic face:1.2), sketch, (blurry lineart:1.1)"
        }
        '国风'     {
            # 国风：以国风山水 LoRA 为主，这里只补底层风格词（不写 <lora:...>，避免与表单 LoRA 栏叠两层）
            $pos = "traditional Chinese style, guofeng, (ink wash painting elements:1.15), elegant hanfu, silk texture, misty mountains, (classical Chinese aesthetic:1.2)"
            $neg = "(3d:1.2), photorealistic, (western cartoon:1.1), modern city, neon lights"
        }
        '赛博朋克' {
            # 赛博朋克：以赛博朋克场景 LoRA 为主，这里只补场景/光照底词
            $pos = "cyberpunk, neon lights, rain-slick night city, holographic signs, (high-tech low-life:1.1), volumetric neon fog, reflective wet streets"
            $neg = "daylight, rural, countryside, (flat lighting:1.1)"
        }
        '一致（自动检测参考图）' {
            # 决策 C-1a：不注入固定画风词——画风与主体从**参考图**里自动检测（PNG 元数据 → A1111 反推 → VLM），
            # 由主流程在出图前写进提示词。这里保持空映射是语义，不是漏写。
        }
        '保持画风' {
            # 明确「不注入任何画风词」：维持底图/LoRA/用户自己的提示词——保持空映射是这个档位的语义，
            # 不是漏写（下方 厚涂/水彩/像素风 同理只补对应风格的词）。
        }
        '厚涂'     {
            $pos = "impasto, thick paint, oil painting, visible brush strokes, palette knife texture"
            $neg = "flat color, cel shading, lineart"
        }
        '水彩'     {
            $pos = "watercolor painting, wet-on-wet, soft washes, pigment bleed, paper texture"
            $neg = "thick paint, impasto, 3d render"
        }
        '像素风'   {
            $pos = "pixel art, 8-bit, limited color palette, dithering, retro game sprite"
            $neg = "smooth shading, gradient, blurry"
        }
    }
    return @{ Pos = $pos; Neg = $neg }
}

# ---- 出图参数表单（WinForms）：正向/负向提示词 + 迭代次数 / Denoising / 比例 / 画风 / 画质 ----
# 提示词（基底已预填）作为多行文本框放在表单顶部，所有可填项一次填完；画风在图生图时默认「保持画风」。
function Show-ParamForm {
    param(
        [int]$DefaultRounds,
        [bool]$HasBaseImage,
        [string]$Positive,
        [string]$Negative,
        [string[]]$LoraList,
        [string[]]$CheckpointList,
        [string]$InitImageDefault = "",
        [string]$CurrentModel = ""
    )
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "sd-inject 出图参数"
    $form.ClientSize = New-Object System.Drawing.Size(350, 726)
    $form.FormBorderStyle = 'FixedDialog'
    $form.StartPosition = 'CenterScreen'
    $form.MaximizeBox = $false
    $form.TopMost = $true

    # 0) 正向 / 负向提示词（多行文本框：基底已预填，英文标签，逗号分隔，可整栏直接改）
    $lbPos = New-Object System.Windows.Forms.Label
    $lbPos.Text = '正向提示词：'
    $lbPos.SetBounds(20, 12, 200, 22)
    $form.Controls.Add($lbPos)

    $txtPos = New-Object System.Windows.Forms.TextBox
    $txtPos.Multiline = $true
    $txtPos.ScrollBars = 'Vertical'
    $txtPos.Text = $Positive
    $txtPos.SetBounds(20, 36, 310, 78)
    $form.Controls.Add($txtPos)

    $lbNeg = New-Object System.Windows.Forms.Label
    $lbNeg.Text = '负向提示词：'
    $lbNeg.SetBounds(20, 122, 200, 22)
    $form.Controls.Add($lbNeg)

    $txtNeg = New-Object System.Windows.Forms.TextBox
    $txtNeg.Multiline = $true
    $txtNeg.ScrollBars = 'Vertical'
    $txtNeg.Text = $Negative
    $txtNeg.SetBounds(20, 146, 310, 78)
    $form.Controls.Add($txtNeg)

    # 1-7) 参数行（y 从 240 起，行距 40）
    $labels = @('模式：', '底图：', '蒙版：', 'Denoising：', '迭代次数：', '比例：', '画风：', '画质：', 'LoRA：', '模型：', '命名：')
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $lb = New-Object System.Windows.Forms.Label
        $lb.Text = $labels[$i]
        $lb.SetBounds(20, (244 + $i * 40), 90, 22)
        $form.Controls.Add($lb)
    }

    # 0) 模式（只读下拉：文生图 / 图生图）—— 决策 C-0 / C-1 的总开关
    $cboMode = New-Object System.Windows.Forms.ComboBox
    $cboMode.DropDownStyle = 'DropDownList'
    foreach ($m in @('文生图', '图生图')) { $null = $cboMode.Items.Add($m) }
    $cboMode.SelectedIndex = 0
    $cboMode.SetBounds(120, (240 + 0 * 40), 190, 24)
    $form.Controls.Add($cboMode)
    $lbModeHint = New-Object System.Windows.Forms.Label
    $lbModeHint.Text = '（图生图用底图重绘；替换衣服/脸/背景请配合蒙版）'
    $lbModeHint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 7)
    $lbModeHint.ForeColor = [System.Drawing.Color]::Gray
    $lbModeHint.SetBounds(120, (240 + 0 * 40 + 24), 220, 16)
    $form.Controls.Add($lbModeHint)

    # 1) 底图（图生图用）：留空 = 最近一张；「最近」= 输出目录最新一张；也可填路径或点「浏览…」选图
    $txtInit = New-Object System.Windows.Forms.TextBox
    $txtInit.Text = "$InitImageDefault"
    $txtInit.SetBounds(120, (240 + 1 * 40), 120, 24)
    $form.Controls.Add($txtInit)
    $btnInitBrowse = New-Object System.Windows.Forms.Button
    $btnInitBrowse.Text = '浏览…'
    $btnInitBrowse.SetBounds(246, (240 + 1 * 40), 64, 24)
    $btnInitBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = '选一张底图（图生图用）'
        $ofd.Filter = '图片|*.png;*.jpg;*.jpeg;*.webp;*.bmp|所有文件|*.*'
        if ($ofd.ShowDialog() -eq 'OK') { $txtInit.Text = $ofd.FileName }
    })
    $form.Controls.Add($btnInitBrowse)
    $lbInitHint = New-Object System.Windows.Forms.Label
    $lbInitHint.Text = '（留空=最近一张；或填路径）'
    $lbInitHint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 7)
    $lbInitHint.ForeColor = [System.Drawing.Color]::Gray
    $lbInitHint.SetBounds(120, (240 + 1 * 40 + 24), 220, 16)
    $form.Controls.Add($lbInitHint)

    # 2) 蒙版（决策 C-1b：替换衣服/脸/背景时只重绘这一块，其余像素原样保留 → 画风天然一致）
    $cboMask = New-Object System.Windows.Forms.ComboBox
    $cboMask.DropDownStyle = 'DropDown'
    foreach ($v in @('无（整图重绘）', '上半（脸）', '下半（衣服）', '中间（主体）', '四周（背景）', '上半（脸）反选', '四周（背景）反选')) { $null = $cboMask.Items.Add($v) }
    $cboMask.Text = '无（整图重绘）'
    $cboMask.SetBounds(120, (240 + 2 * 40), 190, 24)
    $form.Controls.Add($cboMask)
    $lbMaskHint = New-Object System.Windows.Forms.Label
    $lbMaskHint.Text = '（白色=重绘区；也可填蒙版图路径）'
    $lbMaskHint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 7)
    $lbMaskHint.ForeColor = [System.Drawing.Color]::Gray
    $lbMaskHint.SetBounds(120, (240 + 2 * 40 + 24), 220, 16)
    $form.Controls.Add($lbMaskHint)

    # 3) Denoising（**恒可编辑**下拉：0 = 文生图；>0 = 重绘幅度）
    $cboDenoise = New-Object System.Windows.Forms.ComboBox
    $cboDenoise.DropDownStyle = 'DropDown'
    foreach ($v in @('0（文生图·不用底图）', '0.3', '0.4', '0.45', '0.5', '0.6', '0.7', '0.8', '0.9')) { $null = $cboDenoise.Items.Add($v) }
    $cboDenoise.Text = '0（文生图·不用底图）'
    $cboDenoise.SetBounds(120, (240 + 3 * 40), 190, 24)
    $cboDenoise.Enabled = $true
    $form.Controls.Add($cboDenoise)
    $lbDenoiseHint = New-Object System.Windows.Forms.Label
    $lbDenoiseHint.Text = '（图生图：0.4-0.5 贴底图；≥0.7 大改）'
    $lbDenoiseHint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 7)
    $lbDenoiseHint.ForeColor = [System.Drawing.Color]::Gray
    $lbDenoiseHint.SetBounds(120, (240 + 3 * 40 + 24), 220, 16)
    $form.Controls.Add($lbDenoiseHint)

    # 4) 迭代次数（可编辑下拉）
    $cboRounds = New-Object System.Windows.Forms.ComboBox
    $cboRounds.DropDownStyle = 'DropDown'
    foreach ($n in @(1, 2, 3, 4, 5, 8, 12, 16, 24, 32)) { $null = $cboRounds.Items.Add("$n") }
    $cboRounds.Text = "$DefaultRounds"
    $cboRounds.SetBounds(120, (240 + 4 * 40), 190, 24)
    $form.Controls.Add($cboRounds)

    # 5) 比例（只读下拉）
    $cboRatio = New-Object System.Windows.Forms.ComboBox
    $cboRatio.DropDownStyle = 'DropDownList'
    foreach ($r in @('9:16', '1:1', '3:4', '4:3', '16:9', '2:3', '3:2', '21:9')) { $null = $cboRatio.Items.Add($r) }
    $cboRatio.SelectedIndex = 0
    $cboRatio.SetBounds(120, (240 + 5 * 40), 190, 24)
    $form.Controls.Add($cboRatio)

    # 6) 画风（只读下拉）：首项「一致（自动检测参考图）」= 决策 C-1a，从参考图反推画风/主体；
    #    「保持画风」= 不注入任何画风词；其余档位 = 注入对应画风词（见 Get-StylePrompt）。
    $cboStyle = New-Object System.Windows.Forms.ComboBox
    $cboStyle.DropDownStyle = 'DropDownList'
    foreach ($s in @('一致（自动检测参考图）', '保持画风', '二次元', '写实二次元', '写实二次元·东亚脸', '彩色哥特', '釉彩调色盘', '国风', '赛博朋克', '写实', '厚涂', '水彩', '像素风')) { $null = $cboStyle.Items.Add($s) }
    $cboStyle.SelectedIndex = 2   # 默认「二次元」（文生图的默认档；切到图生图会自动改「一致」）
    $cboStyle.SetBounds(120, (240 + 6 * 40), 190, 24)
    $form.Controls.Add($cboStyle)

    # 7) 画质（只读下拉）
    $cboQuality = New-Object System.Windows.Forms.ComboBox
    $cboQuality.DropDownStyle = 'DropDownList'
    foreach ($q in @('480p', '640p', '768p', '1024p', '1280p', '1440p', '2160p（4K）')) { $null = $cboQuality.Items.Add($q) }
    $cboQuality.SelectedIndex = 0
    $cboQuality.SetBounds(120, (240 + 7 * 40), 190, 24)
    $form.Controls.Add($cboQuality)

    # 8) LoRA（可编辑下拉）
    $cboLora = New-Object System.Windows.Forms.ComboBox
    $cboLora.DropDownStyle = 'DropDown'
    $null = $cboLora.Items.Add('（不用 LoRA）')
    foreach ($l in $LoraList) { $null = $cboLora.Items.Add("$l 0.8") }
    $cboLora.SelectedIndex = 0
    $cboLora.SetBounds(120, (240 + 8 * 40), 190, 24)
    $form.Controls.Add($cboLora)
    if ($LoraList.Count -eq 0) {
        $lbLoraHint = New-Object System.Windows.Forms.Label
        $lbLoraHint.Text = '（SD 未运行，拉不到列表；可手填「名称 权重」）'
        $lbLoraHint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 7.5)
        $lbLoraHint.ForeColor = [System.Drawing.Color]::Gray
        $lbLoraHint.SetBounds(120, (240 + 8 * 40 + 26), 220, 18)
        $form.Controls.Add($lbLoraHint)
    }

    # 9) 模型（只读下拉）：首项显示真实当前模型；第 2 项「一致（照参考图）」= 用参考图自带的模型（PNG 元数据）
    $cboModel = New-Object System.Windows.Forms.ComboBox
    $cboModel.DropDownStyle = 'DropDownList'
    $curModelLabel = '（当前模型）'
    if ($CurrentModel) { $curModelLabel = "（当前模型：$CurrentModel）" }
    $null = $cboModel.Items.Add($curModelLabel)
    $null = $cboModel.Items.Add('一致（照参考图）')
    foreach ($m in $CheckpointList) { $null = $cboModel.Items.Add($m) }
    $cboModel.SelectedIndex = 0
    $cboModel.SetBounds(120, (240 + 9 * 40), 190, 24)
    $form.Controls.Add($cboModel)
    if ($CheckpointList.Count -eq 0) {
        $lbModelHint = New-Object System.Windows.Forms.Label
        $lbModelHint.Text = '（SD 未运行，拉不到列表）'
        $lbModelHint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 7.5)
        $lbModelHint.ForeColor = [System.Drawing.Color]::Gray
        $lbModelHint.SetBounds(120, (240 + 9 * 40 + 26), 220, 18)
        $form.Controls.Add($lbModelHint)
    }

    # 10) 命名（留空 = 按提示词总结命名）
    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Text = ''
    $txtName.SetBounds(120, (240 + 10 * 40), 190, 24)
    $form.Controls.Add($txtName)
    $lbNameHint = New-Object System.Windows.Forms.Label
    $lbNameHint.Text = '（留空 = 自动总结提示词命名）'
    $lbNameHint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 7.5)
    $lbNameHint.ForeColor = [System.Drawing.Color]::Gray
    $lbNameHint.SetBounds(120, (240 + 10 * 40 + 26), 220, 18)
    $form.Controls.Add($lbNameHint)

    # 画风联动：切换画风时把该画风的词**幂等**写进两个提示词框（剥旧词 → 加新词，不重复、不留 ",,"）
    $script:injectedStylePos = ""
    $script:injectedStyleNeg = ""
    $cboStyle.Add_SelectedIndexChanged({
        if ($script:injectedStylePos -and $txtPos.Text.Contains($script:injectedStylePos)) {
            $txtPos.Text = Remove-StyleWords -Text $txtPos.Text -Words $script:injectedStylePos
        }
        if ($script:injectedStyleNeg -and $txtNeg.Text.Contains($script:injectedStyleNeg)) {
            $txtNeg.Text = Remove-StyleWords -Text $txtNeg.Text -Words $script:injectedStyleNeg
        }
        $st = Get-StylePrompt -Style ([string]$cboStyle.SelectedItem)
        $script:injectedStylePos = ""
        $script:injectedStyleNeg = ""
        if ($st.Pos) {
            $script:injectedStylePos = $st.Pos
            $txtPos.Text = Add-StyleWords -Text $txtPos.Text -Words $st.Pos
        }
        if ($st.Neg) {
            $script:injectedStyleNeg = $st.Neg
            $txtNeg.Text = Add-StyleWords -Text $txtNeg.Text -Words $st.Neg
        }
    })

    # 模式联动：切到「图生图」→ 默认画风「一致（自动检测参考图）」+ Denoising 0.45；
    #            切回「文生图」→ 默认画风「二次元」+ Denoising 0（不用底图）。
    $cboMode.Add_SelectedIndexChanged({
        $st = Get-StylePrompt -Style ([string]$cboStyle.SelectedItem)
        if ([string]$cboMode.SelectedItem -eq '图生图') {
            if ([string]$cboStyle.SelectedItem -ne '一致（自动检测参考图）') { $cboStyle.SelectedIndex = 0 }
            if ($cboDenoise.Text -notmatch '^0?\.') { $cboDenoise.Text = '0.45' }
        } else {
            if ([string]$cboStyle.SelectedItem -eq '一致（自动检测参考图）') { $cboStyle.SelectedIndex = 2 }
            $cboDenoise.Text = '0（文生图·不用底图）'
        }
    })

    # 初始档位也要注入一次（SelectedIndex 是在挂事件之前设的，不补这一下默认档就没有词）
    try {
        $st0 = Get-StylePrompt -Style ([string]$cboStyle.SelectedItem)
        if ($st0.Pos) {
            $script:injectedStylePos = $st0.Pos
            $txtPos.Text = Add-StyleWords -Text $txtPos.Text -Words $st0.Pos
        }
        if ($st0.Neg) {
            $script:injectedStyleNeg = $st0.Neg
            $txtNeg.Text = Add-StyleWords -Text $txtNeg.Text -Words $st0.Neg
        }
    } catch { }

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '确定出图'
    $btnOk.SetBounds(110, 684, 100, 30)
    $form.AcceptButton = $btnOk
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.SetBounds(220, 684, 100, 30)
    $form.Controls.Add($btnCancel)

    $btnOk.Add_Click({ $form.DialogResult = 'OK'; $form.Close() })
    $btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })
    $form.CancelButton = $btnCancel

    # 诊断日志已关闭（用户要求 2026-10-14）：不再写 sd-inject-form-diag.log
    try {
        $dlgResult = $form.ShowDialog()
    } catch {
        $dlgResult = 'Cancel'
    }
    if ($dlgResult -ne 'OK') {
        Write-Host "已在参数表单取消。" -ForegroundColor Yellow
        exit 0
    }

    # 解析：非法输入回落默认（迭代次数回落默认轮数、Denoising 回落 0 = 文生图）
    $rounds = $DefaultRounds
    $null = [int]::TryParse($cboRounds.Text.Trim(), [ref]$rounds)
    if ($rounds -lt 1) { $rounds = 1 } elseif ($rounds -gt 32) { $rounds = 32 }
    # Denoising **恒定解析**（不再按 HasBaseImage 强行归零——表单先弹，那一刻必然还没有素体成品）：
    # 取文本框开头的数字（兼容「0（文生图·不用底图）」这类带说明的条目），0 = 文生图，>0 = 图生图重绘幅度；
    # 空值/非法 → 0（等于现状行为）。上限 0.95，防止填 1 直接把底图信息全洗掉。
    $den = 0.0
    $denMatch = [regex]::Match(($cboDenoise.Text -replace ',', '.').Trim(), '^[0-9]*\.?[0-9]+')
    if ($denMatch.Success) { $null = [double]::TryParse($denMatch.Value, [ref]$den) }
    if ($den -lt 0) { $den = 0 } elseif ($den -gt 0.95) { $den = 0.95 }
    return @{
        Pos     = $txtPos.Text.Trim()
        Neg     = $txtNeg.Text.Trim()
        Rounds  = $rounds
        Denoise = $den
        Ratio   = [string]$cboRatio.SelectedItem
        Style   = [string]$cboStyle.SelectedItem
        Quality = [string]$cboQuality.SelectedItem
        Lora    = $cboLora.Text.Trim()
        Model   = [string]$cboModel.SelectedItem
        Name    = $txtName.Text.Trim()
        InitImg = $txtInit.Text.Trim()
        Mode    = [string]$cboMode.SelectedItem
        Mask    = $cboMask.Text.Trim()
    }
}

# 比例 + 画质短边档 → SD 尺寸（8 的倍数；面积随画质档走，比例只定形状）
function Get-SizeFor {
    param([string]$Ratio, [string]$Quality)
    $short = 480
    switch ($Quality) {
        '640p'  { $short = 640 }
        '768p'  { $short = 768 }
        '1024p' { $short = 1024 }
        '1280p' { $short = 1280 }
        '1440p' { $short = 1440 }
        '2160p（4K）' { $short = 2160 }
    }
    $rw = 9.0; $rh = 16.0
    if ($Ratio -match '^(\d+):(\d+)$') { $rw = [double]$Matches[1]; $rh = [double]$Matches[2] }
    if ($rw -ge $rh) {
        $w = $short; $h = [int][math]::Round($short * $rh / $rw)
    } else {
        $h = $short; $w = [int][math]::Round($short * $rw / $rh)
    }
    $w = [int]([math]::Floor($w / 8)) * 8
    $h = [int]([math]::Floor($h / 8)) * 8
    if ($w -lt 256) { $w = 256 }
    if ($h -lt 256) { $h = 256 }
    return @{ W = $w; H = $h }
}

# ---- 素体自检迭代（只跑基底，绝不改提示词）----
# 脸/手质检：把图发给本地视觉模型（Ollama OpenAI 兼容端点 /chat/completions，image_url 用 base64 data URI），
# 让它只回一个 0-100 的整数分（脸部 + 手部综合）。判定线：>= 75 过关；< 45 且已试过面部修复 → 判定该模型不会看图，质检降级为「只要没成功启动过一次就当过关」，避免无限烧卡。
function Test-VlmApi {
    try {
        $null = Invoke-RestMethod -Uri "$QwenBase/models" -Method Get -TimeoutSec 5
        return $true
    } catch {
        return $false
    }
}

function Get-VlmCandidates {
    # 质检要的是视觉模型：vl / vision 排最前，专用代码模型依旧压底；缓存结果
    if ($script:VlmCandidateCache) { return $script:VlmCandidateCache }
    $models = @()
    foreach ($ep in @("$QwenBase/models", "$QwenBase/../api/tags")) {
        if ($models.Count -gt 0) { break }
        try {
            $r = Invoke-RestMethod -Uri $ep -Method Get -TimeoutSec 10
            if ($r -and $r.data) { $models = @($r.data | ForEach-Object { [string]$_.id }) }
            elseif ($r -and $r.models) { $models = @($r.models | ForEach-Object { [string]$_.name }) }
        } catch { }
    }
    if ($models.Count -eq 0) {
        # 一个都没枚举到：最常见的根因是 OLLAMA_MODELS 指向了空目录（模型实际在别处）。
        Write-Host "本地模型服务上一个模型都没枚举到（$QwenBase）" -ForegroundColor Red
        $ollamaModels = $env:OLLAMA_MODELS
        if (-not $ollamaModels) { $ollamaModels = '(未设，用默认 ~/.ollama/models)' }
        Write-Host "常见根因：OLLAMA_MODELS 指向了空目录。当前值：$ollamaModels" -ForegroundColor Yellow
    }
    $visionFirst = @($models | Where-Object { $_ -match 'vl|vision|llava|bakllava|moondream|minicpm-v|internvl' })
    $rest = @($models | Where-Object { $visionFirst -notcontains $_ })
    $script:VlmCandidateCache = @($visionFirst + $rest | Where-Object { $_ -and ($_ -notmatch 'embed|rerank') })
    return $script:VlmCandidateCache
}

function Test-FaceQuality {
    # 返回 0-100 整数分（解析失败返回 -1）。问句刻意只聊脸部与手部结构，不给模型任何「画面内容」的发挥空间。
    # 用户要求（2026-10-15）：手部细节也纳入质检——手指数量/多指/少指/粘连/畸形，与脸部一起综合打分。
    # 超时 180s：VLM 冷启动要把模型加载进显存，首问可能远慢于热状态（实测 8B 首问 >120s）。
    param([string]$ImagePath)
    try {
        $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ImagePath))
    } catch { return -1 }
    $userContent = @"
这张图里的人物脸部与手部结构健康吗？只检查两点：
① 脸部：眼睛是否对称/无多余、五官是否扭曲错位、脸部是否畸形融化；
② 手部：每只手是否五根手指齐全、有无多余或缺失的手指、手指是否扭曲粘连、手部是否畸形。
脸部或手部任一处崩坏都要相应扣分。只回复一个 0-100 的整数分（100=完全健康，0=严重崩坏），除此之外一个字符都不要输出。
"@
    $body = @{
        model = $VlmModel
        messages = @(
            @{ role = "user"; content = @(
                @{ type = "text"; text = $userContent },
                @{ type = "image_url"; image_url = @{ url = "data:image/png;base64,$b64" } }
            ) }
        )
        temperature = 0.1
        stream = $false
    }
    try {
        $headers = @{ "Content-Type" = "application/json; charset=utf-8" }
        if ($QwenApiKey) { $headers["Authorization"] = "Bearer $QwenApiKey" }
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 8))
        $resp = Invoke-RestMethod -Uri "$QwenBase/chat/completions" -Method Post -Headers $headers -Body $bodyBytes -TimeoutSec 180
    } catch { return -1 }
    $raw = Repair-Utf8Mojibake ([string]$resp.choices[0].message.content)
    $m = [regex]::Match($raw, '\d{1,3}')
    if (-not $m.Success) { return -1 }
    $score = 0
    if (-not [int]::TryParse($m.Value, [ref]$score)) { return -1 }
    if ($score -lt 0 -or $score -gt 100) { return -1 }
    return $score
}

function Invoke-BaseIterate {
    # 素体迭代主流程：只跑 $BasePrompt，每轮换 seed；有视觉模型时逐轮质检，没有就只出一张。
    # 返回 @{ Path = 图路径; Seed = 实际 seed; Score = 脸/手得分（没质检 = -1） }; 真出不了图才返回 $null。
    # 铁律：本函数不修改 $positive / $negative 的任何内容——不加词、不加替换词、不加安全词。
    # 2026-10-15 修：质检不可用**不再直接 return $null**——那样图生图（Denoising > 0）会因为
    # 「没有素体成品」被静默降级成文生图（用户实测：C 档根本用不了图生图）。现在照样出一张底图。
    $vlmOk = $true
    if (-not (Test-VlmApi)) {
        Write-Host "本地视觉模型不可用（$QwenBase）→ 素体只出一张底图、不跑脸/手质检迭代（图生图底图照常可用）" -ForegroundColor Yellow
        $vlmOk = $false
    } elseif (-not $VlmModel -or ((Get-VlmCandidates) -notcontains $VlmModel)) {
        $vlm = Get-VlmCandidates | Where-Object { $_ -match 'vl|vision' } | Select-Object -First 1
        if (-not $vlm) {
            Write-Host "本机没有视觉模型（vl/vision）→ 素体只出一张底图、不跑脸/手质检迭代；想质检请先：ollama pull qwen3-vl:8b" -ForegroundColor Yellow
            $vlmOk = $false
        } elseif ($vlm -ne $VlmModel) {
            Write-Host "质检模型已回退到 '$vlm'（要固定用 '$VlmModel' 先执行：ollama pull $VlmModel）" -ForegroundColor Yellow
            $script:VlmModel = $vlm
        }
    }
    # 预热：发一条纯文本空问，把模型先加载进显存——否则首轮带图质检会撞冷启动超时（实测 >120s）
    if ($vlmOk) {
        try {
            $null = Invoke-RestMethod -Uri "$QwenBase/chat/completions" -Method Post `
                -Headers @{ "Content-Type" = "application/json; charset=utf-8"; "Authorization" = "Bearer $QwenApiKey" } `
                -Body ([System.Text.Encoding]::UTF8.GetBytes((@{ model = $VlmModel; messages = @(@{ role = "user"; content = "1" }); stream = $false } | ConvertTo-Json -Depth 6))) `
                -TimeoutSec 300
        } catch { }
    }

    Write-Host "素体自检迭代中..." -ForegroundColor Cyan
    $bestPath = ''
    $bestSeed = -1
    $bestScore = -1
    $roundsUsed = 0
    $vlmEverWorked = $false
    $giveUpVlm = (-not $vlmOk)   # 没质检 → 出完第一轮就收（当底图用）
    for ($round = 1; $round -le $IterateRounds; $round++) {
        $roundsUsed = $round
        $iterArgs = @(
            "-ExecutionPolicy", "Bypass", "-File", "`"$SdDirect`"",
            "-Prompt", "`"$BasePrompt`"",
            "-Negative", "`"$BaseNegative`"",
            "-Width", "$Width", "-Height", "$Height",
            "-Steps", "$Steps", "-Cfg", "$Cfg",
            "-Sampler", "`"$Sampler`"",
            "-Seed", "-1",
            "-OutDir", "`"$script:IterTempDir`"",
            "-Name", "`"$Name`""
        )
        if ($SdDir) { $iterArgs += @("-SdDir", "`"$SdDir`"") }
        # 坑33：不开 SD 内置面部修复（-RestoreFaces）。8G 显存下 CodeFormer/GFPGAN 与质检模型
        # 抢显存，出图进度 100% 后卡死（实测「出图第 2 轮（含面部修复）卡住」）。质检已靠
        # VLM 打分换 seed 重试，不需要 SD 内置修复。
        # 迭代期间不弹窗，最终那张才弹；sd-direct.ps1 会打印 SEEDVALUE 行，捕获真实 seed
        $iterArgs += "-NoOpen"
        Write-Host "素体第 $round/$IterateRounds 轮..." -ForegroundColor Cyan
        $iterOut = & powershell @iterArgs 2>&1
        $iterOut | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "素体出图失败（exit $LASTEXITCODE），中止迭代" -ForegroundColor Red
            Remove-IterTempDir
            exit 1
        }
        # 从输出里解析真实 seed（Seed: 行；SEEDVALUE 是给机器看的冗余行）
        $roundSeed = -1
        $seedLine = @($iterOut | Where-Object { $_ -match '^SEEDVALUE:\s*(\d+)' } | Select-Object -First 1)
        if ($seedLine -and $seedLine -match '^SEEDVALUE:\s*(\d+)') { $roundSeed = [long]$Matches[1] }
        # sd-direct.ps1 的命名规则 = <Name>_<序号:D3>.png，本流程独占 $Name 前缀，取序号最大的那张
        $cand = Get-ChildItem -LiteralPath $script:IterTempDir -Filter "$Name`_*.png" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $cand) {
            Write-Host "找不到本轮产物（$script:IterTempDir\$Name`_*.png），中止迭代" -ForegroundColor Red
            Remove-IterTempDir
            exit 1
        }
        if ($giveUpVlm) {
            $bestPath = $cand.FullName
            $bestSeed = $roundSeed
            break
        }
        $score = Test-FaceQuality -ImagePath $cand.FullName
        if ($score -ge 0) { $vlmEverWorked = $true }
        if ($score -lt 0) {
            # 视觉模型没给出分数：第一轮先重试一轮（可能是冷启动抖动），仍不行就降级为「出一张就收」
            if ($round -lt $IterateRounds) {
                Write-Host "质检无分数（视觉模型未就绪或解析失败），再试一轮" -ForegroundColor Yellow
                continue
            }
            $bestPath = $cand.FullName
            $bestSeed = $roundSeed
            break
        }
        Write-Host "  脸/手质检得分：$score/100（>= 75 过关）" -ForegroundColor DarkGray
        if ($score -gt $bestScore) {
            $bestScore = $score; $bestPath = $cand.FullName; $bestSeed = $roundSeed
            # 增量落盘：新最高分立即复制进工作区（中途关闭也不丢当前最优成品）
            try {
                $null = New-Item -ItemType Directory -Path $OutDir -Force
                Copy-Item -LiteralPath $bestPath -Destination (Join-Path $OutDir (Split-Path $bestPath -Leaf)) -Force
            } catch { }
        }
        if ($score -ge 75) { break }
        # 低于 45 且已经开过面部修复还没救回来 → 质检模型大概率不会看图，别再烧轮数
        if ($score -lt 45 -and $round -ge 2) {
            Write-Host "  连续低分且已开面部修复——判定质检模型不可靠，采用本轮结果" -ForegroundColor Yellow
            $giveUpVlm = $true
            $bestPath = $cand.FullName
            $bestSeed = $roundSeed
            try {
                $null = New-Item -ItemType Directory -Path $OutDir -Force
                Copy-Item -LiteralPath $bestPath -Destination (Join-Path $OutDir (Split-Path $bestPath -Leaf)) -Force
            } catch { }
            break
        }
    }
    if (-not $bestPath) { return $null }
    return @{ Path = $bestPath; Seed = $bestSeed; Score = $bestScore; RoundsUsed = $roundsUsed }
}

function Invoke-FinalIterate {
    # 最终出图迭代：按表单参数连出 $Rounds 张（换 seed），每张质检脸/手取最高分。
    # 质检失败/超时（得分 < 0）时：不再烧轮数，改为把「本轮及后续各轮」都生成出来、
    # 全部保留让用户自己选（多选模式）。返回 @{ Paths = 图路径数组; Seed; Score }。
    param(
        [string]$InitImage = "",
        [double]$Denoising = 0.7,
        [int]$Rounds = 1,
        [int]$W = 512,
        [int]$H = 768,
        [string]$Checkpoint = "",
        [string]$Mask = "",           # 蒙版图（白=重绘区）：决策 C-1b 替换衣服/脸/背景时走蒙版重绘
        [int]$InpaintFill = 0         # 蒙版区底色：0=填充（默认，替换最稳）1=保留原图 2=潜空间噪声（会在蒙版区留噪点）
    )
    $bestPath = ''
    $bestSeed = -1
    $bestScore = -1
    $allPaths = @()
    $vlmDown = $false
    for ($round = 1; $round -le $Rounds; $round++) {
        $finalArgs = @(
            "-ExecutionPolicy", "Bypass", "-File", "`"$SdDirect`"",
            "-Prompt", "`"$positive`"",
            "-Negative", "`"$finalNegative`"",
            "-Width", "$W", "-Height", "$H",
            "-Steps", "$Steps", "-Cfg", "$Cfg",
            "-Sampler", "`"$Sampler`"",
            "-Seed", "-1",
            "-OutDir", "`"$script:IterTempDir`"",
            "-Name", "`"$Name`""
        )
        if ($Checkpoint) { $finalArgs += @("-Checkpoint", "`"$Checkpoint`"") }
        if ($InitImage -and (Test-Path -LiteralPath $InitImage)) {
            $finalArgs += @("-InitImage", "`"$InitImage`"", "-Denoising", "$Denoising")
            if ($Mask -and (Test-Path -LiteralPath $Mask)) {
                $finalArgs += @("-Mask", "`"$Mask`"", "-InpaintFill", "$InpaintFill", "-InpaintPadding", "32")
            }
        }
        if ($SdDir) { $finalArgs += @("-SdDir", "`"$SdDir`"") }
        $finalArgs += "-NoOpen"
        $roundMode = if ($Mask) { "蒙版重绘 denoising=$Denoising" } elseif ($InitImage) { "图生图 denoising=$Denoising" } else { "文生图" }
        Write-Host "出图第 $round/$Rounds 轮（$roundMode）..." -ForegroundColor Cyan
        $finalOut = & powershell @finalArgs 2>&1
        $finalOut | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "出图失败（exit $LASTEXITCODE），中止迭代" -ForegroundColor Red
            Remove-IterTempDir
            exit 1
        }
        $roundSeed = -1
        $seedLine = @($finalOut | Where-Object { $_ -match '^SEEDVALUE:\s*(\d+)' } | Select-Object -First 1)
        if ($seedLine -and $seedLine -match '^SEEDVALUE:\s*(\d+)') { $roundSeed = [long]$Matches[1] }
        $cand = Get-ChildItem -LiteralPath $script:IterTempDir -Filter "$Name`_*.png" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $cand) {
            Write-Host "找不到本轮产物（$script:IterTempDir\$Name`_*.png），中止迭代" -ForegroundColor Red
            Remove-IterTempDir
            exit 1
        }
        # 记录本轮产物
        $allPaths += $cand.FullName
        $bestPath = $cand.FullName
        $bestSeed = $roundSeed

        if ($vlmDown) {
            # 质检已失效：后续轮不再质检，直接出满剩余张数（多选模式）
            Write-Host "  质检已失效，直接生成（用户自选）" -ForegroundColor Yellow
            continue
        }
        $score = Test-FaceQuality -ImagePath $cand.FullName
        if ($score -lt 0) {
            # 质检失败/超时：不再烧轮数，改为出满 $Rounds 张让用户自选（用户要求）
            Write-Host "  质检无分数——后续各轮直接生成，全部保留供你选择" -ForegroundColor Yellow
            $vlmDown = $true
            $bestScore = -1
            continue
        }
        Write-Host "  脸/手质检得分：$score/100（>= 75 过关）" -ForegroundColor DarkGray
        if ($score -gt $bestScore) { $bestScore = $score; $bestPath = $cand.FullName; $bestSeed = $roundSeed }
        if ($score -ge 75) { break }
    }
    if ($allPaths.Count -eq 0) { return $null }
    return @{ Paths = $allPaths; Path = $bestPath; Seed = $bestSeed; Score = $bestScore; VlmDown = $vlmDown }
}

# 质检模型起不来时的收尾选择器：把候选图列成「文件名 + 勾选框」的多选对话框（纯文本，绝不白屏），
# 右侧带一张选中项的预览图；取消或一张没选 = 全部保留。返回保留的路径数组。
function Show-ImagePicker {
    param([string[]]$Images)
    if (-not $Images -or $Images.Count -eq 0) { return @() }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "质检模型未就绪 · 请选择要保留的图片（勾选 = 保留）"
    $form.ClientSize = New-Object System.Drawing.Size(720, 520)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'
    $form.MinimizeBox = $true
    $form.MaximizeBox = $true
    $form.TopMost = $true

    # 左侧：文件名勾选列表（纯文本，不依赖缩略图加载，从根上杜绝白屏）
    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.CheckOnClick = $true
    $clb.IntegralHeight = $false
    $clb.SetBounds(12, 12, 300, 460)
    $clb.Font = New-Object System.Drawing.Font('Microsoft YaHei', 9)
    foreach ($src in $Images) {
        $idx = $clb.Items.Add((Split-Path $src -Leaf))
        $clb.SetItemChecked($idx, $true)   # 默认全选
    }
    $form.Controls.Add($clb)

    # 右侧：选中项预览（加载失败就显示灰色占位，不影响左侧列表）
    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.SetBounds(324, 12, 380, 400)
    $pic.SizeMode = 'Zoom'
    $pic.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 46)
    $pic.BorderStyle = 'FixedSingle'
    $form.Controls.Add($pic)

    # 选中变化 → 刷新预览（用脚本作用域数组按索引取路径；缩略图加载失败静默跳过）
    $script:pickerPaths = @($Images)
    $clb.Add_SelectedIndexChanged({
        $i = $clb.SelectedIndex
        if ($i -ge 0 -and $script:pickerPaths[$i]) {
            $srcPath = $script:pickerPaths[$i]
            try {
                if (Test-Path -LiteralPath $srcPath) {
                    $img = [System.Drawing.Image]::FromFile($srcPath)
                    try { $pic.Image = New-Object System.Drawing.Bitmap($img) }
                    finally { $img.Dispose() }
                }
            } catch { $pic.Image = $null }
        }
    })
    # 默认选中第一张并出预览
    if ($clb.Items.Count -gt 0) { $clb.SelectedIndex = 0 }

    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Dock = 'Bottom'
    $pnl.Height = 46
    $pnl.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 8)
    $form.Controls.Add($pnl)

    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = '全选'
    $btnAll.SetBounds(10, 8, 70, 30)
    $pnl.Controls.Add($btnAll)
    $btnAll.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } })

    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = '全不选'
    $btnNone.SetBounds(90, 8, 70, 30)
    $pnl.Controls.Add($btnNone)
    $btnNone.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } })

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '保留所选'
    $btnOk.SetBounds(560, 8, 90, 30)
    $pnl.Controls.Add($btnOk)
    $form.AcceptButton = $btnOk
    $btnOk.Add_Click({ $form.DialogResult = 'OK'; $form.Close() })

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消（全部保留）'
    $btnCancel.SetBounds(655, 8, 100, 30)
    $pnl.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel
    $btnCancel.Add_Click({ $form.DialogResult = 'Cancel'; $form.Close() })

    $null = $form.ShowDialog()
    $kept = @()
    if ($form.DialogResult -eq 'OK') {
        for ($i = 0; $i -lt $clb.Items.Count; $i++) {
            if ($clb.GetItemChecked($i) -and $script:pickerPaths[$i]) { $kept += [string]$script:pickerPaths[$i] }
        }
        if ($kept.Count -eq 0) { $kept = @($Images) }   # 一张没选 = 视为全部保留，避免误删
    } else {
        $kept = @($Images)   # 取消 = 全部保留
    }
    $form.Dispose()
    return $kept
}


function Find-Ollama {
    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe", "D:\ollama\ollama.exe", "C:\ollama\ollama.exe", "$env:ProgramFiles\Ollama\ollama.exe", "${env:ProgramFiles(x86)}\Ollama\ollama.exe")) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return ''
}


# ---- 0) 出图参数表单先弹（脚本一启动就弹，不等素体迭代）：正向/负向提示词 + 迭代次数 / Denoising / 比例 / 画风 / 画质 / LoRA / 模型 ----
# 表单放最前面：用户先填参数 → 再跑素体迭代与最终出图，避免「屏幕静止几分钟像卡死」。
# 注：表单时素体还没跑（HasBaseImage=false），Denoising 档位先按无素体展示。
$hasBaseImg = $false
if ($baseWin -and (Test-Path -LiteralPath $baseWin.Path)) { $hasBaseImg = $true }

# 0a) 弹表单前先预热 SD：确保本机 SD API 已就绪，这样表单里 LoRA / 模型下拉能拉到真实列表，
#     不会因为 SD 还没起（首次冷启动要加载模型 1-3 分钟）而显示「SD 未运行，拉不到列表」。
#     用 sd-direct.ps1 的 -StartOnly 模式拉起：它自带启动进度条与运行时间，就绪即退、不出图。
if (-not (Test-SdApiReady)) {
    Write-Host "首次使用：正在拉起 Stable Diffusion（含模型加载，进度见下方进度条）..." -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $SdDirect)) {
        Write-Host "预热跳过：找不到 sd-direct.ps1（$SdDirect），LoRA/模型列表可能为空" -ForegroundColor Yellow
    } else {
        $preheatArgs = @("-ExecutionPolicy", "Bypass", "-File", "`"$SdDirect`"", "-StartOnly")
        if ($SdDir) { $preheatArgs += @("-SdDir", "`"$SdDir`"") }
        $preheatOut = & powershell @preheatArgs 2>&1
        $preheatOut | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            # 预热失败不阻断主流程：仍弹出表单，只是 LoRA/模型列表可能拉不到
            Write-Host "SD 预热未完成（exit $LASTEXITCODE），继续弹表单（LoRA/模型列表可能为空）" -ForegroundColor Yellow
        } else {
            Write-Host "SD 已就绪，正在拉取 LoRA / 模型列表..." -ForegroundColor Cyan
        }
    }
}

# 迭代次数默认 3（用户指定；质检不稳定时降到 3 轮快速验证，多选时出 3 张让用户选）
$paramFormRounds = 3
$sdLoras = Get-SdLoras
$sdCheckpoints = Get-SdCheckpoints
$sdCurrentModel = Get-SdCurrentModel   # 真实当前底子：画风切模型是持久的，规则与表单都要看到它
# 表单预填前先补末尾英文逗号：让两个输入框里显示的基底提示词末尾就带逗号（用户要求）
$formPositive = $BasePrompt
$formNegative = $BaseNegative
if ($formPositive -and ($formPositive -notmatch ',\s*$')) { $formPositive = $formPositive.TrimEnd() + ", " }
if ($formNegative -and ($formNegative -notmatch ',\s*$')) { $formNegative = $formNegative.TrimEnd() + ", " }
$P = Show-ParamForm -DefaultRounds $paramFormRounds -HasBaseImage $hasBaseImg -Positive $formPositive -Negative $formNegative -LoraList $sdLoras -CheckpointList $sdCheckpoints -InitImageDefault $InitImage -CurrentModel $sdCurrentModel
# 表单里的提示词是最终值（基底 + 用户在表单里的修改/追加）
$positive = $P.Pos
$negative = $P.Neg
# 点确定后立即显示「开始绘制」（用户要求：表单确认后立刻显示）
Write-Host ""
Write-Host "开始绘制" -ForegroundColor Cyan

# 末尾补英文逗号：两个输入框处理后的提示词，若末尾没有逗号就补一个，
# 保证后面追加脸部词/LoRA/全身等拼接时不会粘连（用户要求）。
if ($positive -and $positive.Trim() -and ($positive.Trim() -notmatch ',\s*$')) { $positive = $positive.Trim() + ", " }
if ($negative -and $negative.Trim() -and ($negative.Trim() -notmatch ',\s*$')) { $negative = $negative.Trim() + ", " }

# 默认景别「全身」：若用户未在正向提示词里指定任何构图/景别词（上半身/半身/头像/特写等），
# 自动追加 "full body"（用户要求：没说明就默认全身）。
$framingWords = 'full body|upper body|half body|headshot|portrait|close-up|closeup|bust|waist up|waist-up|cowboy shot|knee up|face|half-length|three-quarter|fullbody|whole body'
if ($positive -and ($positive -notmatch $framingWords)) {
    if ($positive -notmatch 'full body') {
        $positive = "$positive full body, "
    }
}

# ---- 0b) 素体自检迭代（表单确认后再跑）：只跑基底，换 seed + 面部修复迭代到脸部过关 ----
# 追加为空时迭代产物就是最终图；有追加/参数变化时用 winning seed/图锚定最终出图，保住过关的脸。
$baseWin = $null
if (-not $NoIterate) {
    $baseWin = Invoke-BaseIterate
    if ($baseWin) {
        Write-Host "素体迭代完成：$($baseWin.Path)（seed=$($baseWin.Seed)，脸/手 $($baseWin.Score)/100）" -ForegroundColor Green
    }
}
if ($baseWin -and (Test-Path -LiteralPath $baseWin.Path)) { $hasBaseImg = $true }

# 脸部细节词：自动追加进正向（去重——用户已手写过的词不重复加）
$faceTags = @()
foreach ($t in ($FaceBoostTags -split ',')) {
    $tt = $t.Trim()
    if ($tt -and ($positive -notmatch [regex]::Escape($tt))) { $faceTags += $tt }
}
if ($faceTags.Count -gt 0) {
    $positive = "$positive, $($faceTags -join ', ')"
    Write-Host "已追加脸部细节词：$($faceTags -join ', ')" -ForegroundColor DarkGray
}

# LoRA：表单选择 → <lora:名称:权重> 拼进正向（用户要求：可选择拉取新 lora）
$loraFragment = ""
if ($P.Lora -and $P.Lora -ne '（不用 LoRA）') {
    $loraName = $P.Lora
    $loraWeight = 0.8
    if ($P.Lora -match '^(.*?)\s+([0-9]+(?:\.[0-9]+)?)\s*$') {
        $loraName = $Matches[1].Trim()
        $null = [double]::TryParse($Matches[2], [ref]$loraWeight)
        if ($loraWeight -le 0) { $loraWeight = 0.8 } elseif ($loraWeight -gt 1.5) { $loraWeight = 1.5 }
    }
    $loraFragment = Format-LoraFragment -LoraName $loraName -Weight $loraWeight
    $positive = "$positive, $loraFragment"
    Write-Host "已挂 LoRA：$loraFragment" -ForegroundColor DarkGray
}

$size = Get-SizeFor -Ratio $P.Ratio -Quality $P.Quality
# 模型切换：表单选了具体 checkpoint（非「（当前模型）」）才传给出图子流程
$formCheckpoint = ""
if ($P.Model -and ($P.Model -notlike '（当前模型*') -and $P.Model -ne '') { $formCheckpoint = $P.Model }

# 最终命名：表单「命名」栏 > 提示词总结 > 默认 inject；统一用 Get-UniqueOutPath 去重递增
$finalBaseName = $P.Name
if (-not $finalBaseName) { $finalBaseName = Summarize-PromptName -Prompt $positive }
if (-not $finalBaseName) { $finalBaseName = $Name }

Write-Host ""
$denoiseDesc = if ($P.Denoise -gt 0) { "Denoising $($P.Denoise)（图生图）" } else { "Denoising 0（文生图）" }
$initDesc = if ("$($P.InitImg)") { "底图「$($P.InitImg)」" } else { "底图=素体成品" }
Write-Host "出图参数：迭代 $($P.Rounds) 次 | $denoiseDesc | $initDesc | 比例 $($P.Ratio)（$($size.W)x$($size.H)） | 画风 $($P.Style) | 画质 $($P.Quality)$(if ($loraFragment) { " | LoRA $loraFragment" })$(if ($formCheckpoint) { " | 模型 $formCheckpoint" }) | 命名 $finalBaseName" -ForegroundColor Green
Write-Host "正向: $positive" -ForegroundColor White
Write-Host "负向: $negative" -ForegroundColor White

# ---- 5) 最终出图（按表单参数迭代，取脸/手最高分那张）----
# 画风词已由表单联动（切换画风时注入两个提示词框）写进 $P.Pos/$P.Neg，这里**不再二次追加**，
# 否则会重复（用户要求：C 档弹表单时根据画风在两个提示词框里加入对应画风词）。
# 这里只保留「画风 → 自动切模型」的兜底逻辑（写实 → majicMIX；写实二次元 → 首选动漫底子不切模型，备选 SemiRealMix）。

# 二次元画风：**必须显式切回动漫底**（2026-10-15 修「二次元画风画不出来」的核心）。
# 原因：画风自动切模型是持久的——写实 → majicMIX、彩色哥特 → SemiRealMix 之后，SD 会一直停在那；
# 再选「二次元」若不切回来，出的就是写实/半写实图（实测现网 SD 当时正停在 SemiRealMix 上）。
if ($P.Style -eq '二次元' -and -not $formCheckpoint) {
    $animeCkpt = Get-AnimeCheckpoint -Checkpoints $sdCheckpoints
    if ($animeCkpt) {
        $formCheckpoint = $animeCkpt
        if ($sdCurrentModel -and $sdCurrentModel -ne $animeCkpt) {
            Write-Host "二次元画风：当前底子是 $sdCurrentModel（不是动漫底）→ 自动切回动漫底 $animeCkpt" -ForegroundColor DarkGray
        } else {
            Write-Host "二次元画风：使用动漫底 $animeCkpt" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "二次元画风：本机未找到动漫底 checkpoint（当前 $sdCurrentModel），建议装 AWPainting / anything-v5" -ForegroundColor Yellow
    }
}

# 写实画风且用户没在表单里手动选模型 → 自动切到本机写实 checkpoint（majicMIX），
# 否则写实词落在动漫模型上会画风漂移（实测：AWPainting + 写实词 → 光影写实但脸还是动漫）。
if ($P.Style -eq '写实' -and -not $formCheckpoint) {
    $realisticCkpt = @($sdCheckpoints | Where-Object { $_ -match 'majicMIX|majicmix|realistic|麦橘|写实' } | Select-Object -First 1)
    if ($realisticCkpt) {
        $formCheckpoint = $realisticCkpt
        Write-Host "写实画风：自动切换模型 → $formCheckpoint" -ForegroundColor DarkGray
    } else {
        Write-Host "写实画风：本机未找到写实 checkpoint，用当前模型（建议 ollama 或 SD 里补装 majicMIX）" -ForegroundColor Yellow
    }
}

# 写实二次元画风（十轮迭代实测结论）：首选「动漫底子 + 半写实 LoRA」——画风词里的
# <lora:semirealisticanime:0.6> 已经把脸拉向现代 CG 半写实，此时**保持动漫模型（不切）**效果最好；
# 实测 SemiRealMix 做底反而容易出 3D 娃娃脸或直接跑成真人照片，只在半写实 LoRA 缺失时退回它。
if ($P.Style -in @('写实二次元', '写实二次元·东亚脸') -and -not $formCheckpoint) {
    $hasSemirealLora = @($sdLoras | Where-Object { $_ -match 'semirealisticanime' }).Count -gt 0
    if ($hasSemirealLora) {
        if (Test-RealisticCheckpoint $sdCurrentModel) {
            # 当前底是写实向（多半是上一次 写实/彩色哥特 留下的）→ 先切回动漫底，不然半写实 LoRA 挂在写实底上更糊
            $animeCkpt = Get-AnimeCheckpoint -Checkpoints $sdCheckpoints
            if ($animeCkpt) {
                $formCheckpoint = $animeCkpt
                Write-Host "写实二次元画风：当前底子是写实向（$sdCurrentModel）→ 先切回动漫底 $animeCkpt，再挂半写实 LoRA 0.6" -ForegroundColor DarkGray
            } else {
                Write-Host "写实二次元画风：当前是写实底（$sdCurrentModel）且本机找不到动漫底，保持当前模型 + 半写实 LoRA（会偏写实）" -ForegroundColor Yellow
            }
        } else {
            Write-Host "写实二次元画风：保持动漫模型 + 半写实 LoRA 0.6（实测最优路径，不切模型）" -ForegroundColor DarkGray
        }
    } else {
        $semirealCkpt = @($sdCheckpoints | Where-Object { $_ -match 'SemiReal|semireal|半写实|2.5d|2\.5D' } | Select-Object -First 1)
        if ($semirealCkpt) {
            $formCheckpoint = $semirealCkpt
            Write-Host "写实二次元画风：未找到半写实 LoRA（semirealisticanime），退回 SemiRealMix 模型 → $formCheckpoint（建议跑 install-sd.ps1 补装 semireal LoRA，效果更稳）" -ForegroundColor Yellow
        } else {
            Write-Host "写实二次元画风：半写实 LoRA 与 SemiRealMix 都没有，用当前模型（跑 install-sd.ps1 补装 semireal / semirealmix）" -ForegroundColor Yellow
        }
    }
}

# 彩色哥特画风（原「真人感半写实」改名演化）：SemiRealMix 做底——它堆金、厚涂、高饱和的
# 特性在这套词里正好是哥特华丽感的本体。用户没手动选模型时自动切到 SemiRealMix。
if ($P.Style -eq '彩色哥特' -and -not $formCheckpoint) {
    $semirealCkpt = @($sdCheckpoints | Where-Object { $_ -match 'SemiReal|semireal|半写实|2.5d|2\.5D' } | Select-Object -First 1)
    if ($semirealCkpt) {
        $formCheckpoint = $semirealCkpt
        Write-Host "彩色哥特画风：自动切换模型 → $formCheckpoint" -ForegroundColor DarkGray
    } else {
        Write-Host "彩色哥特画风：本机未找到 SemiRealMix，用当前模型（跑 install-sd.ps1 补装 semirealmix）" -ForegroundColor Yellow
    }
}

# 追加为空（表单里提示词与基底一致 + 无脸部词/LoRA 追加）+ 素体迭代已产出成品 + 参数全是默认形态（无比例/画质/画风调整）
# + Denoising=0（用户没要求图生图）：不重复出图，直接收尾。
# 注：Denoising>0 时**不**走这条捷径——用户明确要用素体图做底图重绘，必须真正出一轮图生图。
$defaultsOnly = ($P.Ratio -eq '9:16' -and $P.Quality -eq '480p' -and $P.Style -in @('保持画风', '二次元') -and $P.Rounds -eq $paramFormRounds -and $P.Denoise -le 0 -and -not "$($P.InitImg)")
$promptsUntouched = ($positive -eq $formPositive.Trim() -and $negative -eq $formNegative.Trim())
# 决策日志已关闭（用户要求 2026-10-14）：不再写 sd-inject-decision.log
if ($promptsUntouched -and $hasBaseImg -and $defaultsOnly) {
    Write-Host ""
    Write-Host "追加为空：素体迭代产物即最终图，不再重复出图。" -ForegroundColor Green
    # 素体图目前还在临时目录：用「工作区唯一序号」复制进工作区（不覆盖历史成品）
    $finalPath = Get-UniqueOutPath -BaseName $finalBaseName
    Copy-Item -LiteralPath $baseWin.Path -Destination $finalPath -Force
    Remove-IterTempDir
    Write-Host "成品: $finalPath（seed=$($baseWin.Seed)，脸/手 $($baseWin.Score)/100）"
    if (-not $NoOpen) {
        try {
            Start-Process -FilePath $finalPath
            Write-Host "已打开: $finalPath"
        } catch {
            Write-Host "自动打开失败（$($_.Exception.Message)），可手动打开：$finalPath" -ForegroundColor Yellow
        }
    }
    exit 0
}

# 组装最终负向：负向提示词已含「画风负面词」（表单联动注入），这里直接用 $negative。
# 画风词不再二次追加（否则会与表单里已注入的词重复）。
$finalNegative = $negative

# 组装最终正向：正向提示词已含「画风正向词」（表单联动注入），这里直接用 $positive。

# 最终末尾补英文逗号：正向/负向经过 full body、脸部词、LoRA、画风负面等追加后，
# 末尾可能又没有逗号了，出图前统一再补一次（用户要求：提示词末尾加英文逗号）。
if ($positive -and ($positive -notmatch ',\s*$')) { $positive = $positive.TrimEnd() + ", " }
if ($finalNegative -and ($finalNegative -notmatch ',\s*$')) { $finalNegative = $finalNegative.TrimEnd() + ", " }

# 送 SD 前最后一道提示词净化：脸部词/LoRA/画风词反复追加可能留下 "a,, b" 这种空标签（实测会出现），
# 折叠成单个逗号后再补回结尾逗号（把「末尾必须有英文逗号」这条要求保下来）。
if ($positive) { $positive = (($positive -replace '(\s*,\s*)+', ', ').Trim().TrimEnd(',')).Trim() + ", " }
if ($finalNegative) { $finalNegative = (($finalNegative -replace '(\s*,\s*)+', ', ').Trim().TrimEnd(',')).Trim() + ", " }

# ---- 决策树：C-0 文生图 / C-1a 图生图·一致 / C-1b 图生图·替换（蒙版重绘）----
# 表单的「模式」是总开关：
#   C-0  文生图                → 忽略底图与蒙版，用完整提示词直出
#   C-1  图生图 + 画风=一致     → 从**参考图**自动检测画风/主体/模型并写进提示词，denoising 0.4-0.5 保画风
#   C-1b 图生图 + 替换（衣服/脸/背景）→ **蒙版重绘**：只重绘目标区域，未蒙版区域像素原样保留
#        （画风天然一致；这正是「换个衣服结果画风也变了」的正解）
$mode = "$($P.Mode)"
$maskSpecRaw = "$($P.Mask)"
$initRaw = "$($P.InitImg)"
$refPath = Resolve-InitImagePath -Raw $initRaw -OutDirPath $OutDir
$finalInit = ""
$finalDenoise = 0.0
$finalMask = ""
$inpaintFill = 0
$branchTag = "C-0 文生图"

if ($mode -eq '图生图' -and -not $refPath) {
    # 图生图没给底图 → 自动退到「输出目录最新一张」；再没有就明确报错，不默默改成文生图
    $refPath = Resolve-InitImagePath -Raw '最近' -OutDirPath $OutDir
    if ($refPath) {
        Write-Host "图生图：表单没填底图 → 自动用输出目录最新一张：$refPath" -ForegroundColor DarkGray
    } else {
        Write-Host "错误：选了「图生图」但没有可用底图（表单「底图」留空，输出目录里也没有图片）。" -ForegroundColor Red
        Write-Host "      请填底图路径 / 点「浏览…」选一张，或先出一张图再重试。" -ForegroundColor Yellow
        Remove-IterTempDir
        exit 1
    }
}

if ($mode -eq '文生图') {
    Write-Host "[决策 C-0] 文生图：忽略底图与蒙版，用完整提示词直出" -ForegroundColor Cyan
} else {
    $finalInit = $refPath
    $pngParams = Get-PngGenParams -Path $refPath          # ① 参考图自带 A1111 元数据（最强一致）
    $refTags = ''
    $styleFromRef = ''
    $styleBasis = @()
    if ($pngParams) {
        if ($pngParams.Model) { $styleBasis += "PNG 元数据 Model=$($pngParams.Model)" }
        if ($pngParams.Positive) { $styleBasis += 'PNG 元数据 原提示词' }
    }

    # 画风=一致 → 自动检测（元数据 → VLM → A1111 反推），并把参考图的词并进提示词
    if ("$($P.Style)" -eq '一致（自动检测参考图）') {
        if ($pngParams -and $pngParams.Model) {
            if (Test-RealisticCheckpoint $pngParams.Model) { $styleFromRef = '写实二次元' } else { $styleFromRef = '二次元' }
        }
        if (-not $styleFromRef) { $styleFromRef = Get-ImageStyleByVlm -Path $refPath }
        if (-not $refTags) { $refTags = Get-ImageTags -Path $refPath -PreferClip ([bool](-not $pngParams)) }
        if (-not $styleFromRef -and $refTags) {
            if ($refTags -match 'photo|realistic|photograph|portrait photo') { $styleFromRef = '写实' } else { $styleFromRef = '二次元' }
        }
        if ($styleFromRef) {
            Write-Host "画风一致：检测到「$styleFromRef」（依据：$($styleBasis -join ' / ')）" -ForegroundColor DarkGray
            # 用检测到的画风补一套画风词（之前注入的是空的「一致」档，这里补上）
            $stRef = Get-StylePrompt -Style $styleFromRef
            if ($stRef.Pos) { $positive = Add-StyleWords -Text $positive -Words $stRef.Pos }
            if ($stRef.Neg) { $negative = Add-StyleWords -Text $negative -Words $stRef.Neg }
            if (-not $formCheckpoint) {
                if ($styleFromRef -eq '写实二次元') {
                    $animeCk = Get-AnimeCheckpoint -Checkpoints $sdCheckpoints
                    if ($animeCk) { $formCheckpoint = $animeCk }
                } elseif ($styleFromRef -eq '二次元') {
                    $animeCk = Get-AnimeCheckpoint -Checkpoints $sdCheckpoints
                    if ($animeCk) { $formCheckpoint = $animeCk }
                } elseif ($styleFromRef -eq '写实') {
                    $realCk = @($sdCheckpoints | Where-Object { $_ -match 'majicMIX|majicmix|realistic|麦橘|写实' } | Select-Object -First 1)
                    if ($realCk.Count -gt 0) { $formCheckpoint = [string]$realCk[0] }
                }
            }
        } else {
            Write-Host "画风一致：没能从参考图判出画风（元数据/反推/VLM 都不可用），按当前设置出图" -ForegroundColor Yellow
        }
    }

    # 主体/画风一致性：把参考图的词并进提示词（剥掉与「替换目标」冲突的旧标签 → 换衣服不改画风）
    $replaceTarget = Get-ReplaceTarget -Text $positive
    $refBase = ''
    if ($pngParams -and $pngParams.Positive) { $refBase = $pngParams.Positive } elseif ($refTags) { $refBase = $refTags }
    if ($refBase) {
        $positive = Merge-ConsistencyPrompt -UserPos $positive -RefPos $refBase -Target $replaceTarget
        if ($pngParams -and $pngParams.Negative) { $negative = Add-StyleWords -Text $negative -Words $pngParams.Negative }
        Write-Host "一致性：已把参考图的词并入提示词（$(if ($replaceTarget) { "替换目标=$replaceTarget" } else { '整体一致' })）" -ForegroundColor DarkGray
    }

    # 模型=一致（照参考图）→ 用参考图自带模型
    if ("$($P.Model)" -like '一致*' -and $pngParams -and $pngParams.Model) {
        $formCheckpoint = $pngParams.Model
        Write-Host "模型一致：按参考图元数据切换 → $formCheckpoint" -ForegroundColor DarkGray
    }

    # 蒙版（C-1b）：显式填了就用；填「无」但检测到替换动作 → 按目标自动选区域
    $maskSpec = $maskSpecRaw
    if ($maskSpec -match '^无' -or $maskSpec -eq '') { $maskSpec = '' }
    if (-not $maskSpec -and $replaceTarget) {
        switch ($replaceTarget) {
            '衣服' { $maskSpec = '下半（衣服）' }
            '脸'   { $maskSpec = '上半（脸）' }
            '背景' { $maskSpec = '四周（背景）' }
            default { $maskSpec = '中间（主体）' }
        }
        Write-Host "检测到替换动作（$replaceTarget）→ 自动选用蒙版区域：$maskSpec" -ForegroundColor DarkGray
    }
    if ($maskSpec) {
        if ($maskSpec -match '\.(png|jpg|jpeg|webp|bmp)$') {
            $mp = $maskSpec
            if (-not [System.IO.Path]::IsPathRooted($mp)) { $mp = Join-Path $OutDir $mp }
            if (Test-Path -LiteralPath $mp) { $finalMask = $mp } else { Write-Host "蒙版图不存在：$maskSpec → 改为按区域生成" -ForegroundColor Yellow }
        }
        if (-not $finalMask) {
            $refSize = Get-ImageSizePx -Path $refPath
            $maskOut = Join-Path $script:IterTempDir 'region-mask.png'
            $finalMask = New-RegionMask -Spec $maskSpec -W $refSize.W -H $refSize.H -OutPath $maskOut
            if (-not $finalMask) { Write-Host "蒙版区域认不出（$maskSpec）→ 退回整图重绘" -ForegroundColor Yellow }
        }
    }

    if ($finalMask) {
        # 蒙版重绘：只改目标区域，其余像素原样 → 画风/背景天然一致
        $branchTag = "C-1b 图生图·替换$(if ($replaceTarget) { "（$replaceTarget）" })"
        $finalDenoise = [double]$P.Denoise
        if ($finalDenoise -lt 0.55) { $finalDenoise = 0.75 }   # 蒙版内要盖住旧内容，太小的 denoising 换不掉
        $inpaintFill = 0                                       # 填充模式：换新衣服/新背景用（实测 fill=2 潜空间噪声会在蒙版区留噪点）
        # 蒙版重绘按参考图原生尺寸走，保证未蒙版区域像素级保留
        $refSize = Get-ImageSizePx -Path $refPath
        $size = @{ W = [int]([Math]::Floor($refSize.W / 8) * 8); H = [int]([Math]::Floor($refSize.H / 8) * 8) }
        Write-Host "[决策 C-1b] 蒙版重绘：蒙版=$finalMask（denoising=$finalDenoise，填充=噪声，尺寸=$($size.W)x$($size.H)）" -ForegroundColor Cyan
        Write-Host "            未蒙版区域按原图保留 → 画风不会跟着换衣服一起变" -ForegroundColor DarkGray
    } else {
        $branchTag = 'C-1a 图生图·一致'
        $finalDenoise = [double]$P.Denoise
        if ($finalDenoise -le 0) { $finalDenoise = 0.45 }
        Write-Host "[决策 C-1a] 图生图：底图=$finalInit，denoising=$finalDenoise（0.4-0.5 贴底图保画风）" -ForegroundColor Cyan
    }
}
Write-Host "最终出图：$branchTag" -ForegroundColor Cyan
$finalWin = Invoke-FinalIterate -InitImage $finalInit -Denoising $finalDenoise -Rounds $P.Rounds -W $size.W -H $size.H -Checkpoint $formCheckpoint -Mask $finalMask -InpaintFill $inpaintFill


if ($finalWin) {
    if ($finalWin.VlmDown) {
        # 质检模型起不来：先把本轮生成的所有候选图复制进工作区并全部打开，
        # 再弹带缩略图的多选对话框，让用户勾选要保留的（单选/多选/全选），未勾选的删除。
        Write-Host ""
        Write-Host "质检模型未就绪，已生成 $($finalWin.Paths.Count) 张候选图：" -ForegroundColor Green
        $saved = @()
        foreach ($p in $finalWin.Paths) {
            $dst = Get-UniqueOutPath -BaseName $finalBaseName
            Copy-Item -LiteralPath $p -Destination $dst -Force
            $saved += $dst
            Write-Host "  $dst"
        }
        Remove-IterTempDir
        if (-not $NoOpen) {
            foreach ($dst in $saved) {
                try { Start-Process -FilePath $dst } catch { }
            }
        }
        if ($saved.Count -gt 1) {
            $kept = Show-ImagePicker -Images $saved
            foreach ($dst in $saved) {
                if ($kept -notcontains $dst) {
                    try { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue } catch { }
                    Write-Host "  已删除未选中: $(Split-Path $dst -Leaf)" -ForegroundColor DarkGray
                }
            }
            Write-Host "已保留 $($kept.Count) 张。" -ForegroundColor Green
        } else {
            Write-Host "仅生成 1 张，已保留。" -ForegroundColor DarkGray
        }
    } else {
        # 正常模式：复制最高分那张
        $finalPath = Get-UniqueOutPath -BaseName $finalBaseName
        Copy-Item -LiteralPath $finalWin.Path -Destination $finalPath -Force
        Remove-IterTempDir
        Write-Host ""
        Write-Host "最终成品: $finalPath（seed=$($finalWin.Seed)$(if ($finalWin.Score -ge 0) { "，脸/手 $($finalWin.Score)/100" })）" -ForegroundColor Green
        Write-Host "（迭代中间图已存于临时目录并清理，工作区只保留成品）" -ForegroundColor DarkGray
        if (-not $NoOpen) {
            try {
                Start-Process -FilePath $finalPath
                Write-Host "已打开: $finalPath"
            } catch {
                Write-Host "自动打开失败（$($_.Exception.Message)），可手动打开：$finalPath" -ForegroundColor Yellow
            }
        }
    }
} else {
    Remove-IterTempDir
    Write-Host "最终出图未产出（迭代全部失败）" -ForegroundColor Red
    exit 1
}
