#!/usr/bin/env python3
"""生成软件著作权 / 电子版权认证要交的两份材料（以及一份申请表信息）。

    python3 tools/make-copyright.py
    python3 tools/make-copyright.py --name "ClassOUT 课表待办计划软件" --version V1.5.1 \
        --owner "真实姓名" --date 2026-10-27

产物（默认落在 dist/copyright/，`/dist` 已被 .gitignore 挡住，不会入库）：

    ClassOUT-源程序.pdf      60 页（前 30 页 + 后 30 页），每页 50 行，页眉带软件名/版本/页码
    ClassOUT-用户手册.pdf    软件说明书（README 渲染 + 真机截图）
    申请表信息.txt           登记表要填的字段（著作权人/日期用 --owner / --date 传入）
    提交说明.md              交到哪里、注意什么

注意事项（写在代码里，改之前先读）：
1. **字体**：reportlab 不支持 Noto CJK 的 CFF 轮廓（会报 postscript outlines not supported），
   所以用系统的 AR PL UMing（TrueType，`uming.ttc`）。它没有粗体，标题靠字号区分。
2. **源程序**：不按文件切块、不插文件路径注释 —— 版权中心要的是连续代码。
   长行**按渲染宽度折行**，每页固定 50 个显示行（含折行后的续行）。
3. **说明书**：只做一个够用的 markdown 渲染（标题/段落/列表/表格/图片/代码块/引用），
   不支持嵌套列表与 HTML；README 里出现的 emoji 会被去掉（UMing 没有 emoji 字形）。
"""

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, 'pylibs'))

try:
    from reportlab.lib import colors                 # noqa: E402
except ImportError:                                  # pragma: no cover
    print('缺少 reportlab。先装到项目内（不会污染系统 Python）：\n'
          '  python3 -m pip install --target tools/pylibs reportlab',
          file=sys.stderr)
    raise SystemExit(1)
from reportlab.lib.pagesizes import A4              # noqa: E402
from reportlab.lib.styles import ParagraphStyle      # noqa: E402
from reportlab.lib.units import mm                   # noqa: E402
from reportlab.pdfbase import pdfmetrics             # noqa: E402
from reportlab.pdfbase.ttfonts import TTFont         # noqa: E402
from reportlab.pdfgen import canvas                  # noqa: E402
from reportlab.platypus import (BaseDocTemplate, Frame, Image, KeepTogether,  # noqa: E402
                                PageBreak, PageTemplate, Paragraph, Spacer, Table,
                                TableStyle)

FONT_PATH = '/usr/share/fonts/truetype/arphic/uming.ttc'
FONT_NAME = 'UMing'

# 说明书里**不收录**的 README 章节（按标题里出现的关键词匹配）：
#   · 「装到手机上」是"数据线 + hdc + 调试签名"的开发者步骤，上架后用户从应用市场装；
#   · 「给开发者」是编译/上架流程；
#   · 「目录」是 README 的锚点链接，渲染出来没用（手册自己按章节分页）。
# 说明书的"安装与运行"用封面下方那两行说明代替。
SKIP_HEADINGS = ('装到手机上', '给开发者', '目录')

EMOJI = re.compile(
    '[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F000-\U0001F02F'
    '\U0001F0A0-\U0001F0FF\U00002190-\U000021FF\U00002B00-\U00002BFF\uFE0F]')


def register_fonts():
    pdfmetrics.registerFont(TTFont(FONT_NAME, FONT_PATH, subfontIndex=0))


def clean_text(s: str) -> str:
    """去掉 emoji、加粗星号、行内反引号；行内链接只留文字。"""
    s = EMOJI.sub('', s)
    s = s.replace('**', '')
    s = re.sub(r'`([^`]*)`', r'\1', s)
    s = re.sub(r'!\[([^\]]*)\]\([^)]*\)', r'\1', s)
    s = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', lambda m: m.group(1), s)
    return s


def xml_escape(s: str) -> str:
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


# ---------------------------------------------------------------- 源程序

