import struct, sys, os

NUL = chr(0).encode()

def versions(path):
    d = open(path, "rb").read()
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    shent = struct.unpack_from("<H", d, 0x3A)[0]
    shnum = struct.unpack_from("<H", d, 0x3C)[0]
    shstr = struct.unpack_from("<H", d, 0x3E)[0]
    sec = [struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * shent) for i in range(shnum)]
    strs = d[sec[shstr][4]:sec[shstr][4] + sec[shstr][5]]
    out = {}
    for s in sec:
        name = strs[s[0]:strs.index(NUL, s[0])].decode()
        if name == "__versions":
            for j in range(s[4], s[4] + s[5], 64):
                sym = d[j + 8:j + 64].split(NUL)[0].decode()
                out[sym] = struct.unpack_from("<I", d, j)[0]
    return out

def exports(path):
    """CRCs a module exports, from its __crc_<sym> symbols."""
    d = open(path, "rb").read()
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    shent = struct.unpack_from("<H", d, 0x3A)[0]
    shnum = struct.unpack_from("<H", d, 0x3C)[0]
    sec = [struct.unpack_from("<IIQQQQIIQQ", d, shoff + i * shent) for i in range(shnum)]
    shstr = struct.unpack_from("<H", d, 0x3E)[0]
    strs = d[sec[shstr][4]:sec[shstr][4] + sec[shstr][5]]
    names = [strs[x[0]:strs.index(NUL, x[0])].decode() for x in sec]
    out = {}
    for s in sec:
        if s[1] != 2:
            continue
        st = sec[s[6]]
        sd = d[st[4]:st[4] + st[5]]
        for i in range(s[5] // 24):
            o = s[4] + i * 24
            nm, info, other, shndx, val, sz = struct.unpack_from("<IBBHQQ", d, o)
            name = sd[nm:sd.index(NUL, nm)].decode()
            if name.startswith("__crc_"):
                # CONFIG_MODULE_REL_CRCS (6.x): the symbol is defined in
                # __kcrctab and st_value is an offset into it, not the CRC.
                sname = names[shndx] if shndx < len(names) else ""
                if sname.startswith("__kcrctab") and val + 4 <= sec[shndx][5]:
                    out[name[6:]] = struct.unpack_from("<I", d, sec[shndx][4] + val)[0]
                else:
                    out[name[6:]] = val & 0xFFFFFFFF
    return out

def reference(path):
    """A reference is either a Module.symvers-style text file or another .ko."""
    if path.endswith(".ko"):
        return exports(path)
    ref = {}
    for line in open(path):
        f = line.split()
        if len(f) >= 2:
            ref[f[1]] = int(f[0], 16)
    return ref

ko, refs = sys.argv[1], sys.argv[2:]
if not os.path.exists(ko):
    print("missing " + ko); sys.exit(1)
imports = versions(ko)
if not imports:
    print("no __versions section in " + ko + " - built without MODVERSIONS?"); sys.exit(1)

bad = checked = 0
for r in refs:
    for sym, crc in reference(r).items():
        if sym in imports:
            checked += 1
            if imports[sym] != crc:
                bad += 1
                print("MISMATCH %-40s reference=0x%08x built=0x%08x" % (sym, crc, imports[sym]))

print("%s: %d symbol(s) checked, %d mismatched" % (os.path.basename(ko), checked, bad))
if checked == 0:
    # Against the device's symvers that means the reference is wrong. Against a
    # sibling .ko it just means this driver imports nothing from it - ath.ko and
    # ath9k_hw.ko pull only kernel-core symbols, which is normal.
    if any(not r.endswith(".ko") for r in refs):
        print("nothing was compared - the reference does not overlap this module")
        sys.exit(1)
if bad:
    print("")
    print("This module will not load on the device, or will call the wrong function")
    print("pointer and panic the kernel. A config guard INSIDE a struct the module")
    print("passes across the ABI is the usual cause - CONFIG_NL80211_TESTMODE guards")
    print("two members of struct cfg80211_ops. Take those values from the vendor")
    print("fragment, never infer them.")
    sys.exit(1)
