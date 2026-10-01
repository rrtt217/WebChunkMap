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
	PngFactor = 6,

	RememberTiles = true,     -- 是否记住曾经加载过的区块
	RememberedShade = 1.0,    -- 记忆中的区块的压暗系数（1.0 = 与实时一致）
	MaxTiles = 6000,          -- 快照数量上限（每个约 1 KiB 内存 + 磁盘）
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

	local Body = {}
	local Count = 0
	for WorldName, Tiles in pairs(R.Tiles) do
		local NameLen = #WorldName
		if (NameLen <= 255) then
			for Key, Tile in pairs(Tiles) do
				local CX = floor(Key / 2097152) - 1048576
				local CZ = (Key % 2097152) - 1048576
				Body[#Body + 1] = char(NameLen) .. WorldName .. PackI32(CX) .. PackI32(CZ) .. Tile
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
	if (#Body > 0) then
		F:write(concat(Body))
	end
	F:close()

	if (os ~= nil) and (os.rename ~= nil) then
		os.rename(Path .. ".tmp", Path)
	end

	R.Dirty = {}
	R.LastSave = Now()
	Log(string.format("区块快照已保存：%d 个区块，%.1f KiB", Count, (#concat(Body) + 11) / 1024))
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

	local Data = F:read("*a")
	F:close()
	if (Data == nil) or (#Data < 11) or (Data:sub(1, 4) ~= MAGIC) then
		Log("快照文件头无效，忽略")
		return 0
	end

	local Ver = UnpackU16(Data, 5)
	if (Ver ~= VERSION) then
		Log("快照版本不匹配（文件 " .. tostring(Ver) .. "，期望 " .. VERSION .. "），忽略")
		return 0
	end

	local Count = UnpackU32(Data, 7)
	local P = 11
	local Loaded = 0
	for _ = 1, Count do
		local NameLen = Data:byte(P)
		if (NameLen == nil) then
			break
		end
		P = P + 1
		local WorldName = Data:sub(P, P + NameLen - 1)
		P = P + NameLen
		local CX = UnpackI32(Data, P)
		P = P + 4
		local CZ = UnpackI32(Data, P)
		P = P + 4
		local Tile = Data:sub(P, P + TILE_SIZE - 1)
		P = P + TILE_SIZE
		if ((CX ~= nil) and (CZ ~= nil) and (#Tile == TILE_SIZE)) then
			R.PutTile(WorldName, CX, CZ, Tile, true)
			Loaded = Loaded + 1
		else
			break
		end
	end

	R.Dirty = {}
	Log("已载入 " .. Loaded .. " 个区块快照（" .. string.format("%.1f", #Data / 1024) .. " KiB）")
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
	R.CacheOrder[#R.CacheOrder + 1] = Key
	while (#R.CacheOrder > Cfg.MaxCacheEntries) do
		local Old = table.remove(R.CacheOrder, 1)
		if (Old ~= Key) then
			R.Cache[Old] = nil
		else
			R.CacheOrder[#R.CacheOrder + 1] = Old
		end
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

function R.GetChunkInfo(WorldName, CX, CZ)
	local ByWorld = R.ChunkInfo[WorldName]
	if (ByWorld == nil) then
		return nil
	end
	return ByWorld[ChunkKey(CX, CZ)]
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

		ByWorld[ChunkKey(CX, CZ)] = Info
	end
end

----------------------------------------------------------------------
-- 任务执行（只在 tick 线程上调用）
----------------------------------------------------------------------

-- 自动补全的冷却记录：区域键 -> 上次时间
R.AutoLoadLast = {}

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

