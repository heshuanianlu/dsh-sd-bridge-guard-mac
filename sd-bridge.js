/**
 * dsh-sd-bridge-guard — dsh-sd-bridge 的违规分流增强版（v0.5，跨机器可移植）。
 *
 * 目标：用户不需要提前打开 SD WebUI。第一次生图时插件自己把 API 服务拉起来
 * （`python launch.py --api --nowebui --port 7860`，纯 API、不开浏览器、不开 Gradio 页面），
 * 之后所有请求都走 A1111 的 REST 接口 `/sdapi/v1/*`。如果 SD 已经在跑且开了 `--api`，
 * 插件探测到就直接复用，不会重复启动。
 *
 * 可移植性（v0.5 起）：源码不写死任何机器专属路径。
 *   - SD 目录自动探测：配置 > DSH_SD_DIR 环境变量 > ~/.dsh-sd-bridge.json（install-sd.ps1 自举记录）
 *     > 扫盘候选；找不到时工具返回可读的安装指引（跑包内 install-sd.ps1），而不是崩溃。
 *   - 产物/参考图/脚本同步目录全部相对**会话工作区**解析，任何机器装上即用。
 *   - 工具描述与 sd-paint 技能全文在 apply 时按本机配置注入路径（%SD%/%OUT%/%REF%/%DIRECT%）。
 *
 * 五个工具：
 *   sd_txt2img  文生图（支持 checkpoint 临时切换、LoRA 语法、hires fix、批次）
 *   sd_img2img  图生图（本地图片路径 → base64）
 *   sd_script   只生成可复现脚本，不碰 SD、不出图（违规分流 B 档专用）
 *   sd_models   列出 checkpoints / LoRA / 采样器 / VAE / 当前选项
 *   sd_server   服务状态 / 启动 / 停止
 *
 * 与原版的差异（违规分流协议 · 两档）：
 *   A 档轻微违规（删几个词后完全正常）：
 *     剔除违规片段 → 照常出图存盘贴图 → 回复说明剔除 → 附 script 脚本 →
 *     回复最末尾列出被剔除违规提示词的英文，注明不能加进脚本/给别人使用。
 *   B 档明显违规（露骨/整体性质）：
 *     **不调生图工具、一张图都不生成** —— 只把原需求译成提示词、提炼出合规素体，
 *     调 sd_script 拿可复现脚本（【文生图】/【图生图】标注）贴进回复，
 *     用户自己运行 sd-direct.ps1 出图并存进要求路径；回复最末尾同样列英文违规词。
 *   判定发生在模型层（skill 行为规范），插件不做过滤词表；sd_script 负责 B 档脚本的
 *   参数转义与格式生成（提示词在 powershell 代码块中高亮成蓝色）。
 *
 * @module dsh-sd-bridge-guard/index.js
 */

import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

export const name = 'sd-bridge'
export const inject = ['tools']

const PKG_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)))

const DEFAULTS = {
  /**
   * SD WebUI 安装目录（含 launch.py 与 venv/python）。
   * 留空 = 自动探测：配置覆盖 > 环境变量 DSH_SD_DIR > 自举安装记录（~/.dsh-sd-bridge.json）
   * > 常见目录扫描（各盘根的 SD.4.8 / stable-diffusion-webui 等）。装过 SD 的机器零配置可用。
   */
  sdDir: '',
  /** API 端口；与 SD 默认端口一致，便于复用已打开的服务 */
  port: 7860,
  /** 探测不到 API 时是否由插件自动启动 SD */
  autoStart: true,
  /** 启动 SD 的最长等待（首次还要加载 checkpoint，给足余量） */
  startupTimeoutMs: 420000,
  /** 单次生图请求的最长等待 */
  requestTimeoutMs: 600000,
  /** 空闲多少分钟后自动关掉由本插件拉起的 SD（0 = 不自动关） */
  idleStopMinutes: 0,
  /** 追加给 launch.py 的额外命令行参数（高级项） */
  extraArgs: [],
  /**
   * 生图产物目录：绝对路径原样使用，相对路径解析到**会话工作区**。
   * 默认 `SD-Picture` = 每台机器的工作区下自建 SD-Picture 目录，文件名 = 提示词总结_序号.png。
   */
  outputDir: 'SD-Picture',
  /**
   * 图生图参考图固化目录（相对路径同样解析到会话工作区）：用户给的图若在工作区之外
   * （聊天附件缓存、临时目录……），复制一份到这里，脚本 -InitImage 引用这份稳定副本
   * （内容与用户给的图逐字节一致）；已在工作区内的图原样使用，绝不替换成其他图片。
   */
  refDir: 'ref',
  /** 注册生图工具 */
  enabled: true,
}

// ---------------------------------------------------------------------------
// SD WebUI 目录探测（可移植性的核心：任何机器零配置找到本机 SD）
// ---------------------------------------------------------------------------

/** 自举安装（install-sd.ps1）把装到哪记在这里，插件下次启动直接读 */
const STATE_FILE = path.join(
  process.env.USERPROFILE || process.env.HOME || process.env.USERPROFILE || '.',
  '.dsh-sd-bridge.json',
)

/** 目录是否是一个可用的 SD WebUI 安装（判据：存在 launch.py） */
function looksLikeSdDir(dir) {
  try {
    return Boolean(dir) && fs.existsSync(path.join(dir, 'launch.py'))
  } catch {
    return false
  }
}

function readInstallRecord() {
  try {
    const parsed = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'))
    const dir = parsed && typeof parsed.sdDir === 'string' ? parsed.sdDir.replace(/[\\/]+$/, '') : ''
    return looksLikeSdDir(dir) ? dir : ''
  } catch {
    return ''
  }
}

/**
 * 探测顺序：显式配置 > 环境变量 DSH_SD_DIR > 自举安装记录 > 扫盘候选目录。
 * 扫盘只做 existsSync（微秒级），候选名有限、不会拖慢插件启动。
 */
function detectSdDir(explicit) {
  const explicitDir = String(explicit || '').replace(/[\\/]+$/, '')
  if (explicitDir) {
    if (looksLikeSdDir(explicitDir)) return explicitDir
    log(`配置的 sdDir 不是 SD WebUI 目录（缺 launch.py）：${explicitDir}，继续自动探测`)
  }
  const fromEnv = String(process.env.DSH_SD_DIR || '').replace(/[\\/]+$/, '')
  if (looksLikeSdDir(fromEnv)) return fromEnv
  const fromRecord = readInstallRecord()
  if (fromRecord) return fromRecord

  const dirNames = [
    'SD.4.8',
    'SD',
    'sd',
    'stable-diffusion-webui',
    'stable-diffusion-webui-master',
    'sd.webui',
    'webui',
    'a1111',
    'sd-webui',
  ]
  const home = process.env.USERPROFILE || process.env.HOME || ''
  const localAppData = process.env.LOCALAPPDATA || ''
  const fixedCandidates = [
    home && path.join(home, 'stable-diffusion-webui'),
    home && path.join(home, 'sd.webui'),
    localAppData && path.join(localAppData, 'stable-diffusion-webui'),
    localAppData && path.join(localAppData, 'Programs'),
    'D:/SD.4.8',
  ]
  for (const candidate of fixedCandidates) {
    if (looksLikeSdDir(candidate)) return path.resolve(candidate).replace(/[\\/]+$/, '')
  }
  // 各盘根目录下的常见安装名
  for (let code = 67; code <= 90; code += 1) {
    const root = `${String.fromCharCode(code)}:/`
    for (const name of dirNames) {
      const candidate = path.join(root, name)
      if (looksLikeSdDir(candidate)) return path.resolve(candidate).replace(/[\\/]+$/, '')
    }
  }
  return ''
}

/** 找不到 SD 时给所有工具统一的可读指引（不抛栈、不静默） */
function installGuidance() {
  const script = path.join(PKG_DIR, 'install-sd.ps1')
  return (
    'sd-bridge: 未找到本机 Stable Diffusion WebUI（配置 sdDir 为空且自动探测无果）。\n' +
    `尚未安装 SD？在 PowerShell 里跑一条命令自动装（WebUI + 模型，约 10-30 分钟）：\n` +
    `powershell -ExecutionPolicy Bypass -File "${script}"\n` +
    '装完重启 DSH 即可；已装过 SD？把路径写进环境变量 DSH_SD_DIR，' +
    '或在 cordis.patch.yml 按 id sd-bridge 覆盖 sdDir。'
  )
}

// ---------------------------------------------------------------------------
// 运行时状态（模块级；插件热重载会重新执行 apply，这里的句柄自然作废）
// ---------------------------------------------------------------------------

const state = {
  child: null,
  startedByUs: false,
  starting: null,
  base: '',
  logTail: [],
  idleTimer: null,
  lastUsedAt: 0,
}

const cfg = { ...DEFAULTS }

function baseUrl() {
  return `http://127.0.0.1:${cfg.port}`
}

