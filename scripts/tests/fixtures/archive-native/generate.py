#!/usr/bin/env python3
"""Materialize deterministic native-reader checks without network or an archiver.

Normal checks use the committed archives. --refresh-7z /path/to/7zz regenerates
the original 7z fixtures; that optional maintainer action needs official 7-Zip.
"""
import argparse
import binascii
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import zipfile
import zlib

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[3]


def write(root, name, data):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def expected(root):
    folder = root / "folder"
    (folder / "中文目录" / "空目录").mkdir(parents=True, exist_ok=True)
    write(folder, "hello.txt", b"hello")
    write(folder, "empty", b"")
    write(folder, "中文目录/😀.txt", "离线归档比较\nCrossDiff\n".encode())
    # Small, deterministic and not too compressible; also exercises BCJ/Delta.
    write(folder, "binary.bin", bytes(range(256)) * 32 + b"\xe8\x10\0\0\0" * 512)
    write(folder, "repeated.txt", b"CrossDiff archive native reader\n" * 256)
    for kind in ["rar5-stored", "rar5-compressed", "rar5-solid", "rar4-stored"]:
        (root / kind).mkdir(parents=True, exist_ok=True)
    write(root / "rar5-stored", "helloworld.txt", b"hello libarchive test suite!\n")
    def numbers(magic, size):
        return b"".join(struct.pack("<I", max(0, k*k-3*k+1+magic)) for k in range(1, size//4+1))
    write(root / "rar5-compressed", "test.bin", numbers(0, 1200))
    for magic in range(1, 5):
        write(root / "rar5-solid", f"test{magic}.bin", numbers(magic, 4096))
    write(root / "rar4-stored", "test.txt", b"test text document\r\n")
    write(root / "rar4-stored", "testdir/test.txt", b"test text document\r\n")
    (root / "rar4-stored/testemptydir").mkdir(parents=True, exist_ok=True)
    (root / "rar4-stored/testlink").symlink_to("test.txt")
    return folder


SEVEN_CASES = {
    "copy.7z": ["-m0=Copy", "-ms=off", "-mhc=off"],
    "lzma1.7z": ["-m0=LZMA:d=1m", "-ms=off", "-mhc=off"],
    "lzma2.7z": ["-m0=LZMA2:d=1m", "-ms=off", "-mhc=off"],
    "solid.7z": ["-m0=LZMA2:d=1m", "-ms=on", "-mhc=off"],
    "header-compressed.7z": ["-m0=LZMA2:d=1m", "-ms=on", "-mhc=on"],
    "bcj.7z": ["-m0=BCJ", "-m1=LZMA2:d=1m", "-ms=on", "-mhc=off"],
    "delta.7z": ["-m0=Delta:1", "-m1=LZMA2:d=1m", "-ms=on", "-mhc=off"],
    "encrypted-data.7z": ["-m0=LZMA2:d=1m", "-pfixture-only", "-mhe=off"],
    "encrypted-header.7z": ["-m0=LZMA2:d=1m", "-pfixture-only", "-mhe=on"],
    "unsupported-bzip2.7z": ["-m0=BZip2", "-mhc=off"],
}


def refresh(archiver, root, folder):
    for name, options in SEVEN_CASES.items():
        archive = HERE / "archives" / name
        archive.unlink(missing_ok=True)
        subprocess.run([str(archiver), "a", "-t7z", "-mtm=off", "-mta=off", "-mtc=off", "-mmt=1", *options,
                        str(archive), "."], cwd=folder, check=True, stdout=subprocess.DEVNULL)
    split = root / "split.7z"
    subprocess.run([str(archiver), "a", "-t7z", "-m0=Copy", "-mhc=off", "-v4k", "-mtm=off", "-mta=off", "-mtc=off",
                    str(split), "."], cwd=folder, check=True, stdout=subprocess.DEVNULL)
    shutil.copyfile(root / "split.7z.001", HERE / "archives/split.7z.001")
    # This independent oracle is collected only during fixture maintenance;
    # regular verification does not invoke 7-Zip or extract any archive.
    name = "test_read_format_rar_compress_normal.rar"
    archive = HERE / "archives" / name
    manifest = {}
    for path in ["LibarchiveAddingTest.html", "testdir/LibarchiveAddingTest.html", "testdir/test.txt"]:
        data = subprocess.run([str(archiver), "e", "-so", str(archive), path], check=True, stdout=subprocess.PIPE).stdout
        manifest[path] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "crc32": f"{zlib.crc32(data):08x}"}
    (HERE / "rar4-compressed-expected.json").write_text(json.dumps(manifest, indent=2) + "\n")
    sums = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((HERE / "archives").iterdir())}
    (HERE / "SHA256SUMS.json").write_text(json.dumps(sums, indent=2) + "\n")


