/**
 * macOS 端到端实测：真的把 SD 拉起来、真的出图。
 * 与 test-mac.mjs / test-mac-smoke.mjs 的区别：那两个**不连 SD**，这个连。
 *
 * 覆盖（每一项都是 Windows 版代码在 macOS 上会挂的地方）：
 *   1. detectSdDir 走 STATE_FILE / /Volumes 外接卷
 *   2. resolvePython 找到 venv/bin/python（不是 python.exe / 不是 PATH 上的 python）
 *   3. spawnServer 带上 macLaunchArgs()（少了 --skip-torch-cuda-test 就永远起不来）
 *   4. buildLaunchEnv 的 git 兜底（GIT / GIT_PYTHON_GIT_EXECUTABLE / .dsh-bin 前置 PATH）
 *      —— 没有它，WebUI 在 `import git` 处 rc=69 直接退出
 *   5. macPrepareBeforeLaunch 的 Mach-O 零填充段自检
 *   6. /sdapi/v1/txt2img → base64 → 落盘 %OUT% → replyImages
 *   7. sd_img2img / sd_inpaint 的参数映射（init_image / mask / denoising）
 *   8. sd_models 的 qualityHint 用的是正斜杠 mac 路径
 *   9. sd_script 生成的命令是 `bash '…/sd-direct.sh' …` 单行、且真能被 bash 解析
 *
 * 跑法：node test-mac-e2e.mjs         （首次含模型加载，整体 2-4 分钟）
 *      DSH_SD_DIR=/别的路径 node test-mac-e2e.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SD_DIR = process.env.DSH_SD_DIR || '/Volumes/大神的拓展/stable-diffusion-webui'
const WS = fs.mkdtempSync(path.join(os.tmpdir(), 'sd-mac-e2e-'))
let pass = 0
let fail = 0
const ok = (name, cond, extra = '') => {
  if (cond) {
    pass += 1
    console.log(`  ✔ ${name}${extra ? ' — ' + extra : ''}`)
  } else {
    fail += 1
    console.log(`  ✘ ${name}${extra ? ' — ' + extra : ''}`)
  }
}
const isPng = (file) => {
  try {
    const b = fs.readFileSync(file)
    return b.length > 1000 && b[0] === 0x89 && b.toString('latin1', 1, 4) === 'PNG'
  } catch {
    return false
  }
}

const mod = await import(pathToFileURL(path.join(HERE, 'sd-bridge.js')).href)
const { apply } = mod

const tools = new Map()
const ctx = {
  logger: { info() {}, warn() {}, error() {}, log() {}, debug() {} },
  tools: { register(tool) { tools.set(tool.name, tool); return { dispose() {} } } },
  effect(fn) { const d = fn(); return typeof d === 'function' ? d : () => {} },
  get(name) {
    if (name === 'settings') {
      return { register: () => ({ get: () => ({}), watch() {} }) }
    }
    if (name === 'skills') return { register: (def) => { tools.set(`skill:${def.name}`, def); return { dispose() {} } } }
    if (name === 'attachments') return { saveImage: async ({ data, name: n }) => ({ id: `att-${n}`, data }) }
    if (name === 'fs') return fs
    return undefined
  },
}

process.chdir(WS)
apply(ctx, { sdDir: SD_DIR, autoStart: true, outputDir: '', port: 7860 })
await new Promise((r) => setTimeout(r, 300))

const EXEC = { agent: { session: { header: { cwd: WS } } } }   // 与 test-mac.mjs 同形状的 exec 桩
const call = async (name, args) => {
  const tool = tools.get(name)
  if (!tool) throw new Error(`没注册工具 ${name}`)
  const raw = await tool.execute(args, EXEC)
  return typeof raw === 'string' ? JSON.parse(raw) : raw
}

console.log(`工作区 ${WS}`)
console.log(`SD 目录 ${SD_DIR}`)

// --------------------------------------------------------------------------- 1. 状态 + 拉起
console.log('\n[1] 服务状态与自动拉起（首次含 MPS 加载，最多等 15 分钟）')
const t0 = Date.now()
let status = await call('sd_server', { action: 'status' })
ok('sd_server status 认出 SD 目录', status.sdDir === SD_DIR || String(status.sdDir || '').includes('stable-diffusion-webui'),
  JSON.stringify(status.sdDir))
ok('status 可读且带 sdDir/baseUrl', typeof status.state === 'string' && /:\d+/.test(String(status.baseUrl)),
  `${status.state} ${status.baseUrl}`)
console.log('  正在真正拉起 SD …')
status = await call('sd_server', { action: 'start' })
const up = status.ok !== false && !/失败|未找到/.test(String(status.reason || ''))
ok('sd_server start 把 API 拉起来（mac 参数 + git 兜底 + Mach-O 自检全链路）', up,
  `耗时 ${((Date.now() - t0) / 1000).toFixed(0)}s · ${JSON.stringify(status).slice(0, 220)}`)

// --------------------------------------------------------------------------- 2. 模型清单
console.log('\n[2] sd_models')
const models = await call('sd_models', { section: 'all' })
ok('列出 checkpoints', Array.isArray(models.checkpoints) && models.checkpoints.length > 0,
  (models.checkpoints || []).map((c) => c.name || c).join(',').slice(0, 120))
ok('列出 LoRA', Array.isArray(models.loras), `数量 ${(models.loras || []).length}`)
ok('列出 VAE', Array.isArray(models.vaes), `数量 ${(models.vaes || []).length}`)
ok('列出采样器', Array.isArray(models.samplers) && models.samplers.length > 5, `数量 ${(models.samplers || []).length}`)
ok('qualityHint 用正斜杠 mac 路径（不再是 models\\Stable-diffusion\\）',
  !models.qualityHint || !/models\\\\|\.ps1|powershell/i.test(String(models.qualityHint)),
  String(models.qualityHint || '').slice(0, 120))

// --------------------------------------------------------------------------- 3. 文生图
console.log('\n[3] sd_txt2img（真出图）')
const gen = await call('sd_txt2img', {
  prompt: '1girl, silver hair, blue eyes, school uniform, cherry blossoms, masterpiece, best quality',
  negativePrompt: 'lowres, bad anatomy, bad hands, watermark',
  width: 512,
  height: 512,
  steps: 20,
  summary: '银发少女樱花',
})
ok('返回 paths 且文件真实落盘', Array.isArray(gen.paths) && gen.paths.length === 1 && isPng(gen.paths[0]),
  JSON.stringify(gen.paths))
ok('文件名 = summary + 三位序号', /银发少女樱花_\d{3}\.png$/.test(gen.fileNames?.[0] || ''), gen.fileNames?.[0])
ok('落在工作区的 SD-Picture 下', String(gen.paths?.[0] || '').startsWith(path.join(WS, 'SD-Picture')), gen.dir)
const ri = String(gen.replyImages?.[0] || '')
ok('replyImages 可直接贴进回复（![摘要](<绝对路径>) 形态）',
  ri.startsWith('![') && ri.includes('](<') && ri.endsWith('>)') && ri.includes('.png'),
  JSON.stringify(ri))
ok('seed 回传（复现用）', Number.isFinite(gen.seed), String(gen.seed))
ok('脚本命令是 bash 单行', /^bash '/.test(String(gen.script?.command || '')) && !/\n/.test(String(gen.script?.command || '')),
  String(gen.script?.command || '').slice(0, 100))

// --------------------------------------------------------------------------- 4. 图生图
console.log('\n[4] sd_img2img（拿上一张当参考，低重绘幅度）')
const i2i = await call('sd_img2img', {
  init_image: gen.paths[0],   // ← 工具的真实参数名是 snake_case（我第一版写成 initImage，直接撞在插件的入参校验上）
  prompt: '1girl, silver hair, blue eyes, school uniform, cherry blossoms, masterpiece, best quality',
  negativePrompt: 'lowres, bad anatomy, bad hands, watermark',
  denoisingStrength: 0.3,
  width: 512,
  height: 512,
  steps: 20,
  summary: '樱花微调',
})
ok('图生图出图成功', Array.isArray(i2i.paths) && isPng(i2i.paths[0]), JSON.stringify(i2i.paths))
ok('参考图路径被固化到工作区（ref/）或原样可用',
  typeof i2i.source === 'string' && fs.existsSync(i2i.source), String(i2i.source))
ok('【图生图】标注 + -Denoising 出现在命令里',
  /图生图/.test(String(i2i.script?.asMarkdown || '')) && /-Denoising 0\.3/.test(String(i2i.script?.command || '')),
  String(i2i.script?.command || '').slice(0, 120))

// --------------------------------------------------------------------------- 5. 蒙版重绘
console.log('\n[5] sd_inpaint（矩形蒙版改一小块）')
const inp = await call('sd_inpaint', {
  image: gen.paths[0],
  maskBox: '180,120,150,150',
  prompt: 'white cat sitting, masterpiece, best quality',
  denoisingStrength: 0.75,
  summary: '蒙版换猫',
})
ok('蒙版重绘出图成功', Array.isArray(inp.paths) && isPng(inp.paths[0]), JSON.stringify(inp.paths))
ok('蒙版文件落盘并可读', typeof inp.mask === 'string' && fs.existsSync(inp.mask), String(inp.mask))

// --------------------------------------------------------------------------- 6. 手跑脚本（真的执行一次）
console.log('\n[6] 用户视角：把 asMarkdown 里的命令真跑一遍')
const cmd = String(gen.script?.command || '')
const sh = spawnSync('/bin/bash', ['-c', cmd], { encoding: 'utf8', cwd: WS, timeout: 900000 })
ok('命令能直接跑通（bash -c 整行）', sh.status === 0,
  `exit=${sh.status} ${(sh.stderr || '').trim().split('\n').slice(-2).join(' / ').slice(0, 200)}`)
const after = fs.existsSync(path.join(WS, 'SD-Picture')) ? fs.readdirSync(path.join(WS, 'SD-Picture')) : []
ok('脚本出图也存进了同一个 SD-Picture 目录', after.filter((f) => /银发少女樱花/.test(f)).length >= 2,
  after.join(', ').slice(0, 160))

console.log(`\n结果：${pass} 通过 / ${fail} 失败`)
console.log(`（工作区留在 ${WS}，想看图用 read_image 打开上面这些 png）`)
process.exit(fail === 0 ? 0 : 1)