function log(...args) {
  try {
    // Cordis 的 logger 是 %s 风格；这里只做原样输出，缺 logger 时退回 console。
    (state.logger ?? console).log?.('[sd-bridge]', ...args)
  } catch {
    /* logging must never break a tool call */
  }
}

function pushLog(chunk) {
  const lines = String(chunk).split(/\r?\n/).filter((l) => l.trim() !== '')
  if (lines.length === 0) return
  state.logTail.push(...lines)
  if (state.logTail.length > 120) state.logTail.splice(0, state.logTail.length - 120)
}

function logTailText() {
  return state.logTail.slice(-25).join('\n')
}

// ---------------------------------------------------------------------------
// HTTP：探测 / 调用
// ---------------------------------------------------------------------------

async function probeApi(timeoutMs = 4000) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const res = await fetch(`${baseUrl()}/sdapi/v1/options`, {
      signal: controller.signal,
      headers: { Accept: 'application/json' },
    })
    if (res.ok) {
      const text = await res.text()
      try {
        return { kind: 'ready', options: JSON.parse(text) }
      } catch {
        return { kind: 'ready', options: {} }
      }
    }
    return { kind: 'http-error', status: res.status }
  } catch (error) {
    if (error && (error.name === 'AbortError' || error.name === 'TimeoutError')) {
      return { kind: 'timeout' }
    }
    return { kind: 'offline' }
  } finally {
    clearTimeout(timer)
  }
}

async function apiGet(route, timeoutMs = 20000) {
  const res = await fetch(`${baseUrl()}${route}`, {
    signal: AbortSignal.timeout(timeoutMs),
    headers: { Accept: 'application/json' },
  })
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`SD API GET ${route} 失败：HTTP ${res.status} ${body.slice(0, 400)}`)
  }
  return res.json()
}

async function apiPost(route, payload, timeoutMs) {
  const res = await fetch(`${baseUrl()}${route}`, {
    method: 'POST',
    signal: AbortSignal.timeout(timeoutMs),
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(payload),
  })
  if (!res.ok) {
    const body = await res.text().catch(() => '')
    throw new Error(`SD API POST ${route} 失败：HTTP ${res.status} ${body.slice(0, 800)}`)
  }
  return res.json()
}

// ---------------------------------------------------------------------------
// 服务生命周期
// ---------------------------------------------------------------------------

function resolvePython() {
  const candidates = [
    path.join(cfg.sdDir, 'python', 'python.exe'),
    path.join(cfg.sdDir, 'venv', 'Scripts', 'python.exe'),
    path.join(cfg.sdDir, 'venv', 'bin', 'python'),
  ]
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate
  }
  return 'python'
}

function spawnServer() {
  const python = resolvePython()
  const launchPy = path.join(cfg.sdDir, 'launch.py')
  if (!fs.existsSync(launchPy)) {
    throw new Error(installGuidance())
  }
  // 全新安装（venv 尚未创建）时不能跳过环境准备，也不能离线——首次启动要联网装 torch 等依赖
  const prepared = fs.existsSync(path.join(cfg.sdDir, 'venv')) || fs.existsSync(path.join(cfg.sdDir, 'python'))
  const args = [
    launchPy,
    '--api',
    '--nowebui',
    '--port', String(cfg.port),
    ...(prepared ? ['--skip-prepare-environment'] : []),
    '--skip-version-check',
    ...(Array.isArray(cfg.extraArgs) ? cfg.extraArgs : []),
  ]
  log('启动 SD API：', python, args.join(' '))
  const child = spawn(python, args, {
    cwd: cfg.sdDir,
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: {
      ...process.env,
      GRADIO_ANALYTICS_ENABLED: 'False',
      // 已成型的安装：走 SD 自带的 HuggingFace 缓存并禁止联网校验——本机直连 huggingface.co
      // 不通时，transformers 每个文件会重试 5 次 × 10s 超时，足以把生图卡死几分钟。
      // 全新安装（未 prepared）保持联网，否则首次依赖下载会失败。
      ...(prepared
        ? {
            HF_HOME: path.join(cfg.sdDir, '.cache', 'huggingface'),
            HF_HUB_OFFLINE: '1',
            TRANSFORMERS_OFFLINE: '1',
            ...(process.env.HF_ENDPOINT ? {} : { HF_ENDPOINT: 'https://hf-mirror.com' }),
          }
        : {}),
    },
  })
  child.stdout?.on('data', (chunk) => pushLog(chunk))
  child.stderr?.on('data', (chunk) => pushLog(chunk))
  child.on('error', (error) => pushLog(`spawn error: ${error.message}`))
  child.on('exit', (code, signal) => {
    pushLog(`SD 进程退出 code=${code} signal=${signal}`)
    if (state.child === child) {
      state.child = null
      state.startedByUs = false
    }
  })
  state.child = child
  state.startedByUs = true
  return child
}

function stopServer() {
  const child = state.child
  if (!child) {
    return { ok: false, reason: '当前没有由 sd-bridge 拉起的 SD 进程（若 SD 是手动打开的，请手动关闭）' }
  }
  state.child = null
  state.startedByUs = false
  try {
    child.kill()
    return { ok: true, reason: '已发送停止信号' }
  } catch (error) {
    return { ok: false, reason: `停止失败：${error.message}` }
  }
}

/**
 * 保证 API 可用：已在跑就复用；没在跑且允许 autoStart 就启动并等待就绪。
 * 并发调用共享同一个启动 Promise。
 */
async function ensureServer({ allowStart = true } = {}) {
  const probe = await probeApi()
  if (probe.kind === 'ready') {
    state.base = baseUrl()
    touchIdleTimer()
    return probe.options
  }
  if (probe.kind === 'http-error' && probe.status === 401) {
    throw new Error(`sd-bridge: ${baseUrl()} 需要 API 认证（--api-auth），插件当前没有凭据配置`)
  }
  if (probe.kind === 'http-error') {
    throw new Error(
      `sd-bridge: 端口 ${cfg.port} 已被占用，但该服务没有 A1111 API（HTTP ${probe.status}）。` +
      '请换一个端口，或关闭占用进程后重试。',
    )
  }
  if (!allowStart || !cfg.autoStart) {
    throw new Error(`sd-bridge: SD API 未运行（${baseUrl()}），且当前不允许自动启动`)
  }
  if (!cfg.sdDir) {
    // 自动探测无果：给可执行的安装/指向指引，而不是 spawn 一个不存在的 launch.py
    throw new Error(installGuidance())
  }
  if (state.starting) return state.starting

  state.starting = (async () => {
    if (state.child) stopServer()
    spawnServer()
    const deadline = Date.now() + Number(cfg.startupTimeoutMs || DEFAULTS.startupTimeoutMs)
    let lastKind = ''
    while (Date.now() < deadline) {
      if (!state.child) {
        throw new Error(
          `sd-bridge: SD 启动进程提前退出，最近输出：\n${logTailText() || '(无输出)'}`,
        )
      }
      const current = await probeApi(3000)
      if (current.kind === 'ready') {
        state.base = baseUrl()
        log('SD API 就绪')
        touchIdleTimer()
        return current.options
      }
      lastKind = current.kind
      await new Promise((resolve) => setTimeout(resolve, 2000))
    }
    throw new Error(
      `sd-bridge: 等待 SD API 就绪超时（${Math.round(Number(cfg.startupTimeoutMs) / 1000)}s，最后状态 ${lastKind}），` +
      `最近输出：\n${logTailText() || '(无输出)'}`,
    )
  })().finally(() => {
    state.starting = null
  })
  return state.starting
}

function touchIdleTimer() {
  state.lastUsedAt = Date.now()
  if (state.idleTimer) {
    clearTimeout(state.idleTimer)
    state.idleTimer = null
  }
  const minutes = Number(cfg.idleStopMinutes || 0)
  if (minutes > 0 && state.child && state.startedByUs) {
    state.idleTimer = setTimeout(() => {
      if (Date.now() - state.lastUsedAt >= minutes * 60000) {
        log(`空闲 ${minutes} 分钟，关闭由 sd-bridge 启动的 SD`)
        stopServer()
      }
    }, minutes * 60000)
    state.idleTimer.unref?.()
  }
}

// ---------------------------------------------------------------------------
// 工具公共件
// ---------------------------------------------------------------------------

const stringOutput = {
  schema: { type: 'string' },
  render: (_args, value) => [{ type: 'text', text: value }],
}

function sessionCwd(exec) {
  const session = exec && exec.agent && exec.agent.session
  const cwd = session && session.header && session.header.cwd
  return typeof cwd === 'string' && cwd !== '' ? cwd : process.cwd()
}

/** 产物目录：绝对路径原样用，相对路径解析到会话工作区（跨机器零适配的关键之一） */
function resolveOutputDir(exec) {
  const cwd = sessionCwd(exec)
  const raw = String(cfg.outputDir || DEFAULTS.outputDir)
  return path.resolve(path.isAbsolute(raw) ? raw : path.resolve(cwd, raw))
}

