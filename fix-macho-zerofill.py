#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
修复 Mach-O「零填充段 offset 非零」问题（macOS 移植必踩坎，本机实测）。

## 症状
依赖明明装完了，A1111 一启动就崩在 imports：

    File ".../torchmetrics/__init__.py", line 31, in <module>  import scipy.signal
    ImportError: dlopen(.../scipy/sparse/linalg/_propack/_spropack.cpython-310-darwin.so, 0x0002):
      tried: '...(_spropack.cpython-310-darwin.so)'
      (section '__DATA/__thread_bss' has a zero-fill section type, but offset field is not zero)

## 根因
新版 macOS 的 dyld 开始严格校验：section 类型是零填充（S_ZEROFILL=0x02、
S_THREAD_LOCAL_ZEROFILL=0x12）时，`offset` 字段**必须为 0**。老链接器（ld64，
Xcode 14 那批 CI 镜像）会在这里留下「下一个可用偏移」的垃圾值，PyPI 上按老工具链
构建的 wheel 就带着它 —— scipy 1.15.3（Python 3.10 能装到的最后一版）正是如此。
dyld 拒绝加载 → pytorch_lightning / torchmetrics 全线 import 失败 → WebUI 起不来。

## 为什么可以直接改
零填充段的 `offset` 本来就没有语义：这段在内存里全零、文件里不占内容，
dyld 只用 `addr`/`size`。把它写成 0 既不改行为，也不改大小。

## 为什么改完还要签名
arm64 上所有可执行映像必须有有效签名，签名覆盖文件内容 —— 改一个字节就会被
判无效（进程直接 SIGKILL）。所以每个改过的文件重新 **ad-hoc 签名**（`codesign -f -s -`），
本机自签足够（不对接 App Store 分发）。

## 用法
    python3 fix-macho-zerofill.py <site-packages 目录>          # 只报告（dry-run）
    python3 fix-macho-zerofill.py <site-packages 目录> --apply  # 真改 + 重签名

