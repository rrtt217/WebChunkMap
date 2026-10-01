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

	TablesReady = true
end

--- 32 位异或（操作数在 0 .. 2^32-1 之间）。
local function Xor32(A, B)
	return XorByte[(floor(A / 16777216) % 256) * 256 + (floor(B / 16777216) % 256)] * 16777216
	     + XorByte[(floor(A / 65536) % 256) * 256 + (floor(B / 65536) % 256)] * 65536
	     + XorByte[(floor(A / 256) % 256) * 256 + (floor(B / 256) % 256)] * 256
	     + XorByte[(A % 256) * 256 + (B % 256)]
end

--- CRC32（PNG 每个 chunk 的校验和）。
local function Crc32(Data)
	local Crc = 4294967295  -- 0xFFFFFFFF
	for i = 1, #Data do
		local Idx = XorByte[(Crc % 256) * 256 + Data:byte(i)]
		Crc = Xor32(CrcTable[Idx], floor(Crc / 256))
	end
	return Xor32(Crc, 4294967295)
end

--- 大端 32 位整数。
local function U32(N)
	return char(floor(N / 16777216) % 256, floor(N / 65536) % 256, floor(N / 256) % 256, N % 256)
end

--- 一个完整的 PNG chunk：长度 + 类型 + 数据 + CRC。
local function Chunk(Type, Data)
	return U32(#Data) .. Type .. Data .. U32(Crc32(Type .. Data))
end

--- 把一行原始像素做 Sub 滤波（PNG filter type 1），对成片同色区域压缩率提升明显。
local function SubFilter(Row)
	local Out = { "\1" }
	local n = 0
	local Bpp = 3
	for i = 1, #Row do
		local Cur = Row:byte(i)
		local Left = 0
		if (i > Bpp) then
			Left = Row:byte(i - Bpp)
		end
		n = n + 1
		Out[n + 1] = char((Cur - Left) % 256)
	end
	return table.concat(Out)
end

--- 把 RGB 原始像素编码成 PNG。
-- @param Width, Height 图片尺寸
-- @param Pixels Width*Height*3 字节的原始 RGB 数据（逐行排列）
-- @param Factor ZLIB 压缩等级 0..9
-- @return string PNG 文件内容
function WCM_Png.Encode(Width, Height, Pixels, Factor)
	EnsureTables()
	Factor = floor(tonumber(Factor) or 6)
	if (Factor < 0) then Factor = 0 end
	if (Factor > 9) then Factor = 9 end

	local Stride = Width * 3
	local Rows = {}
	for y = 0, Height - 1 do
		Rows[#Rows + 1] = SubFilter(Pixels:sub(y * Stride + 1, y * Stride + Stride))
	end
	local Raw = table.concat(Rows)

	local Idat = cStringCompression.CompressStringZLIB(Raw, Factor)
	local Ihdr = U32(Width) .. U32(Height) .. char(8, 2, 0, 0, 0)  -- 8bit, truecolor, no filter/interlace

	return "\137PNG\r\n\26\n" .. Chunk("IHDR", Ihdr) .. Chunk("IDAT", Idat) .. Chunk("IEND", "")
end
