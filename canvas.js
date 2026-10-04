// WebChunkMap 画布渲染器（协议 v1）—— 服务端只发"预打包调色板 / 群系 / 状态"，
// 逐像素的颜色展开、山体阴影、区块网格线全部在这里做。
//
// 为什么值得这么做（实测，48x48 视野 = 768x768 = 2304 个区块）：
//     服务端纯 Lua：像素合成 ~216 ms + PNG 编码 ~60 ms，而且占着世界 tick 线程
//     浏览器：     解压 5 ms + 渲染 28 ms + 上屏 4 ms = 38 ms，且完全不占服务端
// 而且这条路是"逐像素精确"的 —— 实测重建结果与服务端 PNG 逐字节一致
// （FNV-1a 与逐行哈希都对上，见 docs/canvas-test.py）。
//
// 协议（小端）：
//     头部 27 字节：
//         "WCMB" | u16 版本 | u8 mode(0 topo / 1 chunks / 2 biome) | u8 flags(bit0 阴影 bit1 网格)
//         i32 originChunkX | i32 originChunkZ | u16 sizeChunks
//         u16 gridFactor*10000 | u16 rememberedShade*10000 | u8 unknownR,G,B
//         u16 extraLen
//     然后是 extraLen 字节的扩展段（按 mode）：
//         chunks: 3 组状态配色（未知 / 记忆 / 实时），每组 RGB
//         biome:  u8 无群系 RGB | u16 表长 | 表长 x (u8 群系id, u8 R, u8 G, u8 B)
//         topo:   u8 RGB(全 0) | u16 0
//     随后按行优先，每个区块：
//         u8 state（0 未知 / 1 记忆 / 2 实时）
//           topo:   state != 0 时跟 177 字节调色板段 +（开阴影时）256 字节高度
//                   调色板段 = u8 颜色数 + 最多 16 个 RGB + 128 字节 4 位索引
//                              颜色数为 0 表示"颜色超过 16 种"，此时换成 768 字节 RGB
//           chunks: 状态字节就是全部 —— 这一层因此只有 1 B/区块
//           biome:  state != 0 时跟 256 字节群系 id（颜色查扩展段里的表）
//
// ⚠ 两个踩过的坑：
//   1. 阴影查表**必须用 Uint16Array 之类**，不能用 Uint8Array ——
//      floor(255 * 1.35) = 344 会被 Uint8Array 回绕成 88，表现为个别像素出现
//      诡异的小数值（实测每行 1 个像素，255 变成 3）。
//   2. gridFactor / rememberedShade 在协议里是 **u16 存 4 位小数**，不是一个字节：
//      一个字节的量化误差（0.16%）会让网格线的 floor(Cr*F) 和服务端差 1，
//      实测造成 4.4 万个像素不一致。
var WCMCanvas = (function () {
	"use strict";

	var HEADER_BYTES = 27;
	var REC_PALETTE = 177;
	var REC_HEIGHTS = 256;
	var MODE_TOPO = 0, MODE_CHUNKS = 1, MODE_BIOME = 2;

	// 阴影系数：高度差 d 被夹在 ±8，所以只有 17 种；做成查表省掉每像素的浮点乘。
	// 值可能超过 255（F 最大 1.35），所以用 Uint16Array。
	function buildShadeTables() {
		var T = [];
		for (var d = -8; d <= 8; d++) {
			var F = Math.min(1.35, Math.max(0.62, 1 + d * 0.05));
			var t = new Uint16Array(256);
			for (var c = 0; c < 256; c++) {
				t[c] = Math.floor(c * F);
			}
			T.push(t);
		}
		return T;
	}
	var ST = buildShadeTables();

	/// 解析 payload（不解压）。三种图层共用同一个头部，记录部分按 mode 分派。
	function decode(buf) {
		var dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
		var magic = String.fromCharCode(buf[0], buf[1], buf[2], buf[3]);
		if (magic !== "WCMB") {
			throw new Error("不是画布 payload（magic=" + magic + "）");
		}
		var p = 4;
		var ver = dv.getUint16(p, true); p += 2;
		if (ver !== 1) {
			throw new Error("画布协议版本不支持：" + ver);
		}
		var mode = buf[p++];
		var flags = buf[p++];
		var originCX = dv.getInt32(p, true); p += 4;
		var originCZ = dv.getInt32(p, true); p += 4;
		var size = dv.getUint16(p, true); p += 2;
		var gridFactor = dv.getUint16(p, true) / 10000; p += 2;
		var shade = dv.getUint16(p, true) / 10000; p += 2;
		var unkR = buf[p++], unkG = buf[p++], unkB = buf[p++];
		var extraLen = dv.getUint16(p, true); p += 2;
		if (p !== HEADER_BYTES) {
			throw new Error("头部长度对不上");
		}

		// 扩展段：chunks / biome 图层要的颜色表
		var noBiome = [96, 100, 110];
		var biomeCols = {};
		var stateCols = [[62, 66, 78], [150, 158, 102], [96, 160, 82]];
		var q = p;
		noBiome = [buf[q], buf[q + 1], buf[q + 2]]; q += 3;
		if (mode === MODE_CHUNKS) {
			for (var s = 0; s < 3; s++) {
				stateCols[s] = [buf[q], buf[q + 1], buf[q + 2]]; q += 3;
			}
		} else if (mode === MODE_BIOME) {
			var bc = dv.getUint16(q, true); q += 2;
			for (var bi = 0; bi < bc; bi++) {
				biomeCols[buf[q]] = [buf[q + 1], buf[q + 2], buf[q + 3]]; q += 4;
			}
		}
		p += extraLen;

		var n = size * size;
		var states = new Uint8Array(n);
		var pals = new Array(n);      // topo：调色板 RGB
		var idxs = new Array(n);      // topo：4 位索引；null = 用 768 字节 RGB 段
		var hts = new Array(n);       // topo：高度
		var bios = new Array(n);      // biome：群系 id

		for (var i = 0; i < n; i++) {
			var st = buf[p++];
			states[i] = st;
			if (st === 0) {
				continue;
			}
			if (mode === MODE_CHUNKS) {
				continue;                       // 状态字节就是全部
			}
			if (mode === MODE_BIOME) {
				bios[i] = buf.subarray(p, p + REC_HEIGHTS);
				p += REC_HEIGHTS;
				continue;
			}
			var cnt = buf[p];
			if (cnt > 0) {
				pals[i] = buf.subarray(p + 1, p + 1 + cnt * 3);
				var pk = buf.subarray(p + 49, p + REC_PALETTE);
				var ii = new Uint8Array(256);
				for (var k = 0; k < 256; k++) {
					ii[k] = (k & 1) ? (pk[k >> 1] & 15) : (pk[k >> 1] >> 4);
				}
				idxs[i] = ii;
			} else {
				pals[i] = buf.subarray(p + 1, p + 769);
				idxs[i] = null;
			}
			p += REC_PALETTE;
			if (flags & 1) {
				hts[i] = buf.subarray(p, p + REC_HEIGHTS);
				p += REC_HEIGHTS;
			}
		}

		return {
			Mode: mode, Flags: flags, SizeChunks: size,
			OriginChunkX: originCX, OriginChunkZ: originCZ,
			GridFactor: gridFactor, RememberedShade: shade,
			Unknown: [unkR, unkG, unkB],
			NoBiome: noBiome, BiomeColors: biomeCols, StateColors: stateCols,
			States: states, Palettes: pals, Indices: idxs, Heights: hts, Biomes: bios,
			BytesUsed: p
		};
	}

	/// 合成到 RGBA（返回可直接 putImageData 的 Uint8ClampedArray）。
	function compose(M) {
		var size = M.SizeChunks;
		var W = size * 16, H = W;
		var SHADING = (M.Flags & 1) !== 0;
		var DRAWGRID = (M.Flags & 2) !== 0;
		var gf = M.GridFactor, shade = M.RememberedShade;
		var IsChunks = (M.Mode === MODE_CHUNKS);
		var IsBiome = (M.Mode === MODE_BIOME);
		var out = new Uint8ClampedArray(W * H * 4);

		for (var bz = 0; bz < H; bz++) {
			var cz = (bz / 16) | 0, ty = bz & 15;
			for (var bx = 0; bx < W; bx++) {
				var cx = (bx / 16) | 0, tx = bx & 15;
				var gi = cz * size + cx;
				var st = M.States[gi];
				var k = ty * 16 + tx;
				var Cr, Cg, Cb;

				if (IsChunks) {
					var SC = M.StateColors[st] || M.StateColors[0];
					Cr = SC[0]; Cg = SC[1]; Cb = SC[2];
				} else if (IsBiome) {
					var Seg = M.Biomes[gi];
					var B = Seg ? Seg[k] : 0;
					var BC = M.BiomeColors[B] || M.NoBiome;
					Cr = BC[0]; Cg = BC[1]; Cb = BC[2];
				} else if (st === 0) {
					Cr = M.Unknown[0]; Cg = M.Unknown[1]; Cb = M.Unknown[2];
				} else {
					var pal = M.Palettes[gi];
					var ii = M.Indices[gi];
					if (ii === null) {
						Cr = pal[k * 3]; Cg = pal[k * 3 + 1]; Cb = pal[k * 3 + 2];
					} else {
						var j = ii[k];
						Cr = pal[j * 3]; Cg = pal[j * 3 + 1]; Cb = pal[j * 3 + 2];
					}

					// 山体阴影：向西北邻居取高度，跨区块连续。
					// 注意服务端的阴影只对 state != 0 的区块生效，这里也是。
					if (SHADING && bx > 0 && bz > 0) {
						var ngi = (((bz - 1) / 16) | 0) * size + (((bx - 1) / 16) | 0);
						var nh = M.Heights[ngi];
						var there = (M.States[ngi] !== 0 && nh) ? nh[(((bz - 1) & 15) * 16) + ((bx - 1) & 15)] : 0;
						var here = M.Heights[gi][k];
						if (here > 0 && there > 0) {
							var d = here - there;
							if (d > 8) { d = 8; } else if (d < -8) { d = -8; }
							if (d !== 0) {
								var T = ST[d + 8];
								Cr = T[Cr]; Cg = T[Cg]; Cb = T[Cb];
							}
						}
					}

					if (st === 1 && shade !== 1) {
						Cr = Math.floor(Cr * shade);
						Cg = Math.floor(Cg * shade);
						Cb = Math.floor(Cb * shade);
					}
				}

				if (DRAWGRID && (tx === 0 || ty === 0)) {
					Cr = Math.floor(Cr * gf);
					Cg = Math.floor(Cg * gf);
					Cb = Math.floor(Cb * gf);
				}

				var o = (bz * W + bx) * 4;
				out[o] = Cr > 255 ? 255 : Cr;
				out[o + 1] = Cg > 255 ? 255 : Cg;
				out[o + 2] = Cb > 255 ? 255 : Cb;
				out[o + 3] = 255;
			}
		}
		return { Width: W, Height: H, Pixels: out };
	}

	/// 解压 -> 解析 -> 合成 -> 上屏。返回 {Ok, Ms, Meta}。
	async function draw(canvas, compressed) {
		var T0 = performance.now();
		var ds = new DecompressionStream("deflate");
		var w = ds.writable.getWriter();
		w.write(compressed);
		w.close();
		var raw = new Uint8Array(await new Response(ds.readable).arrayBuffer());
		var T1 = performance.now();
		var M = decode(raw);
		var img = compose(M);
		var T2 = performance.now();
		canvas.width = img.Width;
		canvas.height = img.Height;
		var ctx = canvas.getContext("2d");
		var id = ctx.createImageData(img.Width, img.Height);
		id.data.set(img.Pixels);
		ctx.putImageData(id, 0, 0);
		var T3 = performance.now();
		return {
			Ok: true, Model: M, Image: img,
			DecodeMs: T1 - T0, RenderMs: T2 - T1, PutMs: T3 - T2, TotalMs: T3 - T0
		};
	}

	function b64ToBytes(s) {
		var bin = atob(s);
		var a = new Uint8Array(bin.length);
		for (var i = 0; i < bin.length; i++) {
			a[i] = bin.charCodeAt(i);
		}
		return a;
	}

	return { decode: decode, compose: compose, draw: draw, b64ToBytes: b64ToBytes, HEADER_BYTES: HEADER_BYTES };
})();