退出码：0 = 没有问题（或已修完）；1 = dry-run 发现问题；2 = 用法错误。
"""
import os
import struct
import subprocess
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE          # 大端头（多架构容器）
LC_SEGMENT_64 = 0x19
# SECTION_TYPE 掩码 0xFF 里的两个「零填充」类型（**别记错**：0x02 是 S_CSTRING_LITERALS，
# 它是有真实文件内容的，动它 = 破坏二进制；S_ZEROFILL 是 0x01）
S_ZEROFILL = 0x01                # __bss
S_THREAD_LOCAL_ZEROFILL = 0x12   # __thread_bss

# struct section_64：sectname[16] segname[16] addr(8) size(8) offset(4) align(4)
#                    reloff(4) nreloc(4) flags(4) reserved1..3(4×3) = 80 字节
SECTION64_SIZE = 80
OFF_SECTNAME = 0
OFF_SEGNAME = 16
OFF_OFFSET = 48          # addr@32(8) size@40(8) → offset@48
OFF_FLAGS = 64

TEXT_SEG_HDR = 32        # mach_header_64
LC_HDR = 8               # cmd(4) + cmdsize(4)
SEGMENT64_NAME = 8       # segname[16] 在 cmd/cmdsize 之后
SEGMENT64_NSECT = 64     # nsects 字段偏移


def cstr(raw):
    return raw.split(b'\0', 1)[0].decode('utf-8', 'replace')


def arch_offsets(buf):
    """单个 thin 文件 → [(0)]；fat 容器 → 每个 slice 的起始偏移。"""
    if len(buf) < 4:
        return []
    magic = struct.unpack_from('<I', buf, 0)[0]
    if magic == MH_MAGIC_64:
        return [0]
    if magic == FAT_MAGIC:  # fat 头是**大端**
        nfat = struct.unpack_from('>I', buf, 4)[0]
        out = []
        for i in range(min(nfat, 16)):
            base = 8 + i * 20
            if base + 20 > len(buf):
                break
            _cputype, _cpusub, off, _size, _align = struct.unpack_from('>IIIII', buf, base)
            out.append(off)
        return out
    return []


def sections(buf, arch_off):
    """产出 (section_64 绝对偏移, sectname, segname, flags, offset)。"""
    if struct.unpack_from('<I', buf, arch_off)[0] != MH_MAGIC_64:
        return
    ncmds, = struct.unpack_from('<I', buf, arch_off + 16)
    p = arch_off + TEXT_SEG_HDR
    for _ in range(ncmds):
        if p + LC_HDR > len(buf):
            return
        cmd, cmdsize = struct.unpack_from('<II', buf, p)
        if cmdsize == 0:
            return
        if cmd == LC_SEGMENT_64:
            segname = cstr(struct.unpack_from('16s', buf, p + SEGMENT64_NAME)[0])
            nsect, = struct.unpack_from('<I', buf, p + SEGMENT64_NSECT)
            for j in range(nsect):
                so = p + 72 + j * SECTION64_SIZE
                if so + SECTION64_SIZE > len(buf):
                    break
                yield (so,
                       cstr(struct.unpack_from('16s', buf, so + OFF_SECTNAME)[0]),
                       segname,
                       struct.unpack_from('<I', buf, so + OFF_FLAGS)[0],
                       struct.unpack_from('<I', buf, so + OFF_OFFSET)[0])
        p += cmdsize


def is_macho(path):
    try:
        with open(path, 'rb') as f:
            head = f.read(4)
    except OSError:
        return False
    return len(head) == 4 and struct.unpack('<I', head)[0] in (MH_MAGIC_64, FAT_MAGIC)


def patch_file(path, apply):
    """返回该文件里需要修的段列表 [(sectname, segname, offset)]；apply=True 时写回并重签名。"""
    with open(path, 'rb') as f:
        buf = bytearray(f.read())
    changed = []
    for arch_off in arch_offsets(buf):
        for so, sectname, segname, flags, offset in sections(buf, arch_off):
            if (flags & 0xFF) in (S_ZEROFILL, S_THREAD_LOCAL_ZEROFILL) and offset != 0:
                changed.append((sectname, segname, offset))
                if apply:
                    struct.pack_into('<I', buf, so + OFF_OFFSET, 0)
    if changed and apply:
        tmp = path + '.dsh-zerofill.tmp'
        with open(tmp, 'wb') as f:
            f.write(buf)
        os.replace(tmp, path)
        os.chmod(path, 0o755)
        subprocess.run(['codesign', '--force', '--sign', '-', path],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return changed


def macho_files(root):
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if fn.endswith(('.so', '.dylib', '.bundle')):
                p = os.path.join(dirpath, fn)
                if is_macho(p):
                    yield p


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    apply = '--apply' in sys.argv
    if len(args) != 1 or not os.path.isdir(args[0]):
        print(__doc__)
        return 2
    root = args[0]
    n_files = n_secs = 0
    for path in macho_files(root):
        try:
            changed = patch_file(path, apply)
        except Exception as e:
            print('跳过（读取失败）%s：%s' % (path, e))
            continue
        for sectname, segname, offset in changed:
            print('  %s：%s,%s offset=%d%s' % (path, segname, sectname, offset,
                  ' → 0' if apply else ''))
        if changed:
            n_files += 1
            n_secs += len(changed)
    if n_secs == 0:
        print('干净：没有零填充段的 offset 非零（这台机器的 dyld 校验不会拦你）')
    elif apply:
        print('已修复：%d 个 Mach-O 文件里的 %d 个零填充段 offset 归零，并重新 ad-hoc 签名' % (n_files, n_secs))
    else:
        print('待修复：%d 个 Mach-O 文件里有 %d 个零填充段的 offset 非零（dry-run，加 --apply 才真改）' % (n_files, n_secs))
    return 0 if (apply or n_secs == 0) else 1


if __name__ == '__main__':
    sys.exit(main())
