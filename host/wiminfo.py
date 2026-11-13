#!/usr/bin/env python3
"""List the Windows editions (install.wim indexes) inside a Windows ISO without extracting it.

Windows ISOs keep their files in UDF, which needs a UDF reader: this uses pycdlib
(pip install pycdlib, ideally in a virtualenv). Only the WIM header and its XML
metadata are read, so it takes a second even for an 8 GB ISO.

Usage: wiminfo.py <windows.iso>
"""
import re
import struct
import sys

import pycdlib


def main(path):
    iso = pycdlib.PyCdlib()
    iso.open(path)
    udf = iso.get_udf_facade()
    name = None
    for cand in ("/sources/install.wim", "/sources/install.esd"):
        try:
            udf.get_record(cand)
            name = cand
            break
        except pycdlib.pycdlibexception.PyCdlibInvalidInput:
            continue
    if not name:
        sys.exit("no install.wim / install.esd found")
    with iso.open_file_from_iso(udf_path=name) as f:
        hdr = f.read(208)
        if hdr[:8] != b"MSWIM\0\0\0":
            sys.exit("not a WIM file")
        count = struct.unpack_from("<I", hdr, 44)[0]
        xml_size = int.from_bytes(hdr[72:79], "little")       # RESHDR_DISK_SHORT for the XML data
        xml_off = struct.unpack_from("<Q", hdr, 80)[0]
        f.seek(xml_off)
        xml = f.read(xml_size).decode("utf-16-le", "ignore")
    print(f"{name}: {count} image(s)")
    for m in re.finditer(r'<IMAGE INDEX="(\d+)">(.*?)</IMAGE>', xml, re.S):
        body = m.group(2)

        def tag(t):
            r = re.search(rf"<{t}>(.*?)</{t}>", body, re.S)
            return r.group(1) if r else ""
        print(f"  index {m.group(1)}: {tag('NAME')} | edition {tag('EDITIONID')} | "
              f"{tag('INSTALLATIONTYPE')} | build {tag('BUILD')}.{tag('SPBUILD')}")
    iso.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
