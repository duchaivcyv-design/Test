"""Minimal ONNX reader (no onnx package): returns nodes + initializers as numpy."""
import struct, numpy as np
def varint(b, i):
    r = 0; s = 0
    while True:
        c = b[i]; i += 1; r |= (c & 0x7f) << s; s += 7
        if not c & 0x80: return r, i
def fields(b):
    i = 0; n = len(b)
    while i < n:
        k, i = varint(b, i); f, w = k >> 3, k & 7
        if w == 0: v, i = varint(b, i)
        elif w == 1: v = b[i:i+8]; i += 8
        elif w == 2: l, i = varint(b, i); v = b[i:i+l]; i += l
        elif w == 5: v = b[i:i+4]; i += 4
        else: raise ValueError(w)
        yield f, w, v
def packed_varints(v):
    out = []; i = 0
    while i < len(v): x, i = varint(v, i); out.append(x)
    return out
def tensor(b):
    dims = []; dt = 1; raw = None; fl = []; i64 = []; name = ""
    for f, w, v in fields(b):
        if f == 1: dims += packed_varints(v) if w == 2 else [v]
        elif f == 2: dt = v
        elif f == 4: fl += list(struct.unpack("<%df" % (len(v)//4), v)) if w == 2 else [struct.unpack("<f", v)[0]]
        elif f == 7: i64 += packed_varints(v) if w == 2 else [v]
        elif f == 8: name = v.decode()
        elif f == 9: raw = v
    dtype = {1: np.float32, 7: np.int64, 6: np.int32, 11: np.float64}[dt]
    if raw is not None: a = np.frombuffer(raw, dtype=dtype)
    elif fl: a = np.array(fl, np.float32)
    else: a = np.array(i64, np.int64)
    return name, a.reshape(dims) if dims else (a.reshape(()) if a.size == 1 else a)
def attr(b):
    d = {"name": "", "f": None, "i": None, "ints": [], "t": None, "s": None, "floats": []}
    for f, w, v in fields(b):
        if f == 1: d["name"] = v.decode()
        elif f == 2: d["f"] = struct.unpack("<f", v)[0]
        elif f == 3: d["i"] = v if v < 2**63 else v - 2**64
        elif f == 4: d["s"] = v.decode(errors="ignore")
        elif f == 5: d["t"] = tensor(v)[1]
        elif f == 7: d["floats"] += list(struct.unpack("<%df" % (len(v)//4), v)) if w == 2 else [struct.unpack("<f", v)[0]]
        elif f == 8: d["ints"] += [x if x < 2**63 else x - 2**64 for x in (packed_varints(v) if w == 2 else [v])]
    return d
def load(path):
    b = open(path, "rb").read(); g = None
    for f, w, v in fields(b):
        if f == 7: g = v
    nodes = []; inits = {}; inputs = []; outputs = []
    for f, w, v in fields(g):
        if f == 1:
            n = {"in": [], "out": [], "op": "", "a": {}}
            for f2, w2, v2 in fields(v):
                if f2 == 1: n["in"].append(v2.decode())
                elif f2 == 2: n["out"].append(v2.decode())
                elif f2 == 4: n["op"] = v2.decode()
                elif f2 == 5: a = attr(v2); n["a"][a["name"]] = a
            nodes.append(n)
        elif f == 5: k, a = tensor(v); inits[k] = a
        elif f == 11: inputs.append([v2 for f2, w2, v2 in fields(v) if f2 == 1][0].decode())
        elif f == 12: outputs.append([v2 for f2, w2, v2 in fields(v) if f2 == 1][0].decode())
    return nodes, inits, inputs, outputs