def source_files():
    import glob
    files = sorted(set(glob.glob(os.path.join(ROOT, 'entry/src/main/ets/**/*.ets'),
                                  recursive=True)))
    return [f for f in files if '/build/' not in f]


def read_source_lines():
    out = []
    for f in source_files():
        with open(f, encoding='utf-8') as fh:
            out.extend(fh.read().split('\n'))
    while out and out[-1].strip() == '':
        out.pop()
    return out


def wrap_line(line: str, size: float, max_w: float):
    """按渲染宽度折行（CJK 与 ASCII 都按真实字宽算）。空行原样保留。"""
    if line == '':
        return ['']
    lines, cur = [], ''
    for ch in line:
        cand = cur + ch
        if pdfmetrics.stringWidth(cand, FONT_NAME, size) > max_w and cur:
            lines.append(cur)
            cur = ch
        else:
            cur = cand
    lines.append(cur)
    return lines


def build_source_pdf(path: str, name: str, version: str):
    lines = read_source_lines()
    size, leading = 7.0, 11.8
    page_w, page_h = A4
    margin_x, top, bottom = 40, 54, 40
    max_w = page_w - 2 * margin_x
    per_page = 50

    # 折行后的显示行
    view = []
    for l in lines:
        view.extend(wrap_line(l, size, max_w))
    total_pages = (len(view) + per_page - 1) // per_page
    if total_pages <= 60:
        chosen = view
        out_pages = total_pages
        sampled = '全部（不足 60 页）'
    else:
        chosen = view[:30 * per_page] + view[-30 * per_page:]
        out_pages = 60
        sampled = '前 30 页 + 后 30 页'

    c = canvas.Canvas(path, pagesize=A4)
    c.setTitle(f'{name} {version} 源程序')
    c.setAuthor(name)
    for p in range(out_pages):
        chunk = chosen[p * per_page:(p + 1) * per_page]
        # 页眉
        c.setFont(FONT_NAME, 9)
        c.drawString(margin_x, page_h - 34, f'{name} {version}')
        c.drawRightString(page_w - margin_x, page_h - 34,
                          f'第 {p + 1} 页 / 共 {out_pages} 页')
        c.setLineWidth(0.4)
        c.line(margin_x, page_h - 40, page_w - margin_x, page_h - 40)

        # 正文
        c.setFont(FONT_NAME, size)
        y = page_h - top
        for line in chunk:
            c.drawString(margin_x, y, line)
            y -= leading

        # 页脚
        c.setFont(FONT_NAME, 8)
        c.drawCentredString(page_w / 2, 22, f'{name} {version} · 源程序（{sampled}）')
        c.showPage()
    c.save()
    return {'总行数': len(lines), '显示行数': len(view), '总页数': total_pages,
            '取样': sampled, '输出页数': out_pages}


# ---------------------------------------------------------------- 用户手册

def para(text, style, size=None):
    t = clean_text(text).strip()
    if not t:
        return None
    p = ParagraphStyle('p', parent=style, wordWrap='CJK')
    if size:
        p.fontSize = size
        p.leading = size * 1.6
    return Paragraph(xml_escape(t), p)


