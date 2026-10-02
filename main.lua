-- main.lua
-- WebChunkMap 入口：读配置、载入区块快照、注册 WebAdmin 标签页与命令。

--- 确保 settings.ini 存在：没有就从 settings.ini.example 复制一份。
-- settings.ini 是"每台机器各自的配置"，不进版本库；进库的是 settings.ini.example。
-- 这样在任何机器上改配置都不会弄脏工作区，也不会和 git pull 打架。
local function EnsureSettingsFile(Folder)
	local Path = Folder .. "/settings.ini"

	if (io == nil) or (io.open == nil) then
		return false
	end

	local F = io.open(Path, "rb")
	if (F ~= nil) then
		F:close()
		return true
	end

	local Src = io.open(Folder .. "/settings.ini.example", "rb")
	if (Src == nil) then
		LOG("WebChunkMap: 既没有 settings.ini 也没有 settings.ini.example，将全部使用内置默认值")
		return false
	end
	local Data = Src:read("*a")
	Src:close()

	local Dst = io.open(Path, "wb")
	if (Dst == nil) then
		LOG("WebChunkMap: 无法创建 " .. Path .. "，将全部使用内置默认值")
		return false
	end
	Dst:write(Data)
	Dst:close()

	LOG("WebChunkMap: 已从 settings.ini.example 生成 settings.ini（可自由修改，不会进版本库）")
	return true
end

--- 读取 settings.ini（键不存在时用默认值）。
local function ReadSettings(Folder)
	local Ini = cIniFile()
	Ini:ReadFile(Folder .. "/settings.ini")

	return {
		TabTitle      = Ini:GetValueSet("Web", "TabTitle", "Chunk Map"),
		DefaultSize   = Ini:GetValueSetI("Web", "DefaultSizeChunks", 8),
		DefaultScale  = Ini:GetValueSetI("Web", "DefaultScale", 2),
		DefaultMode   = Ini:GetValueSet("Web", "DefaultMode", "topo"),
		InlineImages  = Ini:GetValueSetB("Web", "UseInlineImages", true),

		CacheTTL      = Ini:GetValueSetI("Render", "CacheTTL", 600),
		MaxCache      = Ini:GetValueSetI("Render", "MaxCacheEntries", 24),
		MaxPixels     = Ini:GetValueSetI("Render", "MaxPixels", 1000000),
		MaxSizeChunks = Ini:GetValueSetI("Render", "MaxSizeChunks", 48),
		DrawChunkGrid = Ini:GetValueSetB("Render", "DrawChunkGrid", true),
		HillShading   = Ini:GetValueSetB("Render", "HillShading", true),
		DrawPlayers   = Ini:GetValueSetB("Render", "DrawPlayers", true),
		DrawStructures = Ini:GetValueSetB("Render", "DrawStructures", true),
		PngFactor     = Ini:GetValueSetI("Render", "PngCompression", 6),

		RememberTiles    = Ini:GetValueSetB("Cache", "RememberChunks", true),
		RememberedShade  = Ini:GetValueSetF("Cache", "RememberedShade", 1.0),
		MaxTiles         = Ini:GetValueSetI("Cache", "MaxChunks", 6000),
		MaxLoadedChunks  = Ini:GetValueSetI("Cache", "MaxLoadedChunks", 0),
		SaveInterval     = Ini:GetValueSetI("Cache", "SaveInterval", 300),
		AutoLoadOnView   = Ini:GetValueSetB("Cache", "AutoLoadOnView", true),
		AutoLoadMax      = Ini:GetValueSetI("Cache", "AutoLoadMaxChunks", 256),
		MaxWarmChunks    = Ini:GetValueSetI("Cache", "MaxWarmChunks", 512),
		AutoLoadCooldown = Ini:GetValueSetI("Cache", "AutoLoadCooldown", 10),
	}
end

--- WebAdmin 里这张地图的地址（供玩家命令显示）。
local function GetMapURL()
	local Port = "?"
	local WebAdmin = cRoot:Get():GetWebAdmin()
	if (WebAdmin ~= nil) then
		local Ports = WebAdmin:GetPorts()
		if (Ports ~= nil) and (Ports ~= "") then
			Port = tostring(Ports):match("%d+") or Ports
		end
	end
	return "http://<server>:" .. Port .. "/webadmin/" .. g_PluginInfo.Name .. "/map"
end

--- /chunkmap : 告诉玩家地图地址。
function HandleChunkMapCommand(Split, Player)
	Player:SendMessageInfo("WebAdmin 区块地图: " .. GetMapURL())
	Player:SendMessageInfo("区块快照 " .. WCM_Render.TileStats(nil) .. " 个，上次渲染 "
		.. WCM_Render.Stats.LastRenderMs .. " ms")
	return true
end