function multipleOf8(value, fallback) {
  const n = Math.round(Number(value))
  if (!Number.isFinite(n) || n <= 0) return fallback
  return Math.max(64, Math.min(2048, Math.round(n / 8) * 8))
}

function clampInt(value, fallback, min, max) {
  const n = Math.round(Number(value))
  if (!Number.isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

/**
 * 从图片头解析像素尺寸（PNG / JPEG / WebP / BMP），
 * 让 img2img 在模型没给 width/height 时按原图尺寸重绘，而不是被裁成 512x512。
 */
function imageSizeOf(buffer) {
  try {
    if (buffer.length > 32 && buffer.readUInt32BE(0) === 0x89504e47) {
      return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) }
    }
    if (buffer.length > 30 && buffer.toString('ascii', 0, 2) === 'BM') {
      return { width: buffer.readInt32LE(18), height: Math.abs(buffer.readInt32LE(22)) }
    }
    if (
      buffer.length > 30 &&
      buffer.toString('ascii', 0, 4) === 'RIFF' &&
      buffer.toString('ascii', 8, 12) === 'WEBP'
    ) {
      const chunk = buffer.toString('ascii', 12, 16)
      if (chunk === 'VP8X') {
        return {
          width: 1 + buffer.readUIntLE(24, 3),
          height: 1 + buffer.readUIntLE(27, 3),
        }
      }
      if (chunk === 'VP8 ') {
        return { width: buffer.readUInt16LE(26) & 0x3fff, height: buffer.readUInt16LE(28) & 0x3fff }
      }
      if (chunk === 'VP8L') {
        const bits = buffer.readUInt32LE(21)
        return { width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1 }
      }
    }
    if (buffer.length > 4 && buffer[0] === 0xff && buffer[1] === 0xd8) {
      let offset = 2
      while (offset + 9 < buffer.length) {
        if (buffer[offset] !== 0xff) {
          offset += 1
          continue
        }
        const marker = buffer[offset + 1]
        if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
          offset += 2
          continue
        }
        const size = buffer.readUInt16BE(offset + 2)
        const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc
        if (isSof) {
          return { height: buffer.readUInt16BE(offset + 5), width: buffer.readUInt16BE(offset + 7) }
        }
        if (size <= 0) break
        offset += 2 + size
      }
    }
  } catch {
    /* 头解析失败时回退默认值 */
  }
  return null
}

function readImageBase64(exec, rawPath) {
  const input = String(rawPath ?? '').trim()
  if (!input) throw new Error('sd_img2img: init_image 不能为空（本地图片绝对路径或工作区相对路径）')
  const fsService = typeof ctxRef.get === 'function' ? ctxRef.get('fs') : undefined
  const cwd = sessionCwd(exec)
  const localPath = path.isAbsolute(input) ? input : path.resolve(cwd, input)

  const finish = (buffer) => {
    if (!buffer || buffer.length === 0) {
      throw new Error(`sd_img2img: 图片为空或不可读：${localPath}`)
    }
    if (buffer.length > 32 * 1024 * 1024) {
      throw new Error(`sd_img2img: 图片过大（${Math.round(buffer.length / 1048576)}MB），请先缩到 32MB 以内`)
    }
    const ext = path.extname(localPath).toLowerCase()
    const mime = ext === '.jpg' || ext === '.jpeg' ? 'image/jpeg' : ext === '.webp' ? 'image/webp' : 'image/png'
    const size = imageSizeOf(buffer)
    // 用户给的那张图若是临时/附件路径，固化成工作区内的稳定副本，脚本 -InitImage 指向它
    const stablePath = stabilizeRefImage(localPath, buffer, cwd)
    return { base64: buffer.toString('base64'), mime, localPath: stablePath, originalPath: localPath, width: size?.width, height: size?.height }
  }

  if (fsService && typeof fsService.resolve === 'function' && typeof fsService.readBytes === 'function') {
    return (async () => {
      try {
        const target = await fsService.resolve(localPath, { cwd })
        const bytes = await fsService.readBytes(target, undefined, 32 * 1024 * 1024)
        return finish(Buffer.from(bytes))
      } catch (error) {
        // 沙箱拒绝时给出可读错误；文件不存在也落到同一分支
        throw new Error(`sd_img2img: 读取图片失败 ${localPath}（${error && error.message ? error.message : error}）`)
      }
    })()
  }
  return Promise.resolve().then(() => finish(fs.readFileSync(localPath)))
}

/**
 * 图生图参考图固化：用户给的那张图若是聊天附件/临时路径（在工作区之外），
 * 复制一份到 cfg.refDir（相对路径解析到会话工作区），脚本与返回值都改用这份稳定副本——
 * 内容与用户给的图逐字节一致（按源文件 sha1 命名，重复上传自动复用同名），
 * 不会随临时目录清理而失效。工作区内的图原样返回，不复制。
 */