def build_manual_pdf(path: str, name: str, version: str, date: str):
    from reportlab.lib.enums import TA_CENTER

    base = ParagraphStyle('base', fontName=FONT_NAME, fontSize=10.5, leading=17,
                          wordWrap='CJK', spaceAfter=4)
    h2 = ParagraphStyle('h2', parent=base, fontSize=16, leading=22, spaceBefore=6,
                        spaceAfter=10, textColor=colors.HexColor('#1A2A4A'))
    h3 = ParagraphStyle('h3', parent=base, fontSize=12.5, leading=18, spaceBefore=6,
                        spaceAfter=4, textColor=colors.HexColor('#2A3A5A'))
    caption = ParagraphStyle('cap', parent=base, fontSize=8.5, leading=12, alignment=TA_CENTER,
                             textColor=colors.HexColor('#555555'))
    note = ParagraphStyle('note', parent=base, fontSize=9.5, leading=15,
                          textColor=colors.HexColor('#555555'), leftIndent=10)
    cell = ParagraphStyle('cell', parent=base, fontSize=8, leading=11, spaceAfter=0)
    mono = ParagraphStyle('mono', parent=base, fontSize=8, leading=11,
                          leftIndent=10, textColor=colors.HexColor('#333333'))

    story = []
    # 封面
    story.append(Spacer(1, 210))
    story.append(Paragraph(xml_escape(name) + '<br/>' + version, ParagraphStyle(
        'cover', parent=base, fontSize=26, leading=38, alignment=TA_CENTER)))
    story.append(Spacer(1, 26))
    story.append(Paragraph('用户手册（软件说明书）', ParagraphStyle(
        'cover2', parent=base, fontSize=18, leading=26, alignment=TA_CENTER)))
    story.append(Spacer(1, 160))
    story.append(Paragraph(f'版本：{version}<br/>编写日期：{date}', ParagraphStyle(
        'cover3', parent=base, fontSize=11, leading=18, alignment=TA_CENTER)))
    story.append(Paragraph('ClassOUT 完全离线运行：不联网、不上传、不需要账号。',
                           ParagraphStyle('cover4', parent=base, fontSize=10, leading=16,
                                          alignment=TA_CENTER,
                                          textColor=colors.HexColor('#555555'))))
    story.append(Spacer(1, 8))
    story.append(Paragraph('运行环境：HarmonyOS 5.1 及以上 · 安装方式：华为应用市场搜索「ClassOUT」',
                           ParagraphStyle('cover5', parent=base, fontSize=9.5, leading=15,
                                          alignment=TA_CENTER,
                                          textColor=colors.HexColor('#777777'))))
    story.append(PageBreak())

    with open(os.path.join(ROOT, 'README.md'), encoding='utf-8') as fh:
        lines = fh.read().split('\n')

    i, first_section = 0, True
    skipping = False
    while i < len(lines):
        raw = lines[i]
        s = raw.strip()

        # 章节级跳过：命中 SKIP_HEADINGS 就一路跳到下一个 "## " 为止
        if s.startswith('## '):
            title_probe = clean_text(s[3:]).strip()
            skipping = any(k in title_probe for k in SKIP_HEADINGS)
        if skipping:
            i += 1
            continue

        if s.startswith('```'):
            i += 1
            block = []
            while i < len(lines) and not lines[i].strip().startswith('```'):
                block.append(lines[i])
                i += 1
            i += 1
            for b in block:
                story.append(Paragraph(xml_escape(b).replace(' ', '&nbsp;'), mono))
            story.append(Spacer(1, 4))
            continue

        if s.startswith('# '):
            i += 1
            continue   # 一级标题已经在封面
        if s.startswith('## '):
            title = clean_text(s[3:]).strip()
            if not first_section:
                story.append(PageBreak())
            first_section = False
            story.append(Paragraph(xml_escape(title), h2))
            i += 1
            continue
        if s.startswith('### '):
            story.append(Paragraph(xml_escape(clean_text(s[4:]).strip()), h3))
            i += 1
            continue
        if s.startswith('---') or s.startswith('> 目录') or s == '---':
            i += 1
            continue

        # 图片
        m = re.match(r'!\[([^\]]*)\]\(([^)]+)\)', s)
        if m:
            img_path = os.path.join(ROOT, m.group(2))
            if os.path.exists(img_path):
                from PIL import Image as PILImage
                with PILImage.open(img_path) as im:
                    w, h = im.size
                max_w, max_h = 300, 560
                scale = min(max_w / w, max_h / h)
                story.append(KeepTogether([
                    Spacer(1, 6),
                    Image(img_path, width=w * scale, height=h * scale),
                    Paragraph(xml_escape(clean_text(m.group(1))), caption),
                    Spacer(1, 8),
                ]))
            i += 1
            continue

        # 表格
        if s.startswith('|') and i + 1 < len(lines) and lines[i + 1].strip().startswith('|'):
            rows = []
            while i < len(lines) and lines[i].strip().startswith('|'):
                row = [c.strip() for c in lines[i].strip().strip('|').split('|')]
                if not all(re.fullmatch(r':?-{2,}:?', c) for c in row):
                    rows.append(row)
                i += 1
            ncol = max(len(r) for r in rows) if rows else 0
            if ncol:
                data = []
                for r in rows:
                    r = r + [''] * (ncol - len(r))
                    data.append([Paragraph(xml_escape(clean_text(c)), cell) for c in r])
                width = A4[0] - 2 * 46
                col_w = [width / ncol] * ncol
                t = Table(data, colWidths=col_w, repeatRows=1, hAlign='LEFT')
                t.setStyle(TableStyle([
                    ('GRID', (0, 0), (-1, -1), 0.4, colors.HexColor('#BBBBBB')),
                    ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor('#EEF1F6')),
                    ('VALIGN', (0, 0), (-1, -1), 'TOP'),
                    ('LEFTPADDING', (0, 0), (-1, -1), 3),
                    ('RIGHTPADDING', (0, 0), (-1, -1), 3),
                    ('TOPPADDING', (0, 0), (-1, -1), 2),
                    ('BOTTOMPADDING', (0, 0), (-1, -1), 2),
                ]))
                story.append(Spacer(1, 3))
                story.append(t)
                story.append(Spacer(1, 6))
            continue

        if s.startswith('> '):
            story.append(Paragraph(xml_escape(clean_text(s[2:])), note))
            i += 1
            continue
        if s.startswith('- '):
            p = para('· ' + s[2:], base)
            if p:
                story.append(p)
            i += 1
            continue
        if re.match(r'^\d+\.\s', s):
            p = para(s, base)
            if p:
                story.append(p)
            i += 1
            continue
        if s == '':
            i += 1
            continue

        p = para(s, base)
        if p:
            story.append(p)
        i += 1

    def on_page(c, doc):
        c.setFont(FONT_NAME, 8)
        c.setFillColor(colors.HexColor('#888888'))
        c.drawCentredString(A4[0] / 2, 20, f'{name} {version} · 用户手册 · 第 {doc.page} 页')
        c.setFillColor(colors.black)

    doc = BaseDocTemplate(path, pagesize=A4, title=f'{name} {version} 用户手册',
                          author=name,
                          leftMargin=46, rightMargin=46, topMargin=56, bottomMargin=44)
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id='f')
    doc.addPageTemplates([PageTemplate(id='main', frames=[frame], onPage=on_page)])
    doc.build(story)
    return doc.page


