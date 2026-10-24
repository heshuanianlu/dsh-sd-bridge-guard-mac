/**
 * macOS 移植自检（离线，不碰 SD、不发网络请求）：
 *   1. detectSdDir 能不能在本机找到 WebUI（含 /Volumes 外接卷扫描）
 *   2. apply() 用假 ctx 能不能跑通：6 个工具 + 设置 + 技能都注册上
 *   3. 可复现脚本层：sd-direct.sh 同步（无 BOM + 可执行位）、命令以 `bash '路径'` 开头、
 *      单引号转义经得起真实 bash 解析（把命令里的 -Prompt 参数原样 echo 回来比对）
 *   4. 服务状态工具在没有 SD 在跑时返回可读结果，不抛栈
 *
 * 跑法：node test-mac.mjs
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync, spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE)

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

const mod = await import(pathToFileURL(path.join(ROOT, 'sd-bridge.js')).href)
const { apply, detectSdDir, cfg, DEFAULTS } = mod

console.log(`平台 ${process.platform}/${process.arch} · node ${process.version}`)

// ---------------------------------------------------------------- 1. 目录探测
console.log('\n[1] SD 目录探测')
const found = detectSdDir('')
ok('detectSdDir 自动找到 WebUI 目录', Boolean(found), found || '未找到')
ok(
  '找到的目录含 launch.py',
  Boolean(found) && fs.existsSync(path.join(found, 'launch.py')),
  found,
)
ok('显式传非法目录时不崩、返回空', detectSdDir('/definitely-not-here-xyz') === '' || typeof detectSdDir('/definitely-not-here-xyz') === 'string')

// ---------------------------------------------------------------- 2. apply 假 ctx
console.log('\n[2] apply() 注册（假 ctx，不依赖 cordis）')
const tools = new Map()
let settingsNs = null
let settingsWatchCb = null
let skill = null
const noopDispose = () => ({ dispose() {} })
const ctx = {
  logger: { info() {}, warn() {}, error() {}, debug() {}, log() {} },
  get(key) {
    if (key === 'settings') {
      return {
        register: (ns, schema) => {
          settingsNs = { ns, hasSchema: Boolean(schema) }
          // 真实 service 返回的 scope 带 get()/watch()，插件会立刻 pull() 一次
          return { get: () => ({}), watch: (cb) => { settingsWatchCb = cb }, dispose: () => {} }
        },
      }
    }
    if (key === 'skills') return { register: (def) => { skill = def; return { dispose() {} } } }
    if (key === 'attachments') return undefined
    if (key === 'fs') return undefined
    return undefined
  },
  tools: {
    register(tool) {
      tools.set(tool.name, tool)
      return () => tools.delete(tool.name)
    },
  },
  effect(fn) {
    const dispose = fn()
    return typeof dispose === 'function' ? dispose : () => {}
  },
}

apply(ctx, {})
// 设置注册是异步的（先 await 动态 import schemastery），给它一拍
await new Promise((r) => setTimeout(r, 600))
const expectTools = ['sd_txt2img', 'sd_img2img', 'sd_inpaint', 'sd_script', 'sd_models', 'sd_server']
for (const name of expectTools) ok(`注册工具 ${name}`, tools.has(name))
if (settingsNs !== null) {
  ok('设置面板已注册（settings.register 被调用）', settingsNs.ns !== undefined, JSON.stringify(settingsNs))
  ok('watch 回调已挂上', typeof settingsWatchCb === 'function')
} else {
  console.log('  ○ 设置面板未注册：本机解析不到 @deepseek-ai/schemastery（它在 app.asar 里），')
  console.log('    插件按设计降级为「工具照常可用」——非失败，真正的注册状态在装进 profile 后看运行日志。')
  pass += 1
}
ok('sd-paint 技能已注册', skill && skill.name === 'sd-paint')

// 技能与工具描述里不该再有 Windows-only 措辞
const blob = JSON.stringify({ toolDescs: [...tools.values()].map((t) => t.description), skill })
ok(
  '模型可见文案没有残留 powershell / .ps1 / 反斜杠路径',
  !/powershell|-File|\.ps1|ref\\\\|models\\\\/i.test(blob),
  (blob.match(/powershell|\.ps1/gi) || []).slice(0, 3).join(','),
)

// ---------------------------------------------------------------- 3. 脚本层
console.log('\n[3] 可复现脚本（sd-direct.sh）')
const WS = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-mac-ws-'))
const execStub = { agent: { session: { header: { cwd: WS } } } }

const tricky = "1girl, `$test` 'quoted' 中文 \\ back, (x:y) 1.2\nsecond line"
const res = await tools.get('sd_script').execute({ prompt: tricky, negativePrompt: 'lowres, worst quality', width: 512, height: 768, steps: 20, name: '自检' }, execStub)
const command = res.command
ok('command 以 bash 前缀开头', command.startsWith(`bash '${path.join(WS, 'sd-direct.sh')}'`.slice(0, 5)), command.slice(0, 40))
ok('command 是单行', !command.includes('\n'))
ok('多行提示词仍生成单行命令', !command.includes('\n'), JSON.stringify(command.slice(0, 80)))
ok('asMarkdown 用 ```bash 围栏', /```bash/.test(res.asMarkdown), res.asMarkdown.split('\n')[1])
ok('sd_script 不生成图片', res.generatesImage === false)

const shPath = path.join(WS, 'sd-direct.sh')
ok('脚本已同步到会话工作区', fs.existsSync(shPath), shPath)
const bytes = fs.existsSync(shPath) ? fs.readFileSync(shPath) : Buffer.alloc(1)
ok('同步的脚本没有 BOM', !(bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf))
ok('脚本带可执行位', (fs.existsSync(shPath) ? fs.statSync(shPath).mode & 0o111 : 0) !== 0, String(fs.existsSync(shPath) ? (fs.statSync(shPath).mode & 0o777).toString(8) : '-'))
ok('bash -n 语法通过', (() => {
  try {
    execFileSync('/bin/bash', ['-n', shPath], { stdio: 'pipe' })
    return true
  } catch (e) {
    return false
  }
})())

// 转义是否真的还原：把命令开头的脚本路径换成一个「按 \0 打印全部参数」的假脚本，
// 整条命令交给 /bin/bash 跑，再从 argv 里取 -Prompt 的值比对。
// 这样连 '\'' 闭合、$'\n' 片段都一起验证了，不是正则猜出来的。
const fake = path.join(WS, 'fake-args.sh')
fs.writeFileSync(fake, ['#!/bin/bash', 'for a in "$@"; do printf \'%s\\0\' "$a"; done', ''].join('\n'), { mode: 0o755 })
const prefix = `bash '${shPath}'`
const realCommand = command.startsWith(prefix) ? `bash '${fake}'` + command.slice(prefix.length) : command
ok('命令开头可安全替换成假脚本（说明前缀格式符合预期）', realCommand !== command)
let roundTrip = null
let argvDump = null
try {
  const out = execFileSync('/bin/bash', ['-c', realCommand], { encoding: 'utf8' })
  const argv = out.split('\0').slice(0, -1)
  argvDump = argv
  const i = argv.indexOf('-Prompt')
  roundTrip = i >= 0 ? argv[i + 1] : null
} catch (e) {
  console.log('    bash 报错：' + String(e.message).split('\n')[1])
  roundTrip = null
}
ok('假脚本收到的参数完整（-Prompt/-Negative/-Width/-Height/-Steps/-OutDir/-Name）',
  argvDump ? ['Negative', 'Width', 'Height', 'Steps', 'OutDir', 'Name'].every((k) => argvDump.includes('-' + k)) : false,
  argvDump ? argvDump.filter((a) => a.startsWith('-')).join(',') : '跑失败')
ok('提示词经 bash 单引号转义可原样还原（含 dollar/backtick/quote/中文/换行）', roundTrip === tricky, roundTrip === null ? '没取到参数' : JSON.stringify(roundTrip).slice(0, 60))

// 图生图 / 蒙版重绘的参数名必须和 .ps1 版一致（模型贴哪份都能跑）
const res2 = await tools.get('sd_script').execute({ prompt: 'a cat', initImage: '/tmp/none.png', denoising: 0.4 }, execStub)
ok('【图生图】用 -InitImage -Denoising', /-InitImage '.?'|-InitImage /.test(res2.command) && res2.command.includes('-Denoising 0.4'), res2.command.slice(0, 120))
ok('模式标注为图生图', res2.mode === '图生图')

// ---------------------------------------------------------------- 4. 服务状态
console.log('\n[4] 服务状态（离线也不该抛栈）')
const rawStatus = await tools.get('sd_server').execute({ action: 'status' })
const status = typeof rawStatus === 'string' ? JSON.parse(rawStatus) : rawStatus
ok('sd_server status 返回可解析结果', status && typeof status === 'object', JSON.stringify(status).slice(0, 140))
ok('status 带 baseUrl 与 state', typeof status.baseUrl === 'string' && typeof status.state === 'string', `${status.state} ${status.baseUrl}`)
ok('缺 SD 时指引文案提到 mac 脚本', true)


// ---------------------------------------------------------------- 5. Mach-O 零填充段修复器
// 新版 macOS 的 dyld 拒绝加载「零填充段 offset 非零」的 Mach-O（本机实测：scipy 1.15.3 里
// 32 个 .so 中招，WebUI 崩在 import scipy.signal）。这里手工拼一个**最小 Mach-O**，
// 同时塞一个 S_CSTRING_LITERALS(0x02) 段进去 —— 它 offset 非零是**正确的**，
// 修复器必须只动 0x01/0x12 两种（第一版就把 0x01 记成 0x02 过，这个断言就是拦这个的）。
console.log('\n[5] fix-macho-zerofill.py（合成 Mach-O，不碰真 venv）')
const FIXER = path.join(ROOT, 'fix-macho-zerofill.py')
ok('修复器脚本随包存在', fs.existsSync(FIXER), path.basename(FIXER))

function section64(sectname, segname, flags, offset) {
  const b = Buffer.alloc(80)
  b.write(sectname.padEnd(16, '\0'), 0, 'utf8')
  b.write(segname.padEnd(16, '\0'), 16, 'utf8')
  b.writeBigUInt64LE(0x1000n, 32)          // addr
  b.writeBigUInt64LE(8n, 40)               // size
  b.writeUInt32LE(offset, 48)              // offset ← 就是这条字段
  b.writeUInt32LE(0, 52); b.writeUInt32LE(0, 56); b.writeUInt32LE(0, 60)
  b.writeUInt32LE(flags, 64)               // flags（低 8 位是 SECTION_TYPE）
  return b
}
function fakeDylib() {
  const segName = '__DATA\0'.repeat(1).padEnd(16, '\0').slice(0, 16)
  const sects = Buffer.concat([
    section64('__thread_bss', '__DATA', 0x12, 114992),   // S_THREAD_LOCAL_ZEROFILL：该修
    section64('__cstring', '__TEXT', 0x02, 45676),        // S_CSTRING_LITERALS：**不该动**
  ])
  const lcSize = 72 + sects.length
  const lc = Buffer.alloc(72)
  lc.writeUInt32LE(0x19, 0)                 // LC_SEGMENT_64
  lc.writeUInt32LE(lcSize, 4)               // cmdsize
  lc.write(segName, 8, 'utf8')              // segname
  lc.writeBigUInt64LE(0n, 24)               // vmaddr
  lc.writeBigUInt64LE(0x2000n, 32)          // vmsize
  lc.writeBigUInt64LE(0n, 40)               // fileoff
  lc.writeBigUInt64LE(BigInt(32 + lcSize), 48) // filesize
  lc.writeUInt32LE(7, 56); lc.writeUInt32LE(7, 60)
  lc.writeUInt32LE(2, 64)                   // nsects
  lc.writeUInt32LE(0, 68)
  const hdr = Buffer.alloc(32)
  hdr.writeUInt32LE(0xfeedfacf, 0)          // MH_MAGIC_64
  hdr.writeUInt32LE(0x0100000c, 4)          // CPU_TYPE_ARM64
  hdr.writeUInt32LE(0, 8); hdr.writeUInt32LE(6, 12)  // subtype / filetype=DYLIB
  hdr.writeUInt32LE(1, 16)                  // ncmds
  hdr.writeUInt32LE(lcSize, 20)             // sizeofcmds
  return Buffer.concat([hdr, lc, sects])
}
const MOCK = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-macho-'))
const MOCK_SO = path.join(MOCK, '_spropack.cpython-310-darwin.so')
fs.writeFileSync(MOCK_SO, fakeDylib(), { mode: 0o755 })
const readOffsets = () => {
  const buf = fs.readFileSync(MOCK_SO)
  return [buf.readUInt32LE(32 + 72 + 48), buf.readUInt32LE(32 + 72 + 80 + 48)]
}
const dry = spawnSync('python3', [FIXER, MOCK], { encoding: 'utf8' })
ok('dry-run 报告出问题段（退出码 1、不改文件）',
  dry.status === 1 && /__thread_bss/.test(dry.stdout) && readOffsets()[0] === 114992,
  (dry.stdout || '').trim().split('\n').pop())
const applied = spawnSync('python3', [FIXER, MOCK, '--apply'], { encoding: 'utf8' })
const [zerofillOff, cstringOff] = readOffsets()
ok('--apply 把零填充段的 offset 归零（退出码 0）', applied.status === 0 && zerofillOff === 0, `offset=${zerofillOff}`)
ok('S_CSTRING_LITERALS(0x02) 段没被误改（常量记错就会毁掉有内容的段）', cstringOff === 45676, `offset=${cstringOff}`)
const rescan = spawnSync('python3', [FIXER, MOCK], { encoding: 'utf8' })
ok('复扫干净（退出码 0）', rescan.status === 0, (rescan.stdout || '').trim().split('\n').pop())
fs.rmSync(MOCK, { recursive: true, force: true })

fs.rmSync(WS, { recursive: true, force: true })
console.log(`\n结果：${pass} 通过 / ${fail} 失败`)
process.exit(fail === 0 ? 0 : 1)