function stabilizeRefImage(localPath, buffer, wsRoot) {
  try {
    const root = path.resolve(wsRoot || process.cwd())
    const abs = path.resolve(localPath)
    if (abs.toLowerCase().startsWith(root.toLowerCase() + path.sep) || abs.toLowerCase() === root.toLowerCase()) {
      return abs
    }
    const raw = String(cfg.refDir || DEFAULTS.refDir)
    const refDir = path.resolve(root, path.isAbsolute(raw) ? raw : raw)
    fs.mkdirSync(refDir, { recursive: true })
    const ext = path.extname(abs).toLowerCase() || '.png'
    const base = path.basename(abs, path.extname(abs)).replace(/[\\/:*?"<>|]/g, '_').slice(0, 40) || 'ref'
    const hash = crypto.createHash('sha1').update(buffer).digest('hex').slice(0, 8)
    const target = path.join(refDir, `${base}_${hash}${ext}`)
    if (!fs.existsSync(target)) fs.writeFileSync(target, buffer)
    log('参考图已固化 →', target, `（源：${abs}）`)
    return target
  } catch (error) {
    // 固化失败不致命：退回原路径，脚本仍指向用户给的那张图
    log('参考图固化失败（沿用原路径）：', error && error.message ? error.message : error)
    return localPath
  }
}

/** 把 A1111 返回的 base64 图片落盘 + 挂附件，构造统一返回值。 */
async function materializeImages(exec, images, meta) {
  // 统一成 Windows 原生反斜杠绝对路径，回复里的 Markdown 路径才稳定可渲染
  const dir = resolveOutputDir(exec)
  fs.mkdirSync(dir, { recursive: true })

  const summary = sanitizeSummary(meta.summary || meta.prompt || 'sd')
  const base = nextSequence(dir, summary)
  const total = images.length

  const paths = []
  const fileNames = []
  const attachments = []
  const replyImages = []
  const attachmentsService = typeof ctxRef.get === 'function' ? ctxRef.get('attachments') : undefined

  let index = 0
  for (const b64 of images) {
    index += 1
    const buffer = Buffer.from(b64, 'base64')
    const seq = total > 1 ? `${base + index - 1}` : `${base}`
    const fileName = `${summary}_${String(seq).padStart(3, '0')}.png`
    const file = path.join(dir, fileName)
    fs.writeFileSync(file, buffer)
    paths.push(file)
    fileNames.push(fileName)
    replyImages.push(`![${summary}](<${file}>)`)
    if (attachmentsService && typeof attachmentsService.saveImage === 'function') {
      try {
        const ref = await attachmentsService.saveImage({ data: buffer, mediaType: 'image/png', name: summary })
        attachments.push(ref)
      } catch (error) {
        log('附件保存失败（不影响出图）：', error && error.message ? error.message : error)
      }
    }
  }
  return { paths, fileNames, dir, attachments, replyImages }
}

/**
 * 提示词总结 → 文件名安全片段：去掉路径/Windows 非法字符与标签权重语法，
 * 取前几个关键词拼成 12-24 字的短标题（中英文均可）。
 */
function sanitizeSummary(raw) {
  let text = String(raw ?? '')
    .replace(/<lora:[^>]*>/gi, ' ')
    .replace(/\([^)]*\)|\[[^\]]*\]/g, ' ')
    .replace(/[,，;；:：!！?？"'“”‘’\\\/\*\?<>|]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  if (!text) text = 'sd'
  // 优先按逗号切分的标签取前 4 个有意义词，保证「总结」而不是整段提示词
  const tokens = text.split(' ').filter((t) => t && !/^(and|the|of|a|an|with|in|on)$/i.test(t))
  text = tokens.slice(0, 4).join(' ')
  text = text.slice(0, 30).replace(/[.\s]+$/, '')
  // Windows 文件名非法字符兜底
  text = text.replace(/[\\/:*?"<>|]/g, '').trim()
  return text || 'sd'
}

/** 为「总结_NNN」找下一个可用序号（扫描目录里同名前缀的最大编号 +1）。 */
function nextSequence(dir, summary) {
  let max = 0
  let entries = []
  try {
    entries = fs.readdirSync(dir)
  } catch {
    return 1
  }
  const re = new RegExp(`^${escapeRegExp(summary)}_(\\d{1,6})\\.png$`, 'i')
  for (const entry of entries) {
    const match = re.exec(entry)
    if (match) {
      const n = Number.parseInt(match[1], 10)
      if (Number.isFinite(n) && n > max) max = n
    }
  }
  return max + 1
}

function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function presentOutput(value) {
  const { attachments, ...rest } = value
  const blocks = [{ type: 'text', text: JSON.stringify(rest) }]
  for (const attachment of attachments || []) {
    blocks.push({ type: 'image', attachment })
  }
  return blocks
}

// ---------------------------------------------------------------------------
// 违规分流协议：可复现脚本（sd-direct.ps1）生成
// ---------------------------------------------------------------------------

/**
 * 自愈：把包内附带的 sd-direct.ps1 同步到「当前工作区根目录」与「SD 目录」两处。
 * 命令里用哪条路径由 resolveDirectPath 按会话工作区决定；同步过的工作区记在缓存里，
 * 避免每次生图都重复读盘比对。任一目标缺失或内容过期时覆盖，保证两条路径都能直接跑。
 */
const syncedRoots = new Set()

function syncDirectScripts(wsRoot) {
  const source = path.join(PKG_DIR, 'sd-direct.ps1')
  let body
  try {
    body = fs.readFileSync(source)
  } catch (error) {
    log('包内 sd-direct.ps1 缺失，跳过同步：', error && error.message ? error.message : error)
    return
  }
  const root = path.resolve(wsRoot || process.cwd())
  const targets = [path.join(root, 'sd-direct.ps1')]
  if (cfg.sdDir) targets.push(path.join(cfg.sdDir, 'sd-direct.ps1'))
  let allOk = true
  for (const target of targets) {
    try {
      let same = false
      try {
        same = fs.readFileSync(target).equals(body)
      } catch {
        same = false
      }
      if (same) continue
      fs.writeFileSync(target, body)
      log('已同步 sd-direct.ps1 →', target)
    } catch (error) {
      allOk = false
      log('同步 sd-direct.ps1 失败（不影响工具）：', target, error && error.message ? error.message : error)
    }
  }
  if (allOk) syncedRoots.add(root)
}

/** 命令里的脚本路径 = 当前工作区根目录下的 sd-direct.ps1（绝对路径，单行命令可直接复制运行） */
function directPathFor(wsRoot) {
  const root = path.resolve(wsRoot || process.cwd())
  if (!syncedRoots.has(root)) syncDirectScripts(root)
  return path.join(root, 'sd-direct.ps1')
}

/** 文本 → powershell 双引号字符串字面量（PowerShell 用反引号转义 ` " $） */
function psQuote(text) {
  return (
    '"' +
    String(text ?? '')
      .replace(/`/g, '``')
      .replace(/"/g, '`"')
      .replace(/\$/g, '`$') +
    '"'
  )
}

/**
 * 生成与本次调用等价的 sd-direct.ps1 命令行，供模型原样贴进回复的
 * ```powershell 代码块（宿主会把字符串高亮成蓝色）。
 * 命令恒为**单行完整命令**：以 `powershell -ExecutionPolicy Bypass -File "..."` 开头，
 * 复制整行到 PowerShell / cmd 都能直接跑——不给这个前缀，用户裸跑 .ps1 会被执行策略拦，
 * 写成 `& "路径"` 又容易被模型自造路径（历史故障：模型猜出不存在的 skills\...\sd-direct.ps1）。
 * 脚本路径与输出目录都由插件注入，与本次会话工作区一致，用户机器无需任何本地适配。
 * mode：'文生图' | '图生图'
 */
function buildCommand(mode, opts, directPath, outDir) {
  const parts = ['powershell', '-ExecutionPolicy', 'Bypass', '-File', psQuote(directPath), '-Prompt', psQuote(opts.prompt)]
  if (opts.negative) parts.push('-Negative', psQuote(opts.negative))
  if (mode === '图生图') {
    if (opts.initImage) parts.push('-InitImage', psQuote(opts.initImage))
    if (opts.denoising !== undefined) parts.push('-Denoising', String(opts.denoising))
  }
  parts.push('-Width', String(opts.width), '-Height', String(opts.height))
  if (opts.steps !== undefined) parts.push('-Steps', String(opts.steps))
  if (Number.isFinite(opts.seed) && opts.seed >= 0) parts.push('-Seed', String(opts.seed))
  if (outDir) parts.push('-OutDir', psQuote(outDir))
  if (mode === '文生图' && opts.name) parts.push('-Name', psQuote(opts.name))
  return parts.join(' ')
}

/** 脚本块上方的模式标注 + 代码块，模型直接贴进回复。 */
function commandBlock(mode, command) {
  return {
    mode,
    command,
    asMarkdown:
      '【' + mode + '】\n```powershell\n' +
      '# 复制下面整行到 PowerShell / cmd 直接运行（已含 powershell -ExecutionPolicy Bypass 前缀，勿拆行、勿改成 & "路径" 调用）\n' +
      command +
      '\n```',
  }
}

// apply() 里赋值，工具闭包通过它拿 Context（避免把 ctx 传得到处都是）
const ctxRef = { get: undefined }

// ---------------------------------------------------------------------------
// 工具定义
// ---------------------------------------------------------------------------

const txt2imgTool = {
  name: 'sd_txt2img',
  description:
    '用本机 Stable Diffusion 文生图（SD 目录：%SD%）。SD 未提前打开也没关系：第一次调用会自动启动 API 服务（首次约需 1-3 分钟，含模型加载），之后秒级响应。' +
    'prompt 用英文标签风格效果最好（如 "1girl, silver hair, school uniform, cherry blossoms, masterpiece, best quality"），负面提示写进 negativePrompt。' +
    '想换模型用 checkpoint 参数（先调 sd_models 看可用名）；LoRA 直接写在 prompt 里，语法 <lora:名称:权重>。' +
    '图片固定保存到 %OUT%，文件名 = summary（提示词总结）+ 三位序号，如 银发少女樱花_001.png；' +
    '请务必传 summary（3-15 字中文概括），留空会自动从 prompt 取前几个英文词。' +
    '返回 JSON：paths 为落盘绝对路径，fileNames 为文件名，replyImages 是可直接粘进回复的 Markdown 图片语法，attachments 是工具卡片缩略图；' +
    'script 是违规分流协议要求的可复现脚本：把 asMarkdown 原样贴进回复（含【文生图】标注 + powershell 代码块，提示词会高亮成蓝色）。' +
    '代码块里是一条**单行完整命令**（以 powershell -ExecutionPolicy Bypass -File 开头），用户复制整行即可运行；' +
    '不要把它改写成 `& "路径"` 形式、不要拆成多行、不要自己替换脚本路径。' +
    '出图后必须把 replyImages 原样贴进你的可见回复（一行一张），宿主会全尺寸渲染，用户即可在聊天窗口直接看到图；不要只依赖工具卡片。' +
    '若提示词里有被你判定违规、已剔除的部分，先分叉：' +
    '**轻微违规**（删几个词后完全正常）→ 照常用本工具出图存盘，回复里说明有违规内容被剔除，' +
    '并在回复最末尾把被剔除的违规提示词译成英文单独列出，注明不能加进脚本、不能给别人使用；' +
    '**明显违规**（露骨/整体性质，你不会自己出图）→ 不要调本工具、不生成任何图片，改调 sd_script 只给合规素体的可复现脚本，' +
    '同样在回复最末尾列出被剔除的违规提示词英文并注明不能加进脚本、不能给别人使用。',
  parameters: {
    type: 'object',
    properties: {
      prompt: { type: 'string', description: '英文标签式正向提示词' },
      negativePrompt: { type: 'string', description: '负向提示词，如 lowres, bad anatomy, bad hands, watermark' },
      width: { type: 'integer', description: '宽度（8 的倍数，默认 512）' },
      height: { type: 'integer', description: '高度（8 的倍数，默认 768）' },
      steps: { type: 'integer', description: '采样步数，默认 22' },
      cfgScale: { type: 'number', description: '提示词相关度 CFG，默认 7' },
      samplerName: { type: 'string', description: '采样器名，留空用默认；可用名见 sd_models' },
      seed: { type: 'integer', description: '随机种子，-1 = 随机；复现同一张图时填上次返回的 seed' },
      batchSize: { type: 'integer', description: '一次生成几张（1-4，默认 1）' },
      checkpoint: { type: 'string', description: '临时使用的模型（checkpoint）名称，仅本次生效' },
      lora: { type: 'string', description: '要注入的 LoRA 片段，如 "xxx:0.8"；会拼进 prompt，等价于自行写 <lora:xxx:0.8>"' },
      restoreFaces: { type: 'boolean', description: '启用面部修复（ADetailer/GFPGAN），默认 false' },
      enableHiresFix: { type: 'boolean', description: '启用 hires fix 高分辨率修复，默认 false' },
      hiresScale: { type: 'number', description: 'hires fix 放大倍率，默认 2' },
      styles: { type: 'array', items: { type: 'string' }, description: '使用的 SD 预设风格名（WebUI 里的 styles）' },
      summary: {
        type: 'string',
        description: '提示词总结：3-15 字概括这张图（用于文件命名，如"银发少女樱花"）；留空自动从 prompt 提取前几个关键词',
      },
    },
    required: ['prompt'],
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        paths: { type: 'array', items: { type: 'string' } },
        fileNames: { type: 'array', items: { type: 'string' } },
        savedDir: { type: 'string' },
        replyImages: { type: 'array', items: { type: 'string' } },
        seed: { type: 'integer' },
        width: { type: 'integer' },
        height: { type: 'integer' },
        elapsedMs: { type: 'integer' },
        info: { type: 'string' },
        script: {
          type: 'object',
          properties: {
            mode: { type: 'string', enum: ['文生图', '图生图'] },
            command: { type: 'string' },
            asMarkdown: { type: 'string' },
          },
          description:
            '违规分流协议的可复现脚本；asMarkdown 含【文生图】标注与 powershell 代码块（单行完整命令，powershell -ExecutionPolicy Bypass -File 开头），原样贴进回复',
        },
      },
    },
    render: (_args, value) => presentOutput(value),
  },
  async execute(args, exec) {
    const startedAt = Date.now()
    await ensureServer()

    const payload = {
      prompt: String(args.prompt ?? ''),
      negative_prompt: String(args.negativePrompt ?? ''),
      width: multipleOf8(args.width, 512),
      height: multipleOf8(args.height, 768),
      steps: clampInt(args.steps, 22, 1, 150),
      cfg_scale: Number.isFinite(Number(args.cfgScale)) ? Number(args.cfgScale) : 7,
      seed: Number.isFinite(Number(args.seed)) ? Math.trunc(Number(args.seed)) : -1,
      batch_size: clampInt(args.batchSize, 1, 1, 4),
      n_iter: 1,
      save_images: false,
      restore_faces: args.restoreFaces === true,
      ...(String(args.samplerName ?? '').trim() !== ''
        ? { sampler_name: String(args.samplerName).trim() }
        : {}),
      ...(String(args.checkpoint ?? '').trim() !== ''
        ? {
            override_settings: { sd_model_checkpoint: String(args.checkpoint).trim() },
            override_settings_restore_afterwards: true,
          }
        : {}),
      ...(args.enableHiresFix === true
        ? {
            enable_hr: true,
            hr_scale: Number.isFinite(Number(args.hiresScale)) ? Number(args.hiresScale) : 2,
            hr_second_pass_steps: 0,
          }
        : {}),
      ...(Array.isArray(args.styles) && args.styles.length > 0
        ? { styles: args.styles.map((s) => String(s)) }
        : {}),
    }

    // LoRA 片段拼进 prompt（A1111 的 extra networks 语法）
    const lora = String(args.lora ?? '').trim().replace(/^<lora:|>$/g, '')
    if (lora) payload.prompt = `<lora:${lora}> ${payload.prompt}`

    const data = await apiPost('/sdapi/v1/txt2img', payload, Number(cfg.requestTimeoutMs))
    const images = Array.isArray(data.images) ? data.images : []
    if (images.length === 0) {
      throw new Error(`sd_txt2img: SD 没有返回图片。info=${String(data.info ?? '').slice(0, 400)}`)
    }

    let seed = payload.seed
    let infoText = ''
    try {
      const info = typeof data.info === 'string' ? JSON.parse(data.info) : data.info
      infoText = typeof data.info === 'string' ? data.info : JSON.stringify(info)
      if (info && Number.isFinite(Number(info.seed))) seed = Number(info.seed)
    } catch {
      infoText = String(data.info ?? '')
    }

    const { paths, fileNames, dir, attachments, replyImages } = await materializeImages(exec, images, {
      seed,
      summary: args.summary,
      prompt: payload.prompt,
    })
    touchIdleTimer()
    const script = commandBlock(
      '文生图',
      buildCommand(
        '文生图',
        {
          prompt: payload.prompt,
          negative: payload.negative_prompt,
          width: payload.width,
          height: payload.height,
          steps: payload.steps,
          seed,
          name: String(args.summary || 'direct'),
        },
        directPathFor(sessionCwd(exec)),
        resolveOutputDir(exec),
      ),
    )
    return {
      ok: true,
      paths,
      fileNames,
      savedDir: dir,
      replyImages,
      attachments,
      seed,
      width: payload.width,
      height: payload.height,
      elapsedMs: Date.now() - startedAt,
      info: infoText.slice(0, 1500),
      script,
      hint:
        '图片已保存并作为附件展示。请把 replyImages 里的 Markdown 原样贴进你的可见回复（一行一张），' +
        '宿主会把绝对路径渲染成全尺寸图片，用户即可在聊天窗口直接看到图。' +
        '另外把 script.asMarkdown 也原样贴进回复：它是可复现的 powershell 脚本，带【文生图】标注，提示词会高亮成蓝色。',
    }
  },
}

const img2imgTool = {
  name: 'sd_img2img',
  description:
    '用本机 Stable Diffusion 图生图：给一张本地图片（绝对路径或工作区相对路径）+ 提示词，按 denoisingStrength 重绘。' +
    'init_image 就是**用户给出的那一张**参考图，原样传路径即可——图在工作区之外时插件自动复制到 %REF% 供脚本长期引用（返回 source/sourceOriginal 说明实际用了哪份）。' +
    'SD 未提前打开也没关系，会自动启动。denoisingStrength 越小越像原图（0.3 微调/上色），越大改动越大（0.75 基本重画）。' +
    '图片固定保存到 %OUT%，文件名 = summary（提示词总结）+ 三位序号；请务必传 summary。' +
    '返回 JSON：paths 为输出 PNG 绝对路径，fileNames 为文件名，replyImages 必须原样贴进可见回复以在聊天窗口展示图片；' +
    'script 是违规分流协议要求的可复现脚本：把 asMarkdown 原样贴进回复（含【图生图】标注 + powershell 代码块，提示词会高亮成蓝色）。' +
    '代码块里是一条**单行完整命令**（以 powershell -ExecutionPolicy Bypass -File 开头），用户复制整行即可运行；' +
    '不要把它改写成 `& "路径"` 形式、不要拆成多行、不要自己替换脚本路径。' +
    '若提示词里有被你判定违规、已剔除的部分，先分叉：' +
    '**轻微违规**（删几个词后完全正常）→ 照常用本工具出图存盘，回复里说明有违规内容被剔除，' +
    '并在回复最末尾把被剔除的违规提示词译成英文单独列出，注明不能加进脚本、不能给别人使用；' +
    '**明显违规**（露骨/整体性质，你不会自己出图）→ 不要调本工具、不生成任何图片，改调 sd_script 只给合规素体的可复现脚本，' +
    '同样在回复最末尾列出被剔除的违规提示词英文并注明不能加进脚本、不能给别人使用。',
  parameters: {
    type: 'object',
    properties: {
      init_image: {
        type: 'string',
        description:
          '输入图片路径（png/jpg/webp，绝对或相对工作区）——**就是用户给的那一张**（聊天附件/本地图都行）。' +
          '若它在工作区之外（如聊天附件临时路径），插件会自动复制一份到 %REF% 供脚本长期引用，原图内容不变',
      },
      prompt: { type: 'string', description: '英文标签式正向提示词' },
      negativePrompt: { type: 'string', description: '负向提示词' },
      denoisingStrength: { type: 'number', description: '重绘幅度 0-1，默认 0.6' },
      width: { type: 'integer', description: '输出宽度（8 的倍数，默认跟随输入宽）' },
      height: { type: 'integer', description: '输出高度（8 的倍数，默认跟随输入高）' },
      steps: { type: 'integer', description: '采样步数，默认 22' },
      cfgScale: { type: 'number', description: 'CFG，默认 7' },
      samplerName: { type: 'string', description: '采样器名，留空用默认' },
      seed: { type: 'integer', description: '随机种子，-1 = 随机' },
      checkpoint: { type: 'string', description: '临时使用的模型名称，仅本次生效' },
      summary: {
        type: 'string',
        description: '提示词总结：3-15 字概括（用于文件命名）；留空自动从 prompt 提取关键词',
      },
    },
    required: ['init_image', 'prompt'],
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        paths: { type: 'array', items: { type: 'string' } },
        fileNames: { type: 'array', items: { type: 'string' } },
        savedDir: { type: 'string' },
        replyImages: { type: 'array', items: { type: 'string' } },
        source: { type: 'string', description: '实际使用的参考图（图生图脚本 -InitImage 指向它）' },
        sourceOriginal: { type: 'string', description: '用户原始给出的图片路径' },
        seed: { type: 'integer' },
        elapsedMs: { type: 'integer' },
        script: {
          type: 'object',
          properties: {
            mode: { type: 'string', enum: ['文生图', '图生图'] },
            command: { type: 'string' },
            asMarkdown: { type: 'string' },
          },
          description:
            '违规分流协议的可复现脚本；asMarkdown 含【图生图】标注与 powershell 代码块（单行完整命令，powershell -ExecutionPolicy Bypass -File 开头），原样贴进回复',
        },
      },
    },
    render: (_args, value) => presentOutput(value),
  },
  async execute(args, exec) {
    const startedAt = Date.now()
    const source = await readImageBase64(exec, args.init_image)
    await ensureServer()

    const outWidth = multipleOf8(args.width, source.width || 512)
    const outHeight = multipleOf8(args.height, source.height || 768)

    const payload = {
      init_images: [source.base64],
      prompt: String(args.prompt ?? ''),
      negative_prompt: String(args.negativePrompt ?? ''),
      denoising_strength: Math.max(0.05, Math.min(1, Number(args.denoisingStrength ?? 0.6) || 0.6)),
      width: outWidth,
      height: outHeight,
      resize_mode: 0,
      steps: clampInt(args.steps, 22, 1, 150),
      cfg_scale: Number.isFinite(Number(args.cfgScale)) ? Number(args.cfgScale) : 7,
      seed: Number.isFinite(Number(args.seed)) ? Math.trunc(Number(args.seed)) : -1,
      batch_size: 1,
      n_iter: 1,
      save_images: false,
      ...(String(args.samplerName ?? '').trim() !== ''
        ? { sampler_name: String(args.samplerName).trim() }
        : {}),
      ...(String(args.checkpoint ?? '').trim() !== ''
        ? {
            override_settings: { sd_model_checkpoint: String(args.checkpoint).trim() },
            override_settings_restore_afterwards: true,
          }
        : {}),
    }

    const data = await apiPost('/sdapi/v1/img2img', payload, Number(cfg.requestTimeoutMs))
    const images = Array.isArray(data.images) ? data.images : []
    if (images.length === 0) {
      throw new Error(`sd_img2img: SD 没有返回图片。info=${String(data.info ?? '').slice(0, 400)}`)
    }

    let seed = payload.seed
    try {
      const info = typeof data.info === 'string' ? JSON.parse(data.info) : data.info
      if (info && Number.isFinite(Number(info.seed))) seed = Number(info.seed)
    } catch {
      /* info 解析失败不致命 */
    }

    const { paths, fileNames, dir, attachments, replyImages } = await materializeImages(exec, images, {
      seed,
      summary: args.summary,
      prompt: payload.prompt,
    })
    touchIdleTimer()
    const script = commandBlock(
      '图生图',
      buildCommand(
        '图生图',
        {
          prompt: payload.prompt,
          negative: payload.negative_prompt,
          initImage: source.localPath,
          denoising: payload.denoising_strength,
          width: outWidth,
          height: outHeight,
          steps: payload.steps,
          seed,
        },
        directPathFor(sessionCwd(exec)),
        resolveOutputDir(exec),
      ),
    )
    return {
      ok: true,
      paths,
      fileNames,
      savedDir: dir,
      replyImages,
      attachments,
      source: source.localPath,
      sourceOriginal: source.originalPath,
      seed,
      elapsedMs: Date.now() - startedAt,
      script,
      hint:
        '图片已保存并作为附件展示。请把 replyImages 里的 Markdown 原样贴进你的可见回复（一行一张），' +
        '宿主会把绝对路径渲染成全尺寸图片，用户即可在聊天窗口直接看到图。' +
        '另外把 script.asMarkdown 也原样贴进回复：它是可复现的 powershell 脚本，带【图生图】标注，提示词会高亮成蓝色。',
    }
  },
}

/**
 * sd_script —— 只生成可复现脚本，绝不调用 SD、不出图。
 * 违规分流协议的「明显违规」分支专用：模型判定明显违规时不得调用生图工具，
 * 改调本工具拿 asMarkdown（【文生图】/【图生图】标注的 powershell 代码块，
 * 提示词 = 剔除违规后的合规素体），用户自己跑脚本出图并存进要求路径。
 */
const scriptTool = {
  name: 'sd_script',
  description:
    '只生成可复现的 powershell 出图脚本（调 sd-direct.ps1），**不调用 SD、不生成任何图片**。' +
    '违规分流协议的「明显违规」分支专用：当你判定用户需求明显违规、按协议不得自己出图时，改调本工具，' +
    '把剔除违规后的「合规素体」提示词传进来，返回 { mode, command, asMarkdown }；' +
    '把 asMarkdown 原样贴进回复即可（含【文生图】/【图生图】标注，提示词高亮成蓝色），用户自己运行脚本出图。' +
    'command 是一条**单行完整命令**（以 powershell -ExecutionPolicy Bypass -File 开头，用户复制整行就能跑）；' +
    '贴进回复时保持单行、不要改写成 `& "路径"`、不要换路径。' +
    'command 里的脚本路径以本工具返回为准，**不要自己改路径或参数**（插件会把脚本同步到 %DIRECT% 与 SD 目录各一份，命令用哪份以返回值为准）。' +
    '给了 initImage 走【图生图】（-InitImage -Denoising），没给走【文生图】（-Width -Height -Name）。' +
    '正常需求或「轻微违规仍出图」时不要用本工具，直接调 sd_txt2img / sd_img2img。',
  parameters: {
    type: 'object',
    properties: {
      prompt: { type: 'string', description: '剔除违规后的合规素体提示词（英文标签式）' },
      negativePrompt: { type: 'string', description: '负向提示词' },
      initImage: {
        type: 'string',
        description:
          '参考图绝对路径（用户给的那一张）；给了就是【图生图】，留空是【文生图】。' +
          '工作区之外的临时路径会被固化到 %REF% 后再写进脚本',
      },
      denoising: { type: 'number', description: '图生图重绘幅度 0-1，默认 0.65' },
      width: { type: 'integer', description: '宽度（8 的倍数，默认 640）' },
      height: { type: 'integer', description: '高度（8 的倍数，默认 960）' },
      steps: { type: 'integer', description: '采样步数，默认 24' },
      seed: { type: 'integer', description: '种子，-1 = 随机（不写进脚本）' },
      name: { type: 'string', description: '文生图输出文件名前缀（sd-direct.ps1 的 -Name），如 shorekeeper' },
    },
    required: ['prompt'],
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        mode: { type: 'string', enum: ['文生图', '图生图'] },
        command: { type: 'string', description: '单行完整 powershell 命令，以 powershell -ExecutionPolicy Bypass -File 开头' },
        asMarkdown: { type: 'string' },
        generatesImage: { type: 'boolean', description: '恒为 false：本工具不生图' },
      },
    },
    render: (_args, value) => [{ type: 'text', text: value.asMarkdown ?? JSON.stringify(value) }],
  },
  async execute(args, exec) {
    const wsRoot = sessionCwd(exec)
    const rawInitImage = String(args.initImage ?? '').trim()
    // 用户给的参考图若是临时/附件路径，固化到 ref\ 让脚本长期可跑；读不到就原样透传
    let initImage = rawInitImage
    if (rawInitImage) {
      try {
        const abs = path.isAbsolute(rawInitImage) ? rawInitImage : path.resolve(wsRoot, rawInitImage)
        initImage = stabilizeRefImage(abs, fs.readFileSync(abs), wsRoot)
      } catch {
        initImage = rawInitImage
      }
    }
    const mode = initImage ? '图生图' : '文生图'
    const block = commandBlock(
      mode,
      buildCommand(
        mode,
        {
          prompt: String(args.prompt ?? ''),
          negative: String(args.negativePrompt ?? ''),
          initImage,
          denoising: Number.isFinite(Number(args.denoising)) ? Number(args.denoising) : 0.65,
          width: clampInt(args.width, 640, 64, 2048),
          height: clampInt(args.height, 960, 64, 2048),
          steps: clampInt(args.steps, 24, 1, 150),
          seed: Number.isFinite(Number(args.seed)) ? Math.trunc(Number(args.seed)) : -1,
          name: String(args.name ?? 'direct'),
        },
        directPathFor(wsRoot),
        resolveOutputDir(exec),
      ),
    )
    return { ...block, generatesImage: false }
  },
}