# ---------------------------------------------------------------- 申请表信息

def write_form_info(path: str, name: str, version: str, date: str, owner: str, src_lines: int,
                    manual_pages: int):
    text = f"""ClassOUT 软件著作权登记 · 申请表信息
（照着填线上表单；若仍有【待填】的项，补上即可）

一、软件基本信息
  软件全称        {name}
  软件简称        ClassOUT
  版本号          {version}
  开发完成日期    {date}
  首次发表日期    【未发表】（应用尚未上架；若走「已发表」需填首次发表日期）
  权利取得方式    原始取得
  权利范围        全部权利
  开发方式        独立开发
  著作权人        {owner if owner else '【待填】'}  （个人真实姓名；若用公司主体就填公司全称）
  编程语言        ArkTS / TypeScript（HarmonyOS ArkUI）
  源程序量        约 {src_lines} 行（42 个 .ets 文件）
  开发硬件环境    x86_64 Linux 开发机 + HarmonyOS 手机（PSN-AL00 / API 26）
  运行硬件环境    HarmonyOS 手机（兼容 API 18 / HarmonyOS 5.1 及以上）
  开发软件环境    HarmonyOS SDK 5.1.0（API 18）、hvigor 命令行工具链
  运行软件环境    HarmonyOS 5.1 及以上

二、主要功能（可直接粘到「软件功能与技术特点」）
  ClassOUT 是一款完全离线的课表、待办与计划管理软件。主要功能：
  1. 课表：多时段、单双周、习题课；支持某一周的停课、换教室、调课、补课与撤销，
     不改动整学期规则；上课节次时间可逐节编辑。
  2. 待办：按课程与模板在下课后自动生成待办（标题变量、截止规则、预计时长）；
     支持自定义待办类型、备注、考试起止时间；到期待办与考试分开展示。
  3. 计划：把待办拖入时间轴（单日 / 三日视图），长按拖动改时间、双指张合改时长、
     「对半分」把一块拆成相邻两块、一键找空档并自动避开不可排时段。
  4. 提醒：把上课与截止提醒写进系统日历，由系统日历响铃；支持每日简报。
  5. 数据：本地 SQLite 存储；备份导出 / 恢复；完全离线，无网络权限、无账号、无统计。

三、材料清单（本轮生成）
  源程序.pdf      60 页（{src_lines} 行源码中取前 30 页 + 后 30 页，每页 50 行）
  用户手册.pdf    {manual_pages} 页（README 渲染 + 10 张真机截图）
  申请表信息.txt  本文件

四、注意
  · 源程序每页页眉已带「软件全称 + 版本号」和页码，符合登记要求；
  · 若「软件全称」要改（例如去掉「课表待办计划」），重新跑一次 make-copyright.py 即可；
  · 电子版权认证（易版权）一般只要源程序 + 说明书 + 实名，同样用这两份 PDF。
"""
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(text)


