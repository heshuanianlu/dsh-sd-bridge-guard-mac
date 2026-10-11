// dsh-sd-bridge-guard 验收测试：自动拉起 SD → 出图 → 按「提示词总结_序号」保存 → 返回可复现脚本
// 跨机器可移植：SD 目录走自动探测（DSH_SD_DIR 可覆盖），工作区默认临时目录（ACCEPTANCE_WS 可覆盖）。
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const tools = new Map()
const ctx = {
  logger: console,
  effect: (fn) => fn(),
  get: () => undefined,
  tools: {
    register(def) {
      tools.set(def.name, def)
      return () => tools.delete(def.name)
    },
  },
}
const mod = await import('./sd-bridge.js')
mod.apply(ctx, { sdDir: process.env.DSH_SD_DIR || '', port: Number(process.env.SD_PORT) || 7860, autoStart: true, startupTimeoutMs: 420000 })
console.log('tools:', [...tools.keys()])

// 自动探测到的 SD 目录（同步校验用）
const sdDir = mod.detectSdDir(process.env.DSH_SD_DIR || '')
assert.ok(sdDir, '自动探测必须找到本机 SD WebUI（找不到请设 DSH_SD_DIR）')
console.log('sdDir:', sdDir)

// 工作区：模拟任意用户的会话目录（产物/参考图/脚本都应落在这里）
const ws = process.env.ACCEPTANCE_WS
  ? path.resolve(process.env.ACCEPTANCE_WS)
  : fs.mkdtempSync(path.join(os.tmpdir(), 'sd-guard-acceptance-'))
const outDir = path.join(ws, 'SD-Picture')
const refDir = path.join(ws, 'ref')
const directPs1 = path.join(ws, 'sd-direct.ps1')
console.log('workspace:', ws)

// 自愈同步：包内 sd-direct.ps1 启动时同步进 SD 目录；工作区那份在首次生成脚本时惰性同步
const bundled = fs.readFileSync(new URL('./sd-direct.ps1', import.meta.url))
assert.ok(fs.existsSync(path.join(sdDir, 'sd-direct.ps1')), 'sd-direct.ps1 未同步到 SD 目录')
assert.ok(fs.readFileSync(path.join(sdDir, 'sd-direct.ps1')).equals(bundled), 'SD 目录的 sd-direct.ps1 内容与包内不一致')

const exec = { agent: { session: { header: { cwd: ws } } } }

// 1) 中文 summary → 文件名 = 总结_序号，固定目录
const a = await tools.get('sd_txt2img').execute(
  { prompt: '1girl, silver hair, cherry blossoms, masterpiece, best quality', negativePrompt: 'lowres, watermark', width: 512, height: 512, steps: 10, summary: '银发少女樱花' },
  exec,
)
console.log('gen1:', a.fileNames, a.savedDir, a.elapsedMs + 'ms')
assert.equal(a.savedDir, outDir)
assert.ok(fs.existsSync(a.paths[0]))
// 工作区脚本惰性自愈同步：生成命令时必须已落盘且与包内一致
assert.ok(fs.existsSync(directPs1), `sd-direct.ps1 未同步到工作区 ${directPs1}`)
assert.ok(fs.readFileSync(directPs1).equals(bundled), '工作区的 sd-direct.ps1 内容与包内不一致')
assert.ok(a.replyImages[0].includes(a.paths[0]))
// 违规分流协议：返回可复现脚本（文生图标注 + sd-direct.ps1 命令）
assert.ok(a.script, 'script missing')
assert.equal(a.script.mode, '文生图')
assert.ok(a.script.command.includes(`powershell -ExecutionPolicy Bypass -File "${directPs1}"`))
assert.ok(a.script.command.startsWith('powershell -ExecutionPolicy Bypass -File '), 'command must be a full one-liner')
assert.ok(!a.script.command.includes('\n'), 'command must stay on a single line')
assert.ok(!a.script.command.includes('& '), 'command must not use the & call-operator form')
assert.ok(a.script.command.includes('-Prompt'))
assert.ok(a.script.command.includes(`-OutDir "${outDir}"`), 'command must inject the workspace output dir')
assert.ok(a.script.asMarkdown.startsWith('【文生图】\n```powershell'))
assert.ok(a.script.asMarkdown.includes(a.script.command))
const seq1 = Number(/_(\d+)\.png$/.exec(a.fileNames[0])[1])

// 2) 同名 summary 序号递增，不覆盖
const b = await tools.get('sd_txt2img').execute(
  { prompt: '1girl, blue hair, masterpiece', steps: 10, summary: '银发少女樱花' },
  exec,
)
console.log('gen2:', b.fileNames)
assert.equal(Number(/_(\d+)\.png$/.exec(b.fileNames[0])[1]), seq1 + 1)

// 3) 不传 summary → 自动从 prompt 提词
const c = await tools.get('sd_txt2img').execute(
  { prompt: 'cyberpunk, city, neon lights, rain, masterpiece', steps: 10 },
  exec,
)
console.log('gen3:', c.fileNames)
assert.ok(/_\d{3}\.png$/.test(c.fileNames[0]))
assert.ok(c.fileNames[0].startsWith('cyberpunk'))

