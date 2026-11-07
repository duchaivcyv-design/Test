"""Numpy reference executor for u2netp.onnx; also records a static program (shapes resolved) for the C runtime."""
import numpy as np, onnx_lite as o, sys
def conv(x, w, b, dil, pad):
    C, H, W_ = x.shape; O, I, kh, kw = w.shape
    xp = np.pad(x, ((0, 0), (pad, pad), (pad, pad)))
    out = np.zeros((O, H, W_), np.float32)
    for ky in range(kh):
        for kx in range(kw):
            patch = xp[:, ky*dil:ky*dil+H, kx*dil:kx*dil+W_]
            out += np.tensordot(w[:, :, ky, kx], patch, axes=([1], [0]))
    return out + b[:, None, None]
def maxpool_ceil(x):
    C, H, W_ = x.shape; oh, ow = (H+1)//2, (W_+1)//2
    xp = np.full((C, oh*2, ow*2), -np.inf, np.float32); xp[:, :H, :W_] = x
    return xp.reshape(C, oh, 2, ow, 2).max(axis=(2, 4))
def resize_bilinear(x, oh, ow):
    C, H, W_ = x.shape
    def coords(o_, i_):
        s = (np.arange(o_) + 0.5) * i_ / o_ - 0.5 if o_ > 1 else np.zeros(1)
        s = np.clip(s, 0, i_ - 1); i0 = np.floor(s).astype(int); i1 = np.minimum(i0 + 1, i_ - 1); return i0, i1, (s - i0).astype(np.float32)
    y0, y1, fy = coords(oh, H); x0, x1, fx = coords(ow, W_)
    top = x[:, y0][:, :, x0] * (1 - fx) + x[:, y0][:, :, x1] * fx
    bot = x[:, y1][:, :, x0] * (1 - fx) + x[:, y1][:, :, x1] * fx
    return (top * (1 - fy)[None, :, None] + bot * fy[None, :, None]).astype(np.float32)
def run(img_chw, path='/tmp/u2netp.onnx', record=None):
    nodes, inits, inp, outs = o.load(path)
    env = {inp[0]: img_chw[None]}; env.update(inits)
    names = {}   # tensor name -> buffer id for the program
    prog = []
    def T(n): return env[n]
    for n in nodes:
        op = n["op"]; a = n["a"]; ins = [T(i) if i else None for i in n["in"]]; out = n["out"][0]
        if op == "Constant": r = a["value"]["t"] if False else a["value"]["t"]
        elif op == "Conv":
            x = ins[0][0]; r = conv(x, ins[1], ins[2], a["dilations"]["ints"][0], a["pads"]["ints"][0])[None]
            if record is not None: record.append(("conv", n["in"][0], n["in"][1], n["in"][2], out, a["dilations"]["ints"][0], a["pads"]["ints"][0], r.shape[1:]))
        elif op == "Relu":
            r = np.maximum(ins[0], 0)
            if record is not None: record.append(("relu", n["in"][0], out, r.shape[1:]))
        elif op == "MaxPool":
            r = maxpool_ceil(ins[0][0])[None]
            if record is not None: record.append(("pool", n["in"][0], out, r.shape[1:]))
        elif op == "Concat":
            ax = a["axis"]["i"]; r = np.concatenate(ins, axis=ax)
            if record is not None and ax == 1 and ins[0].ndim == 4: record.append(("cat", n["in"], out, r.shape[1:]))
        elif op == "Add":
            r = ins[0] + ins[1]
            if ins[0].ndim == 4 and record is not None: record.append(("add", n["in"][0], n["in"][1], out, r.shape[1:]))
        elif op == "Sigmoid":
            r = 1 / (1 + np.exp(-ins[0]))
            if record is not None: record.append(("sig", n["in"][0], out, r.shape[1:]))
        elif op == "Shape": r = np.array(ins[0].shape, np.int64)
        elif op == "Gather": r = np.take(ins[0], ins[1], axis=a["axis"]["i"] if a["axis"]["i"] is not None else 0)
        elif op == "Unsqueeze": r = ins[0]; [r := np.expand_dims(r, ax) for ax in a["axes"]["ints"]]
        elif op == "Slice":
            st, en = ins[1], ins[2]; ax = ins[3] if len(ins) > 3 and ins[3] is not None else np.arange(len(st)); sp = ins[4] if len(ins) > 4 and ins[4] is not None else np.ones(len(st), int)
            sl = [slice(None)] * ins[0].ndim
            for s_, e_, x_, p_ in zip(st, en, ax, sp): sl[int(x_)] = slice(int(s_), int(e_) if abs(int(e_)) < 2**62 else None, int(p_))
            r = ins[0][tuple(sl)]
        elif op == "Cast": r = ins[0].astype({1: np.float32, 7: np.int64, 6: np.int32}[a["to"]["i"]])
        elif op == "Resize":
            sizes = ins[3] if len(ins) > 3 and ins[3] is not None and ins[3].size else None
            if sizes is None: sc = ins[2]; sizes = (np.array(ins[0].shape) * sc).astype(int)
            r = resize_bilinear(ins[0][0], int(sizes[2]), int(sizes[3]))[None]
            if record is not None: record.append(("up", n["in"][0], out, r.shape[1:]))
        else: raise Exception("op " + op)
        if op == "Constant": env[out] = a["value"]["t"]
        else: env[out] = r
    return [env[x] for x in outs], env, inp[0], outs
def preprocess(pil, S):
    im = pil.convert("RGB").resize((S, S), 3)
    a = np.asarray(im, np.float32) / 255.0; a = a / max(a.max(), 1e-6)
    a = (a - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]
    return a.transpose(2, 0, 1).astype(np.float32)
