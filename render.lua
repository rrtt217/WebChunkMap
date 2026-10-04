-- render.lua
-- 区块级渲染 + “曾经加载过”的区块快照缓存。
--
-- 每个区块只缓存 1024 字节，而不是 16x16x256 的方块数据：
--     768 字节 = 16x16 的顶面颜色（RGB）
--     256 字节 = 16x16 的地表高度（h+1，0 表示未知）
-- 山体阴影、区块网格、玩家标记都在合成阶段叠加，所以改这些配置不需要重建快照。
--
-- 区块一旦被加载过就会留下快照；之后即使区块被引擎卸载，地图仍然能画出地形。

WCM_Render = {}

local R = WCM_Render
local floor = math.floor
local char = string.char
local concat = table.concat

R.Config = {
	MaxSizeChunks = 48,
	MaxPixels = 1000000,
	CacheTTL = 600,           -- 图片缓存的“后台刷新”阈值；不决定本次请求能否用缓存
	MaxCacheEntries = 24,
	DrawChunkGrid = true,
	HillShading = true,
	DrawPlayers = true,
	DrawSpawn = true,
	DrawStructures = true,    -- 在地图上标出结构位置（跨插件调用 VanillaFeatureComplement 的 Locate API）
	PngFactor = 6,
	PngFilter = "none",
	-- 山体阴影降采样倍率：1 = 每像素都算，2 = 每两像素算一次（省一半推导开销）
	ShadeDownsample = 2,
	CanvasPayload = true,     -- 渲染时顺带产出画布版二进制 payload（协议 v1）
	CanvasOnly = false,       -- 只要画布 payload、不出 PNG（跳过整个像素合成，省最多）

	RememberTiles = true,     -- 是否记住曾经加载过的区块
	RememberedShade = 1.0,    -- 记忆中的区块的压暗系数（1.0 = 与实时一致）
	MaxTiles = 6000,          -- 快照数量上限（每个约 1 KiB 内存 + 磁盘）
	-- 区块详情缓存的上限。它是内部安全边界，故意不放进 settings.ini：
	-- 暴露出去只会鼓励别人调大从而失去保护。丢了会自愈（面板显示 … 再排 info 任务补回来）。
	MaxChunkInfo = 4096,
	-- 一个世界里"已加载区块"的总量阀门。0 = 不限。
	-- 区块是内存大头（实测约 150~200 KB/个，由 Cuberite 的 chunkmap 持有），
	-- 插件能无限往里灌 —— 小内存机器（树莓派等）必须设一个数，参考：可用内存 MiB ÷ 0.2。
	MaxLoadedChunks = 0,
	SaveInterval = 300,       -- 快照落盘间隔（秒）
	AutoLoadOnView = true,    -- 渲染后自动把“从未见过”的区块排进加载队列
	AutoLoadMaxChunks = 256,
	AutoLoadCooldown = 5,
}

-- 界面上可选的视野档位。受像素预算收缩时也只会落到这些档位，
-- 不会产生 31 这种下拉框里没有的值。
R.SizeSteps = { 2, 4, 8, 16, 24, 32, 48 }

R.Cache = {}          -- 图片缓存：Key -> { Time, Png, Meta }
R.CacheOrder = {}
R.Tiles = {}          -- [世界名] = { [chunkKey] = 1024 字节快照 }
R.TileOrder = {}      -- [世界名] = { chunkKey, ... }，FIFO 淘汰用
R.TileCount = {}      -- [世界名] = 快照数
R.Dirty = {}          -- [世界名] = true 表示有未落盘的改动
R.LastSave = 0
R.PluginFolder = nil
R.Stats = { Renders = 0, CacheHits = 0, LiveTiles = 0, ReusedTiles = 0, LastRenderMs = 0, TileBuilds = 0,
	-- 分阶段 CPU 时间累计（秒），配合 WebChunkMap_ProfDump() 看各阶段占比
	PhaseGrid = 0, PhaseMarkers = 0, PhaseStruct = 0, PhasePixels = 0, PhasePng = 0, PhaseBin = 0 }

local TILE_COLORS  = 768    -- 16 * 16 * 3  顶面颜色
local TILE_HEIGHTS = 256    -- 16 * 16      地表高度（h+1，0 = 未知）
local TILE_BIOMES  = 256    -- 16 * 16      生物群系（biome+1，0 = 未知）
local OFF_HEIGHTS  = TILE_COLORS
local OFF_BIOMES   = TILE_COLORS + TILE_HEIGHTS
-- v3 追加的"调色板形式"段（见 BuildPaletteForm 的说明），固定 177 字节
local PAL_MAX      = 16     -- 调色板最多 16 色（实测每个区块最多 10 色）
local PAL_COUNT    = 1
local PAL_RGB      = PAL_MAX * 3
local PAL_INDICES  = TILE_HEIGHTS / 2   -- 256 个像素 x 4 位 = 128 字节
local TILE_EXTRA   = PAL_COUNT + PAL_RGB + PAL_INDICES
local TILE_BASE    = TILE_COLORS + TILE_HEIGHTS + TILE_BIOMES
local TILE_SIZE    = TILE_BASE + TILE_EXTRA
local OFF_PALCOUNT = TILE_BASE
local OFF_PALETTE  = TILE_BASE + PAL_COUNT
local OFF_INDICES  = OFF_PALETTE + PAL_RGB

R.OFF_PALCOUNT, R.OFF_PALETTE, R.OFF_INDICES, R.TILE_SIZE = OFF_PALCOUNT, OFF_PALETTE, OFF_INDICES, TILE_SIZE

