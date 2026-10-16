/**
 * gen-manifest.mjs —— 生成 manifest.json（插件文件完整性基线）
 *
 * 用途：把仓库里每个文件的 sha256 + 大小 + 分类写进 manifest.json，随包发布。
 * 用户端插件启动/退出时用它**反向比对**本机文件，列出「相比仓库缺了什么、哪个文件被改过」。
 *
 * 分类说明（决定「缺失是否正常」）：
 *   runtime  运行时必需 —— 缺任何一个插件都跑不起来（红色告警）
 *   tool     辅助脚本/工具 —— 缺了特定功能不可用（黄色）
 *   doc      文档 —— 缺了不影响运行（灰色）
 *   dev      开发测试用 —— npm 包内 files 白名单不含，缺失属正常（灰色）
 *   ci       CI 配置 —— 同上（灰色）
 *
 * 用法：node gen-manifest.mjs            # 写入 manifest.json
 *      node gen-manifest.mjs --check    # 只比对，不写（CI 用，退出码非 0 = 清单过期）
 */
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const ROOT = path.dirname(fileURLToPath(import.meta.url))
const MANIFEST = path.join(ROOT, 'manifest.json')
const CHECK_ONLY = process.argv.includes('--check')

/** 打包进 npm 的文件（package.json 的 files 白名单，展开 docs/）。 */
const SHIPPED = new Set([
  'sd-bridge.js',
  'sd-direct.ps1',
  'sd-inject.ps1',
  'sd-auto-mask.py',
  'sd-mask-qa.py',
  'install-sd.ps1',
  'cordis.patch.yml',
  'README.md',
  'CHANGELOG.md',
  'LICENSE',
  'publish-npm.ps1',
  'test-region-mask.ps1',
  'test-mask-qa.ps1',
  'test-vlm-cleanup.ps1',
  'test-automask-retry.ps1',
  'test-vram-release.ps1',
  'test-trailing-comma.ps1',
])

/** 分类规则：按文件名/路径判定。 */
function classify(rel) {
  if (rel === 'package.json' || rel === 'manifest.json') return 'runtime'
  if (rel.startsWith('.github/')) return 'ci'
  if (rel.startsWith('docs/')) return 'doc'
  if (/\.(md|txt)$/i.test(rel) || rel === 'LICENSE' || rel === '.gitattributes' || rel === '.gitignore') return 'doc'
  if (/^(acceptance|smoke-skill)\.mjs$/.test(rel)) return 'dev'
  if (/^test-.*\.mjs$/.test(rel)) return 'dev'
  if (/^test-.*\.ps1$/.test(rel)) return 'tool'
  if (rel === 'gen-manifest.mjs') return 'dev'
  if (/\.(tgz)$/.test(rel)) return 'artifact'
  if (/\.(js|ps1|py|yml|yaml)$/.test(rel)) return 'runtime'
  return 'other'
}

/** 忽略的路径（不参与清单）。 */
function ignored(rel) {
  if (rel.startsWith('node_modules/')) return true
  if (rel.startsWith('.git/')) return true
  if (rel.startsWith('Microsoft/')) return true // PS ModuleAnalysisCache 之类运行时产物
  if (rel === 'manifest.json') return true // 自身不参与哈希（否则递归）
  if (/\.tgz$/.test(rel)) return true
  return false
}

function walk(dir, prefix = '') {
  const out = []
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name
    if (ignored(rel)) continue
    if (entry.isDirectory()) {
      out.push(...walk(path.join(dir, entry.name), rel))
    } else if (entry.isFile()) {
      out.push(rel)
    }
  }
  return out
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

const files = walk(ROOT).sort()
const entries = files.map((rel) => {
  const abs = path.join(ROOT, rel)
  const st = fs.statSync(abs)
  return {
    path: rel,
    sha256: sha256(abs),
    bytes: st.size,
    category: classify(rel),
    shipped: SHIPPED.has(rel) || rel.startsWith('docs/'),
  }
})

const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'))
const manifest = {
  name: pkg.name,
  version: pkg.version,
  generatedAt: new Date().toISOString(),
  fileCount: entries.length,
  files: entries,
}

if (CHECK_ONLY) {
  if (!fs.existsSync(MANIFEST)) {
    console.error('manifest.json 不存在，请先运行 node gen-manifest.mjs')
    process.exit(1)
  }
  const old = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'))
  const oldMap = new Map(old.files.map((f) => [f.path, f.sha256]))
  const newMap = new Map(entries.map((f) => [f.path, f.sha256]))
  const missing = [...oldMap.keys()].filter((p) => !newMap.has(p))
  const added = [...newMap.keys()].filter((p) => !oldMap.has(p))
  const changed = [...newMap.keys()].filter((p) => oldMap.has(p) && oldMap.get(p) !== newMap.get(p))
  const stale = old.version !== manifest.version || missing.length || added.length || changed.length
  if (stale) {
    console.error(`manifest.json 已过期（版本 ${old.version} → ${manifest.version}）`)
    if (added.length) console.error(`  新增 ${added.length}: ${added.slice(0, 8).join(', ')}`)
    if (missing.length) console.error(`  移除 ${missing.length}: ${missing.slice(0, 8).join(', ')}`)
    if (changed.length) console.error(`  变更 ${changed.length}: ${changed.slice(0, 8).join(', ')}`)
    console.error('  请运行 node gen-manifest.mjs 重新生成')
    process.exit(1)
  }
  console.log(`manifest.json 是最新的（${entries.length} 个文件，v${old.version}）`)
  process.exit(0)
}

fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + '\n', 'utf8')
const byCat = {}
for (const e of entries) byCat[e.category] = (byCat[e.category] || 0) + 1
console.log(`已写入 manifest.json：${entries.length} 个文件（v${pkg.version}）`)
for (const [cat, n] of Object.entries(byCat).sort()) console.log(`  ${cat.padEnd(9)} ${n}`)
