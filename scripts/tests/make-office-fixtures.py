#!/usr/bin/env python3
"""Small, deterministic OOXML fixtures; generated only inside the project."""
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]).resolve()
if not OUT.is_relative_to(ROOT):
    raise SystemExit("Fixture output must stay inside the project")
OUT.mkdir(parents=True, exist_ok=True)
R = 'http://schemas.openxmlformats.org/package/2006/relationships'
O = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
S = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
C = 'http://schemas.openxmlformats.org/package/2006/content-types'

def rels(items):
    return '<Relationships xmlns="'+R+'">'+''.join('<Relationship Id="'+i+'" Type="'+O+'/'+t+'" Target="'+p+'"/>' for i,t,p in items)+'</Relationships>'

def package(name, kind, main, parts):
    main_type = {'word':'wordprocessingml.document', 'sheet':'spreadsheetml.sheet', 'slides':'presentationml.presentation'}[kind]
    base = {'[Content_Types].xml': '<Types xmlns="'+C+'"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/'+main+'" ContentType="application/vnd.openxmlformats-officedocument.'+main_type+'.main+xml"/></Types>', '_rels/.rels':rels([('root','officeDocument',main)])}
    base.update(parts)
    with zipfile.ZipFile(OUT/name, 'w', zipfile.ZIP_DEFLATED) as z:
        for path, data in base.items():
            z.writestr(path, data)

word = '<w:document xmlns:w="'+W+'"><w:body><w:p><w:r><w:t>中文👩🏽‍💻</w:t><w:tab/><w:t>A</w:t><w:br/><w:t>B</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell one</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>二</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:del><w:r><w:delText>gone</w:delText></w:r></w:del><w:ins><w:r><w:t>kept</w:t></w:r></w:ins></w:p></w:body></w:document>'
package('word.docx','word','word/document.xml', {'word/document.xml':word})
workbook = '<workbook xmlns="'+S+'" xmlns:r="'+O+'"><workbookPr date1904="1"/><sheets><sheet name="Later" sheetId="2" r:id="b"/><sheet name="First" sheetId="1" r:id="a"/></sheets></workbook>'
sheet = '<worksheet xmlns="'+S+'"><sheetData><row r="2"><c r="A2" t="s"><v>0</v></c><c r="D2" t="inlineStr"><is><r><t>中</t></r><r><t>文</t></r></is></c><c r="F2"><f>SUM(B2:C2)</f><v>10</v></c><c r="G2"><f t="shared" si="3" ref="G2:G3">A2*2</f><v>2</v></c><c r="H2" t="b"><v>0</v></c><c r="I2" s="0"><v>45000</v></c></row><row r="3"><c r="G3"><f t="shared" si="3"/><v>4</v></c><c r="H3"><f>NA()</f></c></row></sheetData><mergeCells count="1"><mergeCell ref="A2:B2"/></mergeCells></worksheet>'
empty = '<worksheet xmlns="'+S+'"><sheetData/></worksheet>'
shared = '<sst xmlns="'+S+'"><si><r><t>Studio </t></r><r><t>One</t></r><rPh><t>not visible</t></rPh></si></sst>'
styles = '<styleSheet xmlns="'+S+'"><cellXfs count="1"><xf numFmtId="14"/></cellXfs></styleSheet>'
sheet_parts = {'xl/workbook.xml':workbook, 'xl/_rels/workbook.xml.rels':rels([('a','worksheet','worksheets/sheet1.xml'),('b','worksheet','worksheets/sheet2.xml'),('strings','sharedStrings','sharedStrings.xml'),('styles','styles','styles.xml')]), 'xl/worksheets/sheet1.xml':empty, 'xl/worksheets/sheet2.xml':sheet, 'xl/sharedStrings.xml':shared, 'xl/styles.xml':styles}
package('sheet.xlsx','sheet','xl/workbook.xml',sheet_parts)
def slide(text):
    return '<p:sld xmlns:p="'+P+'" xmlns:a="'+A+'"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>'+text+'</a:t></a:r><a:br/><a:r><a:t>第二行</a:t></a:r></a:p></p:txBody></p:sp><p:graphicFrame><a:graphic><a:graphicData><a:tbl><a:tr><a:tc><a:txBody><a:p><a:r><a:t>Quarter</a:t></a:r></a:p></a:txBody></a:tc><a:tc><a:txBody><a:p><a:r><a:t>42</a:t></a:r></a:p></a:txBody></a:tc></a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame></p:spTree></p:cSld></p:sld>'