--- 从 768 字节颜色段生成 v3 的"调色板形式"扩展段（177 字节）：
---   [0]        调色板颜色数；**0 表示颜色种类超过 16**，调用方应回退用 RGB 段
---   [1..48]    最多 16 个 RGB 三元组（不足的补 0）
---   [49..176]  4 位索引，每字节两个像素（256 像素 = 128 字节）
---
--- 为什么要在这里预打包：实测 6000 个区块，每个区块顶面**最多只有 10 种颜色、
--- 100% 不超过 16 种**，所以 4 位索引是**无损**的，压缩后也比 RGB 小得多。
--- 关键是不能在渲染时打包 —— Lua 里逐像素建表 + 打包的成本和现在的像素循环
--- 同量级，那样画布迁移省下的 CPU 就全还回去了。所以随快照一起算一次、存盘。
local function BuildPaletteForm(ColorSeg)
	local Seen, Pal, Idx = {}, {}, {}
	for i = 0, 255 do
		local C = ColorSeg:sub(i * 3 + 1, i * 3 + 3)
		local n = Seen[C]
		if (n == nil) then
			if (#Pal >= PAL_MAX) then
				-- 极少数颜色太杂的区块：标记 0，渲染时回退到 RGB 段
				return char(0) .. char(0):rep(TILE_EXTRA - 1)
			end
			n = #Pal
			Seen[C] = n
			Pal[n + 1] = C
		end
		Idx[i + 1] = n
	end
	local Packed = {}
	for i = 1, 256, 2 do
		Packed[(i + 1) / 2] = char(Idx[i] * 16 + Idx[i + 1])
	end
	return char(#Pal) .. concat(Pal) .. char(0):rep((PAL_MAX - #Pal) * 3) .. concat(Packed)
end

--- 把 v2 的 1280 字节快照补上调色板段，升级成 v3。
local function UpgradeTileToV3(Tile)
	return Tile .. BuildPaletteForm(Tile:sub(1, TILE_COLORS))
end

--- 把 v3 快照里的调色板形式还原成 768 字节 RGB（自检与协议都用得到）。
--- 返回 nil 表示这个区块是"颜色超过 16 种"的回退情况，应改用 RGB 段。
function R.TilePaletteRGB(Tile)
	local N = Tile:byte(OFF_PALCOUNT + 1)
	if (N == nil) or (N == 0) then
		return nil
	end
	local Pal = Tile:sub(OFF_PALETTE + 1, OFF_PALETTE + PAL_RGB)
	local Packed = Tile:sub(OFF_INDICES + 1, OFF_INDICES + PAL_INDICES)
	local Out = {}
	for i = 0, 255 do
		local B = Packed:byte(floor(i / 2) + 1)
		local n
		if ((i % 2) == 0) then
			n = floor(B / 16)
		else
			n = B % 16
		end
		Out[i + 1] = Pal:sub(n * 3 + 1, n * 3 + 3)
	end
	return concat(Out)
end

local MAGIC = "WCMT"
-- 3 = 在 v2 的 1280 字节后面追加了"调色板形式"段（见 BuildPaletteForm）。
-- 加载器**仍然接受 v2** 并就地升级，所以升级不会丢掉已经攒下的快照。
local VERSION = 3

local function Log(Msg)
	LOG("WebChunkMap: " .. Msg)
end

R.Log = Log

--- 合并配置（Initialize 里从 settings.ini 读出后调用）。
function R.Configure(Cfg)
	for K, V in pairs(Cfg) do
		if (V ~= nil) then
			R.Config[K] = V
		end
	end
end

R.TickCount = 0

--- ChunkStay 统计：跨插件/引擎侧唯一能观察到"悬住的 stay"的地方。
--- 为什么需要：ChunkStay 的完成回调只在**所有**区块就绪时才触发，
--- 而被过载的生成器 skip 掉的区块可能永远不就绪 —— 那样这些区块会一直被钉住
---（stay 标记让 QueueUnloadUnusedChunks 不会卸载它们），而 Lua 这边看上去一切正常。
--- Started 与 Done 长期对不上，就是有 stay 悬住了。
R.StayStats = {
	Started = 0,   -- 发起过多少个 ChunkStay
	Done    = 0,   -- 其中多少个回调真的回来了
	Chunks  = 0,   -- 累计请求过多少个区块
}

local function Now()
	if (os ~= nil) and (os.time ~= nil) then
		return os.time()
	end
	-- 兜底：不要用 cRoot:Get():GetServerUpTime()，避免在世界的 tick 线程上碰 cRoot
	return floor(R.TickCount / 20)
end

R.Now = Now

--- 山体阴影的"颜色级"查表 —— 每像素省掉 3 次 math.floor（那是 C 调用）。
---
--- 明暗系数 F 被夹在 [0.62, 1.35]，高度差又是整数，所以按 F 的**实际取值**
--- 只有 DC in -8..8 这 17 种。于是可以先把 floor(通道值 * F) 全算好：
---     Cr = floor(Cr * F)   -->   Cr = ShadeTab[DC + 8][Cr]
--- 把 "3 次 C 调用 + 3 次浮点乘" 换成 "3 次表索引"。
--- 这是**逐字节等价**的改写（表里存的就是 floor(c * F) 的原值，不是近似）。
local ShadeTab = {}
for DC = -8, 8 do
	local F = 1 + DC * 0.05
	if (F > 1.35) then F = 1.35 end
	if (F < 0.62) then F = 0.62 end
	local T = {}
	for c = 0, 255 do
		T[c] = floor(c * F)
	end
	ShadeTab[DC + 8] = T
end

local function Clock()
	if (os ~= nil) and (os.clock ~= nil) then
		return os.clock()
	end
	return 0
end

--- 清空图片缓存（不影响区块快照）。
function R.FlushCache()
	R.Cache = {}
	R.CacheOrder = {}
end

----------------------------------------------------------------------
-- 区块快照的存取
----------------------------------------------------------------------

--- 区块坐标 -> 唯一数字键（坐标范围 ±1048576 足够任何实际地图）。
local function ChunkKey(CX, CZ)
	return (CX + 1048576) * 2097152 + (CZ + 1048576)
end

R.ChunkKey = ChunkKey

--- 一个“未见过”的区块用的占位快照。
local UnknownTileCache = nil
function R.UnknownTile()
	if (UnknownTileCache == nil) then
		local C = WCM_Blocks.Unloaded
		local Px = char(C[1], C[2], C[3])
		local Colors = {}
		for i = 1, TILE_HEIGHTS do
			Colors[i] = Px
		end
		local Seg = concat(Colors)
		UnknownTileCache = Seg .. char(0):rep(TILE_HEIGHTS + TILE_BIOMES) .. BuildPaletteForm(Seg)
	end
	return UnknownTileCache
end

function R.GetTile(WorldName, CX, CZ)
	local Tiles = R.Tiles[WorldName]
	if (Tiles == nil) then
		return nil
	end
	return Tiles[ChunkKey(CX, CZ)]
end

function R.TileStats(WorldName)
	if (WorldName ~= nil) then
		return R.TileCount[WorldName] or 0
	end
	local Total = 0
	for _, N in pairs(R.TileCount) do
		Total = Total + N
	end
	return Total
end

function R.IsDirty()
	for _, V in pairs(R.Dirty) do
		if V then
			return true
		end
	end
	return false
end

--- 写入 / 更新一个区块快照。
function R.PutTile(WorldName, CX, CZ, Tile, Loading)
	local Tiles = R.Tiles[WorldName]
	if (Tiles == nil) then
		Tiles = {}
		R.Tiles[WorldName] = Tiles
		R.TileOrder[WorldName] = {}
		R.TileCount[WorldName] = 0
	end

	local Key = ChunkKey(CX, CZ)
	if (Tiles[Key] ~= nil) then
		Tiles[Key] = Tile
	else
		Tiles[Key] = Tile
		R.TileCount[WorldName] = (R.TileCount[WorldName] or 0) + 1
		local Order = R.TileOrder[WorldName]
		Order[#Order + 1] = Key

		-- 超出上限时按写入顺序淘汰最旧的快照
		local Max = R.Config.MaxTiles
		while (#Order > Max) do
			local Old = table.remove(Order, 1)
			if (Tiles[Old] ~= nil) then
				Tiles[Old] = nil
				R.TileCount[WorldName] = R.TileCount[WorldName] - 1
			end
		end
	end

	if not Loading then
		R.Dirty[WorldName] = true
	end
end

--- 忘掉一个区块的快照（地图上会重新变成“未知”）。
function R.ForgetTile(WorldName, CX, CZ)
	local Tiles = R.Tiles[WorldName]
	if (Tiles == nil) then
		return false
	end
	local Key = ChunkKey(CX, CZ)
	if (Tiles[Key] == nil) then
		return false
	end
	Tiles[Key] = nil
	R.TileCount[WorldName] = R.TileCount[WorldName] - 1
	R.Dirty[WorldName] = true

	-- 必须把键从 FIFO 里摘掉。否则这个键会在 Order 里留下一条"失效条目"，
	-- 而它指向的键之后可能被重新写入 —— 淘汰时弹出这条失效条目就会把
	-- **刚写进去的活快照**删掉。（同样的重复键 bug 在 CacheOrder 上也有一份。）
	-- O(n)，但 forget / regen 都是用户手动、罕见，且单次最多 64 个，可以接受。
	local Order = R.TileOrder[WorldName]
	if (Order ~= nil) then
		for i = #Order, 1, -1 do
			if (Order[i] == Key) then
				table.remove(Order, i)
			end
		end
	end
	return true
end

----------------------------------------------------------------------
-- 区块快照的持久化
----------------------------------------------------------------------

local function PackU16(N)
	return char(N % 256, floor(N / 256) % 256)
end

local function PackU32(N)
	return char(N % 256, floor(N / 256) % 256, floor(N / 65536) % 256, floor(N / 16777216) % 256)
end

local function PackI32(N)
	if (N < 0) then
		N = N + 4294967296
	end
	return PackU32(N)
end

local function UnpackU16(S, P)
	local A, B = S:byte(P, P + 1)
	if (A == nil) then
		return nil
	end
	return A + B * 256
end

local function UnpackU32(S, P)
	local A, B, C, D = S:byte(P, P + 3)
	if (A == nil) then
		return nil
	end
	return A + B * 256 + C * 65536 + D * 16777216
end

local function UnpackI32(S, P)
	local N = UnpackU32(S, P)
	if (N == nil) then
		return nil
	end
	if (N >= 2147483648) then
		N = N - 4294967296
	end
	return N
end

local function TileFile()
	if (R.PluginFolder == nil) then
		return nil
	end
	return R.PluginFolder .. "/cache/tiles.bin"
end

--- 把快照写入磁盘（先写 .tmp 再改名，避免写一半损坏）。
function R.SaveTiles(Force)
	if (not Force) and (not R.IsDirty()) then
		return 0, "clean"
	end
	local Path = TileFile()
	if (Path == nil) then
		return 0, "no-folder"
	end
	if (io == nil) or (io.open == nil) then
		return 0, "no-io"
	end

	-- 第一趟只数数（不建任何字符串）：文件头的记录数得先知道。
	-- 原来是把全部记录攒进 Body 再一次 concat，于是同时攥住 ~8 MB 记录
	-- 加 7.6 MB 拼接结果；而且打日志时又 concat 了一遍，等于每次落盘拷两次全量。
	local Count = 0
	for WorldName, Tiles in pairs(R.Tiles) do
		if (#WorldName <= 255) then
			for _ in pairs(Tiles) do
				Count = Count + 1
			end
		end
	end

	local F = io.open(Path .. ".tmp", "wb")
	if (F == nil) then
		if (os ~= nil) and (os.execute ~= nil) then
			os.execute("mkdir -p '" .. R.PluginFolder .. "/cache'")
			F = io.open(Path .. ".tmp", "wb")
		end
	end
	if (F == nil) then
		Log("无法写入快照文件 " .. Path .. "（cache 目录不存在？）")
		return 0, "open-failed"
	end

	F:write(MAGIC, PackU16(VERSION), PackU32(Count))

	-- 第二趟分批写：峰值 ≈ 一批（512 条约 0.7 MB），而不是"全部记录 + 全量拼接"两倍。
	-- 顺带把 char(NameLen) .. WorldName 提到世界循环外，每个区块少一次拼接。
	-- 分批写：峰值 ≈ 一批（512 条约 0.7 MB），而不是"全部记录 + 全量拼接"两倍。
	-- 顺带把 char(NameLen) .. WorldName 提到世界循环外，每个区块少一次拼接。
	local Batch, Bytes = {}, 0
	local function Flush()
		if (#Batch == 0) then
			return
		end
		local S = concat(Batch)
		F:write(S)
		Bytes = Bytes + #S
		Batch = {}
	end
	for WorldName, Tiles in pairs(R.Tiles) do
		local NameLen = #WorldName
		if (NameLen <= 255) then
			local Prefix = char(NameLen) .. WorldName
			for Key, Tile in pairs(Tiles) do
				local CX = floor(Key / 2097152) - 1048576
				local CZ = (Key % 2097152) - 1048576
				Batch[#Batch + 1] = Prefix .. PackI32(CX) .. PackI32(CZ) .. Tile
				if (#Batch >= 512) then
					Flush()
				end
			end
		end
	end
	Flush()
	F:close()

	if (os ~= nil) and (os.rename ~= nil) then
		os.rename(Path .. ".tmp", Path)
	end

	R.Dirty = {}
	R.LastSave = Now()
	-- 字节数在写的时候累计，不要再 concat 一遍全量（那是 7.6 MB 的纯浪费）
	Log(string.format("区块快照已保存：%d 个区块，%.1f KiB", Count, (Bytes + 11) / 1024))
	return Count, "saved"
end

--- 从磁盘载入快照。
function R.LoadTiles(Folder)
	R.PluginFolder = Folder
	R.LastSave = Now()

	if (io == nil) or (io.open == nil) then
		Log("运行环境没有 io 库，区块快照不会持久化")
		return 0
	end

	local Path = Folder .. "/cache/tiles.bin"
	local F = io.open(Path, "rb")
	if (F == nil) then
		Log("没有历史区块快照（" .. Path .. " 不存在）")
		return 0
	end

	-- 流式读：先读 11 字节文件头，再逐条读记录。
	-- 原来是 read("*a") 把整个文件攥在手里（几千个区块时约 7.6 MB），
	-- 每个区块还要 Data:sub() 再拷一份 —— 启动时峰值约两倍。
	-- 快照本身（7.6 MB）是必须留的，能省的是那份"整文件副本"。
	-- ⚠ 文件头是 **10** 字节：MAGIC(4) + u16 版本(2) + u32 记录数(4)。
	-- 这里踩过坑：写成 F:read(11) 会多吃掉第一条记录的第一个字节，
	-- 于是每条记录都错位一个字节 —— 解析出来全是乱码世界名，而因为只校验
	-- "#Tile == TILE_SIZE"，它**一声不吭地全收下了**，下次保存再把乱码写回文件。
	-- （原版读整个文件用的 Data:sub(11, ...) 是 Lua 的 1-based 下标，本来就是对的。）
	local Head = F:read(10)
	if (Head == nil) or (#Head < 10) or (Head:sub(1, 4) ~= MAGIC) then
		F:close()
		Log("快照文件头无效，忽略")
		return 0
	end

	local Ver = UnpackU16(Head, 5)
	-- v2 的文件照旧接受：读进来后就地补上调色板段升级到 v3。
	-- 升级不该丢掉已经攒下的几千个快照（重扫一遍要跑遍世界，代价很大）。
	local OnDisk = TILE_SIZE
	if (Ver == 2) then
		OnDisk = TILE_BASE
	elseif (Ver ~= VERSION) then
		F:close()
		Log("快照版本不匹配（文件 " .. tostring(Ver) .. "，期望 " .. VERSION .. "），忽略")
		return 0
	end

	local Count = UnpackU32(Head, 7)
	local Loaded, Bytes = 0, 0
	for _ = 1, Count do
		local LenB = F:read(1)
		if (LenB == nil) then
			break
		end
		local NameLen = LenB:byte(1)
		local RecordBytes = NameLen + 8 + OnDisk
		local Rest = F:read(RecordBytes)
		if (Rest == nil) or (#Rest < RecordBytes) then
			break
		end
		local WorldName = Rest:sub(1, NameLen)
		-- 防御：名字长度/字符集明显不合理就认定文件损坏，立刻停。
		-- 这条是踩出来的 —— 一个 off-by-one 让整份快照被当成"合法但名字是乱码"
		-- 的数据读了进来（只校验 #Tile == TILE_SIZE 是拦不住的）。
		if (NameLen == 0) or (NameLen > 32) or (WorldName:find("[^%w_%-]") ~= nil) then
			Log(string.format("快照第 %d 条的世界名不合法（名长 %d），文件可能损坏，停止解析", Loaded + 1, NameLen))
			break
		end
		local CX = UnpackI32(Rest, NameLen + 1)
		local CZ = UnpackI32(Rest, NameLen + 5)
		local Tile = Rest:sub(NameLen + 9, NameLen + 8 + OnDisk)
		if ((CX ~= nil) and (CZ ~= nil) and (#Tile == OnDisk)) then
			if (OnDisk ~= TILE_SIZE) then
				Tile = UpgradeTileToV3(Tile)   -- v2 -> v3
			end
			R.PutTile(WorldName, CX, CZ, Tile, true)
			Loaded = Loaded + 1
			Bytes = Bytes + 1 + RecordBytes
		else
			break
		end
	end
	F:close()

	R.Dirty = {}
	Log("已载入 " .. Loaded .. " 个区块快照（" .. string.format("%.1f", (Bytes + 11) / 1024) .. " KiB）")
	return Loaded
end

--- 引擎每 tick 调一次：到点且确实有改动时才落盘。
function R.MaybeSave()
	local T = Now()
	if ((T - R.LastSave) < R.Config.SaveInterval) then
		return
	end
	if (not R.IsDirty()) then
		R.LastSave = T
		return
	end
	R.SaveTiles(false)
end

----------------------------------------------------------------------
-- 快照构建
----------------------------------------------------------------------

local BuildCoords = Vector3i(0, 0, 0)

--- 生物群系单字节编码：0 表示未知，否则 biome + 1。
local function BiomeByte(Biome)
	if (Biome == nil) or (Biome < 0) or (Biome > 254) then
		return 0
	end
	return Biome + 1
end

--- 从世界读取一个区块，生成 TILE_SIZE 字节快照。区块未加载时返回 nil。
function R.BuildTile(World, CX, CZ)
	local Colors, Heights, Biomes = {}, {}, {}
	local BaseX = CX * 16
	local BaseZ = CZ * 16
	local LoadedAny = false
	local Idx = 0

	for tz = 0, 15 do
		local Z = BaseZ + tz
		for tx = 0, 15 do
			Idx = Idx + 1
			local Ok, H = World:TryGetHeight(BaseX + tx, Z)
			if Ok then
				LoadedAny = true
				local Hm1 = H + 1
				if (Hm1 > 255) then
					Hm1 = 255
				end
				Heights[Idx] = Hm1
				Biomes[Idx] = BiomeByte(World:GetBiomeAt(BaseX + tx, Z))

				BuildCoords:Set(BaseX + tx, H, Z)
				local Valid, Bt, Meta = World:GetBlockTypeMeta(BuildCoords)
				local C
				if Valid then
					C = WCM_Blocks.ColorFor(Bt, Meta)
				else
					C = WCM_Blocks.Placeholder
				end
				Colors[Idx] = char(C[1], C[2], C[3])
			else
				Heights[Idx] = 0
				Biomes[Idx] = 0
				Colors[Idx] = char(0, 0, 0)
			end
		end
	end

	if (not LoadedAny) then
		return nil
	end

	R.Stats.TileBuilds = R.Stats.TileBuilds + 1
	local Seg = concat(Colors)
	return Seg .. char(unpack(Heights)) .. char(unpack(Biomes)) .. BuildPaletteForm(Seg)
end

--- 只构建一个区块的生物群系段（256 字节），供 biome 图层使用。
function R.BuildBiomeTile(World, CX, CZ)
	local Biomes = {}
	local BaseX = CX * 16
	local BaseZ = CZ * 16
	local Idx = 0
	for tz = 0, 15 do
		local Z = BaseZ + tz
		for tx = 0, 15 do
			Idx = Idx + 1
			Biomes[Idx] = BiomeByte(World:GetBiomeAt(BaseX + tx, Z))
		end
	end
	return char(unpack(Biomes))
end

--- 读取快照里的地表高度（Idx 为 0..255 的区块内下标），没有数据返回 nil。
function R.TileHeightAt(Tile, Idx)
	local V = Tile:byte(OFF_HEIGHTS + Idx + 1)
	if (V == nil) or (V == 0) then
		return nil
	end
	return V - 1
end

--- 读取快照里的生物群系编号，没有数据返回 nil。
function R.TileBiomeAt(Tile, Idx)
	local V = Tile:byte(OFF_BIOMES + Idx + 1)
	if (V == nil) or (V == 0) then
		return nil
	end
	return V - 1
end

--- 视野内的区块加载情况（用于“加载可见区块”按钮）。
-- 未加载的区块分成两档：
--   Unknown    —— 连快照都没有，地图上是黑的，应该优先加载
--   Remembered —— 有快照、地图上已经能看出地形，可以往后排
-- @return Loaded 数量, Total 数量, Unknown 数组, Remembered 数组（元素为 {CX, CZ}）
function R.ViewChunkInfo(World, OriginX, OriginZ, SizeChunks)
	local BaseCX = floor(OriginX / 16)
	local BaseCZ = floor(OriginZ / 16)
	local WorldName = World:GetName()
	local Loaded, Total = 0, 0
	local Unknown, Remembered = {}, {}
	for cz = 0, SizeChunks - 1 do
		for cx = 0, SizeChunks - 1 do
			Total = Total + 1
			local CX, CZ = BaseCX + cx, BaseCZ + cz
			if World:TryGetHeight(CX * 16 + 8, CZ * 16 + 8) then
				Loaded = Loaded + 1
			elseif R.GetTile(WorldName, CX, CZ) == nil then
				Unknown[#Unknown + 1] = { CX, CZ }
			else
				Remembered[#Remembered + 1] = { CX, CZ }
			end
		end
	end
	return Loaded, Total, Unknown, Remembered
end

----------------------------------------------------------------------
-- 渲染
----------------------------------------------------------------------

----------------------------------------------------------------------
----------------------------------------------------------------------
-- 结构位置（跨插件）
----------------------------------------------------------------------

--- 每种结构一个颜色，认不出来的用灰白兜底。
local STRUCTURE_COLORS = {
	Mineshaft      = { 130, 130, 140 },
	Village        = { 240, 180,  55 },
	Desert_Pyramid = { 245, 220, 130 },
	Jungle_Pyramid = {  60, 170,  80 },
	Swamp_Hut      = { 120,  70, 150 },
	Desert_Well    = { 205, 195, 115 },
	Fortress       = { 200,  60,  60 },
}
local STRUCTURE_FALLBACK = { 225, 225, 225 }
R.StructureColors = STRUCTURE_COLORS    -- 给 web.lua 画图例用

--- 目标插件（VanillaFeatureComplement）跨插件 API，当前是 v3：
---
---   StructureLocateAPIVersion() -> 3
---   StructureLocateKinds()      -> { "Mineshaft", "Village", ... }
---   StructureLocateFindAll(World, Kind, MinX, MinZ, MaxX, MaxZ, RefX, RefZ, Biomes)
---        -> { Ok = true, Count, ConfirmedCount, Items = { {Kind, Display, X, Y, Z,
---             Distance, Confirmed, Detail, OriginX, OriginZ}, ... } }
---        -> { Ok = false, Error, ApiVersion }   插件在，但这次问不出来
---        -> nil                                  插件没装 / 函数名对不上
---
---   Biomes 是可选表 {["blockX,blockZ"] = biomeId}，**只在引擎答不出来时**（区块没加载）
---   才被使用；引擎自己的答案永远优先，所以给错了也只是被忽略，不会被当真。
---
--- 三条硬约束：
---  * 只能在 tick 线程调用（对方内部要读世界判断区块是否已生成）。所以它在 R.Render
---    里，不在 web.lua 里 —— 从 WebAdmin 的 HTTP 线程调会锁序反转（铁律一）。
---  * 失败一律静默。整段包 pcall，Ok=false / nil / 抛错都当作"没有结构"。
---  * 跨插件的表是**拷贝**的，所以 Biomes 绝不能铺满视野（见下面 SupplyBiomes 的注释）。
local STRUCTURE_API_VERSION = 3

local StructProbe = { Time = -1e9, Api = nil }

--- 探测一次对方可用性，最多每 60 秒一次；不可用就返回 nil。
--- 限流是为了别让对方每次都往日志里写 "Function '<name>' not found"。
local function StructApi()
	local T = Now()
	if ((T - StructProbe.Time) < 60) then
		return StructProbe.Api
	end
	StructProbe.Time = T
	StructProbe.Api = nil

	local Version = nil
	pcall(function ()
		Version = cPluginManager:CallPlugin("VanillaFeatureComplement", "StructureLocateAPIVersion")
	end)
	if (type(Version) ~= "number") or (Version < STRUCTURE_API_VERSION) then
		return nil
	end
	local Kinds = nil
	pcall(function ()
		Kinds = cPluginManager:CallPlugin("VanillaFeatureComplement", "StructureLocateKinds")
	end)
	if (type(Kinds) ~= "table") or (#Kinds == 0) then
		return nil
	end
	StructProbe.Api = { Version = Version, Kinds = Kinds }
	return StructProbe.Api
end

--- 从我们自己的区块快照里取某个方块的群系；没有快照或快照里没记就返回 nil。
--- 编号与引擎一致（快照里存的就是 World:GetBiomeAt() 的值 + 1）。
local function SnapshotBiome(WorldName, X, Z)
	local CX, CZ = floor(X / 16), floor(Z / 16)
	local Tile = R.GetTile(WorldName, CX, CZ)
	if (Tile == nil) then
		return nil
	end
	local B = R.TileBiomeAt(Tile, (Z - CZ * 16) * 16 + (X - CX * 16))
	if (B == nil) or (B < 0) then
		return nil
	end
	return B
end

-- 一次塞给对方的群系条目上限（防呆）。实际上只有几十到几百条，见下面注释。
local SUPPLY_BIOME_MAX = 2048

--- 给"对方判为不确定"的结构补上我们知道的群系。
---
--- 为什么要分两趟：Biomes 是跨插件拷贝的表，铺满视野代价不可接受
--- （size=16 的视野是 256x256 = 65536 个方块，乘 7 种结构、每方块还要新建一个键字符串）。
--- 而对方真正会去问的坐标其实只有：
---   * 每个候选的**原点方块**（Kind.Biome == "origin" 的那一类）
---   * 村庄还要问原点区块的**全部 256 列**（它要拿整块地的群系去判 pool 的 AllowedBiomes）
--- 所以第一趟不带群系先跑，把"不确定"的原点收上来，第二趟只补这些坐标 ——
--- 表通常只有几十项，村庄也就几百项。
local function SupplyBiomes(WorldName, Kind, Items)
	local Need = {}
	local Count = 0

	local function Want(X, Z)
		local Key = X .. "," .. Z
		if (Need[Key] == nil) and (Count < SUPPLY_BIOME_MAX) then
			Need[Key] = true
			Count = Count + 1
		end
	end

	for _, It in ipairs(Items) do
		if (It.Confirmed ~= true) and (type(It.OriginX) == "number") and (type(It.OriginZ) == "number") then
			Want(It.OriginX, It.OriginZ)
			if (Kind == "Village") then
				local CX, CZ = floor(It.OriginX / 16), floor(It.OriginZ / 16)
				for tz = 0, 15 do
					for tx = 0, 15 do
						Want(CX * 16 + tx, CZ * 16 + tz)
					end
				end
			end
		end
	end

	if (Count == 0) then
		return nil
	end

	local Table_ = {}
	local Filled = 0
	for Key in pairs(Need) do
		local X, Z = Key:match("^(-?%d+),(-?%d+)$")
		if (X ~= nil) then
			local B = SnapshotBiome(WorldName, tonumber(X), tonumber(Z))
			if (B ~= nil) then
				Table_[Key] = B
				Filled = Filled + 1
			end
		end
	end

	-- 一条都对不上就别多跑一趟了
	if (Filled == 0) then
		return nil
	end
	return Table_
end

--- 收集视野内的结构位置。返回 标记表, 结构列表（都可能是 nil）。
local function CollectStructures(World, WorldName, OriginX, OriginZ, Blocks)
	local Api = StructApi()
	if (Api == nil) then
		return nil, nil
	end

	-- 直接问"视野这个矩形里有哪些"，而不是"离中心最近的一个"：
	-- v3 的 FindAll 会把矩形内**所有**该种结构按距离排好返回，
	-- 所以一个视野里有俩村庄时两个都会画出来。
	local MinX, MinZ = OriginX, OriginZ
	local MaxX, MaxZ = OriginX + Blocks - 1, OriginZ + Blocks - 1
	local RefX, RefZ = OriginX + floor(Blocks / 2), OriginZ + floor(Blocks / 2)

	local function FindAll(Kind, Biomes)
		local Res = nil
		pcall(function ()
			Res = cPluginManager:CallPlugin("VanillaFeatureComplement", "StructureLocateFindAll",
				World, Kind, MinX, MinZ, MaxX, MaxZ, RefX, RefZ, Biomes)
		end)
		if (type(Res) == "table") and (Res.Ok == true) and (type(Res.Items) == "table") then
			return Res.Items
		end
		return nil
	end

	local Markers = {}
	local Found = {}

	for _, Kind in ipairs(Api.Kinds) do
		local Items = FindAll(Kind, nil)
		if (Items ~= nil) and (#Items > 0) then
			-- 第二趟：把"引擎答不出来"的坐标用我们自己的快照补上
			local Biomes = SupplyBiomes(WorldName, Kind, Items)
			if (Biomes ~= nil) then
				local Better = FindAll(Kind, Biomes)
				if (Better ~= nil) then
					Items = Better
				end
			end

			local C = STRUCTURE_COLORS[Kind] or STRUCTURE_FALLBACK
			for _, It in ipairs(Items) do
				if (type(It.X) == "number") and (type(It.Z) == "number") then
					local bx = floor(It.X) - OriginX
					local bz = floor(It.Z) - OriginZ
					if (bx >= 0) and (bx < Blocks) and (bz >= 0) and (bz < Blocks) then
						local Confirmed = (It.Confirmed == true)
						-- 确认过的：实心 + 白心；只敢猜的：实心 + 黑心（一眼能区分）
						for dx = -2, 2 do
							for dz = -2, 2 do
								local px, pz = bx + dx, bz + dz
								if (px >= 0) and (px < Blocks) and (pz >= 0) and (pz < Blocks) then
									Markers[px * 4096 + pz] = { C[1], C[2], C[3] }
								end
							end
						end
						local Center = Confirmed and { 255, 255, 255 } or { 0, 0, 0 }
						for dx = -1, 1 do
							for dz = -1, 1 do
								local px, pz = bx + dx, bz + dz
								if (px >= 0) and (px < Blocks) and (pz >= 0) and (pz < Blocks) then
									Markers[px * 4096 + pz] = Center
								end
							end
						end
						Found[#Found + 1] = {
							Kind = Kind,
							Display = It.Display or Kind,
							X = It.X, Y = It.Y, Z = It.Z,
							Confirmed = Confirmed,
							Distance = It.Distance,
						}
					end
				end
			end
		end
	end

	if (#Found == 0) then
		return nil, nil
	end
	table.sort(Found, function (A, B)
		return (A.Distance or 0) < (B.Distance or 0)
	end)
	return Markers, Found
end

--- 收集需要画在地图上的标记（在线玩家 + 出生点）。
local function CollectMarkers(World, OriginX, OriginZ, Blocks)
	local Markers = {}
	local function Plot(BlockX, BlockZ, Cr, Cg, Cb, Radius)
		local BaseBX = floor(BlockX) - OriginX
		local BaseBZ = floor(BlockZ) - OriginZ
		for dx = -Radius, Radius do
			for dz = -Radius, Radius do
				local bx = BaseBX + dx
				local bz = BaseBZ + dz
				if (bx >= 0) and (bx < Blocks) and (bz >= 0) and (bz < Blocks) then
					Markers[bx * 4096 + bz] = { Cr, Cg, Cb }
				end
			end
		end
	end

	local Count = 0
	-- 除了画进像素的 Markers，另外给一份**坐标列表**：切到画布后标记改成
	-- DOM 叠加层（更清晰、与缩放无关、还能带 tooltip），这几个坐标就是给它的。
	local Spots = {}
	World:ForEachPlayer(function (Player)
		local Pos = Player:GetPosition()
		if (Pos ~= nil) then
			Plot(Pos.x, Pos.z, 230, 60, 60, 1)
			Plot(Pos.x, Pos.z, 255, 255, 255, 0)
			Count = Count + 1
			Spots[#Spots + 1] = { X = floor(Pos.x), Z = floor(Pos.z), Kind = "player", Name = Player:GetName() }
		end
	end)

	if (R.Config.DrawSpawn) then
		local SX, SZ = World:GetSpawnX(), World:GetSpawnZ()
		Plot(SX, SZ, 70, 160, 255, 1)
		Plot(SX, SZ, 255, 255, 255, 0)
		Spots[#Spots + 1] = { X = floor(SX), Z = floor(SZ), Kind = "spawn" }
	end

	return Markers, Count, Spots
end

-- biome 图层里没有生物群系数据时的颜色
local NoBiomeColor = { 96, 100, 110 }

-- 区块状态配色（chunks 图层）
local StateColors = {
	[0] = { 62, 66, 78 },     -- 未知（从未加载过）
	[1] = { 150, 158, 102 },  -- 记忆中的快照
	[2] = { 96, 160, 82 },    -- 当前已加载
}

--- 画布协议的头部长度与版本（格式见 AGENTS.md 第 4 节"画布协议"）
-- 头部字节数 = 25 + 2（扩展段长度）。扩展段用来给 chunks / biome 图层带颜色表：
--     u8 noBiomeRGB(3) | u16 biomeCount | biomeCount x (u8 id, u8 R, u8 G, u8 B)
--     | u8 stateRGB[3][3]（chunks 图层的三档状态配色）
-- 注意 gridFactor / rememberedShade 用 **u16 存 4 位小数**（F*10000），
-- 不能存成一个字节：那会引入 0.16% 的量化误差，让网格线的 floor(Cr*F) 和
-- 服务端差 1 —— 实测就这一个精度问题造成了 4.4 万个像素不一致。
local BIN_HEADER = 27
local BIN_VERSION = 1
local GRID_FACTOR = 0.74      -- 区块网格线的压暗系数（和 PNG 路径保持一致）

--- 从渲染时**已经采集好的网格**组装画布 payload（协议 v1，只管 topo 图层）。
---
--- 刻意不碰 cWorld：TileGrid / StateGrid 里已经有全部所需数据
--- （预打包的调色板段 + 高度 + 状态），所以这里只是"拼接 + deflate"。
--- 逐像素的颜色展开、山体阴影、区块网格线、标记**全部留给浏览器** ——
--- 那才是这次迁移要搬走的东西（服务端 ~200 ms -> ~20 ms，而且离开 tick 线程）。
---
--- 每个区块的记录：
---     state(1) + 调色板段(177，原样拷) + 高度(256，仅 topo 且开阴影时)
--- state == 0 的未知区块只占 **1 字节**（颜色从头部取）。服务端的阴影本来就只对
--- state ~= 0 的区块生效，所以丢掉那些高度不会有任何损失。
local function BuildBinaryFromGrid(Plan, TileGrid, StateGrid, BiomeGrid, Cfg, Shading, DrawGrid)
	local SizeChunks = Plan.SizeChunks
	local Buf = {}

	Buf[#Buf + 1] = "WCMB"
	Buf[#Buf + 1] = PackU16(BIN_VERSION)
	-- 头部那个 mode 字节必须按图层填 —— 扩展段和记录布局都按它分派。
	-- （曾经写死 0，于是 biome 的 payload 头部自称是 topo，解析全乱。）
	local ModeByte = 0
	if (Plan.Mode == "chunks") then
		ModeByte = 1
	elseif (Plan.Mode == "biome") then
		ModeByte = 2
	end
	Buf[#Buf + 1] = char(ModeByte, (Shading and 1 or 0) + (DrawGrid and 2 or 0))   -- mode, flags
	Buf[#Buf + 1] = PackI32(Plan.OriginChunkX)
	Buf[#Buf + 1] = PackI32(Plan.OriginChunkZ)
	Buf[#Buf + 1] = PackU16(SizeChunks)
	Buf[#Buf + 1] = PackU16(floor(GRID_FACTOR * 10000 + 0.5) % 65536)
	Buf[#Buf + 1] = PackU16(floor((tonumber(Cfg.RememberedShade) or 1) * 10000 + 0.5) % 65536)
	Buf[#Buf + 1] = R.UnknownTile():sub(1, 3)   -- 未知区块的占位色

	-- 扩展段：chunks / biome 图层要的颜色表
	local Extra = {}
	if (Plan.Mode == "chunks") then
		for i = 0, 2 do
			local C = StateColors[i] or StateColors[0]
			Extra[#Extra + 1] = char(C[1], C[2], C[3])
		end
	elseif (Plan.Mode == "biome") then
		Extra[#Extra + 1] = char(NoBiomeColor[1], NoBiomeColor[2], NoBiomeColor[3])
		-- 把视野里出现过的群系 id 收成一张表。用一次 byte(1,256) 取整段，
		-- 不要逐字节调 byte —— 那是 256 次 C 调用/区块，乘 2304 个区块就是几十毫秒。
		local Seen, List = {}, {}
		for _, Seg in pairs(BiomeGrid or {}) do
			local Bytes = { Seg:byte(1, 256) }
			for i = 1, 256 do
				local B = Bytes[i]
				if (Seen[B] == nil) then
					Seen[B] = true
					local C
					if (B == 0) then
						C = NoBiomeColor
					else
						C = WCM_Blocks.Biomes[B - 1]
						if (C == nil) then
							C = WCM_Blocks.AutoColor(B - 1)
						end
					end
					List[#List + 1] = char(B, C[1], C[2], C[3])
				end
			end
		end
		Extra[#Extra + 1] = PackU16(#List)
		Extra[#Extra + 1] = concat(List)
	else
		Extra[#Extra + 1] = char(0, 0, 0)
		Extra[#Extra + 1] = PackU16(0)
	end
	local ExtraStr = concat(Extra)
	Buf[#Buf + 1] = PackU16(#ExtraStr)
	Buf[#Buf + 1] = ExtraStr

	local IsChunks = (Plan.Mode == "chunks")
	local IsBiome = (Plan.Mode == "biome")
	local ZeroBiomes = char(0):rep(TILE_BIOMES)

	for cz = 0, SizeChunks - 1 do
		for cx = 0, SizeChunks - 1 do
			local gi = cz * SizeChunks + cx + 1
			local State = StateGrid[gi] or 0
			Buf[#Buf + 1] = char(State)

			-- chunks 图层的颜色只由状态决定（表在扩展段里），所以**一个区块一个字节**。
			-- 这一层就从"整张 PNG"变成 1 B/区块，服务端几乎不花时间了。
			if (State ~= 0) and (not IsChunks) then
				if IsBiome then
					local Seg = (BiomeGrid ~= nil) and BiomeGrid[gi] or nil
					Buf[#Buf + 1] = (Seg ~= nil) and Seg or ZeroBiomes
				else
					local Tile = TileGrid[gi]
					if (Tile ~= nil) then
						-- 快照里那 177 字节正好就是线上格式，原样拷（补零由 deflate 吃掉）。
						-- 例外：调色板颜色数为 0 表示"这个区块颜色超过 16 种"，
						-- 那时客户端的约定是**改成读 768 字节 RGB 段** —— 两边必须一致，
						-- 只发 177 字节会让客户端从那里开始整体错位（表现为整张图变黑）。
						if (Tile:byte(OFF_PALCOUNT + 1) == 0) then
							Buf[#Buf + 1] = Tile:sub(1, TILE_COLORS)
						else
							Buf[#Buf + 1] = Tile:sub(OFF_PALCOUNT + 1, TILE_SIZE)
						end
						if Shading then
							Buf[#Buf + 1] = Tile:sub(TILE_COLORS + 1, TILE_COLORS + TILE_HEIGHTS)
						end
					end
				end
			end
		end
	end

	local Raw = concat(Buf)
	return cStringCompression.CompressStringZLIB(Raw, Cfg.PngFactor), Raw
end

--- 取画布 payload（HTTP 线程安全：只读纯 Lua 缓存，绝不碰 cWorld）。
--- 返回 (Data, Meta, RawBytes)；没有缓存时返回 nil。
function R.GetCachedBin(Key)
	local Cached = R.Cache[Key]
	if (Cached == nil) or (Cached.Bin == nil) then
		return nil, nil, 0
	end
	return Cached.Bin, Cached.Meta, Cached.BinRawBytes
end

--- 渲染一块区域。
-- @param World cWorld
-- @param Opts  { Mode, SizeChunks, Scale, CenterX, CenterZ, NoCache }
-- @return PNG 字符串, Meta 表；失败时返回 nil, 错误信息
function R.Render(World, Opts)
	Opts = Opts or {}
	local Cfg = R.Config

	local Plan = R.Plan(Opts, World:GetSpawnX(), World:GetSpawnZ())
	local Mode = Plan.Mode
	local SizeChunks = Plan.SizeChunks
	local Scale = Plan.Scale
	local Blocks = Plan.Blocks
	local ImgSize = Plan.ImgWidth or Plan.Width
	local OriginX, OriginZ = Plan.OriginX, Plan.OriginZ
	local RequestedSize, SizeClamped = Plan.RequestedSizeChunks, Plan.SizeClamped

	local Key = R.PlanKey(World:GetName(), Plan)

	local Time = Now()
	local Cached = R.Cache[Key]
	if (not Opts.NoCache) and (Cached ~= nil) and ((Time - Cached.Time) < Cfg.CacheTTL) then
		R.Stats.CacheHits = R.Stats.CacheHits + 1
		Cached.Meta.CacheHit = true
		return Cached.Png, Cached.Meta
	end

	local T0 = Clock()
	local WorldName = World:GetName()
	local BaseCX = floor(OriginX / 16)
	local BaseCZ = floor(OriginZ / 16)

	-- 组装视野内每个区块的快照
	local TileGrid = {}     -- [cz * SizeChunks + cx + 1] = 完整快照（topo / chunks）
	local BiomeGrid = {}    -- [cz * SizeChunks + cx + 1] = 256 字节生物群系段（biome）
	local StateGrid = {}    -- 0 未知 / 1 记忆 / 2 实时
	local LiveN, RememberedN, UnknownN = 0, 0, 0
	local NewTiles = 0

	local Unknown = R.UnknownTile()
	local ZeroBiomes = char(0):rep(TILE_BIOMES)

	for cz = 0, SizeChunks - 1 do
		for cx = 0, SizeChunks - 1 do
			local CX, CZ = BaseCX + cx, BaseCZ + cz
			local gi = cz * SizeChunks + cx + 1

			-- 只用一根采样柱判断区块是否加载，不必白扫 256 列
			local IsLoaded = World:TryGetHeight(CX * 16 + 8, CZ * 16 + 8) and true or false

			if (Mode == "biome") then
				-- biome 图层只需要生物群系那一段，不需要整块快照
				if IsLoaded then
					BiomeGrid[gi] = R.BuildBiomeTile(World, CX, CZ)
					StateGrid[gi] = 2
					LiveN = LiveN + 1
				else
					local Segment = nil
					if Cfg.RememberTiles then
						local Tile = R.GetTile(WorldName, CX, CZ)
						if (Tile ~= nil) then
							Segment = Tile:sub(OFF_BIOMES + 1, OFF_BIOMES + TILE_BIOMES)
							if (Segment == ZeroBiomes) then
								Segment = nil
							end
						end
					end
					if (Segment ~= nil) then
						BiomeGrid[gi] = Segment
						StateGrid[gi] = 1
						RememberedN = RememberedN + 1
					else
						StateGrid[gi] = 0
						UnknownN = UnknownN + 1
					end
				end
			else
				local Tile = nil
				if IsLoaded then
					Tile = R.BuildTile(World, CX, CZ)
				end

				if (Tile ~= nil) then
					StateGrid[gi] = 2
					LiveN = LiveN + 1
					R.Stats.LiveTiles = R.Stats.LiveTiles + 1
					if Cfg.RememberTiles then
						R.PutTile(WorldName, CX, CZ, Tile)
						NewTiles = NewTiles + 1
					end
				else
					if Cfg.RememberTiles then
						Tile = R.GetTile(WorldName, CX, CZ)
					end
					if (Tile ~= nil) then
						StateGrid[gi] = 1
						RememberedN = RememberedN + 1
						R.Stats.ReusedTiles = R.Stats.ReusedTiles + 1
					else
						StateGrid[gi] = 0
						UnknownN = UnknownN + 1
						Tile = Unknown
					end
				end

				TileGrid[gi] = Tile
			end
		end
	end

	local TGrid = Clock()
	local Markers, PlayerCount, PlayerSpots = nil, 0, {}
	if (Cfg.DrawPlayers or Cfg.DrawSpawn) then
		Markers, PlayerCount, PlayerSpots = CollectMarkers(World, OriginX, OriginZ, Blocks)
	end

	local TMarkers = Clock()
	-- 结构位置（跨插件）。整段包 pcall：对方插件没装、函数改名、内部报错，
	-- 一律当作"没有结构"处理，页面上永远不冒错误。
	local StructMarkers, Structures = nil, nil
	if Cfg.DrawStructures then
		local OkS, M, L = pcall(CollectStructures, World, WorldName, OriginX, OriginZ, Blocks)
		if (not OkS) then
			-- 这是"我们自己内部出错"，和"对方插件没装"那种正常失败不同：
			-- 页面依旧什么都不显示，但控制台每分钟最多记一条。
			-- （曾经全静默，一个真 bug 查了半天才找到，所以留这个窄口子。）
			local TErr = Now()
			if ((TErr - (R.LastStructError or -1e9)) >= 60) then
				R.LastStructError = TErr
				LOG("结构采集内部出错（每分钟最多一条）: " .. tostring(M))
			end
		end
		if OkS then
			StructMarkers, Structures = M, L
		end
	end

	local TStruct = Clock()
	local GridFactor = 0.74
	local Shade = Cfg.RememberedShade

	-- 每批用一次 char(unpack(...))；上限 2048 是为了不撞 Lua 的 unpack 参数上限
	local PIXEL_BATCH = 2048

	-- 画布 payload（协议 v1）：数据都已经在 TileGrid / StateGrid 里了，
	-- 这里只是"拼装 + deflate"。和 PNG 共用同一次区块采集，所以几乎不要钱；
	-- 真正切到画布之后，服务端的渲染就只剩这一步了。
	-- 注意这段必须放在像素阶段之前：WantPng 要按它的结果决定。
	local DrawGrid = Cfg.DrawChunkGrid and true or false
	local Shading = Cfg.HillShading and (Mode == "topo") and true or false
	local BinData, BinRaw = nil, nil
	if Cfg.CanvasPayload then
		local TBin0 = Clock()
		BinData, BinRaw = BuildBinaryFromGrid(Plan, TileGrid, StateGrid, BiomeGrid, Cfg, Shading, DrawGrid)
		R.Stats.PhaseBin = R.Stats.PhaseBin + (Clock() - TBin0)
	end

	-- 是否还要产出 PNG。切到画布之后就不需要了 —— 跳过整个像素合成 + PNG 编码
	-- （48 区块视野实测约 216 + 60 ms，是服务端唯一的大头，而且它占着世界 tick 线程）。
	-- 拿不到画布 payload 时（比如非 topo 图层）自动退回去出 PNG。
	local WantPng = Opts.NoCanvas or (not (Cfg.CanvasOnly and (BinData ~= nil)))
	local Png = nil
	if WantPng then
		local Out = {}
		local IsBiome = (Mode == "biome")
		local IsChunks = (Mode == "chunks")
		-- Shading / DrawGrid 已经在上面算好了（画布 payload 也要用），这里不再重复声明
		-- 阴影降采样倍率（见 [Render] ShadeDownsample 的说明与实测数据）
		local Downsample = floor(tonumber(Cfg.ShadeDownsample) or 1)
		if (Downsample < 1) then Downsample = 1 end

		-- 山体阴影要读"上一像素行"的高度，所以每行保留一份"每区块 16 字节"的高度带，
		-- 两行轮换使用。这样阴影不用每像素去查 TileGrid、也不做除法。
		local PrevRow, CurRow = {}, {}

		-- 标记按"像素行"分组一次。标记本来就很稀疏（结构 + 玩家 + 出生点，几十个），
		-- 而像素循环有几十万次 —— 原来每像素要查两次哈希表。
		-- 分组后每行只查一次，绝大多数行根本没有标记，于是每像素只剩一次 nil 判断。
		-- 顺序有意为之：先结构、后玩家 / 出生点，后者压在上面。
		local RowsMk = nil
		if (StructMarkers ~= nil) or (Markers ~= nil) then
			local Srcs = {}
			if (StructMarkers ~= nil) then Srcs[#Srcs + 1] = StructMarkers end
			if (Markers ~= nil) then Srcs[#Srcs + 1] = Markers end
			RowsMk = {}
			for si = 1, #Srcs do
				for MKey, Mk in pairs(Srcs[si]) do
					local pz = MKey % 4096
					local px = floor(MKey / 4096)
					local RowT = RowsMk[pz]
					if (RowT == nil) then
						RowT = {}
						RowsMk[pz] = RowT
					end
					RowT[px] = Mk
				end
			end
		end

		for bz = 0, Blocks - 1 do
			local RowChunk = floor(bz / 16)
			local ty = bz % 16
			local RowChunkBase = RowChunk * SizeChunks
			local Row, Buf, Bn = {}, {}, 0
			local RowMk = (RowsMk ~= nil) and RowsMk[bz] or nil
			-- 山体阴影的降采样状态（每行重置）：见下面阴影段的说明
			local ShadeReuse, CurShade = 0, nil
			PrevRow, CurRow = CurRow, PrevRow

			-- bx/16 与 bx%16 用递增计数器代替（原来是每像素两次除法 + 两次取模）；
			-- 顺带在区块边界处把该区块的 Tile / State / 当前行高度带一次取好。
			local cx, tx = -1, 15
			local gi, Tile, State, CurBand = 0, nil, 0, nil

			for bx = 0, Blocks - 1 do
				local Cr, Cg, Cb

				tx = tx + 1
				if (tx == 16) then
					tx = 0
					cx = cx + 1
					gi = RowChunkBase + cx + 1
					Tile = TileGrid[gi]
					State = StateGrid[gi] or 0
					if Shading and (State ~= 0) and (Tile ~= nil) then
						-- 一次取 16 列高度（原来是每像素一次 Tile:byte）。
						-- 注意必须用 sub 而不是 byte：string.byte(s, i, j) 返回的是
						-- **j-i+1 个值**，赋给一个变量只会拿到第一个字节的数字。
						CurBand = Tile:sub(TILE_COLORS + ty * 16 + 1, TILE_COLORS + ty * 16 + 16)
					else
						CurBand = nil
					end
					CurRow[cx + 1] = CurBand
				end

				if IsBiome then
					local BG = BiomeGrid[gi]
					local B = 0
					if (BG ~= nil) then
						B = BG:byte(ty * 16 + tx + 1) or 0
					end
					if (B == 0) then
						Cr, Cg, Cb = NoBiomeColor[1], NoBiomeColor[2], NoBiomeColor[3]
					else
						local Biome = B - 1
						local C = WCM_Blocks.Biomes[Biome]
						if (C == nil) then
							C = WCM_Blocks.AutoColor(Biome)
						end
						Cr, Cg, Cb = C[1], C[2], C[3]
					end
				else
					if IsChunks then
						local C = StateColors[State]
						Cr, Cg, Cb = C[1], C[2], C[3]
					else
						local ti = (ty * 16 + tx) * 3 + 1
						Cr, Cg, Cb = Tile:byte(ti, ti + 2)

						-- 山体阴影：向西北邻居取高度，跨区块连续。
						-- 高度已在区块边界按行预取好（CurBand / PrevRow），所以这里
						-- 既不查 TileGrid 也不做除法；明暗系数查表。
						-- 注意 PrevRow 里可能没有这一格（那个区块当时没有快照）——
						-- 对应老代码里 nt == nil 的情况，跳过即可。
						-- 山体阴影。
						--
						-- 降采样：阴影是低频场，所以**每两个像素才算一次明暗系数**，中间那个
						-- 直接复用。误差只是"阴影边界横移一个方块"，肉眼看不出来，
						-- 省下的是每像素两次字符串取字节 + 比较 + 夹取（那才是这里的大头，
						-- 因为 Lua 里字符串取字节是 C 调用）。
						--
						-- 只在真正算过之后才设复用计数：bx == 0（左边越界）不算，
						-- 于是下个像素会自己算，不会把"无阴影"错误地传播出去。
						if (ShadeReuse > 0) then
							ShadeReuse = ShadeReuse - 1
						elseif Shading and (bx > 0) and (bz > 0) and (State ~= 0) then
							local There
							if (tx > 0) then
								local PB = PrevRow[cx + 1]
								There = (PB ~= nil) and PB:byte(tx) or nil
							else
								local PB = PrevRow[cx]
								There = (PB ~= nil) and PB:byte(16) or nil
							end
							local Here = CurBand:byte(tx + 1)
							CurShade = nil
							if (Here ~= nil) and (There ~= nil) and (Here > 0) and (There > 0) then
								local D = Here - There
								-- D == 0 时 F 恰好是 1 —— 平坦地形（海、平原）走这条捷径
								if (D ~= 0) then
									if (D > 8) then D = 8 elseif (D < -8) then D = -8 end
									CurShade = ShadeTab[D + 8]
								end
							end
							ShadeReuse = Downsample - 1
						end
						if (CurShade ~= nil) then
							Cr = CurShade[Cr]
							Cg = CurShade[Cg]
							Cb = CurShade[Cb]
						end

						if (State == 1) and (Shade ~= 1) then
							Cr = floor(Cr * Shade)
							Cg = floor(Cg * Shade)
							Cb = floor(Cb * Shade)
						end
					end
				end

				-- 区块边界
				if (DrawGrid and ((tx == 0) or (ty == 0))) then
					Cr = floor(Cr * GridFactor)
					Cg = floor(Cg * GridFactor)
					Cb = floor(Cb * GridFactor)
				end

				-- 标记（结构和玩家 / 出生点已经按行合并好了，见上面的 RowsMk）
				if (RowMk ~= nil) then
					local Mk = RowMk[bx]
					if (Mk ~= nil) then
						Cr, Cg, Cb = Mk[1], Mk[2], Mk[3]
					end
				end

				if (Cr > 255) then Cr = 255 elseif (Cr < 0) then Cr = 0 end
				if (Cg > 255) then Cg = 255 elseif (Cg < 0) then Cg = 0 end
				if (Cb > 255) then Cb = 255 elseif (Cb < 0) then Cb = 0 end

				-- 数字缓冲 + char(unpack(...)) 分批：原来每个格子是 char() 加 :rep()
				-- 两次分配，大视野下就是百万级可回收对象。表里放数字不进 GC。
				Bn = Bn + 1; Buf[Bn] = Cr
				Bn = Bn + 1; Buf[Bn] = Cg
				Bn = Bn + 1; Buf[Bn] = Cb
				if (Bn >= PIXEL_BATCH) then
					Row[#Row + 1] = char(unpack(Buf, 1, Bn))
					Bn = 0
				end
			end
			if (Bn > 0) then
				Row[#Row + 1] = char(unpack(Buf, 1, Bn))
			end

			Out[#Out + 1] = concat(Row)
		end

		local Pixels = concat(Out)
		local TPixels = Clock()
		Png = WCM_Png.Encode(ImgSize, ImgSize, Pixels, Cfg.PngFactor, Cfg.PngFilter)
		local TPng = Clock()
		R.Stats.PhaseGrid = R.Stats.PhaseGrid + (TGrid - T0)
		R.Stats.PhaseMarkers = R.Stats.PhaseMarkers + (TMarkers - TGrid)
		R.Stats.PhaseStruct = R.Stats.PhaseStruct + (TStruct - TMarkers)
		R.Stats.PhasePixels = R.Stats.PhasePixels + (TPixels - TStruct)
		R.Stats.PhasePng = R.Stats.PhasePng + (TPng - TPixels)
	end

	local Meta = {
		WorldName = WorldName,
		Mode = Mode,
		SizeChunks = SizeChunks,
		RequestedSizeChunks = RequestedSize,
		SizeClamped = SizeClamped,
		Scale = Scale,
		Blocks = Blocks,
		OriginX = OriginX,
		OriginZ = OriginZ,
		Width = Plan.Width,          -- 显示尺寸（web.lua 的叠加层 / 点击坐标用它）
		Height = Plan.Width,
		ImgWidth = ImgSize,          -- PNG 的真实像素
		ImgHeight = ImgSize,
		Players = PlayerCount,
		PlayerSpots = PlayerSpots,
		Structures = Structures,
		OriginChunkX = BaseCX,
		OriginChunkZ = BaseCZ,
		CenterBlockX = OriginX + floor(Blocks / 2),
		CenterBlockZ = OriginZ + floor(Blocks / 2),
		ViewChunks = SizeChunks * SizeChunks,
		LiveChunks = LiveN,
		RememberedChunks = RememberedN,
		UnknownChunks = UnknownN,
		LiveInView = LiveN,
		LoadedInView = LiveN,
		WarmMissing = UnknownN + RememberedN,
		WarmMissingUnknown = UnknownN,
		WarmMissingRemembered = RememberedN,
		NewTiles = NewTiles,
		TotalTiles = R.TileStats(WorldName),
		Pending = false,
		LoadedChunks = World:GetNumChunks(),
		CacheHit = false,
		RenderMs = floor((Clock() - T0) * 1000),
		PngBytes = ((Png ~= nil) and #Png or 0),
	}

	R.Stats.Renders = R.Stats.Renders + 1
	R.Stats.LastRenderMs = Meta.RenderMs

	R.Cache[Key] = { Time = Time, Png = Png, Meta = Meta,
		Bin = BinData, BinRawBytes = ((BinRaw ~= nil) and #BinRaw or 0) }

	-- 同一个视图重绘时 Key 会第二次入队，必须先摘掉旧的那条。
	-- 否则淘汰弹出旧条目时 R.Cache[Old] = nil 会把**当前还有效的缓存图**删掉
	--（原来那句 `if Old ~= Key` 只保护了本次刚插入的那个，保护不了旧重复项），
	-- 结果是"经常看的视图反而被提前淘汰" -> 重绘变多 -> tick 线程更累。
	for i = #R.CacheOrder, 1, -1 do
		if (R.CacheOrder[i] == Key) then
			table.remove(R.CacheOrder, i)
		end
	end
	R.CacheOrder[#R.CacheOrder + 1] = Key

	while (#R.CacheOrder > Cfg.MaxCacheEntries) do
		R.Cache[table.remove(R.CacheOrder, 1)] = nil
	end

	return Png, Meta
end


----------------------------------------------------------------------
-- 线程模型：所有世界访问都必须在 tick 线程上执行
----------------------------------------------------------------------
-- WebAdmin 的标签页回调跑在 HTTP 线程上，并且会持有本插件的 Lua 锁。
-- 如果在那里面调用 cWorld 的接口（TryGetHeight / GetBiomeAt / ChunkStay …），
-- 就会和 tick 线程形成锁序反转：
--     HTTP 线程：持 Lua 锁 -> 等 world chunkmap
--     tick 线程：持 world chunkmap ->（区块回调）等 Lua 锁
-- 两个线程互等，DeadlockDetect 直接把服务器 abort 掉。
-- 所以 HTTP 线程只允许：读纯 Lua 缓存 + 往队列里塞任务；
-- 真正的世界访问全部由 HOOK_WORLD_TICK 在这个函数里完成。

R.Jobs = {}
R.JobStats = { Done = 0, Dropped = 0 }

--- 纯计算：把请求参数折算成实际生效的几何参数（不碰世界，HTTP 线程可调用）。
function R.Plan(Opts, SpawnX, SpawnZ)
	local Cfg = R.Config

	local RequestedSize = floor(Opts.SizeChunks or 8)
	local SizeChunks = RequestedSize
	if (SizeChunks < 1) then SizeChunks = 1 end
	if (SizeChunks > Cfg.MaxSizeChunks) then SizeChunks = Cfg.MaxSizeChunks end

	local Scale = floor(Opts.Scale or 2)
	if (Scale < 1) then Scale = 1 end
	if (Scale > 4) then Scale = 4 end

	-- 按像素预算收缩：优先落到预设档位。
	-- 注意预算现在只按**方块分辨率**算（以前乘了 Scale）—— 因为图片不再把每个像素
	-- 复制 Scale 次，放大交给浏览器（见 R.Render 顶部与 web.lua 的 pixelated）。
	-- 副作用是好的：同样预算下 scale=2 能显示的世界多了一倍。
	if ((SizeChunks * 16) * (SizeChunks * 16)) > Cfg.MaxPixels then
		local Best = nil
		for _, Step in ipairs(R.SizeSteps) do
			if (Step <= SizeChunks) and (((Step * 16) * (Step * 16)) <= Cfg.MaxPixels) then
				Best = Step
			end
		end
		if (Best ~= nil) then
			SizeChunks = Best
		else
			while (SizeChunks > 1) and (((SizeChunks * 16) * (SizeChunks * 16)) > Cfg.MaxPixels) do
				SizeChunks = SizeChunks - 1
			end
		end
	end

	-- ?canvas=0 时强制走 PNG 路径（浏览器画不了 canvas 时的退路）。
	-- 它进缓存键，所以两种形态各自缓存，不会互相污染。
	local NoCanvas = (Opts.NoCanvas == true)

	local Mode = Opts.Mode or "topo"
	if ((Mode ~= "topo") and (Mode ~= "biome") and (Mode ~= "chunks")) then
		Mode = "topo"
	end

	local Blocks = SizeChunks * 16
	local CenterX = floor(Opts.CenterX or SpawnX or 0)
	local CenterZ = floor(Opts.CenterZ or SpawnZ or 0)
	local OriginX = floor((CenterX - floor(Blocks / 2)) / 16) * 16
	local OriginZ = floor((CenterZ - floor(Blocks / 2)) / 16) * 16

	return {
		Mode = Mode,
		SizeChunks = SizeChunks,
		RequestedSizeChunks = RequestedSize,
		SizeClamped = (SizeChunks ~= RequestedSize),
		Scale = Scale,
		NoCanvas = NoCanvas,
		Blocks = Blocks,
		-- Width/Height 是**显示**尺寸：web.lua 用它排叠加层和算点击坐标。
		Width = Blocks * Scale,
		Height = Blocks * Scale,
		-- ImgWidth/ImgHeight 是 PNG 的真实像素：永远是方块分辨率，
		-- 与 Scale 无关（放大由浏览器做，最近邻，视觉完全等价）。
		ImgWidth = Blocks,
		ImgHeight = Blocks,
		CenterX = CenterX,
		CenterZ = CenterZ,
		OriginX = OriginX,
		OriginZ = OriginZ,
		OriginChunkX = floor(OriginX / 16),
		OriginChunkZ = floor(OriginZ / 16),
		CenterBlockX = OriginX + floor(Blocks / 2),
		CenterBlockZ = OriginZ + floor(Blocks / 2),
	}
end

--- 图片缓存的键（只依赖请求参数和配置，不依赖世界数据）。
function R.PlanKey(WorldName, Plan)
	return concat({
		WorldName, Plan.Mode, Plan.OriginX, Plan.OriginZ, Plan.SizeChunks, Plan.Scale,
		Plan.NoCanvas and "n" or "-",
		R.Config.HillShading and "h" or "-",
		R.Config.DrawChunkGrid and "g" or "-",
		R.Config.DrawPlayers and "p" or "-",
		tostring(R.Config.RememberedShade),
	}, ":")
end

--- 只读缓存查询（HTTP 线程可调用）。
-- @return Png, Meta, 缓存年龄（秒）；没有缓存时返回 nil
function R.GetCached(Key)
	local Cached = R.Cache[Key]
	if (Cached == nil) then
		return nil
	end
	return Cached.Png, Cached.Meta, (Now() - Cached.Time)
end

--- 往 tick 线程的任务队列里塞一个任务（HTTP 线程可调用）。
function R.Enqueue(Job)
	R.Jobs[#R.Jobs + 1] = Job
	while (#R.Jobs > 64) do
		table.remove(R.Jobs, 1)
		R.JobStats.Dropped = R.JobStats.Dropped + 1
	end
end

function R.PendingCount()
	return #R.Jobs
end

----------------------------------------------------------------------
-- 世界信息缓存（tick 线程刷新，HTTP 线程只读）
----------------------------------------------------------------------

R.WorldCache = {}
R.KnownWorlds = {}        -- [世界名] = true（由 tick 线程登记，HTTP 线程只读）
R.DefaultWorldName = nil

function R.RefreshWorldCache(World)
	R.TickCount = R.TickCount + 1
	local Name = World:GetName()
	R.KnownWorlds[Name] = true
	-- DefaultWorldName 由 Initialize 读 cRoot:GetDefaultWorld() 定死。
	-- 千万不要写成"谁先 tick 谁当默认"—— 那是几个世界的 tick 线程之间的竞态，
	-- 结果不可预测（本机实测就变成了 world_nether，而 settings.ini 里是 DefaultWorld=world）。
	-- 下面这个分支只是 Initialize 没取到时的退化兜底。
	if (R.DefaultWorldName == nil) then
		R.DefaultWorldName = Name
	end

	local Info = R.WorldCache[Name]
	if (Info == nil) then
		Info = {}
		R.WorldCache[Name] = Info
	end
	Info.SpawnX = World:GetSpawnX()
	Info.SpawnZ = World:GetSpawnZ()
	Info.LoadedChunks = World:GetNumChunks()
	-- ⚠ 这里绝对不能调用 cRoot:Get():GetTotalChunkCount()。
	-- 它会去锁"所有世界"的 chunkmap，而本函数跑在单个世界的 tick 线程上，
	-- 于是两个世界的 tick 线程互等（各自持自己的 chunkmap / 等对方的），
	-- DeadlockDetect 会直接 abort 服务器。同理不要用 cRoot:ForEachPlayer。
	Info.Tiles = R.TileStats(Name)

	local Players = {}
	World:ForEachPlayer(function (Player)
		local Pos = Player:GetPosition()
		if (Pos ~= nil) then
			Players[#Players + 1] = {
				Name = Player:GetName(),
				X = floor(Pos.x), Y = floor(Pos.y), Z = floor(Pos.z),
			}
		end
	end)
	Info.Players = Players
	Info.Known = true
end

function R.GetWorldInfo(Name)
	local Info = R.WorldCache[Name]
	if (Info == nil) then
		return {
			SpawnX = 0, SpawnZ = 0, LoadedChunks = 0, TotalChunks = 0,
			Players = {}, Tiles = 0, Known = false,
		}
	end
	return Info
end

----------------------------------------------------------------------
-- 选中区块的信息缓存（tick 线程刷新，HTTP 线程只读）
----------------------------------------------------------------------

R.ChunkInfo = {}
R.ChunkInfoOrder = {}     -- [世界名] = { chunkKey, ... }，FIFO 淘汰用（见 ForgetChunkInfo 的注释）

function R.GetChunkInfo(WorldName, CX, CZ)
	local ByWorld = R.ChunkInfo[WorldName]
	if (ByWorld == nil) then
		return nil
	end
	return ByWorld[ChunkKey(CX, CZ)]
end

--- 立刻丢弃某个区块的详情缓存。纯 Lua，HTTP 线程可调。
--- regen / forget 之后要用：详情缓存有 InfoTTL(10s)，不作废的话
--- 用户点了按钮后 10 秒内看到的还是旧状态，像是"点了没反应"。
function R.ForgetChunkInfo(WorldName, CX, CZ)
	local ByWorld = R.ChunkInfo[WorldName]
	if (ByWorld == nil) then
		return
	end
	local Key = ChunkKey(CX, CZ)
	if (ByWorld[Key] == nil) then
		return
	end
	ByWorld[Key] = nil
	-- 和 ForgetTile 同一个道理：不从 FIFO 里摘掉的话，这条失效条目之后
	-- 会在同一个键被重新写入时把活条目淘汰掉。
	local Order = R.ChunkInfoOrder[WorldName]
	if (Order ~= nil) then
		for i = #Order, 1, -1 do
			if (Order[i] == Key) then
				table.remove(Order, i)
			end
		end
	end
end

local function RefreshChunkInfo(World, ChunkList)
	local WorldName = World:GetName()
	local ByWorld = R.ChunkInfo[WorldName]
	if (ByWorld == nil) then
		ByWorld = {}
		R.ChunkInfo[WorldName] = ByWorld
	end
	local T = Now()
	local Center = 8 * 16 + 8

	for _, C in ipairs(ChunkList) do
		local CX, CZ = C[1], C[2]
		local Info = { CX = CX, CZ = CZ, Time = T }
		local ProbeX, ProbeZ = CX * 16 + 8, CZ * 16 + 8
		local Ok, H = World:TryGetHeight(ProbeX, ProbeZ)
		Info.Loaded = Ok and true or false
		local Tile = R.GetTile(WorldName, CX, CZ)
		Info.Remembered = (Tile ~= nil)
		Info.Entities = 0
		Info.Players = 0

		if Ok then
			Info.Height = H
			local Coords = Vector3i(ProbeX, H, ProbeZ)
			local Valid, Bt = World:GetBlockTypeMeta(Coords)
			if Valid then
				local N = ItemTypeToString(Bt)
				if (N == nil) or (N == "") then
					N = "block " .. tostring(Bt)
				end
				Info.BlockName = N
			end
			local Bio = World:GetBiomeAt(ProbeX, ProbeZ)
			if (Bio ~= nil) and (Bio >= 0) then
				Info.Biome = BiomeToString(Bio)
			end
		end

		if (Tile ~= nil) then
			if (Info.Height == nil) then
				Info.Height = R.TileHeightAt(Tile, Center)
			end
			if (Info.Biome == nil) or (Info.Biome == "") then
				local B = R.TileBiomeAt(Tile, Center)
				if (B ~= nil) then
					Info.Biome = BiomeToString(B)
				end
			end
		end

		if Info.Loaded then
			pcall(function ()
				World:ForEachEntityInChunk(CX, CZ, function ()
					Info.Entities = Info.Entities + 1
				end)
			end)
			World:ForEachPlayer(function (Player)
				local Pos = Player:GetPosition()
				if (Pos ~= nil) and (floor(Pos.x / 16) == CX) and (floor(Pos.z / 16) == CZ) then
					Info.Players = Info.Players + 1
				end
			end)
		end

		-- 详情缓存是唯一真正"无界"的表：只有 ForgetChunkInfo 会删它。
		-- 每天浏览下来会攒到几万条（每条约 250-300 B）。这里做 FIFO 封顶。
		-- 丢了会自愈：面板显示 … -> InfoStale -> 排一个 info 任务补回来。
		local Key = ChunkKey(CX, CZ)
		if (ByWorld[Key] == nil) then
			local Order = R.ChunkInfoOrder[WorldName]
			if (Order == nil) then
				Order = {}
				R.ChunkInfoOrder[WorldName] = Order
			end
			Order[#Order + 1] = Key
			local Max = R.Config.MaxChunkInfo or 4096
			while (#Order > Max) do
				local Old = table.remove(Order, 1)
				ByWorld[Old] = nil
			end
		end
		ByWorld[Key] = Info
	end
end

----------------------------------------------------------------------
-- 任务执行（只在 tick 线程上调用）
----------------------------------------------------------------------

-- 自动补全的冷却记录：区域键 -> 上次时间
R.AutoLoadLast = {}
R.AutoLoadInserted = 0    -- 距上次清扫新增了多少条（摊还清扫用）

--- R.AutoLoadLast 每访问一个新区域就多一条，从不清。
--- 但不能每 tick 全表扫（20/s × 世界数），所以攒够 256 条才扫一次：O(1) 摊还。
local function PruneAutoLoadLast(T)
	local Keep = (R.Config.AutoLoadCooldown or 60) * 4
	for Key, Stamp in pairs(R.AutoLoadLast) do
		if ((T - Stamp) >= Keep) then
			R.AutoLoadLast[Key] = nil
		end
	end
end

--- 最近一次"因为到了总量上限而拒绝加载"的记录。
--- tick 线程写、HTTP 线程读，纯 Lua 表（和 R.WorldCache 同性质，不碰 cWorld，安全）。
--- 页面读它来告诉用户为什么地图补不全 —— 否则按钮点下去没有任何反应。
R.LastLoadRefusal = nil

local LastRefusalLog = {}    -- [世界名] = 上次写日志的时间，给日志限流

--- 还能再加载多少个区块。没设上限时返回 nil。
--- World:GetNumChunks() 是**单世界**的，在世界的 tick 线程上调安全（不涉及跨世界锁）。
local function LoadBudget(World)
	local Max = R.Config.MaxLoadedChunks
	if (Max == nil) or (Max <= 0) then
		return nil
	end
	return Max - World:GetNumChunks()
end

local function RefuseLoad(World, Job, Loaded, Max)
	local WorldName = World:GetName()
	R.LastLoadRefusal = {
		Time = Now(),
		WorldName = WorldName,
		Loaded = Loaded,
		Max = Max,
		-- 用户明确点的（warm / 加载这些区块）和后台自动补全，提示语气不一样
		Explicit = (Job.Chunks ~= nil),
	}
	local T = Now()
	if ((T - (LastRefusalLog[WorldName] or -1e9)) >= 60) then
		LastRefusalLog[WorldName] = T
		Log(string.format(
			"%s 已加载 %d 个区块，达到上限 %d，跳过本次加载（日志最多每分钟一条）",
			WorldName, Loaded, Max))
	end
end

--- 只保留"当前尚未加载"的区块。
---
--- ⚠ 为什么必须筛（实测出来的，不是理论洁癖）：
--- cWorld:ChunkStay 对**已经加载**的区块不会逐个触发 OnChunkAvailable ——
--- 给 4 个已加载区块发 stay，逐块回调只响了 **1 次**，于是 OnAllChunksAvailable
--- **永远不触发**。后果有两层：
---   1. 这个 stay 永久悬住，它包含的区块被 stay 标记钉死，永远不参与卸载
---      （实测：625 个区块的 stay 悬了 3 分钟以上，已加载数一路只增不减）；
---   2. 完成回调永不执行 —— 自动补全的重绘、regen 后的快照重建全部失效。
--- 对照实验：2 个**未加载**区块 -> 逐块回调 2 次、全部就绪回调 1 次，
--- 加载完 2 秒后它们就被释放了（17011 -> 17009）。所以只要列表干净，stay 是正常的。
---
--- 这解释了插件最早那个"用半天堆到 5965 个区块、从不释放"的现象：
--- 视野里本来就既有已加载也有未加载的区块，混在一起发 stay 必然悬住。
local function IsChunkInMemory(World, C)
	return World:TryGetHeight(C[1] * 16 + 8, C[2] * 16 + 8) and true or false
end

--- 暂时拉黑的区块：本次会话里已经确认"发出去也等不到"的那些。
---
--- 依据：被生成器过载 skip 掉的区块会卡在 queued 状态，IsValid() 一直为假，
--- 于是 ChunkStay 的 ChunkAvailable 永远不会被调用。而**一个这样的区块就足以让
--- 整批区块悬住**（整批被 Stay(true) 钉死、完成回调永不执行），所以必须能跳过它们。
---
--- 为什么是"暂时"而不是永久：引擎其实**会重排**（cChunk::MarkLoadFailed 里
--- MarkDirty() 之后又 QueueGenerateChunk()），只是生成器还在过载时会再次被 skip。
--- 过载缓解后这些区块是有救的，所以给一个过期时间，到点再试。
R.BadChunks = {}    -- [世界名] = { [区块键] = 拉黑时刻 }
local BAD_CHUNK_TTL = 600    -- 秒：拉黑 10 分钟后允许重试

local STAY_STALE = 45    -- 秒：一个批次超过这么久没回来，就认定它等不到了
local PendingStays = {}  -- 在飞的批次，供看门狗超时接管

-- 一次 ChunkStay 最多要多少个区块。
-- 为什么要封顶（实测）：一次要 625 个会让生成器队列溢出，它**跳过**了其中 123 个
--（日志里新增的 "Chunk generator overloaded, skipping chunk" 正好也是 123 条），
-- 被跳过的区块永远不就绪 -> OnAllChunksAvailable 永远不触发 -> 整个 stay 悬住，
-- 连已经加载好的那 502 个也被一起钉死。分批把请求速率压到生成器吃得下的水平。
local STAY_BATCH = 64

--- 分批把这个列表加载进内存，全部就绪（或本来就在内存里）后执行 Done()。
---
--- ⚠ 这里有两件必须做的事，都是实测出来的，不是理论洁癖：
---
--- 1. **必须分批**（核心）。原因见 STAY_BATCH 的注释：一次要太多会让生成器过载，
---    而过载时被丢掉的正是不带玩家的区块（也就是 ChunkStay 要的这批）。
---    被丢的区块永远拿不到 IsValid()，于是 ChunkAvailable 永不调用、
---    OnAllChunksAvailable 永不触发 —— 整批被 Stay(true) 钉死，Done() 也永不执行。
---    这就是插件最早那个"正常用半天堆到 5965 个区块、从不释放"的根因。
---
--- 2. **列表里不含已加载的区块**：让 stay 更小、完成更快（stay 越大越容易触发过载）。
---    *修正一个曾经的误判*：我一开始按黑盒实验以为"含已加载区块会让 stay 悬住"，
---    读源码后否定了 —— cChunkMap::AddChunkStay 对已经 valid 的区块**会**逐个调
---    ChunkAvailable。当时那个现象（4 个区块只回调 1 次）真正的原因是那 4 个里
---    有 3 个其实处于 queued 状态并被 skip 了。教训：黑盒现象要先读源码再下结论。
local function LoadInBatches(World, Queue, Done)
	local WorldName = World:GetName()
	local Bad = R.BadChunks[WorldName]

	local function IssueBatch(Index)
		local Batch = {}
		while (Index <= #Queue) and (#Batch < STAY_BATCH) do
			local C = Queue[Index]
			Index = Index + 1
			-- 跳过：已经在内存里的，以及暂时拉黑的（后者会把整批拖死）
			-- 注意别写成 (Bad ~= nil) and Bad[...]：Bad 为 nil 时那个表达式是 false
			-- 而不是 nil，后面 Now() - BadAt 就会报 "arithmetic on a boolean"。
			local BadAt = nil
			if (Bad ~= nil) then
				BadAt = Bad[ChunkKey(C[1], C[2])]
			end
			local IsBad = (BadAt ~= nil) and ((Now() - BadAt) < BAD_CHUNK_TTL)
			if (not IsBad) and (not IsChunkInMemory(World, C)) then
				Batch[#Batch + 1] = C
			end
		end
		if (#Batch == 0) then
			-- 队列扫完了（本来就都在内存里，或已知坏的全部跳过）
			if (Index > #Queue) then
				Done()
			end
			return
		end

		R.StayStats.Started = R.StayStats.Started + 1
		R.StayStats.Chunks = R.StayStats.Chunks + #Batch

		-- 记一笔在飞的批次，交给看门狗（R.CheckStays）超时接管
		local Rec = { WorldName = WorldName, Queue = Queue, Index = Index, Done = Done, Time = Now(), Batch = Batch }
		PendingStays[#PendingStays + 1] = Rec

		local Ok = pcall(function ()
			World:ChunkStay(Batch, nil, function ()
				R.StayStats.Done = R.StayStats.Done + 1
				for i = 1, #PendingStays do
					if (PendingStays[i] == Rec) then
						table.remove(PendingStays, i)
						break
					end
				end
				IssueBatch(Index)
			end)
		end)
		if (not Ok) then
			for i = 1, #PendingStays do
				if (PendingStays[i] == Rec) then
					table.remove(PendingStays, i)
					break
				end
			end
			Done()
		end
	end

	IssueBatch(1)
end

--- 看门狗（每个世界 tick 调一次）：接管超时未完成的批次。
---
--- 为什么必须有它：被 skip 过的区块永久卡死（见 R.BadChunks 的注释），而一个坏区块
--- 就能让整批区块悬住 —— 那些区块会被 stay 标记钉死永不释放，Done()（重绘 / 重建快照）
--- 也永远不执行。超时后把这一批拉黑、跳过它们继续下一批，就能把损失限制在一批以内。
function R.CheckStays(World)
	if (#PendingStays == 0) then
		return
	end
	local WorldName = World:GetName()
	local T = Now()
	local i = 1
	while (i <= #PendingStays) do
		local Rec = PendingStays[i]
		if (Rec.WorldName ~= WorldName) or ((T - Rec.Time) < STAY_STALE) then
			i = i + 1
		else
			table.remove(PendingStays, i)
			local Bad = R.BadChunks[WorldName]
			if (Bad == nil) then
				Bad = {}
				R.BadChunks[WorldName] = Bad
			end
			for _, C in ipairs(Rec.Batch) do
				Bad[ChunkKey(C[1], C[2])] = T
			end
			local TLog = Now()
			if ((TLog - (R.LastStayTimeoutLog or -1e9)) >= 60) then
				R.LastStayTimeoutLog = TLog
				Log(string.format(
					"%s 有 %d 个区块的 ChunkStay 超过 %d 秒未完成（区块被生成器跳过而永久卡死），已拉黑并跳过（日志最多每分钟一条）",
					WorldName, #Rec.Batch, STAY_STALE))
			end
			-- 继续加载剩下的（不再等这一批）
			LoadInBatches(World, Rec.Queue, Rec.Done)
		end
	end
end

local function RunLoadJob(World, Job)
	local Opts = Job.Opts
	local Plan = R.Plan(Opts, World:GetSpawnX(), World:GetSpawnZ())

	local ChunkList = {}
	if (Job.Chunks ~= nil) then
		-- 明确指定了要加载哪些区块（管理面板的「加载这些区块」）
		for _, C in ipairs(Job.Chunks) do
			ChunkList[#ChunkList + 1] = { C[1], C[2] }
		end
	else
		-- 否则补全视野：从未见过的优先，其次才是记忆中的
		local _, _, Unknown, Remembered = R.ViewChunkInfo(World, Plan.OriginX, Plan.OriginZ, Plan.SizeChunks)
		local Sources = { Unknown }
		if Job.IncludeRemembered then
			Sources[#Sources + 1] = Remembered
		end
		local Max = Job.MaxChunks or 256
		for _, Source in ipairs(Sources) do
			for _, C in ipairs(Source) do
				if (#ChunkList >= Max) then
					break
				end
				ChunkList[#ChunkList + 1] = C
			end
			if (#ChunkList >= Max) then
				break
			end
		end
	end

	if (#ChunkList == 0) then
		return
	end

	-- 总量阀门：不整个拒绝，而是按剩余额度截断，上限附近是平滑逼近而不是突然停摆。
	-- 截断保留队列前部 —— 队列本来就是"从未见过的优先，其次记忆中"，所以留下的是最有价值的。
	-- （LoadAfterRegen 不走这里：那是用户明确要求的重新生成的后续，挡掉就又变回"地图留白洞"。）
	local Budget = LoadBudget(World)
	if (Budget ~= nil) then
		if (Budget <= 0) then
			RefuseLoad(World, Job, World:GetNumChunks(), R.Config.MaxLoadedChunks)
			return
		end
		for i = #ChunkList, Budget + 1, -1 do
			ChunkList[i] = nil
		end
	end

	-- 回调本来就在 tick 线程上跑，直接渲染结果写进缓存
	local RenderOpts = {
		Mode = Plan.Mode, SizeChunks = Plan.SizeChunks, Scale = Plan.Scale,
		CenterX = Plan.CenterX, CenterZ = Plan.CenterZ, NoCache = true,
	}

	-- 分批加载；全部就绪后重绘。
	-- 注意 Done 里调的是 Render 而不是"返回" —— 要的区块本来就在内存里时，
	-- LoadInBatches 会立刻调 Done，这次渲染不能丢。
	LoadInBatches(World, ChunkList, function ()
		pcall(function ()
			R.Render(World, RenderOpts)
		end)
	end)
end

--- 重新生成之后，把这些区块真的加载一次。
--- 为什么必须做：World:RegenerateChunk() 只是**排队**，区块不被加载就不会真正重生成；
--- 而快照也只在"已加载"时才会重建（见 Render 里的 IsLoaded 分支）。
--- 只删不加载的结果是地图上留下一个空白洞（实测：记忆中 DeepOcean Y=61 -> 从未见过）。
local function LoadAfterRegen(World, WorldName, ChunkList)
	local List = {}
	for i, C in ipairs(ChunkList) do
		List[i] = { C[1], C[2] }
	end
	if (#List == 0) then
		return
	end

	local function Rebuild()
		for _, C in ipairs(List) do
			pcall(function ()
				local Tile = R.BuildTile(World, C[1], C[2])
				if (Tile ~= nil) then
					R.PutTile(WorldName, C[1], C[2], Tile)
				end
				RefreshChunkInfo(World, { C })
			end)
		end
	end

	-- 走同一套分批加载。regen 的区块通常本来就是已加载的，LoadInBatches 会
	-- 立刻调 Rebuild（不会白等），所以这里不会退化成"地图上留一个空白洞"。
	LoadInBatches(World, List, Rebuild)
end

--- 跨插件调试出口：把插件自己持有的几个表的大小报出来。
---
--- 为什么需要它：插件的 Lua 堆**没法从外面量** —— 没有对应的 API，而 execute_lua
--- 跑在 MCPServer 的 Lua 状态里，CallPlugin 也只能调对方导出的函数。
--- 所以"哪些表在涨"只能靠读代码推算；有了这个出口就能直接看数。
---
-- luacheck: ignore WebChunkMap_SelfCheck WebChunkMap_BinDump WebChunkMap_ProfDump
-- luacheck: ignore WebChunkMap_ProfReset WebChunkMap_MemStats
--- 【迁移期测试】把缓存里最新一份画布 payload 落盘，返回它的元信息。
--- 只读缓存、不碰 cWorld，所以从 MCP 线程调用是安全的（铁律一）。
--- 写两个文件：deflate 后的（线上就是这个）和解压后的原始字节，供外部解码验证。
function WebChunkMap_BinDump()
	local Best, BestTime, BestKey = nil, nil, nil
	for Key, Cached in pairs(R.Cache) do
		if (Cached.Bin ~= nil) and ((BestTime == nil) or (Cached.Time > BestTime)) then
			Best, BestTime, BestKey = Cached, Cached.Time, Key
		end
	end
	if (Best == nil) then
		return { Ok = false, Error = "缓存里还没有画布 payload（先请求一次地图）" }
	end
	local Folder = R.PluginFolder or "."
	local F = io.open(Folder .. "/cache/last_bin.bin", "wb")
	if (F ~= nil) then
		F:write(Best.Bin)
		F:close()
	end
	local Raw = nil
	local OkZ, Un = pcall(cStringCompression.DecompressStringZLIB, Best.Bin, #Best.Bin + 65536)
	if OkZ then
		Raw = Un
		local F2 = io.open(Folder .. "/cache/last_bin_raw.bin", "wb")
		if (F2 ~= nil) then
			F2:write(Raw)
			F2:close()
		end
	end
	return {
		Ok = true,
		Key = BestKey,
		Header = BIN_HEADER,
		CompressedBytes = #Best.Bin,
		RawBytes = (Raw ~= nil) and #Raw or -1,
		StoredRaw = Best.BinRawBytes,
		Meta = Best.Meta,
	}
end

--- 自检：验证每个快照的"调色板形式"能不能无损还原出 RGB 段。
--- 迁移期间用（确认 v2->v3 的升级没有写坏颜色），结果是个纯值表，跨插件可读。
function WebChunkMap_SelfCheck()
	local Res = { Total = 0, Ok = 0, Mismatch = 0, Fallback = 0, BadLen = 0,
		Version = VERSION, TileSize = TILE_SIZE, PerWorld = {} }
	for WorldName, T in pairs(R.Tiles) do
		local n = 0
		for _, Tile in pairs(T) do
			n = n + 1
			Res.Total = Res.Total + 1
			if (#Tile ~= TILE_SIZE) then
				Res.BadLen = Res.BadLen + 1
			else
				local RGB = R.TilePaletteRGB(Tile)
				if (RGB == nil) then
					Res.Fallback = Res.Fallback + 1
				elseif (RGB == Tile:sub(1, TILE_COLORS)) then
					Res.Ok = Res.Ok + 1
				else
					Res.Mismatch = Res.Mismatch + 1
				end
			end
		end
		Res.PerWorld[#Res.PerWorld + 1] = WorldName .. "=" .. n
	end
	return Res
end
--- 分阶段耗时（每次渲染的毫秒均值），用来定位渲染热点。
function WebChunkMap_ProfDump()
	local N = math.max(R.Stats.Renders, 1)
	return {
		Renders = R.Stats.Renders,
		Grid = R.Stats.PhaseGrid * 1000 / N,
		Markers = R.Stats.PhaseMarkers * 1000 / N,
		Struct = R.Stats.PhaseStruct * 1000 / N,
		Pixels = R.Stats.PhasePixels * 1000 / N,
		Png = R.Stats.PhasePng * 1000 / N,
		LastRenderMs = R.Stats.LastRenderMs,
		TileBuilds = R.Stats.TileBuilds,
		LiveTiles = R.Stats.LiveTiles,
		ReusedTiles = R.Stats.ReusedTiles,
	}
end

function WebChunkMap_ProfReset()
	R.Stats.PhaseGrid, R.Stats.PhaseMarkers, R.Stats.PhaseStruct, R.Stats.PhasePixels, R.Stats.PhasePng = 0, 0, 0, 0, 0
	R.Stats.Renders, R.Stats.LastRenderMs = 0, 0
end
--- 用法：cPluginManager:CallPlugin("WebChunkMap", "WebChunkMap_MemStats")
--- 返回值只能是简单表/数字/字符串（跨插件不能传函数）。
function WebChunkMap_MemStats()
	local function Count(T)
		local n = 0
		for _ in pairs(T) do n = n + 1 end
		return n
	end
	local Sum = function (PerWorld, UseLen)
		local n = 0
		for _, V in pairs(PerWorld) do
			n = n + (UseLen and #V or Count(V))
		end
		return n
	end

	local LuaKiB = -1
	pcall(function ()
		LuaKiB = floor(collectgarbage("count") or 0)
	end)

	return {
		LuaKiB         = LuaKiB,                       -- 本插件 Lua 状态占用的 KiB
		Tiles          = R.TileStats(nil),
		TileOrder      = Sum(R.TileOrder, true),
		ChunkInfo      = Sum(R.ChunkInfo, false),
		ChunkInfoOrder = Sum(R.ChunkInfoOrder, true),
		StayStarted    = R.StayStats.Started,
		StayDone       = R.StayStats.Done,
		StayPending    = R.StayStats.Started - R.StayStats.Done,
		StayInFlight   = #PendingStays,
		StayChunks     = R.StayStats.Chunks,
		BadChunks      = Sum(R.BadChunks, false),
		CacheEntries   = Count(R.Cache),
		CacheOrder     = #R.CacheOrder,
		AutoLoadLast   = Count(R.AutoLoadLast),
		Jobs           = #R.Jobs,
		MaxTiles       = R.Config.MaxTiles,
		MaxChunkInfo   = R.Config.MaxChunkInfo,
	}
end

--- 处理一个任务；返回是否真的处理了（由 HOOK_WORLD_TICK 调用）。
function R.RunOneJob(World)
	local Job = R.Jobs[1]
	if (Job == nil) then
		return false
	end
	if (Job.WorldName ~= nil) and (Job.WorldName ~= World:GetName()) then
		return false
	end
	table.remove(R.Jobs, 1)

	local Kind = Job.Kind
	local Ok, Err = pcall(function ()
		if (Kind == "render") then
			local _, Meta = R.Render(World, Job.Opts)
			-- 渲染完顺手把"从未见过"的区块排进加载队列，这样一路平移地图会自己补全
			if (Meta ~= nil) and R.Config.AutoLoadOnView and (Meta.WarmMissingUnknown > 0) then
				local RegionKey = Job.WorldName .. ":" .. Meta.OriginChunkX .. ":" .. Meta.OriginChunkZ .. ":" .. Meta.SizeChunks
				local T = Now()
				local Last = R.AutoLoadLast[RegionKey]
				if (Last == nil) or ((T - Last) >= R.Config.AutoLoadCooldown) then
					if (Last == nil) then
						R.AutoLoadInserted = R.AutoLoadInserted + 1
						if (R.AutoLoadInserted >= 256) then
							R.AutoLoadInserted = 0
							PruneAutoLoadLast(T)
						end
					end
					R.AutoLoadLast[RegionKey] = T
					RunLoadJob(World, {
						Opts = Job.Opts,
						IncludeRemembered = false,
						MaxChunks = R.Config.AutoLoadMaxChunks,
					})
				end
			end
		elseif (Kind == "load") then
			RunLoadJob(World, Job)
		elseif (Kind == "info") then
			RefreshChunkInfo(World, Job.Chunks)
		elseif (Kind == "regen") then
			for _, C in ipairs(Job.Chunks) do
				World:RegenerateChunk(C[1], C[2])
				R.ForgetTile(Job.WorldName, C[1], C[2])
			end
			R.FlushCache()
			-- 只排队不够：不加载就不会真的重生成，快照也重建不了（会留个空白洞）
			LoadAfterRegen(World, Job.WorldName, Job.Chunks)
		elseif (Kind == "teleport") then
			local X, Z = Job.X, Job.Z
			local Ok2, H = World:TryGetHeight(X, Z)
			local Y = (Ok2 and H or 64) + 2
			-- 用 World:ForEachPlayer 而不是 cRoot:ForEachPlayer：后者会跨世界遍历，
			-- 在世界的 tick 线程上同样是跨世界访问。
			World:ForEachPlayer(function (Player)
				if (string.lower(Player:GetName()) == string.lower(Job.Player)) then
					Player:TeleportToCoords(X, Y, Z)
					Job.Moved = (Job.Moved or 0) + 1
				end
			end)
			R.LastAction = Job.Moved and ("已把 " .. Job.Player .. " 传送到 " .. X .. ", " .. Y .. ", " .. Z .. "。")
				or nil
			R.LastActionError = Job.Error
		end
	end)

	R.JobStats.Done = R.JobStats.Done + 1
	if not Ok then
		Log("任务 " .. tostring(Kind) .. " 执行出错: " .. tostring(Err))
	end
	return true
end