--- 控制台命令：chunkmap status | flush | save | forget <world> all | render ...
function HandleChunkMapConsole(Split, EntireCommand)
	local Sub = string.lower(Split[2] or "status")

	if (Sub == "flush") then
		WCM_Render.FlushCache()
		LOG("WebChunkMap: 图片缓存已清空（区块快照保留）")
		return true
	end

	if (Sub == "save") then
		local N, Reason = WCM_Render.SaveTiles(true)
		LOG("WebChunkMap: 保存结果 " .. tostring(Reason) .. "，写入 " .. tostring(N) .. " 个区块快照")
		return true
	end

	if (Sub == "forget") then
		local WorldName = Split[3]
		if (WorldName == nil) then
			LOG("用法: chunkmap forget <world> all   （只清快照，不动世界数据）")
			return true
		end
		if (Split[4] == "all") then
			local Tiles = WCM_Render.Tiles[WorldName]
			local N = 0
			if (Tiles ~= nil) then
				for _ in pairs(Tiles) do
					N = N + 1
				end
				WCM_Render.Tiles[WorldName] = {}
				WCM_Render.TileOrder[WorldName] = {}
				WCM_Render.TileCount[WorldName] = 0
				WCM_Render.Dirty[WorldName] = true
			end
			WCM_Render.FlushCache()
			LOG("WebChunkMap: 已清除世界 " .. WorldName .. " 的 " .. N .. " 个区块快照")
		else
			local CX = tonumber(Split[4])
			local CZ = tonumber(Split[5])
			if (CX == nil) or (CZ == nil) then
				LOG("用法: chunkmap forget <world> <cx> <cz> | <world> all")
				return true
			end
			local Ok = WCM_Render.ForgetTile(WorldName, CX, CZ)
			WCM_Render.FlushCache()
			LOG("WebChunkMap: 清除区块 (" .. CX .. ", " .. CZ .. ") 的快照: " .. tostring(Ok))
		end
		return true
	end

	if (Sub == "render") then
		local WorldName = Split[3]
		local CX = tonumber(Split[4])
		local CZ = tonumber(Split[5])
		local Size = tonumber(Split[6]) or 8
		local Scale = tonumber(Split[7]) or 1
		-- 这里连 cWorld 都不去取：只认世界名，坐标缺省交给 tick 线程用世界出生点补。
		local Target = WorldName
		if (Target == nil) or (WCM_Render.KnownWorlds[Target] ~= true) then
			Target = WCM_Render.DefaultWorldName
		end
		if (Target == nil) then
			LOG("WebChunkMap: 世界还没登记（等几秒再试）")
			return true
		end
		WCM_Render.Enqueue({
			Kind = "render", WorldName = Target,
			Opts = {
				Mode = "topo",
				SizeChunks = Size,
				Scale = Scale,
				CenterX = CX,
				CenterZ = CZ,
				NoCache = true,
			},
		})
		LOG("WebChunkMap: 已把渲染 " .. Target .. " (" .. tostring(CX) .. "," .. tostring(CZ)
			.. ") 的任务排队，稍后看日志")
		return true
	end

	-- status
	LOG("WebChunkMap 状态:")
	LOG("  地址        " .. GetMapURL())
	LOG("  默认        " .. WCM_Web.DefaultMode .. "，视野 " .. WCM_Web.DefaultSize .. " 区块，缩放 "
		.. WCM_Web.DefaultScale .. "x，内联图片 " .. tostring(WCM_Web.InlineImages))
	-- 上限是**按世界**算的（PutTile 只淘汰本世界的快照），所以这里先给总数、
	-- 再说清"每世界上限"，免得总数 6072 对上限 6000 看着像超了（其实 world 5992 并没超）。
	LOG("  区块快照    共 " .. WCM_Render.TileStats(nil) .. " 个，每世界上限 " .. WCM_Render.Config.MaxTiles
		.. "（各世界用量见下）" .. (WCM_Render.IsDirty() and "（有未落盘的改动）" or "（已落盘）"))
	for WorldName, Count in pairs(WCM_Render.TileCount) do
		local MinCX, MaxCX, MinCZ, MaxCZ = nil, nil, nil, nil
		if (WCM_Render.Tiles[WorldName] ~= nil) then
			for Key in pairs(WCM_Render.Tiles[WorldName]) do
				local CX = math.floor(Key / 2097152) - 1048576
				local CZ = (Key % 2097152) - 1048576
				if (MinCX == nil) or (CX < MinCX) then MinCX = CX end
				if (MaxCX == nil) or (CX > MaxCX) then MaxCX = CX end
				if (MinCZ == nil) or (CZ < MinCZ) then MinCZ = CZ end
				if (MaxCZ == nil) or (CZ > MaxCZ) then MaxCZ = CZ end
			end
		end
		LOG("    " .. WorldName .. ": " .. Count .. " 个，区块 X "
			.. tostring(MinCX) .. ".." .. tostring(MaxCX) .. "，Z "
			.. tostring(MinCZ) .. ".." .. tostring(MaxCZ))
	end
	LOG("  图片缓存    " .. #WCM_Render.CacheOrder .. " 条 / TTL " .. WCM_Render.Config.CacheTTL .. " 秒")
	LOG("  统计        渲染 " .. WCM_Render.Stats.Renders .. " 次（命中 " .. WCM_Render.Stats.CacheHits
		.. "），新区块快照 " .. WCM_Render.Stats.LiveTiles .. "，复用 " .. WCM_Render.Stats.ReusedTiles)
	LOG("  任务队列    " .. WCM_Render.PendingCount() .. " 个待处理，已完成 " .. WCM_Render.JobStats.Done
		.. "，丢弃 " .. WCM_Render.JobStats.Dropped)
	LOG("  用法        chunkmap flush | save | forget <world> all | render [world] [cx] [cz] [size] [scale]")
	return true
end

--- 每 tick：刷新世界信息缓存、执行排队的任务（世界访问只在这里发生）、必要时落盘。
function OnWorldTick(World, TimeDelta)
	WCM_Render.RefreshWorldCache(World)

	-- 每 tick 只处理一个任务：任务里可能包含渲染和区块加载，别把 tick 线程占太久
	local Budget = 1
	while (Budget > 0) and WCM_Render.RunOneJob(World) do
		Budget = Budget - 1
	end

	WCM_Render.MaybeSave()
end

function Initialize(Plugin)
	Plugin:SetName(g_PluginInfo.Name)
	Plugin:SetVersion(1)

	local Folder = Plugin:GetLocalFolder()
	EnsureSettingsFile(Folder)
	local Cfg = ReadSettings(Folder)

	WCM_Web.DefaultSize  = Cfg.DefaultSize
	WCM_Web.DefaultScale = Cfg.DefaultScale
	WCM_Web.DefaultMode  = Cfg.DefaultMode
	WCM_Web.InlineImages = Cfg.InlineImages
	WCM_Web.MaxWarmChunks = Cfg.MaxWarmChunks

	-- 默认世界只在这里解析一次。Initialize 不在世界 tick 线程上，读 cRoot 是安全的
	-- （只是查世界列表，不碰 chunkmap），不能放到 RefreshWorldCache 里按"先到先得"决定。
	pcall(function ()
		local Default = cRoot:Get():GetDefaultWorld()
		if (Default ~= nil) then
			WCM_Render.DefaultWorldName = Default:GetName()
		end
	end)
	if (WCM_Render.DefaultWorldName ~= nil) then
		LOG("WebChunkMap: 默认世界 = " .. WCM_Render.DefaultWorldName)
	else
		LOG("WebChunkMap: 取不到默认世界，将退化为“第一个 tick 的世界”")
	end

	WCM_Render.Configure({
		CacheTTL = Cfg.CacheTTL,
		MaxCacheEntries = Cfg.MaxCache,
		MaxPixels = Cfg.MaxPixels,
		MaxSizeChunks = Cfg.MaxSizeChunks,
		DrawChunkGrid = Cfg.DrawChunkGrid,
		HillShading = Cfg.HillShading,
		DrawPlayers = Cfg.DrawPlayers,
		DrawSpawn = Cfg.DrawPlayers,
		DrawStructures = Cfg.DrawStructures,
		PngFactor = Cfg.PngFactor,
		RememberTiles = Cfg.RememberTiles,
		RememberedShade = Cfg.RememberedShade,
		MaxTiles = Cfg.MaxTiles,
		MaxLoadedChunks = Cfg.MaxLoadedChunks,
		SaveInterval = Cfg.SaveInterval,
		AutoLoadOnView = Cfg.AutoLoadOnView,
		AutoLoadMaxChunks = Cfg.AutoLoadMax,
		AutoLoadCooldown = Cfg.AutoLoadCooldown,
	})

	-- 载入历史区块快照（必须在 Configure 之后，才能应用 MaxTiles 上限）
	WCM_Render.LoadTiles(Folder)

	cPluginManager:AddHook(cPluginManager.HOOK_WORLD_TICK, OnWorldTick)

	cWebAdmin:AddWebTab(Cfg.TabTitle, "map", WCM_Web.HandleRequest)

	cPluginManager:BindCommand("/chunkmap", "", HandleChunkMapCommand, " - 显示 WebAdmin 区块地图地址")
	cPluginManager:BindConsoleCommand("chunkmap", HandleChunkMapConsole,
		"chunkmap status | flush | save | forget <world> all | render [world] [cx] [cz] [size] [scale]")

	LOG("WebChunkMap: 已注册 WebAdmin 标签页 \"" .. Cfg.TabTitle .. "\"，区块快照 "
		.. WCM_Render.TileStats(nil) .. " 个")
	return true
end

function OnDisable()
	WCM_Render.FlushCache()
	local N, Reason = WCM_Render.SaveTiles(true)
	LOG("WebChunkMap: 已停用，快照保存 " .. tostring(Reason) .. "（" .. tostring(N) .. " 个区块）")
end
