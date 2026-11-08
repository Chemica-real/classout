/**
 * 虚拟课程课时命名。
 *
 * 用户 2026-11-01：课时名称可以自主编辑，也可以**通过百分号标签批量生成**。
 * 只提供三个对"第几讲"有意义的变量：
 *   %n = 课程全名，%c = 课程简称（没填简称就退回全名），%N = 第几讲
 * 未知变量原样保留，方便用户看到自己写错了什么。
 */

export const LESSON_TITLE_VARS: string[] = ['n', 'c', 'N'];

export const LESSON_TITLE_DEFAULT: string = '%c 第 %N 讲';

export function renderLessonTitle(template: string, fullName: string, shortName: string,
  seq: number): string {
  const short: string = shortName.length > 0 ? shortName : fullName;
  let out: string = '';
  for (let i = 0; i < template.length; i++) {
    const ch: string = template.charAt(i);
    if (ch !== '%' || i + 1 >= template.length) {
      out += ch;
      continue;
    }
    const code: string = template.charAt(i + 1);
    if (code === 'n') {
      out += fullName;
      i++;
    } else if (code === 'c') {
      out += short;
      i++;
    } else if (code === 'N') {
      out += `${seq}`;
      i++;
    } else if (code === '%') {
      out += '%';
      i++;
    } else {
      out += '%';
    }
  }
  const trimmed: string = out.trim();
  if (trimmed.length > 0) {
    return trimmed;
  }
  return `${short} 第 ${seq} 讲`;
}

/** 模板最多 40 字（和普通标题上限一致，避免课表格子被撑爆） */
export function validateLessonTitleTemplate(template: string): string {
  if (template.length > 40) {
    return '课时命名模板最多 40 个字';
  }
  return '';
}
