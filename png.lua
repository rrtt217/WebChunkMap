-- png.lua
-- 极简 PNG 编码器（8 位 RGB，无隔行），压缩交给 Cuberite 自带的 ZLIB 实现。
-- 这样插件不需要任何外部依赖，也不用把图片写进磁盘。
--
-- Cuberite 的 Lua 是 5.1：没有位运算符，CRC32 需要的 32 位异或用一张
-- 按需构建的字节查表实现（4 位异或表 -> 256x256 字节异或表）。

WCM_Png = {}

local floor = math.floor
local char  = string.char

local XorByte      -- [a * 256 + b] = a XOR b
local CrcT0, CrcT1, CrcT2, CrcT3   -- CRC 表的四个字节平面（见 Crc32）
local CrcTable     -- [n] = CRC32 表项
local TablesReady = false

--- 构建 CRC32 需要的查表（只在第一次编码时做一次）。
local function EnsureTables()
	if TablesReady then
		return
	end

	-- 4 位异或表：
	local Nibble = {}
	for a = 0, 15 do
		local Row = {}
		for b = 0, 15 do
			local Result, Bit, X, Y = 0, 1, a, b
			for _ = 1, 4 do
				if ((X % 2) ~= (Y % 2)) then
					Result = Result + Bit
				end
				X = floor(X / 2)
				Y = floor(Y / 2)
				Bit = Bit * 2
			end
			Row[b] = Result
		end
		Nibble[a] = Row
	end

	-- 由 4 位表拼出 8 位异或表：
	XorByte = {}
	for a = 0, 255 do
		local Base = a * 256
		local aHi, aLo = floor(a / 16), a % 16
		for b = 0, 255 do
			XorByte[Base + b] = Nibble[aHi][floor(b / 16)] * 16 + Nibble[aLo][b % 16]
		end
	end

	CrcTable = {}
	local Poly = 3988292384  -- 0xEDB88320，反转后的 CRC32 多项式
	for n = 0, 255 do
		local C = n
		for _ = 1, 8 do
			if ((C % 2) == 1) then
				C = XorByte[(floor(C / 2) % 256) * 256 + (Poly % 256)]
					+ XorByte[(floor((floor(C / 2)) / 256) % 256) * 256 + (floor(Poly / 256) % 256)] * 256
					+ XorByte[(floor((floor(C / 2)) / 65536) % 256) * 256 + (floor(Poly / 65536) % 256)] * 65536
					+ XorByte[(floor((floor(C / 2)) / 16777216) % 256) * 256 + (floor(Poly / 16777216) % 256)] * 16777216
			else
				C = floor(C / 2)
			end
		end
		CrcTable[n] = C
	end

	-- 把 CRC 表的四个字节平面拆成四张独立小表。
	-- 用途见 Crc32：把 32 位异或按字节平面展开，就不用再调 Xor32 了。
	CrcT0, CrcT1, CrcT2, CrcT3 = {}, {}, {}, {}
	for n = 0, 255 do
		local V = CrcTable[n]
		CrcT0[n] = V % 256
		CrcT1[n] = floor(V / 256) % 256
		CrcT2[n] = floor(V / 65536) % 256
		CrcT3[n] = floor(V / 16777216) % 256
	end

	TablesReady = true
end

--- CRC32（PNG 每个 chunk 的校验和）。
---
--- 为什么把状态拆成四个字节变量（b0 是最低位）：
--- Lua 5.1 没有位运算，32 位异或只能靠查表按字节平面做（见 Xor32）。
--- 原来的写法每字节要调两次 Xor32，每次 4 次查表 + 二十来条 floor/mod/mul/add，
--- 所以 227 KiB 的 IDAT 要花约 100 ms —— 这才是 PNG 编码真正的大头
--- （ZLIB 是原生 C++，只占 3 ms）。
---
--- CRC 的位级更新式是  crc = (crc >> 8) ^ CrcTable[(crc & 0xFF) ^ byte]，
--- 而 crc>>8 恰好就是把最低字节丢掉、b1..b3 顺移一格。逐平面展开后：
---     b0' = b1 ^ T0[Idx]
---     b1' = b2 ^ T1[Idx]
---     b2' = b3 ^ T2[Idx]
---     b3' = 0  ^ T3[Idx]
--- 于是每字节只剩 8 次查表和 5 条算术（乘 256 就是左移一个字节）。
local function Crc32(Data)
	local b0, b1, b2, b3 = 255, 255, 255, 255   -- 初始值 0xFFFFFFFF
	local T0, T1, T2, T3 = CrcT0, CrcT1, CrcT2, CrcT3
	for i = 1, #Data do
		local Idx = XorByte[b0 * 256 + Data:byte(i)]
		b0 = XorByte[b1 * 256 + T0[Idx]]
		b1 = XorByte[b2 * 256 + T1[Idx]]
		b2 = XorByte[b3 * 256 + T2[Idx]]
		b3 = T3[Idx]
	end
	-- 收尾那次异或 0xFFFFFFFF 就是每个字节取反（字节取值范围恰好是 0..255）
	return (255 - b3) * 16777216 + (255 - b2) * 65536 + (255 - b1) * 256 + (255 - b0)
