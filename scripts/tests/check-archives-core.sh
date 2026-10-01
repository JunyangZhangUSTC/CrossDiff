#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$project_root/scripts/project-env.sh"
cd "$project_root"
check_build="$project_root/.build-archive-core-checks"
mkdir -p "$check_build/module-cache" "$check_build/fixtures/folder/nested"
python3 - <<'PY'
from pathlib import Path
root=Path('.build-archive-core-checks/fixtures/folder')
(root/'hello.txt').write_bytes(b'hello')
(root/'nested'/'empty').write_bytes(b'')
import tarfile, zipfile
for method, name in [(zipfile.ZIP_STORED,'stored.zip'),(zipfile.ZIP_DEFLATED,'deflated.zip')]:
    with zipfile.ZipFile(root.parent/name, 'w', compression=method) as archive:
        archive.write(root/'hello.txt', './hello.txt')
        archive.write(root/'nested'/'empty', 'nested/empty')
for suffix, mode in [('tar','w'), ('tar.gz','w:gz'), ('tgz','w:gz'), ('tar.bz2','w:bz2'), ('tbz2','w:bz2'), ('tar.xz','w:xz'), ('txz','w:xz')]:
    with tarfile.open(root.parent/('valid.'+suffix), mode) as archive:
        archive.add(root/'hello.txt', arcname='./hello.txt')
        archive.add(root/'nested'/'empty', arcname='nested/empty')

import io, struct, stat, gzip, shutil, warnings
warnings.filterwarnings('ignore', category=UserWarning)
fixtures=root.parent
for name in ['links', 'mutable', 'many']:
    shutil.rmtree(fixtures/name, ignore_errors=True)
    (fixtures/name).mkdir()
(fixtures/'links'/'file').write_bytes(b'linked')
(fixtures/'links'/'hard').hardlink_to(fixtures/'links'/'file')
(fixtures/'links'/'symbolic').symlink_to('../folder/hello.txt')
import os
os.mkfifo(fixtures/'links'/'fifo')
(fixtures/'mutable'/'child').mkdir()
(fixtures/'mutable'/'child'/'value').write_bytes(b'before')

def zip_bytes(items, method=zipfile.ZIP_STORED):
    buffer=io.BytesIO()
    with zipfile.ZipFile(buffer,'w',compression=method) as archive:
        for name, content in items: archive.writestr(name, content)
    return buffer.getvalue()
def save(name, data): (fixtures/name).write_bytes(data)
def tar_bytes(items, fmt=tarfile.PAX_FORMAT):
    buffer=io.BytesIO()
    with tarfile.open(fileobj=buffer,mode='w',format=fmt) as archive:
        for name, content, kind in items:
            info=tarfile.TarInfo(name); info.type=kind
            info.size=len(content) if kind==tarfile.REGTYPE else 0
            if kind in [tarfile.SYMTYPE, tarfile.LNKTYPE]: info.linkname='../../outside'
            archive.addfile(info,io.BytesIO(content))
    return buffer.getvalue()
for extension in ['zip','tar']:
    encode=(lambda items:zip_bytes([(n,d) for n,d in items])) if extension=='zip' else (lambda items:tar_bytes([(n,d,tarfile.REGTYPE) for n,d in items]))
    save('unicode.'+extension,encode([('中文/😀.txt',b'hello')]))
    for label, items in [('parent',[('../escape',b'')]), ('absolute',[('/outside',b'')]), ('drive',[('C:/outside',b'')]),('backslash',[('a\\b',b'')]),('duplicate',[('a',b''),('./a',b'')]),('ancestor',[('a',b''),('a/b',b'')]),('reverse-ancestor',[('a/b',b''),('a',b'')]),('root-file',[('./',b'')])]:
        save('bad-'+label+'.'+extension,encode(items))
    save('empty.'+extension,zip_bytes([]) if extension=='zip' else tar_bytes([]))
    save('bad-truncated.'+extension,encode([('hello',b'hello')])[:40])
longname='nested/' + 'long-name-'*20 + '.txt'
save('pax.tar',tar_bytes([(longname,b'hello',tarfile.REGTYPE)]))
save('gnu.tar',tar_bytes([(longname,b'hello',tarfile.REGTYPE)],tarfile.GNU_FORMAT))
save('links.tar',tar_bytes([('sym',b'',tarfile.SYMTYPE),('hard',b'',tarfile.LNKTYPE),('fifo',b'',tarfile.FIFOTYPE)]))
save('root.tar',tar_bytes([('./',b'',tarfile.DIRTYPE),('hello.txt',b'hello',tarfile.REGTYPE),('nested/empty',b'',tarfile.REGTYPE)]))
with zipfile.ZipFile(fixtures/'bad-root-file.zip','w') as archive:
    entry=zipfile.ZipInfo('./');entry.create_system=3;entry.external_attr=(stat.S_IFREG|0o644)<<16;archive.writestr(entry,b'')
