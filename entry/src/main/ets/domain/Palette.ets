import { Course, COURSE_COLORS } from '../model/Types';

/**
 * 学科调色盘（用户 2026-10-30：「学科调色盘（可以自定义调色）」）。
 *
 * 两层：
 *   1. **全局 10 色调色盘**：设置页里可以改其中任意一格，所有用这个下标的课一起变；
 *   2. **每门课单独覆盖**：课程编辑页里给这一门课调一个自定义颜色（`Course.colorHex`）。
 *
 * 纯逻辑都放这里，好处是 `tools/domain-check` 能验证：
 *   - 存坏的调色盘（少一格、多一格、写了个 `'#12'`、夹着空行）怎么兜底；
 *   - HSV ↔ HEX 的换算（取色器要用）。
 *
 * ⚠️ 调色器把**明度上限压在 0.68**：本 App 的课程块/胶囊一律压白字，
 *    明度再高（尤其黄色、青色）白字就看不清了。这是刻意的限制，不是没做完。
 */

export const PALETTE_SIZE: number = 10;

/** 默认调色盘 = `model/Types.COURSE_COLORS`（深色版 10 个） */
export const DEFAULT_PALETTE: string[] = COURSE_COLORS;

/** 取色器允许的明度上限（见文件头：白字可读性） */
export const PICKER_MAX_VALUE: number = 0.68;
/** 取色器允许的饱和度范围 */
export const PICKER_MIN_SAT: number = 0.30;
export const PICKER_MAX_SAT: number = 0.90;

function clamp01(v: number): number {
  if (!Number.isFinite(v)) {
    return 0;
  }
  return v < 0 ? 0 : (v > 1 ? 1 : v);
}

function clamp(v: number, lo: number, hi: number): number {
  if (!Number.isFinite(v)) {
    return lo;
  }
  return v < lo ? lo : (v > hi ? hi : v);
}

function hex2(n: number): string {
  const s: string = Math.round(clamp(n, 0, 255)).toString(16);
  return s.length === 1 ? `0${s}` : s;
}

/**
 * 规范化一个颜色串：接受 `#RRGGBB` / `RRGGBB` / 大小写混合；
 * 别的（空串、`#12`、`red`、`rgba(...)`）一律返回 `''`（调用方负责兜底）。
 */
export function normalizeHex(raw: string): string {
  const t: string = raw.trim();
  if (t.length === 7 && t.charAt(0) === '#') {
    const body: string = t.substring(1);
    return /^[0-9a-fA-F]{6}$/.test(body) ? `#${body.toUpperCase()}` : '';
  }
  if (t.length === 6) {
    return /^[0-9a-fA-F]{6}$/.test(t) ? `#${t.toUpperCase()}` : '';
  }
  return '';
}

/**
 * 调色盘字符串（`'\n'` 分隔）→ 长度恰好 `PALETTE_SIZE` 的颜色数组。
 *
 * 规则：
 *   - 能认出来的颜色按顺序填；
 *   - 认不出来的格子用**默认调色盘的同下标**补（不是整盘重置，用户改的 9 格别丢）；
 *   - 多出来的截掉。
 */
export function parsePalette(raw: string): string[] {
  const parts: string[] = raw.split('\n');
  const out: string[] = [];
  for (let i = 0; i < PALETTE_SIZE; i++) {
    const hex: string = i < parts.length ? normalizeHex(parts[i]) : '';
    out.push(hex.length > 0 ? hex : DEFAULT_PALETTE[i]);
  }
  return out;
}

/** 颜色数组 → kv 字符串（`'\n'` 分隔，固定 10 格） */
export function serializePalette(list: string[]): string {
  const out: string[] = [];
  for (let i = 0; i < PALETTE_SIZE; i++) {
    const hex: string = i < list.length ? normalizeHex(list[i]) : '';
    out.push(hex.length > 0 ? hex : DEFAULT_PALETTE[i]);
  }
  return out.join('\n');
}

/** 按 `colorIndex` 取全局色（越界用取模兜底） */
export function paletteColor(palette: string[], index: number): string {
  const p: string[] = palette.length === PALETTE_SIZE ? palette : DEFAULT_PALETTE;
  const i: number = Math.abs(Math.floor(index)) % PALETTE_SIZE;
  return p[i];
}

/**
 * 一门课最终显示的颜色：
 * 有自定义色（且格式合法）就用自己的，否则走全局调色盘的 `colorIndex`。
 */
export function courseColorOf(c: Course, palette: string[]): string {
  const own: string = c.colorHex === undefined ? '' : normalizeHex(c.colorHex);
  if (own.length > 0) {
    return own;
  }
  return paletteColor(palette, c.colorIndex);
}

// ---------------- HSV ↔ HEX（取色器用） ----------------

export interface Hsv {
  h: number;
  s: number;
  v: number;
}

/**
 * HEX → HSV。认不出来的颜色回落到一个中等蓝色（不是黑，免得用户一打开取色器就是黑的）。
 */
export function hexToHsv(hex: string): Hsv {
  const h6: string = normalizeHex(hex);
  if (h6.length === 0) {
    return { h: 215, s: 0.55, v: 0.55 };
  }
  const r: number = parseInt(h6.substring(1, 3), 16) / 255;
  const g: number = parseInt(h6.substring(3, 5), 16) / 255;
  const b: number = parseInt(h6.substring(5, 7), 16) / 255;
  const max: number = Math.max(r, Math.max(g, b));
  const min: number = Math.min(r, Math.min(g, b));
  const d: number = max - min;
  let h: number = 0;
  if (d > 0) {
    if (max === r) {
      h = 60 * (((g - b) / d) % 6);
    } else if (max === g) {
      h = 60 * ((b - r) / d + 2);
    } else {
      h = 60 * ((r - g) / d + 4);
    }
  }
  if (h < 0) {
    h += 360;
  }
  const s: number = max <= 0 ? 0 : d / max;
  return { h: h, s: s, v: max };
}

/**
 * HSV → `#RRGGBB`。
 * `v` 会被夹到 `[0, PICKER_MAX_VALUE]`、`s` 夹到 `[PICKER_MIN_SAT, PICKER_MAX_SAT]`，
 * 保证生成的颜色压在深色背景上还能读白字。
 */
export function hsvToHex(h: number, s: number, v: number): string {
  const hh: number = ((h % 360) + 360) % 360;
  const ss: number = clamp(s, PICKER_MIN_SAT, PICKER_MAX_SAT);
  const vv: number = clamp(v, 0, PICKER_MAX_VALUE);
  const c: number = vv * ss;
  const x: number = c * (1 - Math.abs(((hh / 60) % 2) - 1));
  const m: number = vv - c;
  let r: number = 0;
  let g: number = 0;
  let b: number = 0;
  if (hh < 60) {
    r = c;
    g = x;
  } else if (hh < 120) {
    r = x;
    g = c;
  } else if (hh < 180) {
    g = c;
    b = x;
  } else if (hh < 240) {
    g = x;
    b = c;
  } else if (hh < 300) {
    r = x;
    b = c;
  } else {
    r = c;
    b = x;
  }
  return `#${hex2((r + m) * 255)}${hex2((g + m) * 255)}${hex2((b + m) * 255)}`.toUpperCase();
}
