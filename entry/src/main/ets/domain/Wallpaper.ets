/**
 * 自定义背景的显示几何（纯函数）。
 *
 * 用户 2026-10-15：「背景图片允许选择区域与调整位置」。
 *
 * 模型（和 CSS 的 `background-size: cover` + `background-position` 同一套）：
 *   1. 先把图按"填满取景框"缩放（两条边都不留空）；
 *   2. 再乘用户自己的缩放 `zoom`（≥1，所以永远不会露出底色）；
 *   3. 用户在**可动范围**里选一个位置：`fx` / `fy` ∈ [-1, 1]（0 = 居中，±1 = 顶到边）。
 *
 * 关键点：**位置存的是归一化的 -1..1，不是像素**。屏幕尺寸、横竖屏、换设备都不会让
 * "我调好的构图"跑偏 —— 存像素偏移的话，换个屏就错了。
 *
 * 这里不碰任何鸿蒙 API，所以能进离线断言（tools/domain-check）。
 */

/** 缩放下限 1 = 至少铺满；再小就会露出底下的渐变 */
export const WALLPAPER_MIN_ZOOM: number = 1;
/** 缩放上限：再大就只剩几个像素被拉成一片糊 */
export const WALLPAPER_MAX_ZOOM: number = 4;

export interface WallpaperGeometry {
  /** 图要画多大（vp，已含 zoom） */
  w: number;
  /** 图要画多高（vp，已含 zoom） */
  h: number;
  /** 相对"居中"的偏移量（vp，已按可动范围夹紧） */
  dx: number;
  /** 同上，纵向 */
  dy: number;
  /** 横/纵各自还能移动多少（vp）。0 = 这个方向没有余量（比如 1:1 的照片填竖屏） */
  maxDx: number;
  /** 同上，纵向 */
  maxDy: number;
}

function clampNum(v: number, lo: number, hi: number): number {
  if (Number.isNaN(v)) {
    return lo;
  }
  return v < lo ? lo : (v > hi ? hi : v);
}

/** 把任意输入收进合法区间：fx/fy → [-1,1]，zoom → [1,4] */
export function clampFocus(fx: number, fy: number, zoom: number): number[] {
  return [clampNum(fx, -1, 1), clampNum(fy, -1, 1),
    clampNum(zoom, WALLPAPER_MIN_ZOOM, WALLPAPER_MAX_ZOOM)];
}

/**
 * 'fx,fy,zoom' → [fx, fy, zoom]。
 * 空串 / 坏数据 / 老版本没有这个键 → 回落到"居中、不缩放"。
 */
export function parseWallpaperFocus(s: string): number[] {
  const parts: string[] = s.split(',');
  if (parts.length !== 3) {
    return [0, 0, 1];
  }
  const fx: number = Number.parseFloat(parts[0]);
  const fy: number = Number.parseFloat(parts[1]);
  const z: number = Number.parseFloat(parts[2]);
  if (Number.isNaN(fx) || Number.isNaN(fy) || Number.isNaN(z)) {
    return [0, 0, 1];
  }
  return clampFocus(fx, fy, z);
}

/** [fx, fy, zoom] → 'fx,fy,zoom'（存储格式，和 parseWallpaperFocus 互逆） */
export function formatWallpaperFocus(fx: number, fy: number, zoom: number): string {
  const v: number[] = clampFocus(fx, fy, zoom);
  return `${v[0]},${v[1]},${v[2]}`;
}

/**
 * 算出背景图该怎么画。
 *
 * `imgW/imgH` 是图片本身的像素尺寸（只用比值，绝对值无所谓）；
 * `boxW/boxH` 是取景框（= 屏幕）的 vp 尺寸。
 * 任何一边 <= 0（还没量到 / 图坏了）就返回全 0 —— 调用方据此不画图，别抛异常。
 */
export function wallpaperGeometry(imgW: number, imgH: number, boxW: number, boxH: number,
  zoom: number, fx: number, fy: number): WallpaperGeometry {
  const v: number[] = clampFocus(fx, fy, zoom);
  const z: number = v[2];
  let w: number = 0;
  let h: number = 0;
  if (imgW > 0 && imgH > 0 && boxW > 0 && boxH > 0) {
    // cover：取两个方向里更大的那个比例，保证两条边都不留空
    const s: number = Math.max(boxW / imgW, boxH / imgH);
    w = imgW * s * z;
    h = imgH * s * z;
  }
  const maxDx: number = w > boxW ? (w - boxW) / 2 : 0;
  const maxDy: number = h > boxH ? (h - boxH) / 2 : 0;
  return {
    w: w, h: h,
    dx: v[0] * maxDx,
    dy: v[1] * maxDy,
    maxDx: maxDx,
    maxDy: maxDy
  };
}