const modelsTool = {
  name: 'sd_models',
  description:
    '列出本机 Stable Diffusion 可用的模型资源：checkpoints、LoRA、采样器、VAE、当前生效选项（当前 checkpoint / CLIP skip 等），以及 SD 服务状态。' +
    'sd_txt2img / sd_img2img 换模型前先用它确认名称。会自动拉起 SD API（若未运行）。',
  parameters: {
    type: 'object',
    properties: {
      section: {
        type: 'string',
        enum: ['all', 'checkpoints', 'loras', 'samplers', 'vaes', 'options'],
        description: '只查某一类时指定，默认 all',
      },
    },
    additionalProperties: false,
  },
  output: stringOutput,
  async execute(args) {
    const options = await ensureServer()
    const section = String(args.section ?? 'all')
    const want = (name) => section === 'all' || section === name

    const result = { baseUrl: baseUrl(), port: cfg.port, managedByPlugin: Boolean(state.child) }
    if (want('options')) {
      result.options = {
        sd_model_checkpoint: options?.sd_model_checkpoint,
        sd_vae: options?.sd_vae,
        CLIP_stop_at_last_layers: options?.CLIP_stop_at_last_layers,
      }
    }
    if (want('checkpoints')) {
      const models = await apiGet('/sdapi/v1/sd-models')
      result.checkpoints = models.map((m) => m.title)
    }
    if (want('loras')) {
      const loras = await apiGet('/sdapi/v1/loras')
      result.loras = loras.map((l) => l.name)
    }
    if (want('samplers')) {
      const samplers = await apiGet('/sdapi/v1/samplers')
      result.samplers = samplers.map((s) => s.name)
    }
    if (want('vaes')) {
      const vaes = await apiGet('/sdapi/v1/sd-vae')
      result.vaes = (vaes || []).map((v) => v.model_name || v.name).filter(Boolean)
    }
    touchIdleTimer()
    return JSON.stringify(result, null, 2)
  },
}