presentation = '<p:presentation xmlns:p="'+P+'" xmlns:r="'+O+'"><p:sldIdLst><p:sldId id="257" r:id="two"/><p:sldId id="256" r:id="one"/></p:sldIdLst></p:presentation>'
notes = '<p:notes xmlns:p="'+P+'" xmlns:a="'+A+'"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Speaker note</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>'
slides_parts = {'ppt/presentation.xml':presentation, 'ppt/_rels/presentation.xml.rels':rels([('one','slide','slides/slide1.xml'),('two','slide','slides/slide2.xml')]), 'ppt/slides/slide1.xml':slide('Opening'), 'ppt/slides/slide2.xml':slide('Results'), 'ppt/slides/_rels/slide2.xml.rels':rels([('notes','notesSlide','../notesSlides/notesSlide1.xml')]), 'ppt/notesSlides/notesSlide1.xml':notes}
package('slides.pptx','slides','ppt/presentation.xml',slides_parts)
# Security and malformed-data samples: every payload is inert test data.
for suffix, encoding in [('utf8','utf-8'),('utf16','utf-16'),('utf32','utf-32')]:
    malicious = '<?xml version="1.0"?><!DOCTYPE w:document [<!ENTITY local SYSTEM "file:///nonexistent-crossdiff-fixture">]>'+word.replace('中文👩🏽‍💻','&local;')
    package('doctype-'+suffix+'.docx','word','word/document.xml',{'word/document.xml':malicious.encode(encoding)})