with zipfile.ZipFile(fixtures/'links.zip','w') as archive:
    entry=zipfile.ZipInfo('sym');entry.create_system=3;entry.external_attr=(stat.S_IFLNK|0o777)<<16
    archive.writestr(entry,'../../outside')
for method,label in [(zipfile.ZIP_BZIP2,'bzip2'),(zipfile.ZIP_LZMA,'lzma')]:
    save('bad-method-'+label+'.zip',zip_bytes([('file',b'hello')],method))
base=bytearray(zip_bytes([('file',b'hello')]))
central=base.index(b'PK\x01\x02'); end=base.index(b'PK\x05\x06')
for label,mutate in [
 ('crc',lambda x:x.__setitem__(34,x[34]^1)),
 ('name-mismatch',lambda x:x.__setitem__(30,ord('x'))),
 ('nul',lambda x:(x.__setitem__(31,0),x.__setitem__(central+47,0))),
 ('utf8',lambda x:(x.__setitem__(31,255),x.__setitem__(central+47,255))),
 ('encrypted',lambda x:(struct.pack_into('<H',x,6,1),struct.pack_into('<H',x,central+8,1))),
 ('multivolume',lambda x:struct.pack_into('<H',x,end+4,1)),
 ('zip64',lambda x:struct.pack_into('<I',x,end+12,0xffffffff)),
 ('size',lambda x:(struct.pack_into('<I',x,22,256*1024*1024+1),struct.pack_into('<I',x,central+24,256*1024*1024+1))),
 ('central-crc',lambda x:(struct.pack_into('<I',x,14,0),struct.pack_into('<I',x,central+16,0))),
]:
    modified=base.copy();mutate(modified);save('bad-'+label+'.zip',modified)
# Valid data descriptors emitted by an unseekable ZIP writer.
class Unseekable(io.BytesIO):
    def seekable(self): return False
    def seek(self,*args): raise io.UnsupportedOperation('unseekable')
buffer=Unseekable()
with zipfile.ZipFile(buffer,'w',compression=zipfile.ZIP_DEFLATED) as archive: archive.writestr('file',b'hello')
save('descriptor.zip',buffer.getvalue())
base=bytearray(tar_bytes([('file',b'hello',tarfile.REGTYPE)]))
def tar_checksum(data):
    data[148:156]=b'        '; data[148:156]=('%06o\0 '%sum(data[:512])).encode()
for label,mutate in [
 ('checksum',lambda x:x.__setitem__(0,ord('z'))),
 ('nul',lambda x:x.__setitem__(5,ord('x'))),
 ('utf8',lambda x:x.__setitem__(0,255)),
 ('size',lambda x:x.__setitem__(slice(124,136),('%011o\0'%(256*1024*1024+1)).encode())),
 ('sparse',lambda x:x.__setitem__(156,ord('S'))),
 ('padding',lambda x:x.__setitem__(517,1)),
 ('trailing',lambda x:x.__setitem__(-1,1)),
]:
    modified=base.copy();mutate(modified)
    if label!='checksum':tar_checksum(modified)
    save('bad-'+label+'.tar',modified)
