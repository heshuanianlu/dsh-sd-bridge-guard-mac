#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
sd-auto-mask.py —— 按「这一张图的内容」自动生成重绘蒙版（不预设区域）。

思路（全部用本机已有文件，不联网下载）：
  ① YOLO-World（开放词表检测，文字提示）在参考图里找出目标物体 → 检测框；
  ② SAM（segment-anything，本机已有 vit_l / vit_h 权重）用这些框做 box-prompted 分割 → 精细轮廓蒙版；
  ③ 合并 + 形态学闭运算 + 膨胀 + 羽化 → 输出 8bit 灰度 PNG（白色 = 重绘区，黑色 = 保留区）。

目标映射：
  衣服 → dress/skirt/shirt/clothes/jacket/coat/uniform/kimono/...（取并集）
  脸   → face / head
  背景 → person 取反（人以外的都算背景）
  主体 → person

输出：stdout 打一行 JSON（ok / engine / boxes / coverage / mask / labels / notes），PowerShell 侧据此记录与回退。
失败时 ok=false 并把原因写进 notes，绝不抛栈影响主流程。
"""
import argparse
import glob
import json
import os
import sys

TARGET_LABELS = {
    # YOLO-World 实测：多词一起喂会互相稀释（命中率骤降），必须**单词逐个试**。
    # 下面按「野外命中率」排序，命中即停（最多取 2 个词的结果）。
    "衣服": ["dress", "jacket", "coat", "uniform", "kimono", "sweater", "hoodie",
             "shirt", "skirt", "pants", "shorts", "clothing", "clothes"],
    "脸": ["face", "head"],
    "背景": ["person"],
    "主体": ["person"],
}
INVERT_TARGETS = {"背景"}
# 找不到服饰词时：用「人物轮廓」兜底（按这张图里人的实际形状取躯干/腿部，而不是固定矩形）
SILHOUETTE_FALLBACK = {
    # 只在 --allow-silhouette 显式开启时才用「人物剪影 ∩ 躯干带」兜底。默认**禁止**：
    # 衣服蒙版一旦退化成身体剪影，重绘会把整个躯干重画（实测角色直接转身，等于换人）。
    "衣服": (0.14, 0.55, 1.00, 1.00),
    "脸": (0.00, 0.42, 0.30, 0.70),
}


def find_file(roots, patterns, min_mb=0.5):
    """在 roots 下按 patterns 找文件（限制递归深度，避免扫全盘）。"""
    import fnmatch
    hits = []
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        base_depth = root.rstrip("\\/").count(os.sep)
        for dirpath, dirnames, filenames in os.walk(root):
            if dirpath.count(os.sep) - base_depth > 6:
                dirnames[:] = []
                continue
            for fn in filenames:
                for pat in patterns:
                    if fnmatch.fnmatch(fn.lower(), pat.lower()):
                        p = os.path.join(dirpath, fn)
                        try:
                            if os.path.getsize(p) >= min_mb * 1024 * 1024:
                                hits.append(p)
                        except OSError:
                            pass
    # 大的优先（真权重优先于指针文件）
    hits.sort(key=lambda p: -os.path.getsize(p))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--target", required=True, help="衣服 / 脸 / 背景 / 主体")
    ap.add_argument("--out", required=True)
    ap.add_argument("--sd-dir", default="")
    ap.add_argument("--sam", default="", help="指定 SAM 权重路径（留空自动找）")
    ap.add_argument("--boxes", default="", help="可选：手工框 x1,y1,x2,y2[;x1,y1,x2,y2]（跳过 YOLO-World）")
    ap.add_argument("--box-threshold", type=float, default=0.03, help="检测阈值（YOLO-World 用低阈值才容易命中服饰词）")
    ap.add_argument("--max-side", type=int, default=2048, help="检测最长边（实测 1600 会漏检服饰，2048 才稳）")
    ap.add_argument("--dilate", type=int, default=8, help="蒙版外扩像素（接缝更自然）")
    ap.add_argument("--feather", type=int, default=4, help="羽化半径像素")
    ap.add_argument("--no-invert", action="store_true")
    ap.add_argument("--allow-silhouette", action="store_true", help="允许人物剪影兜底（默认关：会把身体一起重画）")
    ap.add_argument("--fill-sheer", action="store_true", help="衣服：大核闭运算补全薄纱/透视布料（有上限保护）")
    ap.add_argument("--sheer-scale", type=float, default=0.05, help="薄纱补全的闭运算半径系数（相对最长边）")
    ap.add_argument("--points", default="", help="SAM 点提示（图像像素坐标）：x,y;x,y …；给了就跳过检测直接点选")
    ap.add_argument("--max-words", type=int, default=5, help="逐词检测最多试几个词（命中即停）")
    args = ap.parse_args()

    result = {"ok": False, "engine": "", "boxes": 0, "coverage": 0.0,
              "mask": "", "labels": [], "notes": ""}
    notes = []

    try:
        import cv2
        import numpy as np
    except Exception as e:  # pragma: no cover
        result["notes"] = f"缺少 cv2/numpy：{e}"
        print(json.dumps(result, ensure_ascii=False))
        return 0

    if not os.path.isfile(args.image):
        result["notes"] = f"参考图不存在：{args.image}"
        print(json.dumps(result, ensure_ascii=False))
        return 0

    img_bgr = cv2.imread(args.image, cv2.IMREAD_COLOR)
    if img_bgr is None:
        result["notes"] = "参考图读不出来（格式不支持？）"
        print(json.dumps(result, ensure_ascii=False))
        return 0
    H, W = img_bgr.shape[:2]

    labels = TARGET_LABELS.get(args.target, ["person"])
    result["labels"] = labels

    # ---------- ① 检测框：手工框优先，其次 YOLO-World，最后退回 person 专用分割模型 ----------
    boxes = []
    pre_mask = None
    used_words = []
    if args.boxes.strip():
        for part in args.boxes.split(";"):
            vals = [float(v) for v in part.replace("，", ",").split(",") if v.strip()]
            if len(vals) == 4:
                boxes.append(vals)
        if boxes:
            result["engine"] = "手动框 + SAM"

    if not boxes:
        sd = args.sd_dir or ""
        roots = [p for p in [os.path.join(sd, ".cache", "huggingface") if sd else "",
                             os.path.join(sd, "models") if sd else "",
                             sd] if p]
        world_weights = find_file(roots, ["*world*.pt"], min_mb=1)
        if world_weights:
            try:
                from ultralytics import YOLO
                scale = min(1.0, args.max_side / max(H, W))
                im = cv2.resize(img_bgr, None, fx=scale, fy=scale) if scale < 1 else img_bgr
                # 单词逐个试：YOLO-World 多词混喂会稀释分数（实测 15 词 0 命中、单词命中）
                for word in labels[: args.max_words]:
                    if len(boxes) >= 2:
                        break
                    try:
                        m = YOLO(world_weights[0])     # 每个词新建实例：重复 set_classes 会触发 CUDA/CPU 设备错位
                        m.set_classes([word])
                        pred = m.predict(im, conf=args.box_threshold, verbose=False)[0]
                        got = 0
                        for b in pred.boxes:
                            x1, y1, x2, y2 = [float(v) / scale for v in b.xyxy[0].tolist()]
                            boxes.append([x1, y1, x2, y2])
                            got += 1
                        if got:
                            used_words.append(word)
                        del m
                    except Exception as e:
                        notes.append(f"词「{word}」检测异常：{type(e).__name__}")
                        continue
                if boxes:
                    result["engine"] = f"YOLO-World(词：{'/'.join(used_words)}) + SAM"
                    notes.append(f"命中 {len(boxes)} 框")
                else:
                    notes.append(f"YOLO-World 试过 {labels[:args.max_words]} 都没命中")
            except Exception as e:
                notes.append(f"YOLO-World 失败：{type(e).__name__}: {e}")
        else:
            notes.append("没找到 YOLO-World 权重（*.pt）")

    # 脸：YOLO-World 对 face 不稳定 → 用 adetailer 的专用人脸/YOLO 模型拿框
    if not boxes and args.target == "脸":
        sd = args.sd_dir or ""
        face_models = find_file([sd], ["face_yolov8*.pt", "*face*.pt"], min_mb=0.5)
        if face_models:
            try:
                from ultralytics import YOLO
                fm = YOLO(face_models[0])
                pred = fm.predict(img_bgr, conf=0.3, verbose=False)[0]
                for b in pred.boxes:
                    boxes.append([float(v) for v in b.xyxy[0].tolist()])
                if boxes:
                    notes.append(f"人脸专用模型命中 {len(boxes)} 框")
                del fm
            except Exception as e:
                notes.append(f"人脸模型失败：{type(e).__name__}")

    # 衣服/脸兜底：用「人物轮廓」定位（按这张图里人的实际形状，而不是固定矩形）
    if not boxes and args.target in SILHOUETTE_FALLBACK and args.allow_silhouette:
        sd = args.sd_dir or ""
        seg_models = find_file([sd], ["*person*yolov8*-seg.pt"], min_mb=1)
        person_mask = None
        if seg_models:
            try:
                from ultralytics import YOLO
                pm = YOLO(seg_models[0])
                pred = pm.predict(img_bgr, conf=0.25, verbose=False)[0]
                if pred.masks is not None and len(pred.masks.data):
                    person_mask = np.zeros((H, W), dtype=np.uint8)
                    for mm in pred.masks.data:
                        arr = (mm.cpu().numpy() > 0.5).astype(np.uint8) * 255
                        person_mask = np.maximum(person_mask, cv2.resize(arr, (W, H), interpolation=cv2.INTER_NEAREST))
                del pm
            except Exception as e:
                notes.append(f"人物轮廓兜底失败：{type(e).__name__}")
        if person_mask is not None and person_mask.max() > 0:
            # 直接用「人物轮廓 ∩ 躯干带」当蒙版：形状跟着这张图里人的实际剪影走（不固定矩形），
            # 也不再交给 SAM 二次分割——实测把轮廓框喂给 SAM 会只切出一小块（覆盖率 0.1%，等于没改）。
            ys, xs = np.where(person_mask > 127)
            top, bottom = int(ys.min()), int(ys.max())
            band = SILHOUETTE_FALLBACK[args.target]
            y1 = int(top + (bottom - top) * band[0])
            y2 = int(top + (bottom - top) * band[1])
            band_mask = np.zeros_like(person_mask)
            band_mask[max(0, y1):max(0, y2), :] = 255
            pre_mask = cv2.bitwise_and(person_mask, band_mask)
            notes.append(f"按人物轮廓兜底（取人物剪影 y {band[0]}-{band[1]} 区段）")
            result["engine"] = "person-seg 轮廓（跟随人物剪影）"

    # 衣服专用：YOLO-World 的 dress 框往往罩住整个人 → 直接 box-prompt 会把整个人重画（实测角色转身）。
    # 改成在该框的**下半部**取几个点做 SAM 点提示，然后**取最紧的那个掩膜**（衣服只是一块织物，不该是整个人）。
    garment_points = []
    if args.target == "衣服" and boxes:
        for bx in boxes:
            x1, y1, x2, y2 = bx
            cx = (x1 + x2) / 2.0
            bw = x2 - x1
            bh = y2 - y1
            for fy in (0.62, 0.78, 0.90):
                for fx in (0.5, 0.33, 0.67):
                    garment_points.append([[cx + (fx - 0.5) * bw, y1 + fy * bh]])
    if args.points.strip():
        pts = []
        for part in args.points.split(";"):
            vals = [float(v) for v in part.replace("，", ",").split(",") if v.strip()]
            if len(vals) == 2:
                pts.append(vals)
        if pts:
            garment_points = [pts]      # 手动点：只跑一次，不做「取最紧」筛选
    # ---------- ② 用 SAM 把框变成精细蒙版 ----------
    mask_full = np.zeros((H, W), dtype=np.uint8)
    sam_used = False
    sam_path = args.sam
    if not sam_path:
        sd = args.sd_dir or ""
        found = find_file([sd], ["sam_vit_h*.pth", "sam_vit_l*.pth", "sam_vit_b*.pth", "mobile_sam*.pt"], min_mb=50)
        sam_path = found[0] if found else ""
    if pre_mask is not None:
        mask_full = pre_mask
        sam_used = True   # 已由轮廓兜底给出蒙版，跳过 SAM
    elif sam_path and os.path.isfile(sam_path) and (boxes or garment_points):
        try:
            import torch
            from segment_anything import sam_model_registry, SamPredictor
            name = os.path.basename(sam_path).lower()
            if "vit_h" in name:
                kind = "vit_h"
            elif "vit_b" in name:
                kind = "vit_b"
            elif "vit_l" in name or "mobile" not in name:
                kind = "vit_l"
            else:
                kind = "vit_l"
            device = "cuda" if torch.cuda.is_available() else "cpu"
            sam = sam_model_registry[kind](checkpoint=sam_path).to(device)
            predictor = SamPredictor(sam)
            predictor.set_image(cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB))
            if garment_points:
                # 衣服：**把全部候选点当成一次正样本**喂给 SAM（多点比单点稳），在它给的 3 张候选里
                # 挑「最紧但仍是织物级」的那张：
                #   太紧（<3%）= 只切到布片，改了等于没改；
                #   太松（>32%）= 整个人，重绘会把身体/姿势一起重画（实测角色直接转身）。
                # 绝不把所有点的掩膜并起来。先试「只点」，再试「点+框」。
                best = None
                best_cov = 9.9
                best_tag = ""
                tries = [("只点", None)]
                if boxes:
                    tries.append(("点+框", boxes[0]))
                for tag, box in tries:
                    try:
                        kw = {"point_coords": np.array(garment_points[0]),
                              "point_labels": np.ones(len(garment_points[0]), dtype=int),
                              "multimask_output": True}
                        if box is not None:
                            kw["box"] = np.array(box)
                        m, _, _ = predictor.predict(**kw)
                    except Exception:
                        continue
                    for cand in m:
                        arr = (cand.astype(np.uint8)) * 255
                        cov = float((arr > 127).mean())
                        if 0.03 <= cov <= 0.32 and cov < best_cov:
                            best_cov = cov
                            best = arr
                            best_tag = tag
                if best is not None:
                    mask_full = best
                    notes.append(f"衣服：{best_tag} 挑出织物级掩膜（覆盖 {best_cov:.1%}，3%-32% 区间取最紧）")
                else:
                    notes.append("衣服：点提示没给出织物级掩膜（要么过小、要么罩住整个人）→ 请改用 box: 精确框或蒙版图")
            else:
                for bx in boxes:
                    x1, y1, x2, y2 = bx
                    m, _, _ = predictor.predict(box=np.array([x1, y1, x2, y2]), multimask_output=False)
                    mask_full = np.maximum(mask_full, (m[0] if m.ndim == 3 else m).astype(np.uint8) * 255)
            sam_used = True
            notes.append(f"SAM({kind}) 分割完成")
            del sam
            try:
                torch.cuda.empty_cache()
            except Exception:
                pass
        except Exception as e:
            notes.append(f"SAM 失败：{type(e).__name__}: {e}")

    # SAM 不可用时：退回 person 专用分割模型（只对「人」有效，用于背景/主体）
    if not sam_used:
        sd = args.sd_dir or ""
        seg_models = find_file([sd], ["*person*yolov8*-seg.pt", "*yolov8*-seg.pt"], min_mb=1)
        if seg_models and args.target in ("背景", "主体"):
            try:
                from ultralytics import YOLO
                m = YOLO(seg_models[0])
                pred = m.predict(img_bgr, conf=args.box_threshold, verbose=False)[0]
                if pred.masks is not None:
                    for mm in pred.masks.data:
                        arr = (mm.cpu().numpy() > 0.5).astype(np.uint8) * 255
                        arr = cv2.resize(arr, (W, H), interpolation=cv2.INTER_NEAREST)
                        mask_full = np.maximum(mask_full, arr)
                    sam_used = True
                    result["engine"] = result["engine"] or "person-seg(YOLOv8) 兜底"
                    notes.append("改用 person 专用分割模型")
            except Exception as e:
                notes.append(f"person 分割兜底失败：{type(e).__name__}: {e}")

    if mask_full.max() == 0:
        result["notes"] = "；".join(notes + ["没抠出任何区域（换词或用手工框/区域蒙版）"])
        print(json.dumps(result, ensure_ascii=False))
        return 0

    # ---------- ③ 后处理：闭运算补洞 → 膨胀 → 羽化 ----------
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    mask_full = cv2.morphologyEx(mask_full, cv2.MORPH_CLOSE, k)
    # 只留最大连通块（去掉蝴蝶/花点等误检碎块；碎块会让无关区域被重画）
    try:
        n_lab, labels, stats, _ = cv2.connectedComponentsWithStats((mask_full > 127).astype(np.uint8), connectivity=8)
        if n_lab > 2:
            areas = stats[1:, cv2.CC_STAT_AREA]
            keep = 1 + int(np.argmax(areas))
            mask_full = np.where(labels == keep, 255, 0).astype(np.uint8)
            notes.append(f"已只留最大连通块（原 {n_lab - 1} 块）")
    except Exception:
        pass
    if args.dilate > 0:
        k2 = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (args.dilate * 2 + 1, args.dilate * 2 + 1))
        mask_full = cv2.dilate(mask_full, k2)
    # 衣服可选：补全薄纱/透视布料（SAM 对半透明布料常判成非衣服）。用**大核闭运算**桥接细缝——
    # 不要用凸包：裙子是斜跨人体的轮廓，凸包会把 90% 画面都罩进去（实测直接废掉）。
    # 带双重上限保护：变大超过 2.2 倍、或超过画面 22%，就保持原蒙版不动。
    if args.fill_sheer and args.target == "衣服":
        try:
            r = max(10, int(args.sheer_scale * max(H, W)))
            kk = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (r * 2 + 1, r * 2 + 1))
            before = float((mask_full > 127).mean())
            closed = cv2.morphologyEx(mask_full, cv2.MORPH_CLOSE, kk)
            after = float((closed > 127).mean())
            if after <= max(0.22, before * 2.2):
                mask_full = closed
                notes.append(f"已补全薄纱区（{before:.1%} → {after:.1%}）")
            else:
                notes.append(f"薄纱补全会过大（{before:.1%} → {after:.1%}）→ 保持原蒙版")
        except Exception:
            pass

    if args.target in INVERT_TARGETS and not args.no_invert:
        mask_full = cv2.bitwise_not(mask_full)
        notes.append("背景目标：已取反（人以外的区域）")
    if args.feather > 0:
        mask_full = cv2.GaussianBlur(mask_full, (args.feather * 2 + 1, args.feather * 2 + 1), 0)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    cv2.imwrite(args.out, mask_full)
    # 蒙版叠加预览：把重绘区半透明染色盖回原图（验收蒙版准不准就看这张，不用靠生成结果猜）。
    try:
        overlay = img_bgr.copy()
        m3 = (mask_full > 127)
        tint = np.zeros_like(img_bgr)
        tint[:, :, 2] = 255          # BGR：红
        overlay[m3] = (0.45 * tint[m3] + 0.55 * overlay[m3]).astype(np.uint8)
        edge = cv2.morphologyEx((m3.astype(np.uint8)) * 255, cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8))
        overlay[edge > 0] = (255, 255, 255)
        ov_path = os.path.splitext(os.path.abspath(args.out))[0] + "_overlay.png"
        cv2.imwrite(ov_path, overlay)
        result["overlay"] = ov_path
    except Exception as e:
        notes.append(f"叠加预览生成失败：{type(e).__name__}")
    # 重绘区包围盒（便于判断「是不是又罩住整张图了」）
    try:
        ys, xs = np.where(mask_full > 127)
        if len(ys):
            result["bbox"] = [int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())]
            result["bbox_ratio"] = round(float((xs.max() - xs.min()) * (ys.max() - ys.min()) / (H * W)), 3)
    except Exception:
        pass
    result["ok"] = True
    result["mask"] = os.path.abspath(args.out)
    result["boxes"] = len(boxes)
    result["coverage"] = round(float((mask_full > 127).mean()), 4)
    result["notes"] = "；".join(notes)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # 兜底：绝不让辅助脚本把主流程带崩
        print(json.dumps({"ok": False, "engine": "", "boxes": 0, "coverage": 0.0,
                          "mask": "", "labels": [], "notes": f"内部错误：{type(exc).__name__}: {exc}"},
                         ensure_ascii=False))
        sys.exit(0)
