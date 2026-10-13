/**
 * 周次掩码工具
 *
 * 掩码是长度 = 学期总周数的 '0'/'1' 字符串，第 1 个字符对应第 1 教学周。
 * 例：16 周全部上课 = '1111111111111111'；1-8 周 = '1111111100000000'。
 *
 * 为什么不用 bigint：ArkTS 对位运算支持有限，字符串掩码可读、可调试、可直接入库。
 */

/** 判断第 week 周（从 1 开始）是否命中掩码 */
export function maskHas(mask: string, week: number): boolean {
  if (week < 1 || week > mask.length) {
    return false;
  }
  return mask.charAt(week - 1) === '1';
}

/** 生成全 1 掩码 */
export function maskAll(totalWeeks: number): string {
  let s = '';
  for (let i = 0; i < totalWeeks; i++) {
    s += '1';
  }
  return s;
}

/** 生成全 0 掩码 */
export function maskNone(totalWeeks: number): string {
  let s = '';
  for (let i = 0; i < totalWeeks; i++) {
    s += '0';
  }
  return s;
}

/**
 * 解析人类写法，生成掩码。支持：
 *   '1-16'        连续区间
 *   '1-8,10-16'   逗号 / 顿号分隔
 *   '1-16单'      单周
 *   '2-16双'      双周
 *   '5'           单周次
 *   '1-15(单)'    带括号
 * 解析不出来时返回全 1（宁可全上，也不要静默丢课）。
 */
export function maskFromText(text: string, totalWeeks: number): string {
  const chars: string[] = [];
  for (let i = 0; i < totalWeeks; i++) {
    chars.push('0');
  }

  const normalized = text
    .replace(/[（(]/g, ' ')
    .replace(/[）)]/g, ' ')
    .replace(/[、，;；]/g, ',')
    .replace(/周/g, '')
    .trim();

  if (normalized.length === 0) {
    return maskAll(totalWeeks);
  }

  let matched = false;
  const parts: string[] = normalized.split(',');
  for (const rawPart of parts) {
    const part = rawPart.trim();
    if (part.length === 0) {
      continue;
    }
    let parity = 0; // 0 = 不限，1 = 单周，2 = 双周
    let body = part;
    if (body.includes('单')) {
      parity = 1;
      body = body.replace(/单/g, ' ');
    } else if (body.includes('双')) {
      parity = 2;
      body = body.replace(/双/g, ' ');
    }
    body = body.trim();

    let from = 0;
    let to = 0;
    const dash = body.indexOf('-');
    if (dash > 0) {
      from = parseInt(body.substring(0, dash).trim(), 10);
      to = parseInt(body.substring(dash + 1).trim(), 10);
    } else {
      from = parseInt(body, 10);
      to = from;
    }
    if (isNaN(from) || isNaN(to)) {
      continue;
    }
    matched = true;
    if (to < from) {
      const tmp = from;
      from = to;
      to = tmp;
    }
    for (let w = from; w <= to; w++) {
      if (w < 1 || w > totalWeeks) {
        continue;
      }
      if (parity === 1 && w % 2 === 0) {
        continue;
      }
      if (parity === 2 && w % 2 === 1) {
        continue;
      }
      chars[w - 1] = '1';
    }
  }

  if (!matched) {
    return maskAll(totalWeeks);
  }
  return chars.join('');
}

/** 掩码 → 人类可读文本，如 '1-8、10-16' */
export function maskToText(mask: string): string {
  const ranges: string[] = [];
  let start = -1;
  for (let i = 0; i <= mask.length; i++) {
    const on = i < mask.length && mask.charAt(i) === '1';
    if (on && start < 0) {
      start = i;
    } else if (!on && start >= 0) {
      const from = start + 1;
      const to = i;
      ranges.push(from === to ? `${from}` : `${from}-${to}`);
      start = -1;
    }
  }
  if (ranges.length === 0) {
    return '不上课';
  }
  return ranges.join('、');
}

/** 掩码里是否有任意一周命中 */
export function maskIsEmpty(mask: string): boolean {
  return mask.indexOf('1') < 0;
}
