// 技能注册冒烟：验证 sd-paint（双分支违规分流协议）与 7 个工具注册 + 跨机器可移植性
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

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

// 双分支违规分流协议要点（A 档 + C 档，C 档完全覆盖原「明显违规」档）
const c = skill.content
assert.ok(c.includes('违规分流协议'), 'guard protocol section missing')
assert.ok(c.includes('A 档'), 'mild branch missing')
assert.ok(c.includes('C 档'), 'C 档定义缺失')
assert.ok(c.includes('涉及任何违规内容'), 'C 档必须覆盖「涉及任何违规内容」（用户红线）')
assert.ok(c.includes('【本地注入】'), 'C 档必须标注【本地注入】')
assert.ok(c.includes('sd-inject.ps1'), 'C 档必须提及 sd-inject.ps1')
assert.ok(c.includes('-BasePrompt'), 'C 档命令必须带 -BasePrompt')
assert.ok(c.includes('-BaseNegative'), 'C 档命令必须带 -BaseNegative')
assert.ok(c.includes('sd_inject'), 'C 档必须要求调 sd_inject 生成命令（坑22：命令不能在 apply 时固化路径）')
assert.ok(!c.includes('B 档'), 'B 档字样必须全部替换为 C 档')
assert.ok(c.includes('不出图'), 'C: no image generation')
// C 档章节自身不得把违规请求路由到任何**生图/脚本**工具（只输出本地注入命令）；只截取 C 档那一节来判定。
// 允许出现的只有「禁止调用 ...」这种否定措辞，不允许「调/改调/走/给/用/传」这类正向路由。
// sd_inject 是唯一的例外：它不生图，只生成命令字符串。
const cSection = c.slice(c.indexOf('### C 档'), c.indexOf('### 通用'))
assert.ok(
  !/(?:调|改调|走|给|用|传)\s*`?(sd_script|sd_txt2img|sd_img2img|sd_inpaint)/.test(cSection.replace(/禁止调用/g, '')),
  'C 档 section must not route to any tool call',
)
assert.ok(cSection.includes('sd_inject'), 'C 档 section must call sd_inject to build the command')
assert.ok(
  !/不要传\s*`?-OutDir/.test(cSection),
  'C 档不得再教「不要传 -OutDir」——插件必须显式注入工作区 -OutDir（坑22）',
)
// 三个生图工具的 C 档指向也必须是 sd-inject.ps1 本地注入命令
for (const name of ['sd_txt2img', 'sd_img2img', 'sd_inpaint']) {
  const d = tools.get(name).description
  assert.ok(d.includes('sd-inject.ps1'), `${name} C 档 must point to sd-inject.ps1`)
  assert.ok(!d.includes('B 档'), `${name} description must not mention B 档`)
}
// 用户红线（2026-10-14）：A 档 = 完全不违规才出图；涉及任何违规内容一律 C 档，没有「删词后照常出图」的中间路线
assert.ok(c.includes('A 档 · 完全不违规'), '必须写明 A 档前置条件：完全不违规')
assert.ok(c.includes('没有「轻微违规删词后照常出图」这条中间路线'), '必须明令禁止「删词出图」中间路线')
assert.ok(!c.includes('### A 档 · 轻微违规'), '旧「A 档轻微违规出图」章节必须删除')
assert.ok(!c.includes('权重拦截，三步缺一不可'), '旧「A 档三步加权拦截」流程必须删除')
assert.ok(c.includes('末尾'), 'list violating prompts at end')
assert.ok(c.includes('译成提示词') || c.includes('翻译成提示词'), 'image-to-prompt scenario')
// 末尾违规词清单必须是「违禁提示词：」/「建议替换词：」两行、一行排开逗号分隔（不得逐条罗列）
assert.ok(c.includes('违禁提示词：'), '末尾清单第一行必须是「违禁提示词：」')
assert.ok(c.includes('建议替换词：'), '末尾清单第二行必须是「建议替换词：」')
assert.ok(
  /违禁提示词：<被剔除的违规词，全部译成英文，一行排开，中间用逗号隔开>/.test(c),
  '违禁提示词行必须声明：译成英文、一行排开、逗号分隔',
)
assert.ok(
  /建议替换词：<与违禁提示词相反或用于替换的词，一行排开，中间用逗号隔开>/.test(c),
  '建议替换词行必须声明：相反/可替换、一行排开、逗号分隔',
)
assert.ok(
  /不得逐条罗列、不得换行展开/.test(c),
  '必须明确禁止逐条罗列与换行展开',
)
assert.ok(
  /两行都必须是「前缀 \+ 逗号分隔的一行词」/.test(c),
  '必须有两行硬性排版要求',
)