def seven_crc(data):
    next_offset, next_size = struct.unpack_from("<QQ", data, 12)
    at = 32 + next_offset
    struct.pack_into("<I", data, 28, zlib.crc32(data[at:at+next_size]))
    struct.pack_into("<I", data, 8, zlib.crc32(data[12:32]))
    return data


def uint7(value):
    # The 7z integer coding has a leading length mask, unlike RAR's VINT.
    for count in range(8):
        if value < (1 << (7 + 7*count)):
            return bytes([((0xff << (8-count)) & 0xff) | (value >> (8*count))]) + value.to_bytes(8, "little")[:count]
    return b"\xff" + struct.pack("<Q", value)


def synthetic_encoded_header(expanded, packed=b"\0", dictionary=16):
    # An encoded header whose advertised resource requirement must be rejected
    # before libarchive attempts to decode its intentionally irrelevant payload.
    header = b"\x17\x06\0\x01\x09" + uint7(len(packed)) + b"\0"
    header += b"\x07\x0b\x01\0\x01\x21\x21\x01" + bytes([dictionary])
    header += b"\x0c" + uint7(expanded) + b"\0\0"
    data = bytearray(b"7z\xbc\xaf\x27\x1c\0\x04" + bytes(4) + struct.pack("<QQI", len(packed), len(header), 0) + packed + header)
    return seven_crc(data)


def checksum_archives(root):
    # Copy streams make the encoded bytes explicit, independently of both the
    # system decoder and 7-Zip. Verify every advertised CRC, including redundant
    # folder CRCs when each individual substream has its own valid digest.
    payload = b"abcdef"
    for scenario in ["valid", "solid-valid", "folder-only-valid", "bad-pack-crc", "bad-folder-crc", "bad-folder-only-crc"]:
        count = 2 if "solid" in scenario or "folder" in scenario else 1
        folder_crc = zlib.crc32(payload) ^ (1 if "bad-folder" in scenario else 0)
        pack_crc = zlib.crc32(payload) ^ (1 if scenario == "bad-pack-crc" else 0)
        streams = b"\x06\0\x01\x09" + uint7(len(payload)) + b"\x0a\x01" + struct.pack("<I", pack_crc) + b"\0"
        streams += b"\x07\x0b\x01\0\x01\x01\0\x0c" + uint7(len(payload)) + b"\x0a\x01" + struct.pack("<I", folder_crc) + b"\0"
        if count == 2:
            streams += b"\x08\x0d\x02\x09\x03"
            if "folder-only" not in scenario:
                streams += b"\x0a\x01" + struct.pack("<II", zlib.crc32(payload[:3]), zlib.crc32(payload[3:]))
            streams += b"\0"
        else:
            streams += b"\x08\0"
        streams += b"\0"
        names = b"\0" + "".join(chr(97+i) + "\0" for i in range(count)).encode("utf-16le")
        header = b"\x01\x04" + streams + b"\x05" + uint7(count) + b"\x11" + uint7(len(names)) + names + b"\0\0"
        start = struct.pack("<QQI", len(payload), len(header), zlib.crc32(header))
        archive = b"7z\xbc\xaf\x27\x1c\0\4" + struct.pack("<I", zlib.crc32(start)) + start + payload + header
        write(root, scenario + ".7z", archive)
    write(root / "checksum-single", "a", payload)
    write(root / "checksum-solid", "a", payload[:3])
    write(root / "checksum-solid", "b", payload[3:])


def rar_profile_boundaries(root, archives):
    data = bytearray((archives / "test_read_format_rar.rar").read_bytes())
    header_start = 7
    header_size = struct.unpack_from("<H", data, header_start+5)[0]
    flags = struct.unpack_from("<H", data, header_start+3)[0]
    struct.pack_into("<H", data, header_start+3, flags | 8)  # RAR4 MHD_SOLID.
    struct.pack_into("<H", data, header_start, zlib.crc32(data[header_start+2:header_start+header_size]) & 0xffff)
    write(root, "bad-rar4-solid.rar", data)
    def vint(data, at):
        value, shift = 0, 0
        while True:
            byte = data[at]; at += 1
            value |= (byte & 127) << shift
            if byte < 128: return value, at
            shift += 7
    def encode_vint(value):
        result = bytearray()
        while value >= 128:
            result.append((value & 127) | 128); value >>= 7
        result.append(value)
        return result
    data = bytearray((archives / "test_read_format_rar5_compressed.rar").read_bytes())
    at = 8
    while at < len(data):
        size, cursor = vint(data, at+4)
        end = cursor + size
        kind, cursor = vint(data, cursor)
        flags, cursor = vint(data, cursor)
        if flags & 1: _, cursor = vint(data, cursor)
        packed = 0
        if flags & 2: packed, cursor = vint(data, cursor)
        if kind == 2:
            file_flags, cursor = vint(data, cursor)
            _, cursor = vint(data, cursor)  # Expanded size.
            _, cursor = vint(data, cursor)  # Attributes.
            if file_flags & 2: cursor += 4
            if file_flags & 4: cursor += 4
            compression, compression_end = vint(data, cursor)
            for name, changed in [("bad-rar5-dictionary.rar", (compression & ~(31 << 10)) | (10 << 10)),
                                  ("bad-rar5-algorithm.rar", compression | 1)]:
                encoded = encode_vint(changed)
                assert len(encoded) == compression_end - cursor
                changed_data = data.copy()
                changed_data[cursor:compression_end] = encoded
                struct.pack_into("<I", changed_data, at, zlib.crc32(changed_data[at+4:end]))
                write(root, name, changed_data)
            return
        at = end + packed
    raise AssertionError("RAR5 compression fixture has no file header")