const serverTool = {
  name: 'sd_server',
  description:
    '管理本机 Stable Diffusion API 服务：status 查看状态，start 启动（纯 API 模式、不开浏览器），stop 停止由 sd-bridge 启动的进程。' +
    '生图工具本身也会按需自动启动，通常不需要手动 start。',
  parameters: {
    type: 'object',
    properties: {
      action: { type: 'string', enum: ['status', 'start', 'stop'], description: '默认 status' },
    },
    additionalProperties: false,
  },
  output: stringOutput,
  async execute(args) {
    const action = String(args.action ?? 'status')
    if (action === 'start') {
      const options = await ensureServer({ allowStart: true })
      return JSON.stringify(
        {
          ok: true,
          state: 'ready',
          baseUrl: baseUrl(),
          checkpoint: options?.sd_model_checkpoint,
          managedByPlugin: Boolean(state.child && state.startedByUs),
        },
        null,
        2,
      )
    }
    if (action === 'stop') {
      const outcome = stopServer()
      return JSON.stringify({ ok: outcome.ok, state: 'stopped', reason: outcome.reason }, null, 2)
    }
    const probe = await probeApi()
    return JSON.stringify(
      {
        ok: true,
        state: probe.kind === 'ready' ? 'ready' : 'offline',
        baseUrl: baseUrl(),
        sdDir: cfg.sdDir || undefined,
        checkpoint: probe.kind === 'ready' ? probe.options?.sd_model_checkpoint : undefined,
        managedByPlugin: Boolean(state.child && state.startedByUs),
        pid: state.child ? state.child.pid : undefined,
        idleStopMinutes: Number(cfg.idleStopMinutes || 0),
        // 找不到 SD 时给出可执行的安装/指向指引，而不是让人对着空配置猜
        installHint: cfg.sdDir ? undefined : installGuidance(),
        recentLog: state.logTail.slice(-8),
      },
      null,
      2,
    )
  },
}

