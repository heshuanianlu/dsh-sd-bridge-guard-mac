/**
 * 回归检查：macOS 自带 **bash 3.2**，在 locale 不是 UTF-8 时（脚本被从 DSH/Node 里 spawn 出来
 * 常常就是这种环境），`$VAR` 紧跟中文字符会把多字节的**首字节算进变量名**，于是
 * `set -u` 当场报 `VAR\xEF\xBC\x9A unbound variable`，脚本连第一句都跑不到。
 *
 * 本机的真实事故：`note "使用 git：$GIT_BIN（…"` → `install-sd-macos.sh: line 123: GIT_BIN？: unbound variable`
 *
 * 规则：`$IDENT` 后面紧跟非 ASCII 字节 = 违规，必须写成 `${IDENT}`。
 * 注释行（整行以 # 开头）不检查——注释里变量不会被展开。
 *
 * 跑法：node check-sh-varquote.mjs [文件…]（默认查 sd-direct.sh 与 install-sd-macos.sh）
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const files = process.argv.slice(2).length
  ? process.argv.slice(2)
  : ['sd-direct.sh', 'install-sd-macos.sh'].map((f) => path.join(HERE, f))

const VIOLATION = /\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7F])/
let bad = 0
for (const file of files) {
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  lines.forEach((line, i) => {
    if (line.trimStart().startsWith('#')) return
    const m = VIOLATION.exec(line)
    if (m) {
      bad += 1
      console.log(`✘ ${path.basename(file)}:${i + 1}  $${m[1]} 紧跟 ${JSON.stringify(m[2])} → 改成 \${${m[1]}}`)
      console.log(`    ${line.trim().slice(0, 100)}`)
    }
  })
}
if (bad === 0) console.log(`✔ ${files.length} 份脚本没有「$VAR 紧跟非 ASCII」的写法（bash 3.2 + set -u 安全）`)
else console.log(`\n共 ${bad} 处需修`)
process.exit(bad === 0 ? 0 : 1)