def write_readme(path: str, out_dir: str):
    text = f"""# 软著 / 电子版权材料（自动生成）

用 `python3 tools/make-copyright.py` 重新生成。**文件都在 `dist/copyright/`，已被 gitignore 挡住，不会入库。**

| 文件 | 用途 |
|---|---|
| `ClassOUT-源程序.pdf` | 中国版权保护中心「源程序」：60 页，每页 50 行，页眉带软件名/版本/页码 |
| `ClassOUT-用户手册.pdf` | 「文档 / 说明书」：README 渲染 + 真机截图 |
| `申请表信息.txt` | 在线表单要填的字段（两处【待填】：开发完成日期、著作权人） |
| `提交说明.md` | 本文件 |

## 提交时怎么用

1. 中国版权保护中心（软件著作权登记）：登记表里「源程序」和「文档」各上传对应的 PDF。
   文档不足 60 页时**全部提交**（本手册约 20 页，正常）。
2. 易版权（电子版权认证）：源程序 + 说明书 + 实名材料，同样用这两份。
3. 申请表信息里的**著作权人 / 开发完成日期**由 `--owner` / `--date` 传入；
   本仓库是公开的，**不要把真实姓名写进源码或文档**（只落在 gitignore 的 dist/ 里）。

## 重新生成

```bash
python3 tools/make-copyright.py
# 改软件全称/版本：
python3 tools/make-copyright.py --name "ClassOUT 课表待办计划软件" --version V1.5.1
```
"""
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--name', default='ClassOUT 课表待办计划软件')
    ap.add_argument('--version', default='V1.5.1')
    ap.add_argument('--date', default='2026-10-27')
    ap.add_argument('--owner', default='',
                    help='著作权人（真实姓名/公司全称）；只写进 dist 里的申请表信息，不入库')
    ap.add_argument('--outdir', default=os.path.join(ROOT, 'dist/copyright'))
    args = ap.parse_args()

    register_fonts()
    os.makedirs(args.outdir, exist_ok=True)

    src_pdf = os.path.join(args.outdir, 'ClassOUT-源程序.pdf')
    info = build_source_pdf(src_pdf, args.name, args.version)
    print(f'源程序：{src_pdf}  {info}')

    manual_pdf = os.path.join(args.outdir, 'ClassOUT-用户手册.pdf')
    pages = build_manual_pdf(manual_pdf, args.name, args.version, args.date)
    print(f'用户手册：{manual_pdf}  {pages} 页')

    write_form_info(os.path.join(args.outdir, '申请表信息.txt'), args.name, args.version,
                    args.date, args.owner, info['总行数'], pages)
    write_readme(os.path.join(args.outdir, '提交说明.md'), args.outdir)
    print(f'申请表信息 / 提交说明：{args.outdir}')


if __name__ == '__main__':
    main()
