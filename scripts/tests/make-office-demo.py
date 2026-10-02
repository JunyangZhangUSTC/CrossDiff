#!/usr/bin/env python3
"""Small, deterministic OOXML documents for native workflow checks; no user files."""
import sys
from pathlib import Path
from xml.sax.saxutils import escape
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]).resolve()
if ROOT not in OUT.parents:
    raise SystemExit('Fixtures must remain inside the project.')
OUT.mkdir(parents=True, exist_ok=True)
REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/'
PKG = 'http://schemas.openxmlformats.org/package/2006/relationships'
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
S = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'

def relationships(items):
    return f'<Relationships xmlns="{PKG}">' + ''.join(f'<Relationship Id="{i}" Type="{REL}{t}" Target="{target}"/>' for i, t, target in items) + '</Relationships>'

def package(name, main, content_type, parts, overrides=()):
    types = f'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/{main}" ContentType="{content_type}"/>'
    types += ''.join(f'<Override PartName="/{path}" ContentType="{mime}"/>' for path, mime in overrides) + '</Types>'
    parts = {'[Content_Types].xml': types, '_rels/.rels': relationships([('main', 'officeDocument', main)]), **parts}
    with ZipFile(OUT / name, 'w', ZIP_DEFLATED) as archive:
        for path, data in parts.items():
            archive.writestr(path, '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + data)

def word(name, texts):
    body = ''.join('<w:p><w:r><w:t xml:space="preserve">' + escape(t) + '</w:t></w:r></w:p>' for t in texts)
    package(name, 'word/document.xml', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml', {
        'word/document.xml': f'<w:document xmlns:w="{W}"><w:body>{body}<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>'})

word('Research-before.docx', ['CrossDiff · 研究计划', '研究目标：让每一次变化都清晰可见。', '我们计划在十月完成原生界面的第一轮体验测试。', '文档比较支持正文、表格与幻灯片内容。', '参与者可以选择简体中文或 English，所有比较均在本机处理。', '下一步：整理反馈，继续改进。'])
word('Research-after.docx', ['CrossDiff · 研究计划', '研究目标：让每一次重要变化都清晰可见。', '我们计划在十一月完成原生界面的第二轮体验测试。', '参与者可以选择简体中文或 English，所有比较均在本机处理。', '新增：为表格增加跨行匹配，识别重排后的记录。', '下一步：整理反馈，继续改进。'])

def sheet_xml(rows):
    result = ''
    for n, row in enumerate(rows, 1):
        cells = ''
        for col, value in enumerate(row):
            address = chr(65 + col) + str(n)
            if isinstance(value, tuple):
                cells += f'<c r="{address}"><f>{escape(value[0])}</f><v>{value[1]}</v></c>'
            elif isinstance(value, int):
                cells += f'<c r="{address}"><v>{value}</v></c>'
            else:
                cells += f'<c r="{address}" t="inlineStr"><is><t>{escape(value)}</t></is></c>'
        result += f'<row r="{n}">{cells}</row>'
    return f'<worksheet xmlns="{S}"><sheetData>{result}</sheetData></worksheet>'

def workbook(name, rows):
    package(name, 'xl/workbook.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml', {
        'xl/workbook.xml': f'<workbook xmlns="{S}" xmlns:r="{REL[:-1]}"><sheets><sheet name="项目进度 · Milestones" sheetId="1" r:id="s1"/><sheet name="预算 · Budget" sheetId="2" r:id="s2"/></sheets></workbook>',
        'xl/_rels/workbook.xml.rels': relationships([('s1', 'worksheet', 'worksheets/sheet1.xml'), ('s2', 'worksheet', 'worksheets/sheet2.xml')]),
        'xl/worksheets/sheet1.xml': sheet_xml(rows),
        'xl/worksheets/sheet2.xml': sheet_xml([['编号', '项目', '费用'], ['B01', 'Design', 200], ['B02', 'Research', 300], ['TOTAL', '合计', ('SUM(C2:C3)', 500)]])},
        [('xl/worksheets/sheet1.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml'), ('xl/worksheets/sheet2.xml', 'application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml')])

workbook('Milestones-before.xlsx', [['编号 / ID', '任务 / Task', '进度 / Progress'], ['CD-101', '原生界面设计', 100], ['CD-102', 'Word 段落比较', 60], ['CD-103', 'Excel 跨行匹配', 45], ['CD-104', 'PPT 内容预览', 30], ['CD-105', '浅色与深色验收', 80], ['CD-106', '使用文档', 20]])
workbook('Milestones-after.xlsx', [['编号 / ID', '任务 / Task', '进度 / Progress'], ['CD-104', 'PPT 内容预览', 30], ['CD-101', '原生界面设计', 100], ['CD-102', 'Word 段落比较', 90], ['CD-105', '浅色与深色验收', 100], ['CD-103', 'Excel 跨行匹配', 85], ['CD-107', '插件安装验收', 50]])

def ppt(name, slides):
    parts = {'ppt/presentation.xml': f'<p:presentation xmlns:p="{P}" xmlns:r="{REL[:-1]}"><p:sldIdLst>' + ''.join(f'<p:sldId id="{256+i}" r:id="s{i}"/>' for i in range(len(slides))) + '</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>',
        'ppt/_rels/presentation.xml.rels': relationships([(f's{i}', 'slide', f'slides/slide{i+1}.xml') for i in range(len(slides))])}
    overrides = []
    for i, (title, body) in enumerate(slides, 1):
        shapes = ''
        for j, text in enumerate([title, body], 2):
            shapes += f'<p:sp><p:nvSpPr><p:cNvPr id="{j}" name="Text {j}"/><p:cNvSpPr/><p:nvPr><p:ph type="{"title" if j == 2 else "body"}"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="600000" y="{600000+(j-2)*1600000}"/><a:ext cx="10992000" cy="1600000"/></a:xfrm></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="{3200 if j == 2 else 2200}"/><a:t>{escape(text)}</a:t></a:r></a:p></p:txBody></p:sp>'
        path = f'ppt/slides/slide{i}.xml'
        parts[path] = f'<p:sld xmlns:p="{P}" xmlns:a="{A}"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>{shapes}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>'
        overrides.append((path, 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml'))
    package(name, 'ppt/presentation.xml', 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml', parts, overrides)

ppt('Review-before.pptx', [('CrossDiff · 产品回顾', '原生 macOS · 本地比较 · 开源免费'), ('办公比较', 'Word 段落、Excel 单元格、PowerPoint 幻灯片。'), ('下一步', '完成结构解析，开展界面验收。')])
ppt('Review-after.pptx', [('CrossDiff · 产品回顾', '原生 macOS · 本地隐私 · 无需注册 · 开源免费'), ('办公比较', 'Word 段落、Excel 跨行匹配、PowerPoint 内容对照。'), ('下一步', '完成浅深色验收，整理使用文档。')])
print('Created native Office fixtures:', OUT)