def derived(root, folder):
    archives = HERE / "archives"
    sums = json.loads((HERE / "SHA256SUMS.json").read_text())
    for name, digest in sums.items():
        data = (archives / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit(f"Fixture checksum mismatch: {name}")
        write(root, name, data)
    for source in [folder, root / "rar5-stored", root / "rar5-compressed", root / "rar5-solid"]:
        with zipfile.ZipFile(root / (source.name + ".zip"), "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(source.rglob("*")):
                archive.write(path, str(path.relative_to(source)))
        with tarfile.open(root / (source.name + ".tar"), "w", format=tarfile.PAX_FORMAT) as archive:
            for path in sorted(source.rglob("*")):
                archive.add(path, arcname=str(path.relative_to(source)), recursive=False)
    for name in ["copy.7z", "lzma2.7z", "header-compressed.7z", "test_read_format_rar.rar", "test_read_format_rar5_stored.rar", "test_read_format_rar5_compressed.rar"]:
        data = (archives / name).read_bytes()
        write(root, "bad-truncated-" + name, data[:-3])
        write(root, "bad-tail-" + name, data + b"unverified tail")
    for source, at in [("copy.7z", 40), ("test_read_format_rar5_stored.rar", 75)]:
        data = bytearray((archives / source).read_bytes())
        data[at] ^= 1
        write(root, "bad-payload-crc-" + source, data)
    data = bytearray((archives / "lzma2.7z").read_bytes())
    next_at = 32 + struct.unpack_from("<Q", data, 12)[0]
    index = data.index(b"\x21\x21\x01", next_at) + 3
    data[index] = 29  # LZMA2 property 29 advertises 96 MiB.
    write(root, "bad-data-dictionary.7z", seven_crc(data))
    write(root, "bad-header-dictionary.7z", synthetic_encoded_header(64, dictionary=29))
    write(root, "bad-header-expanded-limit.7z", synthetic_encoded_header(1024*1024+1))
    write(root, "bad-header-packed-limit.7z", synthetic_encoded_header(64, packed=bytes(1024*1024+1)))
    checksum_archives(root)
    rar_profile_boundaries(root, archives)
    # Original snapshot stamps must catch replacement even if bytes are equal.
    shutil.copyfile(archives / "copy.7z", root / "mutable.7z")
    shutil.copyfile(HERE / "rar4-compressed-expected.json", root / "rar4-compressed-expected.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--refresh-7z", type=Path)
    parser.add_argument("--refresh-rar", type=Path, help="libarchive 3.8.9 libarchive/test directory containing upstream .uu fixtures")
    args = parser.parse_args()
    output = args.output.resolve()
    fixture_path = output.name.startswith("fixtures") or (output.name == "native" and output.parent.name == "fixtures")
    if not output.is_relative_to(PROJECT) or output == PROJECT or not fixture_path:
        raise SystemExit("Output must be a fixtures* or fixtures/native directory inside this project")
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)
    folder = expected(output)
    if args.refresh_rar:
        for archive in sorted((HERE / "archives").glob("*.rar")):
            encoded = (args.refresh_rar / (archive.name + ".uu")).read_bytes().splitlines()
            begin = next(i for i, line in enumerate(encoded) if line.startswith(b"begin "))
            data = bytearray()
            for line in encoded[begin+1:]:
                if line == b"end": break
                data.extend(binascii.a2b_uu(line))
            archive.write_bytes(data)
    if args.refresh_7z:
        refresh(args.refresh_7z.resolve(), output, folder)
    derived(output, folder)
    print(f"Prepared native archive fixtures: {output}")


if __name__ == "__main__":
    main()
