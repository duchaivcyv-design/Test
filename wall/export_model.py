"""export_model.py <u2netp.onnx> <out.u2p> <S>: bake the ONNX graph into a static program the C runtime executes."""
import sys, struct, numpy as np; sys.path.insert(0, '.')
import u2ref, onnx_lite as o
path, outp, S = sys.argv[1], sys.argv[2], int(sys.argv[3])
rec = []
x = np.random.RandomState(1).randn(3, S, S).astype(np.float32) * 0.5
outs, env, inname, outnames = u2ref.run(x, path, rec)
nodes, inits, _, _ = o.load(path)
tid = {}; shapes = {}
def T(n, shp=None):
    if n not in tid: tid[n] = len(tid)
    if shp is not None: shapes[tid[n]] = shp
    return tid[n]
T(inname, (3, S, S))
wl = []; wid = {}
def W(n):
    if n not in wid: wid[n] = len(wl); wl.append(inits[n].astype(np.float32))
    return wid[n]
ops = []
for r in rec:
    k = r[0]
    if k == "conv": ops.append((1, [T(r[1])], T(r[4], r[7]), W(r[2]), W(r[3]), r[5], r[6]))
    elif k == "relu": ops.append((2, [T(r[1])], T(r[2], r[3]), 0, 0, 0, 0))
    elif k == "pool": ops.append((3, [T(r[1])], T(r[2], r[3]), 0, 0, 0, 0))
    elif k == "cat": ops.append((4, [T(i) for i in r[1]], T(r[2], r[3]), 0, 0, 0, 0))
    elif k == "add": ops.append((5, [T(r[1]), T(r[2])], T(r[3], r[4]), 0, 0, 0, 0))
    elif k == "up": ops.append((6, [T(r[1])], T(r[2], r[3]), 0, 0, 0, 0))
    elif k == "sig": ops.append((7, [T(r[1])], T(r[2], r[3]), 0, 0, 0, 0))
final = tid[outnames[0]]
# keep only ops needed for the first output
need = {final}; keep = []
for op in reversed(ops):
    if op[2] in need: keep.append(op); need.update(op[1])
ops = keep[::-1]
with open(outp, "wb") as f:
    f.write(b"U2P1"); f.write(struct.pack("<7I", S, len(tid), len(ops), len(wl), tid[inname], final, 0))
    for w in wl:
        f.write(struct.pack("<I", w.ndim)); f.write(struct.pack("<%dI" % w.ndim, *w.shape)); f.write(w.astype("<f4").tobytes())
    for (t, ins, out, a, b, p0, p1) in ops:
        c, h, w_ = shapes[out]
        ins6 = (ins + [0xffffffff] * 6)[:6]
        f.write(struct.pack("<I6IIIIIIIII", t, *ins6, out, a, b, p0, p1, c, h, w_))
# reference output for validation
ref = outs[0][0, 0].astype("<f4"); open(outp + ".in", "wb").write(x.astype("<f4").tobytes()); open(outp + ".ref", "wb").write(ref.tobytes())
print("ops", len(ops), "weights", len(wl), "tensors", len(tid), "bytes", __import__("os").path.getsize(outp))