// ---------------------------------------------------------------------------
// 插件入口
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 文案占位符 → 本机实际路径：工具描述与技能全文在 apply 时按配置注入，
// 源码里不残留任何机器专属路径（可移植性 + 隐私要求）。
// ---------------------------------------------------------------------------

function docLabels() {
  const outRaw = String(cfg.outputDir || DEFAULTS.outputDir)
  const refRaw = String(cfg.refDir || DEFAULTS.refDir)
  const asLabel = (raw) =>
    path.isAbsolute(raw) ? path.normalize(raw) : `工作区${path.sep}${raw}`
  return {
    '%SD%': cfg.sdDir ? path.normalize(cfg.sdDir) : '自动探测到的 SD WebUI 目录',
    '%OUT%': asLabel(outRaw),
    '%REF%': asLabel(refRaw),
    '%DIRECT%': `工作区${path.sep}sd-direct.ps1`,
  }
}

function applyDocTokens(text) {
  let out = String(text)
  for (const [token, value] of Object.entries(docLabels())) out = out.split(token).join(value)
  return out
}

function applyDocsToTools() {
  for (const tool of [txt2imgTool, img2imgTool, scriptTool, modelsTool, serverTool]) {
    tool.description = applyDocTokens(tool.description)
    const props = tool.parameters && tool.parameters.properties
    if (!props) continue
    for (const prop of Object.values(props)) {
      if (prop && typeof prop.description === 'string') prop.description = applyDocTokens(prop.description)
    }
  }
}

/** 深度遍历对象，把所有字符串里的路径占位符换成本机实际值（用于技能定义整体注入） */
function mapStringsDeep(value) {
  if (typeof value === 'string') return applyDocTokens(value)
  if (Array.isArray(value)) return value.map(mapStringsDeep)
  if (value && typeof value === 'object') {
    const out = {}
    for (const [key, item] of Object.entries(value)) out[key] = mapStringsDeep(item)
    return out
  }
  return value
}

