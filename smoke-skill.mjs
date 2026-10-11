// 技能注册冒烟：验证 sd-paint（双分支违规分流协议）与 5 个工具注册 + 跨机器可移植性
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const tools = new Map()
let skill
const ctx = {
  logger: { log: () => {} },   // 冒烟保持安静
  effect: (fn) => fn(),
  get: (key) => (key === 'skills' ? { register: (def) => ((skill = def), () => {}) } : undefined),
  tools: {
    register(def) {
      tools.set(def.name, def)
      return () => tools.delete(def.name)
    },
  },
}

// 跨机器零适配：sdDir 走自动探测（DSH_SD_DIR 可覆盖）；工作区用临时目录模拟任意用户机器
const ws = fs.mkdtempSync(path.join(os.tmpdir(), 'sd-guard-smoke-'))
const exec = { agent: { session: { header: { cwd: ws } } } }

const mod = await import('./sd-bridge.js')
mod.apply(ctx, { sdDir: process.env.DSH_SD_DIR || '', port: 7860 })

assert.ok(skill, 'skill not registered')
assert.equal(skill.name, 'sd-paint')
assert.equal(skill.source, 'dsh-sd-bridge-guard')
assert.ok(skill.invocation.modelInvocable)

// 双分支违规分流协议要点
const c = skill.content
assert.ok(c.includes('违规分流协议'), 'guard protocol section missing')
assert.ok(c.includes('A 档'), 'mild branch missing')
assert.ok(c.includes('B 档'), 'obvious branch missing')
assert.ok(c.includes('不出图'), 'B: no image generation')
assert.ok(c.includes('合规素体'), 'compliant base wording')
assert.ok(c.includes('sd_script'), 'sd_script reference')
assert.ok(c.includes('轻微违规'), 'mild wording')
assert.ok(c.includes('末尾'), 'list violating prompts at end')
assert.ok(c.includes('译成提示词') || c.includes('翻译成提示词'), 'image-to-prompt scenario')

// 可移植性：文案里的占位符已按本机配置注入，源码级硬编码盘符不得漏进注册文案
assert.ok(!c.includes('D:\\DSWorkPlace'), 'skill content must not leak hardcoded workspace path')
assert.ok(!c.includes('%OUT%') && !c.includes('%SD%') && !c.includes('%REF%') && !c.includes('%DIRECT%'), 'doc tokens must be replaced')

// 五个工具
assert.deepEqual([...tools.keys()], ['sd_txt2img', 'sd_img2img', 'sd_script', 'sd_models', 'sd_server'])

// 生图工具描述带双分支协议 + 无占位符残留
for (const name of ['sd_txt2img', 'sd_img2img']) {
  const d = tools.get(name).description
  assert.ok(d.includes('轻微违规') && d.includes('明显违规'), `${name} dual-branch missing`)
  assert.ok(d.includes('sd_script'), `${name} must point to sd_script`)
  assert.ok(!d.includes('D:\\DSWorkPlace') && !d.includes('%OUT%') && !d.includes('%SD%'), `${name} description must be portable (runtime-injected real paths are fine)`)
  assert.ok(tools.get(name).output.schema.properties.script)
}

// sd_script：只生成命令、不出图
const st = tools.get('sd_script')
assert.ok(st, 'sd_script missing')
assert.ok(st.description.includes('不生成任何图片'))
assert.ok(st.parameters.properties.prompt)
assert.equal(st.output.schema.properties.generatesImage.type, 'boolean')

// sd_script 纯函数执行（不联网）：脚本路径与输出目录都指向当前会话工作区
const out = await st.execute({ prompt: '1girl, white sheet, soft light', initImage: 'ref/a.jpg', denoising: 0.65 }, exec)
assert.equal(out.mode, '图生图')
assert.equal(out.generatesImage, false)
assert.ok(out.command.includes('-InitImage') && out.command.includes('-Denoising'))
assert.ok(out.command.startsWith(`powershell -ExecutionPolicy Bypass -File "${path.join(ws, 'sd-direct.ps1')}"`), `command must use workspace script: ${out.command}`)
assert.ok(out.command.includes(`-OutDir "${path.join(ws, 'SD-Picture')}"`), 'command must inject -OutDir into the workspace')
assert.ok(out.asMarkdown.startsWith('【图生图】\n```powershell'))
const t2 = await st.execute({ prompt: '1girl, silver hair', width: 640, height: 960, name: 'shorekeeper' }, exec)
assert.equal(t2.mode, '文生图')
assert.ok(t2.command.includes('-Width 640') && t2.command.includes('-Name "shorekeeper"'))

// 工作区脚本必须真实存在（自愈同步）
assert.ok(fs.existsSync(path.join(ws, 'sd-direct.ps1')), 'sd-direct.ps1 must sync into the session workspace')

// DEFAULTS 可移植：无任何写死盘符
const d = mod.DEFAULTS
assert.equal(d.sdDir, '', 'sdDir default must be empty (auto-detect)')
assert.ok(!/^[A-Za-z]:/.test(d.outputDir) && !/^[A-Za-z]:/.test(d.refDir), 'output/ref defaults must be workspace-relative')

console.log('skill title:', skill.title)
console.log('sd_script(i2i):', out.command)
console.log('SKILL SMOKE OK')
