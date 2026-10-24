/**
 * macOS 冒烟测试：用假 ctx 加载插件，验证目录探测、venv python 解析、
 * 可复现脚本生成（bash + sd-direct.sh + 引号转义）、脚本同步（无 BOM + 可执行位）、
 * 以及「找不到 SD 时返回可读指引而不是抛栈」。全程不连 SD。
 *
 * 跑法：node test-mac-smoke.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SD_DIR = process.env.DSH_SD_DIR || '/Volumes/大神的拓展/stable-diffusion-webui'
const WS = fs.mkdtempSync(path.join(os.tmpdir(), 'sd-mac-smoke-'))
let fails = 0
const check = (name, cond, extra = '') => {
  console.log(`${cond ? '  ✔' : '  ✘'} ${name}${cond ? '' : ` — ${extra}`}`)
  if (!cond) fails += 1
}

const mod = await import(pathToFileURL(path.join(HERE, 'sd-bridge.js')).href)
const { apply, detectSdDir, DEFAULTS } = mod

// --------------------------------------------------------------------------- 假 ctx
const registered = { tools: new Map(), settings: null, skills: new Map(), scopeWatch: null }
const ctx = {
  logger: { info() {}, warn() {}, error() {}, log() {}, debug() {} },
  tools: {
    register(tool) {
      registered.tools.set(tool.name, tool)
      return { dispose() {} }
    },
  },
  effect(fn) {
    const d = fn()
    return typeof d === 'function' ? d : () => {}
  },
  get(name) {
    if (name === 'settings') {
      return {
        register(ns, schema) {
          registered.settings = { ns, schema }
          return {
            get: () => ({}),
            watch(cb) {
              registered.scopeWatch = cb
            },
          }
        },
      }
    }
    if (name === 'skills') {
      return {
        register(def) {
          registered.skills.set(def.name, def)
          return { dispose() {} }
        },
      }
    }
    if (name === 'attachments') return { saveImage: async ({ data, name }) => ({ id: `att-${name}`, data }) }
    if (name === 'fs') return fs
    return undefined
  },
}

apply(ctx, { sdDir: SD_DIR, autoStart: false })
await new Promise((r) => setTimeout(r, 200)) // 设置面板注册是异步的

console.log(`\n== 1. 目录 / 解释器探测（本机）`)
check('detectSdDir 命中 WebUI', detectSdDir('') === SD_DIR.replace(/\/+$/, ''), detectSdDir(''))
check('DEFAULTS 13 个键原样保留', Object.keys(DEFAULTS).length === 13, Object.keys(DEFAULTS).length)
check('6 个工具全部注册', ['sd_txt2img', 'sd_img2img', 'sd_inpaint', 'sd_script', 'sd_models', 'sd_server'].every((n) => registered.tools.has(n)), [...registered.tools.keys()].join())
check('sd-paint 技能已注册', registered.skills.has('sd-paint'))

// 解释器解析走的是内部函数，用启动指引 + 进程探测侧面验证不写死 python.exe
const guidance = registered.tools.get('sd_txt2img').description
check('工具描述没有 powershell / python.exe 字样', !/powershell|python\.exe|\\models\\/i.test(guidance), guidance.slice(0, 80))

console.log(`\n== 2. 可复现脚本：sd_script 生成的命令形态`)
const scriptTool = registered.tools.get('sd_script')
const execCtx = { agent: { session: { header: { cwd: WS } } } }
const t2i = await scriptTool.execute({ prompt: "1girl, silver hair, (flower crown:1.2) it's nice $money 'quote'", name: '银发少女' }, execCtx)
check('mode = 文生图', t2i.mode === '文生图', t2i.mode)
check('generatesImage = false（不碰 SD）', t2i.generatesImage === false)
check('命令以 bash 前缀开头', /^bash '[^']*' /.test(t2i.command), t2i.command.slice(0, 60))
check('命令里没有 powershell', !/powershell/i.test(t2i.command))
check('命令是单行', !/[\r\n]/.test(t2i.command))
check('asMarkdown 用 ```bash 围栏', t2i.asMarkdown.includes('```bash'), t2i.asMarkdown.split('\n')[0])
check("提示词里的单引号走 '\\'' 闭合重开", t2i.command.includes(`'\\''`), t2i.command.slice(0, 160))
check('提示词里的 $ 与 ( ) 留在单引号内（不会被 shell 展开/当子 shell）', /\$money/.test(t2i.command) && /\(flower crown:1\.2\)/.test(t2i.command))
const i2i = await scriptTool.execute({ prompt: 'same face', initImage: path.join(WS, 'nope.png'), denoising: 0.4 }, execCtx)
check('给了 initImage 走【图生图】并带 -Denoising', i2i.mode === '图生图' && /-Denoising 0.4/.test(i2i.command), i2i.command.slice(0, 60))

console.log(`\n== 3. 脚本同步（无 BOM + 可执行位）`)
const synced = path.join(WS, 'sd-direct.sh')
check('sd-direct.sh 已同步到工作区', fs.existsSync(synced), synced)
const bytes = fs.existsSync(synced) ? fs.readFileSync(synced) : Buffer.alloc(3)
check('没有 UTF-8 BOM（有就 bad interpreter）', !(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf))
check('带可执行位', fs.existsSync(synced) && (fs.statSync(synced).mode & 0o111) !== 0)
check('包外 SD 目录也同步了一份', fs.existsSync(path.join(SD_DIR, 'sd-direct.sh')))
check('bash -n 语法通过', (() => {
  try {
    return spawnSync('/bin/bash', ['-n', synced], { stdio: 'pipe' }).status === 0
  } catch {
    return false
  }
})())

console.log(`\n== 4. 找不到 SD 时的降级（必须是指引文字，不是栈）`)
const mod2 = await import(pathToFileURL(path.join(HERE, 'sd-bridge.js')).href)
const WS2 = fs.mkdtempSync(path.join(os.tmpdir(), 'sd-mac-smoke2-'))
const ctx2 = { ...ctx, tools: { register: ctx.tools.register } }
mod2.apply(ctx2, { sdDir: '/nonexistent-sd-dir', autoStart: false })
const statusTool = [...registered.tools.values()].find((t) => t.name === 'sd_server')
const st = await statusTool.execute({ action: 'status' })
const txt = typeof st === 'string' ? st : JSON.stringify(st)
check('status 返回体里没有 throw / 栈', !/at .*\(/.test(txt), txt.slice(0, 120))
// 本机其实装了 SD，探测会**自动回退**到真实目录（上游设计：配置无效继续自动探测），
// 所以「找不到 SD」的分支只能从源码层验证。
check('status 在配置了无效 sdDir 时仍回退到真实目录（不误报没装）', /stable-diffusion-webui/.test(txt), txt.slice(0, 200))
const srcText = fs.readFileSync(path.join(HERE, 'sd-bridge.js'), 'utf8')
const guidanceBlock = srcText.slice(srcText.indexOf('function installGuidance'), srcText.indexOf('function installGuidance') + 900)
check('installGuidance 在 POSIX 分支指向 install-sd-macos.sh', /install-sd-macos\.sh/.test(guidanceBlock) && /bash /.test(guidanceBlock), guidanceBlock.slice(0, 200))
check('installGuidance 不再叫用户开 PowerShell', !/PowerShell 里跑/.test(guidanceBlock))

console.log(`\n${fails === 0 ? '✅ 全部通过' : `❌ ${fails} 项失败`}  工作区：${WS}`)
process.exit(fails === 0 ? 0 : 1)