// 4) 批次多张 → 序号连号
const d = await tools.get('sd_txt2img').execute(
  { prompt: 'landscape, mountains, masterpiece', steps: 8, batchSize: 2, summary: '群山风景' },
  exec,
)
console.log('gen4:', d.fileNames)
assert.equal(d.fileNames.length, 2)
assert.equal(Number(/_(\d+)\.png$/.exec(d.fileNames[1])[1]), Number(/_(\d+)\.png$/.exec(d.fileNames[0])[1]) + 1)

// 5) render：文本块 + 图片块（图片直接进聊天窗口）
const blocks = tools.get('sd_txt2img').output.render({}, { ...a, attachments: [{ attachmentId: 'x' }] })
assert.equal(blocks[0].type, 'text')
assert.equal(blocks[1].type, 'image')

// 6) img2img 同一套命名规则
const e = await tools.get('sd_img2img').execute(
  { init_image: a.paths[0], prompt: '1girl, blue hair, masterpiece', denoisingStrength: 0.5, steps: 10, summary: '蓝发改色' },
  exec,
)
console.log('img2img:', e.fileNames)
assert.ok(/^蓝发改色_\d{3}\.png$/.test(e.fileNames[0]))
// 违规分流协议：图生图脚本带 -InitImage / -Denoising，标注【图生图】
assert.equal(e.script.mode, '图生图')
assert.ok(e.script.command.includes('-InitImage'))
assert.ok(e.script.command.includes('-Denoising'))
assert.ok(e.script.asMarkdown.startsWith('【图生图】'))
// 工作区内的参考图直接用原路径，不复制
assert.equal(e.source, e.sourceOriginal)
console.log('script(t2i):', a.script.command)
console.log('script(i2i):', e.script.command)

// 6b) 参考图固化：用户给的图在工作区之外（模拟聊天附件临时路径）→ 复制到 ref\，脚本引用固化副本
const tmpRef = path.join(os.tmpdir(), 'chat-attachment-user-gave.png')
fs.copyFileSync(a.paths[0], tmpRef)
const e2 = await tools.get('sd_img2img').execute(
  { init_image: tmpRef, prompt: '1girl, blue hair, masterpiece', denoisingStrength: 0.5, steps: 10, summary: '外部参考图' },
  exec,
)
assert.equal(e2.sourceOriginal, tmpRef, 'sourceOriginal 必须是用户原始路径')
assert.ok(e2.source.startsWith(refDir + path.sep), `固化副本应在 ref\\ 下，实际：${e2.source}`)
assert.ok(fs.existsSync(e2.source))
assert.ok(fs.readFileSync(e2.source).equals(fs.readFileSync(tmpRef)), '固化副本必须与用户给的图逐字节一致')
assert.ok(e2.script.command.includes(`-InitImage "${e2.source}"`), '脚本必须引用固化副本')
assert.ok(!e2.script.command.includes(tmpRef), '脚本不得再引用临时路径')
fs.rmSync(tmpRef, { force: true })

// 6c) sd_script 同样固化 B 档参考图
const tmpRef2 = path.join(os.tmpdir(), 'chat-attachment-b-tier.png')
fs.copyFileSync(a.paths[0], tmpRef2)
const sB = await tools.get('sd_script').execute({ prompt: '1girl, white sheet', initImage: tmpRef2 }, exec)
assert.ok(sB.command.includes(`-InitImage "${refDir}${path.sep}`), `sd_script 应固化参考图，实际：${sB.command}`)
assert.ok(!sB.command.includes(tmpRef2))
assert.ok(fs.existsSync(/-InitImage "([^"]+)"/.exec(sB.command)[1]))
fs.rmSync(tmpRef2, { force: true })

// 7) sd_script：B 档（明显违规）只出脚本不生图——纯命令生成，不碰 SD
assert.deepEqual([...tools.keys()], ['sd_txt2img', 'sd_img2img', 'sd_script', 'sd_models', 'sd_server'])
const before = fs.readdirSync(outDir).length
const s = await tools.get('sd_script').execute(
  { prompt: '1girl, white sheet, soft light, masterpiece', initImage: a.paths[0], denoising: 0.65, seed: 123 },
  exec,
)
assert.equal(s.generatesImage, false)
assert.equal(s.mode, '图生图')
assert.ok(s.asMarkdown.startsWith('【图生图】\n```powershell'))
assert.ok(s.command.includes('-Seed 123') && s.command.includes('-InitImage'))
// 单行完整命令：powershell 前缀 + 引号包住的脚本路径，禁止 & "路径" 形式
assert.ok(s.command.startsWith(`powershell -ExecutionPolicy Bypass -File "${directPs1}"`))
assert.ok(!s.command.includes('\n') && !s.command.includes('& '))
assert.ok(s.asMarkdown.includes('# 复制下面整行到 PowerShell'))
const s2 = await tools.get('sd_script').execute({ prompt: '1girl, silver hair', name: 'shorekeeper' }, exec)
assert.equal(s2.mode, '文生图')
assert.ok(s2.command.includes('-Name "shorekeeper"'))
// sd_script 不落任何新图
assert.equal(fs.readdirSync(outDir).length, before)
console.log('sd_script(i2i):', s.command)
console.log('sd_script(t2i):', s2.command)

console.log('ACCEPTANCE OK')
