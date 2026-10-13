// install-sd.ps1 清单与预检专项（0.7.0）：静态断言 + 临时目录干跑（不联网下载大文件）
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const ps1Path = path.join(here, 'install-sd.ps1')
const src = fs.readFileSync(ps1Path, 'utf8')

// 1) UTF-8 BOM（坑13 / 坑19：PS5.1 无 BOM 按 GBK 读会语法错）
const raw = fs.readFileSync(ps1Path)
assert.deepEqual([...raw.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'install-sd.ps1 must be UTF-8 with BOM')

// 2) 三张清单：键、sha256（64 位十六进制）、HF 源
function extractCatalog(name) {
  const m = new RegExp(`${name.replace(/\$/g, '\\$')}\\s*=\\s*\\[ordered\\]@\\{([\\s\\S]*?)\\n\\}`, 'm').exec(src)
  assert.ok(m, `${name} catalog missing`)
  const entries = [...m[1].matchAll(/(\w+)\s*=\s*@\{([^}]*)\}/g)]
  const out = {}
  for (const [, key, body] of entries) {
    const sha = /Sha = '([0-9a-f]{64})'/.exec(body)
    const repo = /Repo = '([^']+)'/.exec(body)
    const file = /File = '([^']+)'/.exec(body)
    const name2 = /Name = '([^']+)'/.exec(body)
    out[key] = { sha: sha?.[1], repo: repo?.[1], file: file?.[1], name: name2?.[1] }
  }
  return out
}

const models = extractCatalog('$ModelCatalog')
assert.deepEqual(Object.keys(models), ['awpainting', 'revanimated', 'anythingv5', 'majicmix', 'darksushi'], 'model catalog keys')
assert.equal(models.awpainting.sha, '3d1b3c42ec704f3397d9e2968e3e544eda111741e10793afd78faa8148b36e12', 'AWPainting sha must match the verified local file')

const vaes = extractCatalog('$VaeCatalog')
assert.deepEqual(Object.keys(vaes), ['mse', 'animevae'], 'vae catalog keys')
assert.equal(vaes.animevae.sha, 'f921fb3f29891d2a77a6571e56b8b5052420d2884129517a333c60b1b4816cdf', 'animevae sha must match the verified local file')

const loras = extractCatalog('$LoraCatalog')
assert.deepEqual(Object.keys(loras), ['add_detail', 'easynegative', 'badhandv4'], 'lora catalog keys')
for (const [k, v] of Object.entries({ ...models, ...vaes, ...loras })) {
  assert.ok(v.sha, `${k}: sha256 missing`)
  assert.ok(v.repo && v.file, `${k}: HF repo/file missing`)
}

// 3) 默认值：模型只拉 awpainting、LoRA 拉三件套（风险点 1/2 的拍板）
assert.ok(/\[string\]\$Models = 'awpainting'/.test(src), '-Models default must be awpainting only')
assert.ok(/\[string\]\$Loras = 'add_detail,easynegative,badhandv4'/.test(src), '-Loras default must be the three common items')

// 4) 环境预检段：磁盘 / 网络 / git / Python / VC++ 五个检查都在，失败单条退出
assert.ok(/function Test-Prereqs/.test(src), 'Test-Prereqs missing')
for (const key of ['磁盘空间不足', '探活失败', 'Install-MinGit', 'Install-Python310', 'vc_redist']) {
  assert.ok(src.includes(key), `preflight missing: ${key}`)
}
assert.ok(/\$fail\s*=\s*\{\s*param\(\$k, \$msg\)[\s\S]*?exit 1/.test(src), 'preflight must exit 1 on first hard failure')
assert.ok(/环境预检结果/.test(src), 'preflight summary missing')

// 5) 升级复验与失败不阻断
assert.ok(/\[switch\]\$Upgrade/.test(src), '-Upgrade switch missing')
assert.ok(/Supersedes/.test(src), 'Supersedes (old -> new) declaration missing')
assert.ok(/下载失败（.*跳过继续/.test(src), 'per-item download failure must not abort the run')

// 6) 干跑：临时目录 + 已有 launch.py + 全部跳过 → 预检打印、清单为空、记录无 BOM
const tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), 'sd-guard-home-'))
const tmpSd = fs.mkdtempSync(path.join(os.tmpdir(), 'sd-guard-catalog-'))
fs.writeFileSync(path.join(tmpSd, 'launch.py'), '')
const prevHome = process.env.USERPROFILE
process.env.USERPROFILE = tmpHome
const run = spawnSync(
  'powershell.exe',
  ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1Path, '-Target', tmpSd, '-SkipGit', '-SkipPython', '-SkipVC', '-SkipModel', '-SkipVae', '-Loras', 'none', '-NoConfig'],
  { encoding: 'utf8', timeout: 120000 },
)
process.env.USERPROFILE = prevHome
const out = `${run.stdout || ''}${run.stderr || ''}`
assert.equal(run.status, 0, `dry run must exit 0, got ${run.status}\n${out}`)
assert.ok(out.includes('环境预检结果'), `preflight summary must print\n${out}`)
assert.ok(out.includes('清单里没有') === false, 'no invalid keys expected')
assert.ok(out.includes('BOM=False'), `install record must be BOM-free\n${out}`)

// 7) 非法键 → exit 1 且列出可用键
process.env.USERPROFILE = tmpHome
const bad = spawnSync(
  'powershell.exe',
  ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps1Path, '-Target', tmpSd, '-SkipGit', '-SkipPython', '-SkipVC', '-SkipModel', '-SkipVae', '-Loras', 'notakey', '-NoConfig'],
  { encoding: 'utf8', timeout: 120000 },
)
process.env.USERPROFILE = prevHome
const badOut = `${bad.stdout || ''}${bad.stderr || ''}`
assert.equal(bad.status, 1, 'invalid catalog key must exit 1')
assert.ok(badOut.includes('可用键'), 'must list available keys')

fs.rmSync(tmpHome, { recursive: true, force: true })
fs.rmSync(tmpSd, { recursive: true, force: true })

console.log('models:', Object.keys(models).join(', '))
console.log('loras:', Object.keys(loras).join(', '))
console.log('INSTALL CATALOG OK')
