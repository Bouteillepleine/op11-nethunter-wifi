# Every firmware a shipped driver declares via MODULE_FIRMWARE must be present.
# Hand-written lists go stale: the OP11 set and the OP15 set differ, and a list
# copied between them fails CI for a blob nothing actually asks for.
import struct, sys, os, glob

NUL = chr(0).encode()

def modinfo(path):
    d = open(path, "rb").read()
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    shent = struct.unpack_from("<H", d, 0x3A)[0]
    shnum = struct.unpack_from("<H", d, 0x3C)[0]
    shstr = struct.unpack_from("<H", d, 0x3E)[0]
    sec = [struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * shent) for i in range(shnum)]
    strs = d[sec[shstr][4]:sec[shstr][4] + sec[shstr][5]]
    out = []
    for s in sec:
        if strs[s[0]:strs.index(NUL, s[0])].decode() == ".modinfo":
            for item in d[s[4]:s[4] + s[5]].split(NUL):
                if item.startswith(b"firmware="):
                    out.append(item[9:].decode())
    return out

root = sys.argv[1] if len(sys.argv) > 1 else "."
fwdir = os.path.join(root, "system", "etc", "firmware")
want = {}
for ko in sorted(glob.glob(os.path.join(root, "drivers", "*.ko"))):
    for fw in modinfo(ko):
        want.setdefault(fw, []).append(os.path.basename(ko))

missing = [f for f in want if not os.path.isfile(os.path.join(fwdir, f))]
print("%d firmware file(s) declared by %d driver(s)" % (len(want), len(glob.glob(os.path.join(root, "drivers", "*.ko")))))
for f in sorted(missing):
    print("MISSING %-40s wanted by %s" % (f, ", ".join(sorted(set(want[f])))))
if missing:
    print("")
    print("%d declared firmware file(s) are not shipped. Either add them under" % len(missing))
    print("system/etc/firmware/ or drop the driver that asks for them.")
    sys.exit(1)
print("all declared firmware is present")
