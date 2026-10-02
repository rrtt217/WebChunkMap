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
R.Stats = { Renders = 0, CacheHits = 0, LiveTiles = 0, ReusedTiles = 0, LastRenderMs = 0, TileBuilds = 0 }

local TILE_COLORS  = 768    -- 16 * 16 * 3  顶面颜色
local TILE_HEIGHTS = 256    -- 16 * 16      地表高度（h+1，0 = 未知）
local TILE_BIOMES  = 256    -- 16 * 16      生物群系（biome+1，0 = 未知）
local OFF_HEIGHTS  = TILE_COLORS
local OFF_BIOMES   = TILE_COLORS + TILE_HEIGHTS
local TILE_SIZE    = TILE_COLORS + TILE_HEIGHTS + TILE_BIOMES

local MAGIC = "WCMT"
local VERSION = 2

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

local function Now()
	if (os ~= nil) and (os.time ~= nil) then
		return os.time()
	end
	-- 兜底：不要用 cRoot:Get():GetServerUpTime()，避免在世界的 tick 线程上碰 cRoot
	return floor(R.TickCount / 20)
end

R.Now = Now

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
		UnknownTileCache = concat(Colors) .. char(0):rep(TILE_HEIGHTS + TILE_BIOMES)
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
	if (Ver ~= VERSION) then
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
		local RecordBytes = NameLen + 8 + TILE_SIZE
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
		local Tile = Rest:sub(NameLen + 9, NameLen + 8 + TILE_SIZE)
		if ((CX ~= nil) and (CZ ~= nil) and (#Tile == TILE_SIZE)) then
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
	return concat(Colors) .. char(unpack(Heights)) .. char(unpack(Biomes))
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
	World:ForEachPlayer(function (Player)
		local Pos = Player:GetPosition()
		if (Pos ~= nil) then
			Plot(Pos.x, Pos.z, 230, 60, 60, 1)
			Plot(Pos.x, Pos.z, 255, 255, 255, 0)
			Count = Count + 1
		end
	end)

	if (R.Config.DrawSpawn) then
		Plot(World:GetSpawnX(), World:GetSpawnZ(), 70, 160, 255, 1)
		Plot(World:GetSpawnX(), World:GetSpawnZ(), 255, 255, 255, 0)
	end

	return Markers, Count
end

-- biome 图层里没有生物群系数据时的颜色
local NoBiomeColor = { 96, 100, 110 }

-- 区块状态配色（chunks 图层）
local StateColors = {
	[0] = { 62, 66, 78 },     -- 未知（从未加载过）
	[1] = { 150, 158, 102 },  -- 记忆中的快照
	[2] = { 96, 160, 82 },    -- 当前已加载
}

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
	local ImgSize = Plan.Width
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

	local Markers, PlayerCount = nil, 0
	if (Cfg.DrawPlayers or Cfg.DrawSpawn) then
		Markers, PlayerCount = CollectMarkers(World, OriginX, OriginZ, Blocks)
	end

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

	local GridFactor = 0.74
	local Shade = Cfg.RememberedShade

	local Out = {}
	for bz = 0, Blocks - 1 do
		local RowChunk = floor(bz / 16)
		local ty = bz % 16
		local RowChunkBase = RowChunk * SizeChunks
		local Row, n = {}, 0

		for bx = 0, Blocks - 1 do
			local Cr, Cg, Cb

			if (Mode == "biome") then
				local BG = BiomeGrid[RowChunkBase + floor(bx / 16) + 1]
				local B = 0
				if (BG ~= nil) then
					B = BG:byte(ty * 16 + (bx % 16) + 1) or 0
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
				local gi = RowChunkBase + floor(bx / 16) + 1
				local State = StateGrid[gi] or 0

				if (Mode == "chunks") then
					local C = StateColors[State]
					Cr, Cg, Cb = C[1], C[2], C[3]
				else
					local Tile = TileGrid[gi]
					local ti = (ty * 16 + (bx % 16)) * 3 + 1
					Cr, Cg, Cb = Tile:byte(ti, ti + 2)

					-- 山体阴影：向西北邻居取高度，跨区块连续
					if Cfg.HillShading and (bx > 0) and (bz > 0) and (State ~= 0) then
						local nbx, nbz = bx - 1, bz - 1
						local nt = TileGrid[floor(nbz / 16) * SizeChunks + floor(nbx / 16) + 1]
						if (nt ~= nil) then
							local Here = Tile:byte(TILE_COLORS + ty * 16 + (bx % 16) + 1)
							local There = nt:byte(TILE_COLORS + (nbz % 16) * 16 + (nbx % 16) + 1)
							if (Here > 0) and (There > 0) then
								local F = 1 + (Here - There) * 0.05
								if (F > 1.35) then F = 1.35 end
								if (F < 0.62) then F = 0.62 end
								Cr = floor(Cr * F)
								Cg = floor(Cg * F)
								Cb = floor(Cb * F)
							end
						end
					end

					if (State == 1) and (Shade ~= 1) then
						Cr = floor(Cr * Shade)
						Cg = floor(Cg * Shade)
						Cb = floor(Cb * Shade)
					end
				end
			end

			-- 区块边界
			if Cfg.DrawChunkGrid and (((bx % 16) == 0) or ((bz % 16) == 0)) then
				Cr = floor(Cr * GridFactor)
				Cg = floor(Cg * GridFactor)
				Cb = floor(Cb * GridFactor)
			end

			-- 结构标记（压在玩家 / 出生点下面，别把玩家盖住）
			if (StructMarkers ~= nil) then
				local Mk = StructMarkers[bx * 4096 + bz]
				if (Mk ~= nil) then
					Cr, Cg, Cb = Mk[1], Mk[2], Mk[3]
				end
			end

			-- 玩家 / 出生点标记
			if (Markers ~= nil) then
				local Mk = Markers[bx * 4096 + bz]
				if (Mk ~= nil) then
					Cr, Cg, Cb = Mk[1], Mk[2], Mk[3]
				end
			end

			if (Cr > 255) then Cr = 255 elseif (Cr < 0) then Cr = 0 end
			if (Cg > 255) then Cg = 255 elseif (Cg < 0) then Cg = 0 end
			if (Cb > 255) then Cb = 255 elseif (Cb < 0) then Cb = 0 end

			n = n + 1
			Row[n] = char(Cr, Cg, Cb):rep(Scale)
		end

		local RowStr = concat(Row)
		for _ = 1, Scale do
			Out[#Out + 1] = RowStr
		end
	end

	local Pixels = concat(Out)
	local Png = WCM_Png.Encode(ImgSize, ImgSize, Pixels, Cfg.PngFactor)

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
		Width = ImgSize,
		Height = ImgSize,
		Players = PlayerCount,
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
		PngBytes = #Png,
	}

	R.Stats.Renders = R.Stats.Renders + 1
	R.Stats.LastRenderMs = Meta.RenderMs

	R.Cache[Key] = { Time = Time, Png = Png, Meta = Meta }

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

	-- 按像素预算收缩：优先落到预设档位
	if ((SizeChunks * 16 * Scale) * (SizeChunks * 16 * Scale)) > Cfg.MaxPixels then
		local Best = nil
		for _, Step in ipairs(R.SizeSteps) do
			if (Step <= SizeChunks) and (((Step * 16 * Scale) * (Step * 16 * Scale)) <= Cfg.MaxPixels) then
				Best = Step
			end
		end
		if (Best ~= nil) then
			SizeChunks = Best
		else
			while (SizeChunks > 1) and (((SizeChunks * 16 * Scale) * (SizeChunks * 16 * Scale)) > Cfg.MaxPixels) do
				SizeChunks = SizeChunks - 1
			end
		end
	end

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
		Blocks = Blocks,
		Width = Blocks * Scale,
		Height = Blocks * Scale,
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

	local ChunkStayList = {}
	for i, C in ipairs(ChunkList) do
		ChunkStayList[i] = { C[1], C[2] }
	end

	-- 回调本来就在 tick 线程上跑，直接渲染结果写进缓存
	local RenderOpts = {
		Mode = Plan.Mode, SizeChunks = Plan.SizeChunks, Scale = Plan.Scale,
		CenterX = Plan.CenterX, CenterZ = Plan.CenterZ, NoCache = true,
	}
	pcall(function ()
		World:ChunkStay(ChunkStayList, nil, function ()
			pcall(function ()
				R.Render(World, RenderOpts)
			end)
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

	-- ChunkStay 是异步的，回调在所有区块就绪后于 tick 线程上执行
	pcall(function ()
		World:ChunkStay(List, nil, function ()
			for _, C in ipairs(List) do
				pcall(function ()
					local Tile = R.BuildTile(World, C[1], C[2])
					if (Tile ~= nil) then
						R.PutTile(WorldName, C[1], C[2], Tile)
					end
					RefreshChunkInfo(World, { C })
				end)
			end
		end)
	end)
end

--- 跨插件调试出口：把插件自己持有的几个表的大小报出来。
---
--- 为什么需要它：插件的 Lua 堆**没法从外面量** —— 没有对应的 API，而 execute_lua
--- 跑在 MCPServer 的 Lua 状态里，CallPlugin 也只能调对方导出的函数。
--- 所以"哪些表在涨"只能靠读代码推算；有了这个出口就能直接看数。
---
-- luacheck: ignore WebChunkMap_MemStats
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