// sd-inject.ps1：素体基底参数 + 出图参数表单（翻译模型已按用户要求整段移除，提示词在表单里直接填）
const injectPs1 = fs.readFileSync(new URL('./sd-inject.ps1', import.meta.url), 'utf8')
assert.ok(injectPs1.includes('$BasePrompt'), 'sd-inject.ps1 必须定义 $BasePrompt')
assert.ok(injectPs1.includes('$BaseNegative'), 'sd-inject.ps1 必须定义 $BaseNegative')
assert.ok(!injectPs1.includes('追加正向提示词'), '翻译弹框已移除：不得再出现「追加正向提示词」弹框')
assert.ok(!injectPs1.includes('追加负向提示词'), '翻译弹框已移除：不得再出现「追加负向提示词」弹框')
// 表单流程：正向/负向多行文本框预填基底，所有参数一次填完
assert.ok(injectPs1.includes('正向提示词：'), '表单必须有正向提示词文本框')
assert.ok(injectPs1.includes('负向提示词：'), '表单必须有负向提示词文本框')
assert.ok(/txtPos\.Text = \$Positive/.test(injectPs1), '正向文本框必须预填基底（-Positive 传入）')
assert.ok(/txtNeg\.Text = \$Negative/.test(injectPs1), '负向文本框必须预填基底（-Negative 传入）')
assert.ok(/Show-ParamForm -DefaultRounds \$paramFormRounds -HasBaseImage \$hasBaseImg -Positive \$formPositive -Negative \$formNegative/.test(injectPs1), '表单必须以素体基底预填提示词（已补末尾逗号）')
assert.ok(injectPs1.includes('确定出图'), '表单必须有「确定出图」按钮')
assert.ok(injectPs1.includes('取消'), '表单必须有「取消」出口')
// 翻译模型链路整段移除（用户要求）：不留 Start-QwenApi / 候选枚举 / 翻译弹框 / e-q 确认循环
for (const gone of ['Start-QwenApi', 'Test-QwenApi', 'Rank-QwenModels', 'Get-QwenCandidates', 'Strip-Cjk', 'QwenRetries', 'QwenDefaultModel', 'NoQwenStart', '输入 e 修改提示词，输入 q 退出', '生成最终提示词']) {
  assert.ok(!injectPs1.includes(gone), `翻译链路已移除：sd-inject.ps1 不得再出现 ${gone}`)
}
// 表单参数：迭代次数默认 3（质检不稳定时快速验证 + 多选）、画质最高 2160p（4K）
assert.ok(/\$paramFormRounds = 3/.test(injectPs1), '迭代次数默认必须为 3')
assert.ok(/'2160p（4K）' \{ \$short = 2160 \}/.test(injectPs1), '画质档必须支持 2160p（4K）')
assert.ok(/-gt 32\) \{ \$rounds = 32 \}/.test(injectPs1), '迭代次数上限必须放宽到 32')
// 脸部质检链路保留：VLM 探活 + 打分 + 素体迭代
assert.ok(/function Test-VlmApi/.test(injectPs1), '脸部质检 VLM 探活必须保留')
assert.ok(/function Test-FaceQuality/.test(injectPs1), '脸部质检打分必须保留')
assert.ok(/function Invoke-BaseIterate/.test(injectPs1), '素体自检迭代必须保留')
assert.ok(/OLLAMA_MODELS/.test(injectPs1), '枚举不到模型时必须点出 OLLAMA_MODELS 这个最常见根因')
assert.ok(!/`?\?`?\?/.test(injectPs1), 'sd-inject.ps1 不得使用 PS7 专有的 ?? 运算符（PS5.1 语法错）')
// 坑23 回归：PS5.1 把 CJK 字母也算变量名字符——「$var次」会被当成变量 $var次（未定义→空值），
// 屏幕上只剩「第1/」。所有包内 .ps1 都不允许出现「$变量 + 非 ASCII 字母」紧邻，必须写 ${变量}。
for (const scriptName of ['sd-inject.ps1', 'sd-direct.ps1', 'install-sd.ps1']) {
  const scriptText = fs.readFileSync(new URL(`./${scriptName}`, import.meta.url), 'utf8')
  const offenders = []
  // 只看代码行：整行注释里的示例（如本文件注释里的反例）不算违规
  const codeLines = scriptText.split(/\r?\n/).filter((line) => !/^\s*#/.test(line))
  for (const line of codeLines) {
    for (const m of line.matchAll(/\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7F])/g)) {
      if (/\p{L}/u.test(m[2])) offenders.push(`$${m[1]}${m[2]}`)
    }
  }
  assert.equal(offenders.length, 0, `${scriptName} 里变量名后紧邻中文必须写 \${变量}（坑23）：${offenders.join(', ')}`)
}
// 翻译链路已整段移除（用户要求）：相关的重试文案、原始回复诊断、system prompt、few-shot、坑25 断言一并退役
// 安全底噪 + 权重机制（反 NSFW 拦截）：删词不够，必须把类别词加权压进负向。
// 注意边界（用户红线）：加权安全底噪只属于插件正常出图路径（A 档）的 defaultNegative；
// C 档素体基底（INJECT_BASE_NEGATIVE 与 sd-inject.ps1 的 $BaseNegative 默认值）**只含画质底线**，
// 绝不夹带违禁/安全类标签——所以这里只断言 mod.DEFAULTS，并对 injectPs1 反向锁定。
const SAFETY_TOKENS = ['(nsfw:1.6)', '(nudity:1.5)', '(nude:1.5)', '(explicit sexual content:1.4)', '(sexual content:1.4)', '(suggestive:1.2)']
for (const token of SAFETY_TOKENS) {
  assert.ok(mod.DEFAULTS.defaultNegative.includes(token), `默认负向必须带加权安全底噪 ${token}`)
  assert.ok(!injectPs1.includes(token), `sd-inject.ps1 的 $BaseNegative 默认值不得夹带违禁/安全类标签（C 档素体基底只留画质底线）: ${token}`)
}
// 坑24：PS5.1 传字符串 body 会按 Latin-1 编码——中文到模型那边就是乱码，必须发 UTF-8 字节 + 修响应
//（翻译模型删了，但这些坑的防线现在服务脸部质检 VLM 调用，必须继续成立）
assert.ok(
  /\[System\.Text\.Encoding\]::UTF8\.GetBytes\(/.test(injectPs1),
  '请求 body 必须转成 UTF-8 字节再发（坑24：字符串 body 会被按 Latin-1 编码）',
)
assert.ok(/application\/json; charset=utf-8/.test(injectPs1), '请求头必须声明 charset=utf-8（坑24）')
assert.ok(/function Repair-Utf8Mojibake/.test(injectPs1), '必须有响应乱码修复函数（坑24）')
assert.ok(/Repair-Utf8Mojibake \(?彩票|Repair-Utf8Mojibake \(\[string\]\$resp|Repair-Utf8Mojibake \$raw|Repair-Utf8Mojibake \(\[string\]/.test(injectPs1), 'VLM 响应内容必须过一遍乱码修复（坑24）')
// sd-paint 技能：A 档已收窄为「完全不违规」；加权安全底噪只属于插件默认负向；末尾回执仍要求列全五类
assert.ok(!c.includes('A 档拦截时把剔除的违规标签'), 'A 档不得再有「剔除标签加权追加」流程（涉及违规一律 C 档）')
// C 档必须要求模型调 sd_inject 且传 run:true（自动拉起窗口），否则模型会手写命令、不弹窗（实测故障）
assert.ok(c.includes('run: true') || c.includes('run:true'), '技能正文必须要求 C 档调 sd_inject 传 run:true')
assert.ok(c.includes('禁止自己拼命令') && c.includes('禁止手写路径'), '技能正文必须禁止手写命令/路径')
assert.ok(c.includes('列全，别只列最露骨的两三个'), '末尾回执必须要求列全，而不是只列两三个')
assert.ok(/①.*②.*③.*④.*⑤/s.test(c), '末尾回执必须给出五类自查（裸露/行为/器官/道具场景/姿势氛围）')
assert.ok(
  c.includes('「建议替换词」给的是合规替代方向（如 clothed、fully clothed、sfw、portrait 等）'),
  '建议替换词行必须保持原样式（用户要求：这一行暂时不动）',
)
// 坑13 回归：sd-inject.ps1 同样必须 UTF-8 with BOM（PS5.1 无 BOM 按 GBK 读会语法错）
const injectRaw = fs.readFileSync(new URL('./sd-inject.ps1', import.meta.url))
assert.deepEqual(
  [...injectRaw.subarray(0, 3)],
  [0xef, 0xbb, 0xbf],
  'sd-inject.ps1 must be UTF-8 with BOM (坑13)',
)

// 出图自检循环 + 图生图画风一致（画质优化新增）
assert.ok(c.includes('出图自检'), 'self-check section missing')
assert.ok(c.includes('优化循环'), 'optimize loop missing')
assert.ok(c.includes('图生图画风一致'), 'img2img style-consistency section missing')
assert.ok(c.includes('read_image'), 'must instruct reading the image back for review')
assert.ok(c.includes('仅 A 档，最重要'), 'self-check section must be scoped to A 档（C 档无图可查）')
assert.ok(c.includes('denoising'), 'style-consistency must mention denoising guidance')

// 蒙版重绘（sd_inpaint）
assert.ok(c.includes('蒙版重绘'), 'inpaint section missing')
assert.ok(c.includes('maskBox'), 'maskBox fallback must be documented')
assert.ok(c.includes('接缝'), 'inpaint self-check must mention seams')

// 可移植性：文案里的占位符已按本机配置注入，源码级硬编码盘符不得漏进注册文案。
// 注意 C 档命令是**运行时注入的绝对路径**（用户要照抄执行），允许出现真实路径，
// 但源码里不得写死——这条由「源码不含 D:\ 盘符」单独断言覆盖。
assert.ok(!c.includes('%OUT%') && !c.includes('%SD%') && !c.includes('%REF%') && !c.includes('%DIRECT%'), 'doc tokens must be replaced')
const bridgeSrc = fs.readFileSync(new URL('./sd-bridge.js', import.meta.url), 'utf8')
assert.ok(!/['"`][^'"`]*D:\\DSWorkPlace/.test(bridgeSrc), 'sd-bridge.js 源码不得写死工作区盘符')
// 坑22 回归：C 档命令的路径**不能在 apply 时固化**（技能全局注册，apply 时只有
// process.cwd() = DSH 宿主进程目录 / profile 目录）。命令必须由 sd_inject 在调用时
// 按 sessionCwd(exec) 生成，并且显式带 -OutDir 工作区路径。
// 反面样本（实测踩过）：技能里写死 powershell ... -File "...\profiles\desktop\sd-inject.ps1"，
// 用户跑它时 sd-inject.ps1 的默认 OutDir = $PSScriptRoot\SD-Picture = profile\SD-Picture。
const skillCmdPath = /powershell -ExecutionPolicy Bypass -File "([^"]+)"/.exec(c)
assert.ok(skillCmdPath, '技能里应保留一段形态示例命令')
const examplePath = skillCmdPath[1]
assert.ok(
  examplePath.includes('<工作区>') || path.resolve(examplePath).startsWith(path.resolve(ws)),
  `技能里的示例命令不得固化真实机器路径（坑22），实际：${examplePath}`,
)
const inject = tools.get('sd_inject')
assert.ok(inject, 'sd_inject missing（C 档命令生成器）')
assert.equal(inject.output.schema.properties.generatesImage.type, 'boolean')
assert.ok(inject.description.includes('不生成任何图片'), 'sd_inject 必须声明不出图')

const inj = await inject.execute({ basePrompt: '1girl, solo, upper body, simple background' }, exec)
assert.equal(inj.mode, '本地注入')
assert.equal(inj.generatesImage, false, 'sd_inject 不得生图')
assert.ok(
  inj.command.startsWith(`powershell -ExecutionPolicy Bypass -File "${path.join(ws, 'sd-inject.ps1')}"`),
  `C 档命令必须引用会话工作区里的 sd-inject.ps1：${inj.command}`,
)
assert.ok(
  inj.command.includes(`-OutDir "${path.join(ws, 'SD-Picture')}"`),
  `C 档命令必须显式注入工作区 -OutDir：${inj.command}`,
)
assert.equal(inj.scriptPath, path.join(ws, 'sd-inject.ps1'))
assert.equal(inj.outDir, path.join(ws, 'SD-Picture'))
assert.ok(fs.existsSync(inj.scriptPath), `C 档命令引用的 sd-inject.ps1 必须真实存在：${inj.scriptPath}`)
assert.ok(inj.asMarkdown.startsWith('【本地注入】\n```powershell'), inj.asMarkdown.slice(0, 40))
assert.ok(inj.command.includes('-BasePrompt "1girl, solo, upper body, simple background"'), inj.command)
assert.ok(inj.command.includes('-BaseNegative "'), '默认素体负向必须带上')
assert.ok(
  !inj.command.includes('(nsfw:1.6)') && !inj.command.includes('nudity'),
  `sd_inject 生成的 -BaseNegative 只能含画质底线，不得夹带违禁/安全类标签（用户红线）：${inj.command}`,
)
assert.ok(inj.command.includes('-Width 512') && inj.command.includes('-Height 768'), inj.command)
assert.ok(inj.command.includes('-Name "inject"'), inj.command)
// 不传 basePrompt 时用素体兜底（默认 "1girl, solo"，见 sd-bridge.js 与 sd-inject.ps1 的 $BasePrompt 默认值）
const inj2 = await inject.execute({}, exec)
assert.ok(
  inj2.command.includes('-BasePrompt "1girl, solo"'),
  `留空必须用素体基底兜底：${inj2.command}`,
)
// 反面：命令里的脚本路径与产物目录都不能落在 process.cwd()（= 宿主 profile 目录）里
const hostCwd = path.resolve(process.cwd())
assert.ok(!inj.outDir.startsWith(hostCwd + path.sep) || path.resolve(ws).startsWith(hostCwd + path.sep),
  `产物目录不得落在宿主进程目录：${inj.outDir}`)

// sd-inject.ps1 的默认 OutDir 必须是 $PSScriptRoot（脚本所在目录），不能是 Get-Location
const injectSrc = fs.readFileSync(new URL('./sd-inject.ps1', import.meta.url), 'utf8')
assert.ok(
  /\$OutDir = Join-Path \$PSScriptRoot "SD-Picture"/.test(injectSrc),
  'sd-inject.ps1 默认 OutDir 必须是脚本所在目录下的 SD-Picture（不能是 Get-Location）',
)
assert.ok(
  !/Join-Path \(Get-Location\)/.test(injectSrc),
  'sd-inject.ps1 不得用 Get-Location 解析 OutDir（会随运行目录漂移）',
)

// 八个工具（含蒙版重绘 + 双版本对齐脚本 + C 档本地注入命令生成器）
assert.deepEqual(
  [...tools.keys()],
  ['sd_txt2img', 'sd_img2img', 'sd_inpaint', 'sd_script', 'sd_script_b', 'sd_inject', 'sd_models', 'sd_server'],
)

// sd_inpaint：蒙版来源二选一 + 蒙版参数 + 自检提醒
const ip = tools.get('sd_inpaint')
assert.ok(ip, 'sd_inpaint missing')
assert.ok(ip.description.includes('蒙版'), 'sd_inpaint description must mention mask')
assert.ok(ip.parameters.properties.mask && ip.parameters.properties.maskBox, 'mask 与 maskBox 必须都在参数表里')
assert.ok(ip.parameters.properties.denoisingStrength, 'denoisingStrength missing')
assert.ok(ip.output.schema.properties.selfCheck, 'sd_inpaint must return selfCheck')
assert.equal(ip.output.schema.properties.script.properties.mode.enum[0], '蒙版重绘')

// 生图工具描述带新分流协议（A 档仅限完全不违规 / 涉及违规一律 C 档）+ 无占位符残留
for (const name of ['sd_txt2img', 'sd_img2img']) {
  const d = tools.get(name).description
  assert.ok(d.includes('完全不违规') && d.includes('sd_inject'), `${name} must route any violation to C 档`)
  assert.ok(!d.includes('轻微违规'), `${name} 不得再保留「轻微违规出图」分支（用户红线）`)
  assert.ok(d.includes('sd-inject.ps1'), `${name} C 档 must point to sd-inject.ps1`)
  assert.ok(!d.includes('B 档'), `${name} description must not mention B 档`)
  assert.ok(d.includes('read_image'), `${name} must require image self-review`)
  assert.ok(!d.includes('D:\\DSWorkPlace') && !d.includes('%OUT%') && !d.includes('%SD%'), `${name} description must be portable (runtime-injected real paths are fine)`)
  assert.ok(tools.get(name).output.schema.properties.script)
  assert.ok(tools.get(name).output.schema.properties.selfCheck, `${name} must return selfCheck hint`)
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
assert.ok(st.description.includes('sd_script_b'), 'sd_script must point to sd_script_b for dual-version alignment')

// sd_script_b：双版本逐位置对齐（纯函数、不联网）——prompt 保序留正向，original 的差异词进负向
const sb = tools.get('sd_script_b')
assert.ok(sb, 'sd_script_b missing')
assert.ok(sb.description.includes('不生成任何图片'))
// originalPrompt 已改为可选（插件可自动提取兜底），prompt 仍必填
assert.deepEqual(sb.parameters.required, ['prompt'])
assert.equal(sb.output.schema.properties.generatesImage.type, 'boolean')
assert.ok(sb.output.schema.properties.positivePrompt && sb.output.schema.properties.negativePrompt, 'sd_script_b must return positive/negative for review')
// originalSource 必须存在，且三态可枚举（标记 originalPrompt 的来源，便于排查）
assert.ok(sb.output.schema.properties.originalSource, 'sd_script_b must return originalSource')
assert.deepEqual(sb.output.schema.properties.originalSource.enum, ['explicit', 'extracted', 'fallback'])

const al = await sb.execute(
  { originalPrompt: '1girl, red dress, beach, sunset', prompt: '1girl, red dress rewritten, beach, sunset', negativePrompt: 'lowres', seed: 42 },
  exec,
)
assert.equal(al.positivePrompt, '1girl, red dress rewritten, beach, sunset', '当前版本（prompt）必须保序留在正向')
assert.equal(al.negativePrompt, 'red dress, lowres', 'original 的差异词 + negativePrompt 必须进负向')
assert.ok(al.command.includes('-Prompt "1girl, red dress rewritten, beach, sunset"'), al.command)
assert.ok(al.command.includes('-Negative "red dress, lowres"'), al.command)
assert.equal(al.mode, '文生图')
assert.equal(al.generatesImage, false)
assert.equal(al.originalSource, 'explicit', '显式传入 originalPrompt → explicit')

// extractOriginalInput：从会话上下文提取最近一条用户消息原文（纯字段读取，失败静默返回 ''）
assert.equal(typeof mod.extractOriginalInput, 'function', 'extractOriginalInput must be exported')
assert.equal(
  mod.extractOriginalInput({
    agent: { session: { messages: [
      { role: 'user', content: '画一个银发少女' },
      { role: 'assistant', content: '好的' },
      { role: 'user', content: '改成樱花背景' },
    ] } },
  }),
  '改成樱花背景',
  'must pick the LAST user message',
)
assert.equal(
  mod.extractOriginalInput({ agent: { session: { header: { originalInput: '画一张赛博朋克街景' } } } }),
  '画一张赛博朋克街景',
  'must fall back to header.originalInput',
)
// 提取不到（无 messages、无 header.originalInput）→ 空串，调用方维持现状
assert.equal(mod.extractOriginalInput({ agent: { session: { header: { cwd: ws } } } }), '')
assert.equal(mod.extractOriginalInput(undefined), '')
assert.equal(mod.extractOriginalInput({}), '')
// messages 形状异常 → 静默失败，不抛异常
assert.equal(mod.extractOriginalInput({ agent: { session: { messages: [null, { role: 'user' }, 42] } } }), '')

// originalPrompt 留空 + 会话历史有 user 消息 → 自动提取作为对齐基准（extracted）
const execWithHistory = {
  agent: { session: { header: { cwd: ws }, messages: [
    { role: 'user', content: '1girl, white sheet, soft light, masterpiece' },
  ] } },
}
const ex = await sb.execute({ prompt: '1girl, blue silk sheet, soft light, masterpiece', negativePrompt: 'lowres' }, execWithHistory)
assert.equal(ex.originalSource, 'extracted', '留空 + 提取成功 → extracted')
assert.equal(ex.positivePrompt, '1girl, blue silk sheet, soft light, masterpiece')
assert.equal(ex.negativePrompt, 'white sheet, lowres', '提取到的原文的差异词进负向')
// 提取不到（无会话历史）→ fallback，退化为全部保留正向，不抛异常
const fb = await sb.execute({ prompt: '1girl, silver hair' }, exec)
assert.equal(fb.originalSource, 'fallback', '取不到原始输入 → fallback')
assert.equal(fb.positivePrompt, '1girl, silver hair')
assert.equal(fb.negativePrompt, '')

// 仅 original 非空的位置补进正向；仅 prompt 多出来的标签也保留正向
const al2 = await sb.execute({ originalPrompt: 'a, b, c', prompt: 'a, b' }, exec)
assert.equal(al2.positivePrompt, 'a, b, c')
assert.equal(al2.negativePrompt, '')
const al3 = await sb.execute({ originalPrompt: 'a, b', prompt: 'a, b, c' }, exec)
assert.equal(al3.positivePrompt, 'a, b, c')
assert.ok(!al3.command.includes('-Negative'), '负向为空时命令不写 -Negative')

// 只传 prompt（originalPrompt 留空）且会话无历史 → fallback：退化为全部保留正向
const al4 = await sb.execute({ prompt: '1girl, silver hair' }, exec)
assert.equal(al4.originalSource, 'fallback')
assert.equal(al4.positivePrompt, '1girl, silver hair')

// 图生图：参考图参数 + denoising 默认 0.7
const al5 = await sb.execute({ originalPrompt: '1girl, white sheet', prompt: '1girl, white sheet', initImage: 'ref/a.jpg', denoising: 0.65 }, exec)
assert.equal(al5.mode, '图生图')
assert.ok(al5.command.includes('-InitImage') && al5.command.includes('-Denoising 0.65'), al5.command)
assert.ok(al5.command.startsWith(`powershell -ExecutionPolicy Bypass -File "${path.join(ws, 'sd-direct.ps1')}"`), al5.command)
assert.ok(al5.command.includes(`-OutDir "${path.join(ws, 'SD-Picture')}"`), al5.command)
assert.ok(al5.asMarkdown.startsWith('【图生图】\n```powershell'))
const al6 = await sb.execute({ originalPrompt: 'x', prompt: 'x', initImage: 'ref/a.jpg' }, exec)
assert.ok(al6.command.includes('-Denoising 0.7'), `denoising 默认必须 0.7：${al6.command}`)

// 蒙版重绘：mask 优先 / maskBox 现场造蒙版 / 缺 initImage 直接报错（模式与参数跟 sd_inpaint 对齐）
assert.equal(sb.output.schema.properties.mode.enum[2], '蒙版重绘')
assert.ok(sb.parameters.properties.mask && sb.parameters.properties.maskBox, 'mask 与 maskBox 必须都在参数表里')
const demoImg = fileURLToPath(new URL('./docs/assets/demo-txt2img.jpg', import.meta.url))
const m1 = await sb.execute(
  { originalPrompt: '1girl, white sheet', prompt: '1girl, white sheet', initImage: demoImg, mask: demoImg },
  exec,
)
assert.equal(m1.mode, '蒙版重绘')
assert.ok(m1.command.includes('-Mask ') && m1.command.includes('-InitImage'), m1.command)
assert.ok(m1.command.includes('-MaskBlur 4') && m1.command.includes('-InpaintFill 0') && m1.command.includes('-InpaintPadding 32'), m1.command)
assert.ok(m1.asMarkdown.startsWith('【蒙版重绘】\n```powershell'))
assert.ok(m1.mask.includes(`${path.sep}ref${path.sep}`), `mask 应固化到工作区 ref\\：${m1.mask}`)
const m2 = await sb.execute(
  { originalPrompt: '1girl, white sheet', prompt: '1girl, blue sheet', initImage: demoImg, maskBox: '10,10,60,40' },
  exec,
)
assert.equal(m2.mode, '蒙版重绘')
assert.ok(/^mask_box_10_10_60_40_\d+x\d+\.png$/.test(path.basename(m2.mask)), `maskBox 生成的蒙版命名异常：${m2.mask}`)
assert.ok(fs.existsSync(m2.mask), 'maskBox 生成的蒙版必须落盘')
assert.ok(m2.command.includes(`-Mask "${m2.mask}"`), m2.command)
assert.equal(m2.positivePrompt, '1girl, blue sheet')
assert.equal(m2.negativePrompt, 'white sheet')
await assert.rejects(
  () => sb.execute({ originalPrompt: 'a', prompt: 'a', maskBox: '1,1,4,4' }, exec),
  /必须同时给 initImage/,
  'maskBox 缺 initImage 必须报错',
)

// 外部词表（-TermFile）：命令必须含 -TermFile，占位符原样保留（插件不替换）
const tf = await sb.execute(
  {
    originalPrompt: '1girl, dress, beach',
    prompt: '1girl, __TERM_A__, beach',
    width: 512,
    height: 768,
  },
  exec,
)
assert.ok(tf.command.includes('-TermFile'), '命令必须包含 -TermFile 参数')
assert.ok(tf.command.includes('__TERM_A__'), '占位符必须原样进命令，插件不得替换')
assert.ok(tf.termFile, '输出必须带 termFile 路径')
assert.ok(tf.termFile.startsWith(path.join(ws, 'SD-Picture')), `termFile 默认落在输出目录下：${tf.termFile}`)
assert.ok(/terms_\d+\.json$/.test(tf.termFile), `termFile 命名必须为 terms_<时间戳>.json：${tf.termFile}`)
assert.ok(tf.command.includes(`-TermFile "${tf.termFile}"`), tf.command)
assert.ok(tf.positivePrompt === '1girl, __TERM_A__, beach', '正向提示词必须保留占位符原样')
assert.ok(sb.output.schema.properties.termFile, 'sd_script_b 输出 schema 必须声明 termFile')
assert.ok(sb.parameters.properties.termFile, 'sd_script_b 参数表必须声明 termFile')
// 显式传入的 termFile 必须原样使用
const tf2 = await sb.execute({ prompt: 'a, __X__', termFile: 'D:\\wherever\\my-terms.json' }, exec)
assert.ok(tf2.command.includes('-TermFile "D:\\wherever\\my-terms.json"'), tf2.command)
assert.equal(tf2.termFile, 'D:\\wherever\\my-terms.json')

// sd-direct.ps1 必须定义 $TermFile 参数并做替换
const ps1 = fs.readFileSync(new URL('./sd-direct.ps1', import.meta.url), 'utf8')
assert.ok(ps1.includes('$TermFile'), 'sd-direct.ps1 必须定义 $TermFile 参数')
assert.ok(ps1.includes('.Replace($key, $val)'), 'sd-direct.ps1 必须按词表做字符串替换')
// 坑13 回归：.ps1 必须 UTF-8 with BOM（PS5.1 无 BOM 按 GBK 读会语法错），也不能是 UTF-16 LE
const ps1Raw = fs.readFileSync(new URL('./sd-direct.ps1', import.meta.url))
assert.deepEqual(
  [...ps1Raw.subarray(0, 3)],
  [0xef, 0xbb, 0xbf],
  'sd-direct.ps1 must be UTF-8 with BOM (坑13: PS5.1 reads BOM-less files as GBK → syntax errors)',
)
assert.ok(!ps1Raw.subarray(0, 2).equals(Buffer.from([0xff, 0xfe])), 'sd-direct.ps1 must not be UTF-16 LE')

// 工作区脚本必须真实存在（自愈同步）
assert.ok(fs.existsSync(path.join(ws, 'sd-direct.ps1')), 'sd-direct.ps1 must sync into the session workspace')
// C 档本地注入命令引用的 sd-inject.ps1 也必须同步进工作区
assert.ok(fs.existsSync(path.join(ws, 'sd-inject.ps1')), 'sd-inject.ps1 must sync into the session workspace')
const wsInject = fs.readFileSync(path.join(ws, 'sd-inject.ps1'))
assert.deepEqual([...wsInject.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'synced sd-inject.ps1 must be UTF-8 with BOM')
assert.ok(wsInject.toString('utf8').includes('正向提示词：'), 'synced sd-inject.ps1 must be the merged-form version（表单一次填完）')
// 同步进工作区的那一份也必须是 UTF-8 with BOM（否则用户复制命令去跑会踩坑13）
const wsRaw = fs.readFileSync(path.join(ws, 'sd-direct.ps1'))
assert.deepEqual([...wsRaw.subarray(0, 3)], [0xef, 0xbb, 0xbf], 'synced sd-direct.ps1 must be UTF-8 with BOM')

// DEFAULTS 可移植：无任何写死盘符
const d = mod.DEFAULTS
assert.equal(d.sdDir, '', 'sdDir default must be empty (auto-detect)')
assert.ok(!/^[A-Za-z]:/.test(d.outputDir) && !/^[A-Za-z]:/.test(d.refDir), 'output/ref defaults must be workspace-relative')

// ---------------------------------------------------------------------------
// C 档选项表（A 档出图后必贴）+ 用户自调画风 + 触发话术（0.9.7）
// ---------------------------------------------------------------------------
const quickText = mod.buildQuickOptions ? mod.buildQuickOptions() : ''
assert.ok(quickText.includes('C 档选项表'), 'quickOptions 文本必须自带「C 档选项表」标题')
assert.ok(quickText.includes('写实二次元·东亚脸'), 'C 档选项表必须列出用户自调画风「写实二次元·东亚脸」')
assert.ok(quickText.includes('彩色哥特'), 'C 档选项表必须列出用户自调画风「彩色哥特」')
assert.ok(quickText.includes('釉彩调色盘'), 'C 档选项表必须列出用户自调 LoRA 画风「釉彩调色盘」')
assert.ok(quickText.includes('★'), '用户自调画风必须带 ★ 标记')
assert.ok(quickText.includes('比例') && quickText.includes('画质') && quickText.includes('LoRA') && quickText.includes('模型'), 'C 档选项表必须覆盖 比例/画质/LoRA/模型')
assert.ok(quickText.includes('Denoising') && quickText.includes('迭代'), 'C 档选项表必须覆盖 Denoising 与迭代次数')
for (const name of ['sd_txt2img', 'sd_img2img', 'sd_inpaint']) {
  assert.ok(tools.get(name).output.schema.properties.quickOptions, `${name} 输出 schema 必须声明 quickOptions（A 档出图后贴到图片下方）`)
}

// 技能正文：C 档选项表章节 + 触发话术
assert.ok(c.includes('C 档选项表'), '技能正文必须有「C 档选项表」章节（A 档出图后必贴）')
assert.ok(c.includes('quickOptions'), '技能正文必须点名 quickOptions 字段')
assert.ok(/4 号画风/.test(c), '技能正文必须给出「按编号改参数重出图」的用法示例')
assert.ok(c.includes('打开SD插件'), '技能正文必须写明触发话术「打开SD插件」')
assert.ok(c.includes('用SD插件绘制'), '技能正文必须写明触发话术「用SD插件绘制」')
assert.ok(/★ 用户自调/.test(c) || /★用户自调/.test(c), '技能正文必须标出 ★ 用户自调画风')

// C 档参数表单（sd-inject.ps1）：用户自调画风进入画风下拉 + Get-StylePrompt 映射
assert.ok(injectPs1.includes('写实二次元·东亚脸'), 'sd-inject.ps1 画风下拉必须含用户自调画风「写实二次元·东亚脸」')
assert.ok(injectPs1.includes('釉彩调色盘'), 'sd-inject.ps1 画风下拉必须含用户自调画风「釉彩调色盘」')
assert.ok(injectPs1.includes('slender oval face') && injectPs1.includes('beautiful detailed almond eyes'), '「写实二次元·东亚脸」配方必须写进 Get-StylePrompt')
assert.ok(injectPs1.includes('釉彩·麻袋调色盘_v1.0'), '「釉彩调色盘」必须挂上本机 LoRA 全名')
assert.ok(/\$P\.Style -in @\('写实二次元', '写实二次元·东亚脸'\)/.test(injectPs1), '东亚脸画风必须复用「不切模型 + 半写实 LoRA」路径')

console.log('skill title:', skill.title)
console.log('sd_inject(C 档):', inj.command)
console.log('sd_script(i2i):', out.command)
console.log('sd_script_b(t2i):', al.command)
console.log('quickOptions head:', quickText.split('\n')[0])
console.log('SKILL SMOKE OK')