end

--- 大端 32 位整数。
local function U32(N)
	return char(floor(N / 16777216) % 256, floor(N / 65536) % 256, floor(N / 256) % 256, N % 256)
end

--- 一个完整的 PNG chunk：长度 + 类型 + 数据 + CRC。
local function Chunk(Type, Data)
	return U32(#Data) .. Type .. Data .. U32(Crc32(Type .. Data))
end

--- 行滤波。实测地图数据下 "none" **又更快又更小**，所以默认它。
---
--- A/B 实测（48x48 视野 = 768x768 的真实地图，本机）：
---     sub  : PNG 266.5 KiB，渲染 747 ms
---     none : PNG 217.5 KiB，渲染 556 ms
--- 也就是说不滤波快 26%、小 18%。原因：地图是大片同色（海、平原），zlib 的 LZ77
--- 本来就能把这些长重复串压得很好；Sub 把成片同色变成 0 确实也压得动，但每个色块
--- 边界的差值是高熵数据，得不偿失。**PNG 的 Sub 是为照片那种渐变设计的，不适合色块图。**
---（合成数据上差距更大：Sub 16.0 KiB / none 9.0 KiB —— Sub 流里 93.7% 是 0 字节，
---  反而压得比未滤波的更差。）
--- 另外 Sub 是逐字节纯 Lua 运算，1.7 MB 要花约 250 ms；而 ZLIB 是原生 C++，只占 3 ms。
--- 所以真正值钱的是"别做这件事"，而不是"换个更快的库"。
--- 留着 "sub" 是为了万一有人用完全不同的地形还想对比。
local SUBFILTER_BATCH = 2048

local function FilterNone(Row)
	return "\0" .. Row
end

local function FilterSub(Row)
	local Out = {}
	local Buf, Bn = {}, 0
	for i = 1, #Row do
		local Cur = Row:byte(i)
		local Left = 0
		if (i > 3) then
			Left = Row:byte(i - 3)
		end
		Bn = Bn + 1
		Buf[Bn] = (Cur - Left) % 256
		if (Bn >= SUBFILTER_BATCH) then
			Out[#Out + 1] = char(unpack(Buf, 1, Bn))
			Bn = 0
		end
	end
	if (Bn > 0) then
		Out[#Out + 1] = char(unpack(Buf, 1, Bn))
	end
	return "\1" .. table.concat(Out)
end

local FILTERS = {
	none = FilterNone,
	sub  = FilterSub,
}

--- 把 RGB 原始像素编码成 PNG。
-- @param Width, Height 图片尺寸
-- @param Pixels Width*Height*3 字节的原始 RGB 数据（逐行排列）
-- @param Factor ZLIB 压缩等级 0..9
-- @return string PNG 文件内容
function WCM_Png.Encode(Width, Height, Pixels, Factor, FilterName)
	EnsureTables()
	Factor = floor(tonumber(Factor) or 6)
	if (Factor < 0) then Factor = 0 end
	if (Factor > 9) then Factor = 9 end

	-- 不认识的滤波名一律退回 none（它既快又小，是安全的兜底）
	local Filter = FILTERS[FilterName or "none"] or FilterNone

	local Stride = Width * 3
	local Rows = {}
	for y = 0, Height - 1 do
		Rows[#Rows + 1] = Filter(Pixels:sub(y * Stride + 1, y * Stride + Stride))
	end
	local Raw = table.concat(Rows)

	local Idat = cStringCompression.CompressStringZLIB(Raw, Factor)
	local Ihdr = U32(Width) .. U32(Height) .. char(8, 2, 0, 0, 0)  -- 8bit, truecolor, no filter/interlace

	return "\137PNG\r\n\26\n" .. Chunk("IHDR", Ihdr) .. Chunk("IDAT", Idat) .. Chunk("IEND", "")
end