export function apply(ctx, config = {}) {
  state.logger = ctx.logger ?? console
  for (const key of Object.keys(DEFAULTS)) {
    if (config && config[key] !== undefined && config[key] !== null) cfg[key] = config[key]
  }
  cfg.port = clampInt(cfg.port, 7860, 1024, 65535)
  // sdDir：显式配置优先，为空则自动探测（环境变量 / 自举记录 / 扫盘）
  cfg.sdDir = detectSdDir(cfg.sdDir)

  ctxRef.get = (key) => (typeof ctx.get === 'function' ? ctx.get(key) : undefined)

  syncDirectScripts(process.cwd())
  applyDocsToTools()

  if (cfg.enabled === false) {
    log('sd-bridge 已在配置中禁用（enabled: false）')
    return
  }

  const disposers = []
  for (const tool of [txt2imgTool, img2imgTool, scriptTool, modelsTool, serverTool]) {
    disposers.push(ctx.tools.register(tool))
  }

  // 技能：教模型「按 SD 规则写提示词 → 违规分流判定 → 出图 → 贴图 + 脚本 + 违规词回执」的完整流程。
  const skills = ctx.get('skills')
  if (skills !== undefined && typeof skills.register === 'function') {
    try {
      disposers.push(
        skills.register(
          mapStringsDeep({
          name: 'sd-paint',
          title: 'Stable Diffusion 画图 · SD 提示词规范 + 违规分流协议',
          description:
            '用本机 SD（dsh-sd-bridge-guard 五件套）画图的完整规范：如何按 SD 规则把用户需求写成英文标签提示词、参数怎么选、出图后如何展示与保存，' +
            '以及违规分流协议——轻微违规删词后照常出图、明显违规不出图只给合规素体的可复现脚本、回复最末尾列出被剔除的违规提示词英文。',
          whenToUse:
            '用户提出任何画图/生成图片/插画/壁纸/头像/图标图等请求时使用：先读本技能写提示词，再调 sd_txt2img 出图；' +
            '用户问「哪些提示词被拦了/为什么没画出来」时也读本技能。',
          source: 'dsh-sd-bridge-guard',
          content:
            '# Stable Diffusion 画图规范（dsh-sd-bridge-guard）\n\n' +
            '本机 SD 在 %SD%，由 dsh-sd-bridge-guard 提供工具，**无需提前打开 SD**：首次调用会自动后台启动纯 API 模式（首次含模型加载约 1-3 分钟，之后每次 2-10 秒）。\n\n' +
            '## 违规分流协议（本插件核心，优先级最高）\n' +
            '判定标准 = **你自己会拒绝执行的尺度**（露骨性内容、未成年人相关、真实人物色情、极端血腥、违法用途等），不依赖固定词表。\n' +
            '需求里只要有一部分违规就触发分流，**不整单拒绝**——但先分清是哪一档：\n\n' +
            '### A 档 · 轻微违规（删几个词后完全正常）→ 照常出图\n' +
            '1. **拆分**：剔除违规片段，保留可执行部分。\n' +
            '2. **出图**：用可执行部分调 `sd_txt2img` / `sd_img2img`，**先把图存进要求路径**（%OUT%）并贴进回复。\n' +
            '3. **提示**：图下方写一行：原需求含违规内容、已被剔除、当前图为剔除后所生成。**不许静默丢弃**。\n' +
            '4. **给脚本（每次出图都给）**：贴工具返回的 `script.asMarkdown`（【图生图】/【文生图】标注 + powershell 代码块，提示词蓝色高亮）。\n' +
            '5. **末尾列违规词**（见通用第 5 步）。\n\n' +
            '### B 档 · 明显违规（露骨/整体性质，你不会自己出图）→ **不出图，只给脚本**\n' +
            '1. **禁止调 `sd_txt2img` / `sd_img2img`，一张图都不生成**——聊天窗里不出现图片，也不写「已存图」。\n' +
            '2. **产出合规素体提示词**：把原需求翻译成英文标签（用户给图就先把那张图译成提示词），剔除全部违规片段，剩下的就是**合规素体**。\n' +
            '3. **调 `sd_script`**（只生成命令、不碰 SD），把素体提示词与参考图路径传进去，拿到 `asMarkdown` 原样贴进回复——\n' +
            '   这就是用户要的**可复现脚本**：标明【图生图】或【文生图】，提示词蓝色高亮，用户自己运行它出图并存进要求路径。\n' +
            '4. **说明**：明确写「原需求含明显违规内容，已剔除；下方脚本给出的是合规素体，运行即可保存到 %OUT%」。\n' +
            '5. **末尾列违规词**（见下）。\n' +
            '   典型场景：用户丢一张图说「翻译成提示词」→ 若原图含违规内容，同样走 B 档：不出图，只回素体提示词脚本。\n\n' +
            '### 通用 · 末尾列违规词（A/B 两档都要，最重要）\n' +
            '回复**最末尾**单独一段，把被剔除的违规部分**译成英文**逐条列出，标题写「已剔除的违规提示词（不能加进脚本、不能给别人使用）」——用户要拿去告知别人这些词不能加。\n' +
            '若需求**全部**违规、连素体都提炼不出：仍按 B 档只给 `sd_script` 脚本（prompt 写能成立的最素版本），末尾照列违规词。\n\n' +
            '正常需求（无违规）：出图 → 贴 replyImages → 贴 script 脚本 → 一句话说明保存位置/文件名/seed，无需违规提示与末尾清单。\n\n' +
            '## 回复骨架（对照执行）\n' +
            '1. 图片（仅 A 档与正常需求）：`replyImages` 原样贴出（一行一张）；B 档没有这一步。\n' +
            '2. 保存说明：%OUT%、文件名、seed；B 档说明「运行脚本后会存进去」。\n' +
            '3. 模式标注 + 脚本：`【图生图】` 或 `【文生图】`，下接 powershell 代码块（A 档/正常用 `script.asMarkdown`，B 档用 `sd_script` 返回的 `asMarkdown`）。**脚本必须原样粘贴，禁止改写其中的路径与参数**——代码块里是**一条单行完整命令**，以 `powershell -ExecutionPolicy Bypass -File "%DIRECT%"` 开头，用户复制整行到 PowerShell/cmd 直接就能跑。\n' +
            '   **禁止**把它改写成 `& "..."` + 多行反引号续行的形式：`&` 调用受执行策略限制会直接报错，且模型自造路径根本不存在，会报 CommandNotFoundException。\n' +
            '   `sd-direct.ps1` 由插件同步在工作区根目录与 SD 目录各一份，命令里用哪份**以工具返回的 command 为准**，不要自己拼路径。\n' +
            '4. （仅违规时）违规提示行 + 回复最末尾的英文违规词清单。\n\n' +
            '## 工作流（每次画图都走这条）\n' +
            '1. 先看用户需求，若需要特定风格/模型再调 `sd_models` 确认 checkpoint、LoRA 名称（不确定名称时才查，已知可跳过）。\n' +
            '2. **先做违规分流判定**（A 档/B 档，见上），再按下方规则写出英文标签式 `prompt` 与 `negativePrompt`。\n' +
            '3. B 档走 `sd_script` 到此为止；A 档与正常需求继续：调 `sd_txt2img`（图生图用 `sd_img2img`），**必须传 `summary`**：3-15 字中文概括（如「银发少女樱花」），它就是保存的文件名。\n' +
            '4. 拿到返回后，**把 `replyImages` 里的 Markdown 原样贴进你的可见回复**（一行一张、放在正文里），宿主会渲染成全尺寸图片，用户就能在聊天窗口直接看到图。工具卡片只是缩略图，会被后续消息顶走。\n' +
            '5. 回复里顺带给用户一句话说明：保存位置 %OUT%、文件名、seed（方便复现），并贴 `script.asMarkdown`。\n\n' +
            '## SD 提示词规则（重要）\n' +
            '- **英文标签式**，逗号分隔，权重从高到低排列：主体 > 外貌/服装 > 场景/背景 > 光影构图 > 质量词。例：`1girl, silver hair, red ribbon, school uniform, cherry blossoms, park, depth of field, masterpiece, best quality`。\n' +
            '- 结尾固定补质量词：`masterpiece, best quality, absurdres, highly detailed`；**写实摄影风**改用 `photorealistic, raw photo, 8k uhd, film grain`。\n' +
            '- **负面词**固定底噪：`lowres, bad anatomy, bad hands, extra fingers, fewer digits, watermark, text, signature, jpeg artifacts, worst quality, low quality`；人物图再加 `nsfw` 以外的内容按用户要求。\n' +
            '- 权重语法：`(word:1.3)` 提权，`(word:0.6)` 降权，`[word]` 等价 0.9；LoRA：`<lora:名称:0.8>`（名称用 `sd_models` 查，本机有国风山水、赛博朋克、东方美学等）。\n' +
            '- 中文需求 → 英文标签的映射：银发=**silver hair**、樱花=**cherry blossoms**、赛博朋克=**cyberpunk, neon lights, rain**、国风=**traditional Chinese style, ink wash painting**、写实人像=**portrait photo, studio lighting**。\n' +
            '- 尺寸规则：头像/方图 512x512，竖屏手机壁纸 512x1024（或 768x1344 之类 8 的倍数），横屏壁纸 1280x720，插画竖图 512x768。需要更高清再开 `enableHiresFix`。\n' +
            '- 步数 20-28 即可（默认 22），CFG 6-8；想要随机多样性 seed 用 -1，用户要求「再来一张」时可保持 seed 不变只改词。\n' +
            '- checkpoint 选择：动漫/插画 → AWPainting 或 ReVAnimated 或 anything-v5；写实 → majicMIX realistic；不指定就用当前默认（AWPainting）。\n\n' +
            '## 保存与命名\n' +
            '- 固定保存到 **%OUT%**，文件名 = `summary_序号.png`（如 `银发少女樱花_001.png`、`赛博朋克街景_002.png`），序号自动递增，同名总结不会覆盖。\n' +
            '- `sd_txt2img` 返回里的 `paths` 是绝对路径，`fileNames` 是文件名，`savedDir` 是目录。\n\n' +
            '## 图生图参考图（重要）\n' +
            '- 用户在聊天里给的图（附件或本地路径）就是参考图：把**它的路径**原样传给 `sd_img2img` 的 `init_image`（B 档传 `sd_script` 的 `initImage`），**不要换成上一张生成图、不要换成你以为的同类图**。\n' +
            '- 插件会自动处理路径：用户给的图若在工作区之外（聊天附件临时目录），会复制一份到 **%REF%**（文件名 = 原名_内容哈希），脚本里的 `-InitImage` 指向这份固化副本，内容与用户给的图逐字节一致；工作区内的图直接用原路径。\n' +
            '- 回复里说明用的是哪张：`sd_img2img` 返回的 `source` 是脚本实际引用的路径、`sourceOriginal` 是用户原始给的路径。\n\n' +
            '## 后台运行\n' +
            '- 生图在后台进程执行，你的回复不必等待解释：调用工具 → 贴 replyImages → 贴脚本 → 简短说明即可。\n' +
            '- 想让它空闲自动关：配置 `idleStopMinutes`；手动控制用 `sd_server`（status/start/stop）。\n',
          invocation: { modelInvocable: true, userInvocable: true },
          }),
        ),
      )
    } catch (error) {
      log('技能注册失败（不影响工具）：', error && error.message ? error.message : error)
    }
  }

  // 探测一次已运行的服务，仅记录状态，不启动任何东西。
  probeApi(3000).then((probe) => {
    if (probe.kind === 'ready') log('检测到已在运行的 SD API，将直接复用：', baseUrl())
  }).catch(() => {})

  ctx.effect(
    () =>
      () => {
        for (const dispose of disposers.splice(0)) {
          try {
            dispose()
          } catch {
            /* dispose 尽力而为 */
          }
        }
        if (state.idleTimer) {
          clearTimeout(state.idleTimer)
          state.idleTimer = null
        }
        // 插件卸载不主动杀 SD：用户可能还在用 WebUI 页面；sd_server stop 负责显式关闭。
      },
    'sd-bridge: tools',
  )

  log(
    `已挂载生图工具（sdDir=${cfg.sdDir || '未找到——生图时会返回安装指引'}, port=${cfg.port}, autoStart=${cfg.autoStart}, ` +
    `outputDir=${docLabels()['%OUT%']}）`,
  )
}

export { DEFAULTS, detectSdDir }