package('deep.docx','word','word/document.xml',{'word/document.xml':'<w:document xmlns:w="'+W+'"><w:body>'+'<w:sdt>'*65+'<w:p/>'+'</w:sdt>'*65+'</w:body></w:document>'})
package('broken-rel.docx','word','word/document.xml',{'word/document.xml':word,'_rels/.rels':rels([('root','officeDocument','../../outside.xml')])})
package('encoded-rel.docx','word','word/document.xml',{'word/document.xml':word,'_rels/.rels':rels([('root','officeDocument','%2e%2e/%2e%2e/outside.xml')])})
package('missing-rel.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/_rels/workbook.xml.rels':rels([('a','worksheet','worksheets/sheet1.xml'),('b','worksheet','worksheets/missing.xml')])})
package('namespace-spoof.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/workbook.xml':workbook.replace('xmlns:r="'+O+'"','xmlns:r="urn:not-office"')})
package('duplicate-row.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('<row r="3">','<row r="2">')})
package('duplicate-cell.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('<c r="D2"','<c r="A2"')})
package('missing-formula-master.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('si="3"/>','si="7"/>')})
package('invalid-shared-string.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('t="s"><v>0</v>','t="s"><v>999</v>')})
package('wrong-coordinate.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('r="D2"','r="D8"')})
package('wrong-type.docx','sheet','xl/workbook.xml',sheet_parts)
package('oversized-xml.docx','word','word/document.xml',{'word/document.xml':' '* (16*1024*1024+1)})
package('truncated-xml.docx','word','word/document.xml',{'word/document.xml':word[:-20]})
package('unsafe-zip.docx','word','word/document.xml',{'word/document.xml':word,'../outside.xml':'no extraction'})
package('empty.xlsx','sheet','xl/workbook.xml',{'xl/workbook.xml':'<workbook xmlns="'+S+'"><sheets/></workbook>'})
package('external-link.docx','word','word/document.xml',{'word/document.xml':word,'word/_rels/document.xml.rels':'<Relationships xmlns="'+R+'"><Relationship Id="link" Type="'+O+'/hyperlink" TargetMode="External" Target="https://example.invalid/never-request"/></Relationships>'})
package('utf16.docx','word','word/document.xml',{'word/document.xml':('<?xml version="1.0" encoding="UTF-16"?>'+word).encode('utf-16')})
package('strict.docx','word','word/document.xml',{'word/document.xml':word.replace(W,'http://purl.oclc.org/ooxml/wordprocessingml/main')})
(OUT/'legacy.doc').write_bytes(b'Legacy test placeholder')
with (OUT/'oversized.docx').open('wb') as f:
    f.truncate(128*1024*1024+1)
# CRC mismatch in a stored (uncompressed) selected part.
with zipfile.ZipFile(OUT/'crc.docx','w',zipfile.ZIP_STORED) as z:
    z.writestr('word/document.xml',b'content')
raw=(OUT/'crc.docx').read_bytes(); raw=raw.replace(b'content',b'Content',1); (OUT/'crc.docx').write_bytes(raw)
# Duplicate normalized names are ambiguous even if raw paths differ.
with zipfile.ZipFile(OUT/'duplicate-zip.docx','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('word/document.xml',word)
    z.writestr('word/./document.xml',word)
link=OUT/'link.docx'
if link.is_symlink(): link.unlink()
link.symlink_to('word.docx')
# Deleted table-cell blocks are not part of the current visible content.
revision_cell='<w:document xmlns:w="'+W+'"><w:body><w:tbl><w:tr><w:tc><w:del><w:p><w:r><w:t>deleted cell paragraph</w:t></w:r></w:p></w:del><w:p><w:r><w:t>kept cell paragraph</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>'
package('revision-cell.docx','word','word/document.xml',{'word/document.xml':revision_cell})
package('empty-formula-cache.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('<f>NA()</f></c>','<f>NA()</f><v/></c>')})
package('out-of-order.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':'<worksheet xmlns="'+S+'"><sheetData><row r="8"><c r="D8"><v>4</v></c><c r="A8"><v>1</v></c></row><row r="3"><c r="C3"><v>3</v></c></row></sheetData></worksheet>'})
package('limit-rows.docx','word','word/document.xml',{'word/document.xml':'<w:document xmlns:w="'+W+'"><w:body>'+'<w:p/>'*10001+'</w:body></w:document>'})
package('limit-cell.docx','word','word/document.xml',{'word/document.xml':'<w:document xmlns:w="'+W+'"><w:body><w:p><w:r><w:t>'+'a'*131073+'</w:t></w:r></w:p></w:body></w:document>'})
package('zero-coordinate.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('r="D2"','r="A0"')})
package('limit-column.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('r="D2"','r="XFE2"')})
# Unknown members contribute to expanded-byte limits, not just selected XML.
with zipfile.ZipFile(OUT/'limit-expanded.docx','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('a.bin',b'')
    z.writestr('b.bin',b'')
import struct
raw=bytearray((OUT/'limit-expanded.docx').read_bytes())
for signature, offset in [(b'PK\x01\x02',24),(b'PK\x03\x04',22)]:
    start=0
    while (at:=raw.find(signature,start))>=0:
        struct.pack_into('<I',raw,at+offset,256*1024*1024)
        start=at+4
(OUT/'limit-expanded.docx').write_bytes(raw)
header = '<w:hdr xmlns:w="'+W+'"><w:p><w:r><w:t>Project header</w:t></w:r></w:p></w:hdr>'
footnotes = '<w:footnotes xmlns:w="'+W+'"><w:footnote w:id="-1" w:type="separator"><w:p><w:r><w:t>not prose</w:t></w:r></w:p></w:footnote><w:footnote w:id="1"><w:p><w:r><w:t>A research note</w:t></w:r></w:p></w:footnote></w:footnotes>'
package('word-annotations.docx','word','word/document.xml',{'word/document.xml':word, 'word/_rels/document.xml.rels':rels([('h','header','header1.xml'),('n','footnotes','footnotes.xml')]),'word/header1.xml':header,'word/footnotes.xml':footnotes})
package('duplicate-body.docx','word','word/document.xml',{'word/document.xml':word.replace('</w:document>','<w:body><w:p><w:r><w:t>hidden second body</w:t></w:r></w:p></w:body></w:document>')})
package('duplicate-sheet-data.xlsx','sheet','xl/workbook.xml',{**sheet_parts,'xl/worksheets/sheet2.xml':sheet.replace('</worksheet>','<sheetData><row r="9"><c r="A9"><v>99</v></c></row></sheetData></worksheet>')})
# Markup Compatibility alternatives describe one logical object, not two.
MC = 'http://schemas.openxmlformats.org/markup-compatibility/2006'
word_mce = '<w:document xmlns:w="'+W+'" xmlns:mc="'+MC+'" xmlns:future="urn:future"><w:body><w:p><w:r><w:t>Before </w:t></w:r><mc:AlternateContent><mc:Choice Requires="future"><w:r><w:t>Choice duplicate</w:t></w:r></mc:Choice><mc:Fallback><w:r><w:t>Fallback once</w:t></w:r></mc:Fallback></mc:AlternateContent></w:p></w:body></w:document>'
package('word-mce.docx','word','word/document.xml',{'word/document.xml':word_mce})
package('word-mce-no-fallback.docx','word','word/document.xml',{'word/document.xml':word_mce.replace('<mc:Fallback><w:r><w:t>Fallback once</w:t></w:r></mc:Fallback>','')})
slide_mce = '<p:sld xmlns:p="'+P+'" xmlns:a="'+A+'" xmlns:mc="'+MC+'" xmlns:future="urn:future"><p:cSld><p:spTree><mc:AlternateContent><mc:Choice Requires="future"><p:sp><p:txBody><a:p><a:r><a:t>Choice duplicate</a:t></a:r></a:p></p:txBody></p:sp></mc:Choice><mc:Fallback><p:sp><p:txBody><a:p><a:r><a:t>Fallback once</a:t></a:r></a:p></p:txBody></p:sp></mc:Fallback></mc:AlternateContent></p:spTree></p:cSld></p:sld>'
package('slides-mce.pptx','slides','ppt/presentation.xml',{**slides_parts,'ppt/slides/slide2.xml':slide_mce})
package('slides-mce-no-fallback.pptx','slides','ppt/presentation.xml',{**slides_parts,'ppt/slides/slide2.xml':slide_mce.replace('<mc:Fallback><p:sp><p:txBody><a:p><a:r><a:t>Fallback once</a:t></a:r></a:p></p:txBody></p:sp></mc:Fallback>','')})
