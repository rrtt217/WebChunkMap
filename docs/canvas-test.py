#!/usr/bin/env python3
"""画布渲染器的验证脚本（迁移期用）。

生成一个测试页（内联一份 payload），页面里用 canvas.js 渲染，
然后用 Playwright 打开它、取回 FNV-1a 指纹与耗时，和这里的 python 期望值比对。

用法：
    python3 docs/canvas-test.py                 # 生成 docs/canvas-test.html + 打印期望指纹
    # 然后用浏览器打开它（file:// 可能被浏览器拦住，起个静态服务最省事）。
    # 注意服务根要设在**插件目录**：测试页用 ../canvas.js 引渲染器。
    #   cd <插件目录> && python3 -m http.server 8899 --bind 127.0.0.1
    #   http://127.0.0.1:8899/docs/canvas-test.html
    # 页面会把结果放在 window.WCM_RESULT

payload 从 cache/last_bin.bin 读 —— 那是 WebChunkMap_BinDump() 落盘的
（控制台/MCP 那边调用它是安全的：只读缓存、不碰 cWorld）。
"""
import base64, struct, sys, zlib, os

FOLDER = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAYLOAD = os.path.join(FOLDER, "cache", "last_bin.bin")
OUT = os.path.join(FOLDER, "docs", "canvas-test.html")


def parse(data):
    flags = data[7]
    size = struct.unpack_from("<H", data, 16)[0]
    gf = struct.unpack_from("<H", data, 18)[0] / 10000.0
    shade = struct.unpack_from("<H", data, 20)[0] / 10000.0
    unk = (data[22], data[23], data[24])
    n = size * size
    states = [0] * n
    pals, idxs, hts = [None] * n, [None] * n, [None] * n
    p = 25
    for i in range(n):
        st = data[p]; p += 1; states[i] = st
        if st == 0:
            continue
        pal = data[p:p + 177]
        cnt = pal[0]
        if cnt > 0:
            pals[i] = pal[1:1 + cnt * 3]
            pk = pal[49:177]
            idxs[i] = [(pk[q >> 1] >> 4) if q % 2 == 0 else (pk[q >> 1] & 15) for q in range(256)]
        else:
            pals[i] = pal[1:769]; idxs[i] = None
        p += 177
        if flags & 1:
            hts[i] = data[p:p + 256]; p += 256
    assert p == len(data), "记录长度对不上：用了 %d，实际 %d" % (p, len(data))
    return dict(flags=flags, size=size, gf=gf, shade=shade, unk=unk,
                states=states, pals=pals, idxs=idxs, hts=hts)


def expected(m):
    """按协议语义重建整张图，返回 (FNV-1a, 每行哈希)。"""
    SH = m["flags"] & 1; GRID = m["flags"] & 2
    size = m["size"]; W = size * 16
    ST = [[int(c * min(1.35, max(0.62, 1 + d * 0.05))) for c in range(256)] for d in range(-8, 9)]
    h = 2166136261; rows = []
    for bz in range(W):
        cz, ty = bz // 16, bz % 16
        rh = 2166136261
        for bx in range(W):
            cx, tx = bx // 16, bx % 16
            gi = cz * size + cx; st = m["states"][gi]
            if st == 0:
                Cr, Cg, Cb = m["unk"]
            else:
                k = ty * 16 + tx; pal = m["pals"][gi]
                if m["idxs"][gi] is None:
                    Cr, Cg, Cb = pal[k * 3], pal[k * 3 + 1], pal[k * 3 + 2]
                else:
                    j = m["idxs"][gi][k]; Cr, Cg, Cb = pal[j * 3], pal[j * 3 + 1], pal[j * 3 + 2]
                if SH and bx > 0 and bz > 0:
                    ngi = ((bz - 1) // 16) * size + ((bx - 1) // 16)
                    nh = m["hts"][ngi]
                    there = nh[(((bz - 1) & 15) * 16) + ((bx - 1) & 15)] if (m["states"][ngi] != 0 and nh) else 0
                    here = m["hts"][gi][k]
                    if here > 0 and there > 0:
                        d = here - there; d = 8 if d > 8 else (-8 if d < -8 else d)
                        if d:
                            T = ST[d + 8]; Cr, Cg, Cb = T[Cr], T[Cg], T[Cb]
                if st == 1 and m["shade"] != 1.0:
                    Cr, Cg, Cb = int(Cr * m["shade"]), int(Cg * m["shade"]), int(Cb * m["shade"])
            if GRID and (tx == 0 or ty == 0):
                Cr, Cg, Cb = int(Cr * m["gf"]), int(Cg * m["gf"]), int(Cb * m["gf"])
            for v in (min(255, Cr), min(255, Cg), min(255, Cb)):
                h ^= v; h = (h * 16777619) & 0xFFFFFFFF
                rh ^= v; rh = (rh * 16777619) & 0xFFFFFFFF
        if bz < 8:
            rows.append(rh)
    return h, rows


def main():
    raw = zlib.decompress(open(PAYLOAD, "rb").read())
    m = parse(raw)
    fnv, rows = expected(m)
    b64 = base64.b64encode(open(PAYLOAD, "rb").read()).decode()
    page = """<!DOCTYPE html><html><head><meta charset=utf-8><title>WCM canvas test</title></head>
<body><canvas id=c></canvas>
<script src="../canvas.js"></script>
<script>
const B64 = "%s";
(async function () {
 try {
  const canvas = document.getElementById("c");
  const comp = WCMCanvas.b64ToBytes(B64);
  const R = await WCMCanvas.draw(canvas, comp);
  let h = 2166136261 >>> 0;
  for (let i = 0; i < R.Image.Pixels.length; i += 4) {
    for (let k = 0; k < 3; k++) { h ^= R.Image.Pixels[i + k]; h = Math.imul(h, 16777619) >>> 0; }
  }
  const rows = [];
  for (let y = 0; y < 8; y++) {
    let hh = 2166136261 >>> 0;
    for (let x = 0; x < R.Image.Width; x++) for (let k = 0; k < 3; k++) {
      hh ^= R.Image.Pixels[(y * R.Image.Width + x) * 4 + k]; hh = Math.imul(hh, 16777619) >>> 0;
    }
    rows.push(hh >>> 0);
  }
  window.WCM_RESULT = { ok: true, W: R.Image.Width, H: R.Image.Height, fnv: h >>> 0, rowHash: rows,
    decodeMs: +R.DecodeMs.toFixed(1), renderMs: +R.RenderMs.toFixed(1), putMs: +R.PutMs.toFixed(1), totalMs: +R.TotalMs.toFixed(1) };
 } catch (e) { window.WCM_RESULT = { ok: false, err: String(e) }; }
})();
</script></body></html>""" % b64
    open(OUT, "w").write(page)
    print("测试页: docs/canvas-test.html（%.0f KiB）" % (len(page) / 1024))
    print("期望 FNV  = %d" % fnv)
    print("期望行哈希 = %s" % rows)


if __name__ == "__main__":
    main()