import bz2, lzma
for suffix, encode in [('tar.bz2',bz2.compress), ('tar.xz',lzma.compress)]:
    damaged=bytearray(encode(base));damaged[len(damaged)//2]^=1
    save('bad-compressed-crc.'+suffix,damaged)
# Invalid UTF-8/NUL inside extended PAX paths must not be hidden by C-string conversion.
for label, value in [('pax-nul','a\0b'),('pax-parent','../escape')]:
    buffer=io.BytesIO()
    with tarfile.open(fileobj=buffer,mode='w',format=tarfile.PAX_FORMAT) as archive:
        entry=tarfile.TarInfo('safe');entry.pax_headers={'path':value};archive.addfile(entry)
    save('bad-'+label+'.tar',buffer.getvalue())
compressed=bytearray(gzip.compress(base))
compressed[-8]^=1;save('bad-gzip-crc.tar.gz',compressed)
modified=bytearray(gzip.compress(base));modified[-4]^=1;save('bad-gzip-size.tar.gz',modified)
save('bad-gzip-second-member.tar.gz',gzip.compress(base[:5120])+gzip.compress(base[5120:])[:-3])
save('gzip-members.tar.gz',gzip.compress(base[:5120])+gzip.compress(base[5120:]))
save('bad-gzip-trailing.tar.gz',gzip.compress(base)+b'ignored garbage')
save('bad-bzip2-trailing.tar.bz2',bz2.compress(base)+b'ignored garbage')
save('bad-gzip-truncated.tar.gz',gzip.compress(base)[:-5])
# Source-size cap is tested using sparse files, not multi-gigabyte allocations.
with (fixtures/'bad-source-size.tar').open('wb') as file: file.truncate(2*1024*1024*1024+1)
for index in range(10001): (fixtures/'many'/str(index)).touch()
save('bad-entry-count.zip',zip_bytes([(str(index),b'') for index in range(10001)]))
save('bad-path-bytes.tar',tar_bytes([('x'*4097,b'',tarfile.REGTYPE)]))
save('bad-path-depth.tar',tar_bytes([('/'.join(['x']*129),b'',tarfile.REGTYPE)]))
with (fixtures/'links'/'large').open('wb') as file:file.truncate(256*1024*1024+1)
(fixtures/'large-folder').mkdir(exist_ok=True)
with (fixtures/'large-folder'/'huge').open('wb') as file:file.truncate(256*1024*1024+1)
(fixtures/'links'/'large').unlink()

# XZ checks use standard-library encoders and rebuild only container metadata.
import zlib
rawtar=bytes(base)
for name,check in [('crc32',lzma.CHECK_CRC32),('crc64',lzma.CHECK_CRC64),('sha256',lzma.CHECK_SHA256)]:
    save('xz-'+name+'.tar.xz',lzma.compress(rawtar,check=check))
save('bad-xz-no-check.tar.xz',lzma.compress(rawtar,check=lzma.CHECK_NONE))
save('bad-nested.tar.gz',gzip.compress(lzma.compress(rawtar)))
save('bad-nested.tar.bz2',bz2.compress(gzip.compress(rawtar)))
save('bad-nested.tar.xz',lzma.compress(gzip.compress(rawtar)))
def vli(value):
    encoded=bytearray()
    while value>=128:encoded.append((value&127)|128);value>>=7
    encoded.append(value);return bytes(encoded)
def read_vli(data,at):
    result=0;shift=0
    while True:
        value=data[at];at+=1;result|=(value&127)<<shift
        if value<128:return result,at
        shift+=7
def xz_block(data):
    index_size=(struct.unpack_from('<I',data,len(data)-8)[0]+1)*4
    index_start=len(data)-12-index_size
    unpadded,at=read_vli(data,index_start+2);expanded,at=read_vli(data,at)
    return data[12:index_start],unpadded,expanded
first=lzma.compress(rawtar[:5120]);second=lzma.compress(rawtar[5120:])
blocks=[xz_block(first),xz_block(second)]
def xz_join(blocks):
    index=b'\0'+vli(len(blocks))+b''.join(vli(unpadded)+vli(expanded) for _,unpadded,expanded in blocks)
    index+=b'\0'*((-len(index))%4);index+=struct.pack('<I',zlib.crc32(index))
    footer=struct.pack('<I',(len(index)//4)-1)+first[6:8]
    footer=struct.pack('<I',zlib.crc32(footer))+footer+b'YZ'
    return first[:12]+b''.join(body for body,_,_ in blocks)+index+footer
save('xz-multiblock.tar.xz',xz_join(blocks))
def huge_dictionary(block):
    body,unpadded,expanded=block;body=bytearray(body);header_len=(body[0]+1)*4
    assert body[1:4]==b'\0\x21\x01'
    body[4]=29;struct.pack_into('<I',body,header_len-4,zlib.crc32(body[:header_len-4]))
    return bytes(body),unpadded,expanded
save('bad-xz-dictionary.tar.xz',xz_join([huge_dictionary(xz_block(lzma.compress(rawtar)))]))
save('bad-xz-second-dictionary.tar.xz',xz_join([blocks[0],huge_dictionary(blocks[1])]))
concealed=blocks[0][0]+huge_dictionary(blocks[1])[0]
save('bad-xz-hidden-block.tar.xz',xz_join([(concealed,len(concealed),len(rawtar))]))
save('bad-xz-concat.tar.xz',lzma.compress(rawtar)+lzma.compress(rawtar))
save('bad-xz-padding.tar.xz',lzma.compress(rawtar)+b'\0'*4)
save('bad-xz-filters.tar.xz',lzma.compress(rawtar,filters=[{'id':lzma.FILTER_DELTA,'dist':1},{'id':lzma.FILTER_LZMA2,'dict_size':1024*1024}]))

PY
swiftc -O -swift-version 5 -module-cache-path "$check_build/module-cache" -emit-module -emit-library -module-name CrossDiffCore \
  Sources/CrossDiffCore/Localization.swift Sources/CrossDiffCore/Archive*.swift \
  -emit-module-path "$check_build/CrossDiffCore.swiftmodule" -o "$check_build/libCrossDiffCore.dylib"
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$check_build/module-cache" \
  -I "$check_build" -L "$check_build" -lCrossDiffCore -Xlinker -rpath -Xlinker "$check_build" \
  scripts/tests/ArchiveCoreChecks.swift -o "$check_build/archive-core-checks"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "Built: $check_build/archive-core-checks"
  exit 0
fi
"$check_build/archive-core-checks" "$check_build/fixtures"
