-- web.lua
-- WebAdmin 标签页：HTML 界面 + ?format=png 端点。
--
-- ⚠ 线程模型（踩过一次服务器 abort，务必遵守）：
--   WebAdmin 的处理器跑在 HTTP 线程上，并且此刻持有本插件的 Lua 锁。
--   如果在这里调用任何 cWorld 的接口，会和 tick 线程形成锁序反转：
--       HTTP 线程：持 Lua 锁 -> 等 world chunkmap
--       tick 线程：持 world chunkmap ->（区块/钩子回调）等 Lua 锁
--   DeadlockDetect 检测到后会直接 abort 整个服务器。
--   所以本文件里**只允许**：
--     1) 读纯 Lua 缓存（WCM_Render.GetCached / GetWorldInfo / GetChunkInfo）
--     2) 纯计算（WCM_Render.Plan / PlanKey / ForgetTile / FlushCache）
--     3) 往任务队列里塞任务（WCM_Render.Enqueue），由 HOOK_WORLD_TICK 执行
--
-- 界面使用 WebAdmin 自带的样式（h4 / table / th / td / button / input / a），
-- 只保留极少量自己的 class 用于地图叠层和色块。

WCM_Web = {}

local W = WCM_Web
local floor = math.floor
local concat = table.concat

W.InlineImages = false       -- 由 settings.ini [Web] UseInlineImages 决定
W.DefaultSize = 8
W.DefaultScale = 2
W.DefaultMode = "topo"

W.MaxWarmChunks = 512        -- 手动「加载可见区块」单次上限
W.MaxClickableChunks = 1024  -- 超过这个数量就不生成可点击区域（页面会太大）
W.InfoTTL = 10               -- 选中区块信息的缓存寿命（秒）
W.RenderRefresh = 2          -- 等渲染 / 等操作结果时的整页自动刷新间隔（秒）
W.PanelRefresh = 600         -- 详情面板局部 fetch 的延迟（毫秒）

----------------------------------------------------------------------
-- 小工具
----------------------------------------------------------------------

-- 注意：APIDump 把 GetHTMLEscapedString 标成 static，但运行时它要求第一个参数是
-- cWebAdmin 本身（点号调用会报 "argument #1 is 'string'; 'cWebAdmin' expected"），
-- 所以这里必须用冒号调用。
local function Esc(S)
	return cWebAdmin:GetHTMLEscapedString(tostring(S or ""))
end

--- 把字符串转义成内联 <script> 里的单引号 JS 字符串。
-- 不能复用 Esc()：<script> 是 raw text，HTML 实体不会被解码，
-- 把 & 写成 &amp; 会让 location.href 带上字面量 "&amp;"，查询参数全部丢失。
local function JsStr(S)
	return (tostring(S):gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\r", ""):gsub("\n", "\\n"))
end

local function Param(Request, Name)
	local V
	if (Request.Params ~= nil) then
		V = Request.Params[Name]
	end
	if (V == nil) and (Request.PostParams ~= nil) then
		V = Request.PostParams[Name]
	end
	return V
end

local function IntParam(Request, Name, Default, Min, Max)
	local V = tonumber(Param(Request, Name))
	if (V == nil) then
		return Default
	end
	V = floor(V)
	if (V < Min) then V = Min end
	if (V > Max) then V = Max end
	return V
end

local function UrlEncode(S)
	return (tostring(S):gsub("[^%w%-%_%.~]", function (C)
		return string.format("%%%02X", string.byte(C))
	end))
end

--- 世界查找只碰世界列表，不碰区块，可以在 HTTP 线程上用。
--- 只解析出**世界名**，完全不碰 cWorld / cRoot：
--- 世界列表由 tick 线程登记在 WCM_Render.KnownWorlds 里，HTTP 线程只读它。
local function ResolveWorldName(Request)
	local Name = Param(Request, "world")
	if (Name ~= nil) and (Name ~= "") and (WCM_Render.KnownWorlds[Name] == true) then
		return Name
	end
	return WCM_Render.DefaultWorldName
end

--- Request.Path 是相对路径（"webadmin/WebChunkMap/map"），必须补前导斜杠，
--- 否则浏览器会按当前目录解析，拼成 /webadmin/WebChunkMap/webadmin/WebChunkMap/map。
local function RequestPath(Request)
	local Path = Request.Path or ""
	if (Path:sub(1, 1) ~= "/") then
		Path = "/" .. Path
	end
	if (Path == "/") then
		Path = "/webadmin/" .. g_PluginInfo.Name .. "/map"
	end
	return Path
end

local function OptionList(Values, Current, Labels)
	local Out = {}
	for _, V in ipairs(Values) do
		local Label = V
		if (Labels ~= nil) and (Labels[V] ~= nil) then
			Label = Labels[V]
		end
		local Sel = ""
		if (tostring(V) == tostring(Current)) then
			Sel = " selected"
		end
		Out[#Out + 1] = "<option value='" .. Esc(V) .. "'" .. Sel .. ">" .. Esc(Label) .. "</option>"
	end
	return concat(Out)
end

local function Hidden(Name, Value)
	return "<input type='hidden' name='" .. Esc(Name) .. "' value='" .. Esc(Value) .. "'>"
end

local function Swatch(Hex)
	return "<span class='wcm-sw' style='background:" .. Hex .. "'></span>"
end

local function BlockSwatch(ConstName)
	local Id = _G[ConstName]
	local C = nil
	if (type(Id) == "number") then
		C = WCM_Blocks.Colors[Id]
	end
	if (C == nil) then
		return Swatch("#666666")
	end
	return Swatch(string.format("#%02X%02X%02X", C[1], C[2], C[3]))
end

----------------------------------------------------------------------
-- 选区
----------------------------------------------------------------------

local function ParseSelection(S)
	local Set, List = {}, {}
	if (type(S) == "string") then
		for Item in S:gmatch("[^;]+") do
			local CXs, CZs = Item:match("^(-?%d+):(-?%d+)$")
			if (CXs ~= nil) then
				local CX, CZ = tonumber(CXs), tonumber(CZs)
				local Key = CX .. ":" .. CZ
				if (Set[Key] == nil) then
					local Entry = { CX = CX, CZ = CZ, Key = Key }
					Set[Key] = Entry
					List[#List + 1] = Entry
				end
			end
		end
	end
	return Set, List
end

local function ToggleSelection(SelRaw, CX, CZ)
	local _, List = ParseSelection(SelRaw)
	local Key = CX .. ":" .. CZ
	local Out = {}
	local Removed = false
	for _, C in ipairs(List) do
		if (C.Key == Key) then
			Removed = true
		else
			Out[#Out + 1] = C.Key
		end
	end
	if (not Removed) then
		Out[#Out + 1] = Key
	end
	return concat(Out, ";")
end

local function QueryString(P, Extra)
	local Parts = {
		"world=" .. UrlEncode(P.world),
		"mode=" .. UrlEncode(P.mode),
		"cx=" .. P.cx,
		"cz=" .. P.cz,
		"size=" .. P.size,
		"scale=" .. P.scale,
	}
	if (P.sel ~= nil) and (P.sel ~= "") then
		-- ⚠ sel 里的分隔符必须写成 %3B，不能留裸 ';'。
		-- Cuberite 自己解析裸 ';' 没问题，但中间的代理会把它吃掉：
		-- Tailscale 的 Go 反向代理按 net/url 的规则处理查询串，裸 ';' 会让**整个参数被丢弃**。
		-- 实测 https://<tailnet>/…&sel=5:-1;6:-1 -> 服务器收到 sel 为空 -> 页面显示"选中的区块（0）"，
		-- 而同一个 URL 走 http://<host>:8080 直连完全正常。写成 %3B 后两边都对。
		Parts[#Parts + 1] = "sel=" .. (P.sel:gsub(";", "%%3B"))
	end
	if (Extra ~= nil) then
		Parts[#Parts + 1] = Extra
	end
	return concat(Parts, "&")
end

----------------------------------------------------------------------
-- 页面
----------------------------------------------------------------------

--- 选中区块的管理面板。
--- 单独抽出来是因为 `?panel=1` 只返回这一段：页面用 fetch() 局部替换它，
--- 从而**不必整页重载**。整页重载会在用户点下一个区块时打乱页面，
--- 让点击落到已经选中的区块上（触发取消），表现为"选第二个区块时全被取消"。
local function BuildSelectionPanel(Path, Base, P, WInfo, SelList)
	local Out = {}
	local function A(S)
		Out[#Out + 1] = S
	end

	A("<h4>选中的区块（" .. #SelList .. "）</h4>")
	if (#SelList == 0) then
		A("<p>还没有选中任何区块。点击上面的地图即可选择。</p>")
		return concat(Out)
	end

	A("<form method='get' action='" .. Esc(Path) .. "'>")
	A(Hidden("world", P.world))
	A(Hidden("mode", P.mode))
	A(Hidden("cx", P.cx))
	A(Hidden("cz", P.cz))
	A(Hidden("size", P.size))
	A(Hidden("scale", P.scale))
	A(Hidden("sel", P.sel))

	A("<table>")
	A("<tr><th>区块</th><th>范围 (X, Z)</th><th>状态</th><th>生物群系</th>"
		.. "<th>地表 Y</th><th>顶层方块</th><th>实体 / 玩家</th><th>操作</th></tr>")

	for i, C in ipairs(SelList) do
		if (i > 64) then
			A("<tr><td colspan='8'>… 其余 " .. (#SelList - 64) .. " 个区块不再列出（一次最多管理 64 个）</td></tr>")
			break
		end
		local Info = WCM_Render.GetChunkInfo(P.world, C.CX, C.CZ)
		local State = "从未见过"
		local Biome, Height, Block = "-", "-", "-"
		local Ent = "…"
		if (Info ~= nil) then
			if Info.Loaded then
				State = "<b style='color:#245A48'>已加载</b>"
			elseif Info.Remembered then
				State = "记忆中"
			end
			Biome = Info.Biome or "-"
			Height = (Info.Height ~= nil) and tostring(Info.Height) or "-"
			Block = Info.BlockName or "-"
			Ent = tostring(Info.Entities or 0) .. " / " .. tostring(Info.Players or 0)
		end

		local CenterQ = QueryString({
			world = P.world, mode = P.mode, sel = P.sel,
			cx = C.CX * 16 + 8, cz = C.CZ * 16 + 8, size = P.size, scale = P.scale,
		})
		local RemoveQ = QueryString({
			world = P.world, mode = P.mode, sel = ToggleSelection(P.sel, C.CX, C.CZ),
			cx = P.cx, cz = P.cz, size = P.size, scale = P.scale,
		})
		A("<tr>")
		A("<td>(" .. C.CX .. ", " .. C.CZ .. ")</td>")
		A("<td>" .. (C.CX * 16) .. ".." .. (C.CX * 16 + 15) .. ", " .. (C.CZ * 16) .. ".." .. (C.CZ * 16 + 15) .. "</td>")
		A("<td>" .. State .. "</td>")
		A("<td>" .. Esc(Biome) .. "</td>")
		A("<td>" .. Esc(Height) .. "</td>")
		A("<td>" .. Esc(Block) .. "</td>")
		A("<td>" .. Esc(Ent) .. "</td>")
		A("<td><a href='" .. Esc(Base .. CenterQ) .. "'>定位</a> · <a href='" .. Esc(Base .. RemoveQ) .. "'>取消选择</a></td>")
		A("</tr>")
	end
	A("</table>")

	local PlayerNames = {}
	for _, Pl in ipairs(WInfo.Players or {}) do
		PlayerNames[#PlayerNames + 1] = Pl.Name
	end
	A("<p class='wcm-actions'>")
	A("<button type='submit' name='action' value='load'>加载这些区块</button>")
	A("<button type='submit' name='action' value='forget'>清除记忆</button>")
	A("<button type='submit' name='action' value='regen'>重新生成</button>")
	A("<label><input type='checkbox' name='confirm' value='1'> 我确认重新生成会永久删除这些区块里的所有方块"
		.. "（未加载的区块会因此被加载一次）</label>")
	A("</p>")
	A("<p class='wcm-actions'>")
	if (#PlayerNames > 0) then
		A("把玩家 <select name='player'>" .. OptionList(PlayerNames, "") .. "</select> ")
		A("<button type='submit' name='action' value='teleport'>传送到第 1 个选中区块</button>")
	else
		A("<i>当前没有在线玩家，无法传送。</i>")
	end
	A(" <a href='" .. Esc(Base .. QueryString({
		world = P.world, mode = P.mode, sel = "",
		cx = P.cx, cz = P.cz, size = P.size, scale = P.scale,
	})) .. "'>清空选择</a>")
	A("</p>")
	A("</form>")

	A("<p>说明：<b>加载这些区块</b> 把它们拉进内存并刷新快照；")
	A("<b>清除记忆</b> 只删本地快照（不动世界数据）；")
	A("<b>重新生成</b> 会永久覆盖这些区块，需勾选确认。</p>")

	return concat(Out)
end

local PAGE_CSS = [[
<style>
.wcm-map { position: relative; display: inline-block; line-height: 0; border: 1px solid #CCDDD9; background: #fff; }
.wcm-map img { display: block; image-rendering: pixelated; }
.wcm-pending { display: flex; align-items: center; justify-content: center; color: #888;
	background: #F4F7F6; font-size: 13px; }
.wcm-sel { position: absolute; box-sizing: border-box; border: 2px solid #c14544; pointer-events: none; }
.wcm-sw { display: inline-block; width: 11px; height: 11px; border: 1px solid #999; margin: 0 4px -1px 8px; }
.wcm-actions button { margin-right: 4px; }
</style>
]]

--- 还没有渲染结果时用的占位 Meta（只依赖 Plan 和世界信息缓存）。
local function SyntheticMeta(Plan, WInfo, WorldName)
	local ViewChunks = Plan.SizeChunks * Plan.SizeChunks
	return {
		WorldName = WorldName,
		Mode = Plan.Mode,
		SizeChunks = Plan.SizeChunks,
		RequestedSizeChunks = Plan.RequestedSizeChunks,
		SizeClamped = Plan.SizeClamped,
		Scale = Plan.Scale,
		Blocks = Plan.Blocks,
		OriginX = Plan.OriginX,
		OriginZ = Plan.OriginZ,
		Width = Plan.Width,
		Height = Plan.Height,
		OriginChunkX = Plan.OriginChunkX,
		OriginChunkZ = Plan.OriginChunkZ,
		CenterBlockX = Plan.CenterBlockX,
		CenterBlockZ = Plan.CenterBlockZ,
		ViewChunks = ViewChunks,
		LiveChunks = 0,
		RememberedChunks = 0,
		UnknownChunks = ViewChunks,
		WarmMissing = ViewChunks,
		WarmMissingUnknown = ViewChunks,
		WarmMissingRemembered = 0,
		Players = #(WInfo.Players or {}),
		LoadedChunks = WInfo.LoadedChunks or 0,
		TotalChunks = WInfo.TotalChunks or 0,
		TotalTiles = WInfo.Tiles or 0,
		CacheHit = false,
		RenderMs = 0,
		PngBytes = 0,
		Pending = true,
	}
end

local function BuildPage(Request, P, WInfo, Meta, Png, Notice, RefreshDelay, InfoStale, QueuedRender)
	local Path = RequestPath(Request)
	local Base = Path .. "?"
	local _, SelList = ParseSelection(P.sel)
	local Out = {}
	local function A(S)
		Out[#Out + 1] = S
	end

	A(PAGE_CSS)

	if (Notice ~= nil) then
		A("<p>" .. Notice .. "</p>")
	end

	-- 需要等后台任务时自动刷新一次
	if (RefreshDelay ~= nil) then
		local RefreshUrl = Base .. QueryString(P)
		A("<script>setTimeout(function () { location.href = '" .. JsStr(RefreshUrl) .. "'; }, "
			.. (RefreshDelay * 1000) .. ");</script>")
	end

	------------------------------------------------------------------
	A("<h4>视图</h4>")
	------------------------------------------------------------------
	local WorldNames = {}
	for N in pairs(WCM_Render.KnownWorlds) do
		WorldNames[#WorldNames + 1] = N
	end
	table.sort(WorldNames)

	-- 视野档位：当前生效值必须出现在选项里，否则 <select> 匹配不到就会退回第一项
	-- （之前表现为“视野总是自己变成 2 区块”：32 档被像素预算收缩成 31，而 31 不在列表里）
	local SizeLabels = {
		[2] = "2 区块 (32 格)", [4] = "4 区块", [8] = "8 区块",
		[16] = "16 区块", [24] = "24 区块", [32] = "32 区块", [48] = "48 区块",
	}
	local SizeChoices = {}
	local SizeKnown = false
	for _, V in ipairs(WCM_Render.SizeSteps) do
		if (V <= WCM_Render.Config.MaxSizeChunks) then
			SizeChoices[#SizeChoices + 1] = V
			if (V == P.size) then
				SizeKnown = true
			end
		end
	end
	if (not SizeKnown) and (P.size > 0) then
		SizeChoices[#SizeChoices + 1] = P.size
		table.sort(SizeChoices)
		SizeLabels[P.size] = P.size .. " 区块（受像素上限收缩）"
	end

	A("<form method='get' action='" .. Esc(Path) .. "'>")
	A(Hidden("sel", P.sel))
	A("<table>")
	A("<tr><th style='width:80px'>世界</th><td><select name='world'>" .. OptionList(WorldNames, P.world) .. "</select></td>")
	A("<th style='width:80px'>图层</th><td><select name='mode'>" .. OptionList({ "topo", "biome", "chunks" }, P.mode, {
		topo = "地表 (topo)", biome = "生物群系 (biome)", chunks = "区块状态 (chunks)",
	}) .. "</select></td></tr>")
	A("<tr><th>视野</th><td><select name='size'>" .. OptionList(SizeChoices, P.size, SizeLabels) .. "</select></td>")
	A("<th>缩放</th><td><select name='scale'>" .. OptionList({ 1, 2, 3, 4 }, P.scale,
		{ [1] = "1x", [2] = "2x", [3] = "3x", [4] = "4x" }) .. "</select></td></tr>")
	A("<tr><th>中心</th><td>X <input type='number' name='cx' value='" .. P.cx .. "' style='width:90px'>"
		.. " Z <input type='number' name='cz' value='" .. P.cz .. "' style='width:90px'></td>")
	A("<th></th><td><label><input type='checkbox' name='nocache' value='1'> 强制重绘</label> "
		.. "<input type='submit' value='渲染'></td></tr>")
	A("</table>")
	A("</form>")

	------------------------------------------------------------------
	-- 平移 / 缩放
	------------------------------------------------------------------
	local Half = floor(Meta.Blocks / 2)
	local function Nav(Label, DCX, DCZ, DSize, DScale, Title)
		local Q = QueryString({
			world = P.world, mode = P.mode, sel = P.sel,
			cx = P.cx + DCX, cz = P.cz + DCZ, size = DSize, scale = DScale,
		})
		return "<a href='" .. Esc(Base .. Q) .. "' title='" .. Esc(Title or Label) .. "'>" .. Label .. "</a>"
	end

	A("<p>"
		.. Nav("▲ 北", 0, -Half, P.size, P.scale, "向北移动半个视野") .. " | "
		.. Nav("▼ 南", 0, Half, P.size, P.scale, "向南移动半个视野") .. " | "
		.. Nav("◀ 西", -Half, 0, P.size, P.scale, "向西移动半个视野") .. " | "
		.. Nav("▶ 东", Half, 0, P.size, P.scale, "向东移动半个视野") .. " | "
		.. Nav("－ 缩小", 0, 0, P.size, math.max(1, P.scale - 1), "每格像素更少") .. " | "
		.. Nav("＋ 放大", 0, 0, P.size, math.min(4, P.scale + 1), "每格像素更多") .. " | "
		.. Nav("⊙ 出生点", WInfo.SpawnX - P.cx, WInfo.SpawnZ - P.cz, P.size, P.scale, "回到出生点")
		.. "</p>")

	------------------------------------------------------------------
	-- 地图
	------------------------------------------------------------------
	local ChunkPx = 16 * Meta.Scale
	local Clickable = (Meta.Mode ~= "biome") and ((Meta.SizeChunks * Meta.SizeChunks) <= W.MaxClickableChunks)

	A("<div class='wcm-map'>")
	if (Png ~= nil) then
		local ImgSrc
		if W.InlineImages then
			ImgSrc = "data:image/png;base64," .. Base64Encode(Png)
		else
			local Extra = "format=png"
			if (Param(Request, "nocache") == "1") then
				Extra = Extra .. "&t=" .. tostring(WCM_Render.Now())
			end
			ImgSrc = Path .. "?" .. QueryString(P, Extra)
		end
		A("<img src='" .. Esc(ImgSrc) .. "' width='" .. Meta.Width .. "' height='" .. Meta.Height
			.. "'" .. (Clickable and " usemap='#wcm-chunkmap'" or "") .. " alt='chunk map'>")
	else
		A("<div class='wcm-pending' style='width:" .. Meta.Width .. "px;height:" .. Meta.Height .. "px'>"
			.. "正在后台渲染…</div>")
	end

	for _, C in ipairs(SelList) do
		local bx = C.CX - Meta.OriginChunkX
		local bz = C.CZ - Meta.OriginChunkZ
		if (bx >= 0) and (bx < Meta.SizeChunks) and (bz >= 0) and (bz < Meta.SizeChunks) then
			A("<span class='wcm-sel' style='left:" .. (bx * ChunkPx) .. "px;top:" .. (bz * ChunkPx)
				.. "px;width:" .. ChunkPx .. "px;height:" .. ChunkPx .. "px'></span>")
		end
	end
	A("</div>")

	if Clickable then
		local Areas = {}
		for cz = 0, Meta.SizeChunks - 1 do
			for cx = 0, Meta.SizeChunks - 1 do
				local ChunkX = Meta.OriginChunkX + cx
				local ChunkZ = Meta.OriginChunkZ + cz
				local NewSel = ToggleSelection(P.sel, ChunkX, ChunkZ)
				local Q = QueryString({
					world = P.world, mode = P.mode, sel = NewSel,
					cx = P.cx, cz = P.cz, size = P.size, scale = P.scale,
				})
				Areas[#Areas + 1] = "<area shape='rect' coords='" .. (cx * ChunkPx) .. "," .. (cz * ChunkPx)
					.. "," .. ((cx + 1) * ChunkPx) .. "," .. ((cz + 1) * ChunkPx)
					.. "' href='" .. Esc(Base .. Q) .. "' title='"
					.. Esc("区块 (" .. ChunkX .. ", " .. ChunkZ .. ")") .. "'>"
			end
		end
		A("<map name='wcm-chunkmap'>" .. concat(Areas) .. "</map>")
		A("<p>点击地图上的区块可以选中 / 取消；选中的区块会出现在下面的管理面板里。</p>")
	else
		A("<p>视野太大，已关闭点击选块（把视野调到 32 区块以内即可）。</p>")
	end

	if QueuedRender and (Png ~= nil) then
		A("<p>缓存已过期，正在后台重绘（当前显示的是上一次的结果，页面不会自动跳转）。</p>")
	end

	if (Meta.WarmMissing > 0) and (Png ~= nil) then
		A("<p><a href='" .. Esc(Base .. QueryString(P) .. "&warm=1") .. "'>⏬ 加载可见区块</a>"
			.. " —— 未加载 <b>" .. Meta.WarmMissing .. "</b> 个（未见 <b>" .. Meta.WarmMissingUnknown
			.. "</b> · 记忆中 <b>" .. Meta.WarmMissingRemembered
			.. "</b>）；会优先加载从未见过的区块，已有快照的排在其后。</p>")
	end

	------------------------------------------------------------------
	A("<h4>图层信息</h4>")
	------------------------------------------------------------------
	local ModeNames = { topo = "地表 (topo)", biome = "生物群系 (biome)", chunks = "区块状态 (chunks)" }
	A("<table>")
	A("<tr><th style='width:110px'>世界</th><td>" .. Esc(Meta.WorldName) .. "</td>")
	A("<th style='width:110px'>图层</th><td>" .. Esc(ModeNames[Meta.Mode] or Meta.Mode) .. "</td></tr>")
	A("<tr><th>范围</th><td>X " .. Meta.OriginX .. ".." .. (Meta.OriginX + Meta.Blocks - 1)
		.. "，Z " .. Meta.OriginZ .. ".." .. (Meta.OriginZ + Meta.Blocks - 1) .. "</td>")
	A("<th>区块</th><td>" .. Meta.SizeChunks .. "x" .. Meta.SizeChunks
		.. "（" .. Meta.OriginChunkX .. ", " .. Meta.OriginChunkZ .. " 起）")
	if (Meta.SizeClamped) then
		A(" <span style='color:#a00'>已按像素上限从 " .. Meta.RequestedSizeChunks .. " 区块收缩</span>")
	end
	A("</td></tr>")
	A("<tr><th>图片</th><td>" .. Meta.Width .. "x" .. Meta.Height)
	if (Png ~= nil) then
		A("，" .. string.format("%.1f", Meta.PngBytes / 1024) .. " KiB")
	end
	A("</td>")
	A("<th>渲染耗时</th><td>" .. Meta.RenderMs .. " ms（" .. (Meta.CacheHit and "命中图片缓存" or "实时渲染")
		.. "，队列 " .. WCM_Render.PendingCount() .. "）</td></tr>")
	A("<tr><th>视野内区块</th><td>已加载 " .. Meta.LiveChunks .. " · 记忆中 " .. Meta.RememberedChunks
		.. " · 未见 " .. Meta.UnknownChunks .. "</td>")
	A("<th>区块快照</th><td>" .. Meta.TotalTiles .. " 个</td></tr>")
	A("<tr><th>本世界</th><td>已加载 " .. Meta.LoadedChunks .. " 个区块</td>")
	A("<th>在线玩家</th><td>" .. Meta.Players .. "</td></tr>")
	A("</table>")

	------------------------------------------------------------------
	-- 图例
	------------------------------------------------------------------
	A("<p>")
	if (Meta.Mode == "chunks") then
		A(Swatch("#60A052") .. "当前已加载")
		A(Swatch("#969E66") .. "记忆中的快照")
		A(Swatch("#3E424E") .. "从未见过")
	elseif (Meta.Mode == "biome") then
		A(Swatch("#78AA4C") .. "平原")
		A(Swatch("#569242") .. "森林")
		A(Swatch("#3058A8") .. "海洋")
		A(Swatch("#E0D298") .. "沙漠")
		A(Swatch("#ECEFF6") .. "冰原")
		A(Swatch("#B66434") .. "平顶山")
		A(Swatch("#782826") .. "下界")
	else
		A(BlockSwatch("E_BLOCK_GRASS") .. "草")
		A(BlockSwatch("E_BLOCK_WATER") .. "水")
		A(BlockSwatch("E_BLOCK_SAND") .. "沙")
		A(BlockSwatch("E_BLOCK_STONE") .. "石")
		A(BlockSwatch("E_BLOCK_LEAVES") .. "树叶")
		A(BlockSwatch("E_BLOCK_SNOW") .. "雪")
		A(BlockSwatch("E_BLOCK_LAVA") .. "岩浆")
		A(Swatch("#3E424E") .. "从未见过")
	end
	A(Swatch("#E63C3C") .. "玩家")
	A(Swatch("#46A0FF") .. "出生点")
	A(Swatch("#C14544") .. "选中")
	A("</p>")

	------------------------------------------------------------------
	-- 面板放在独立容器里：详情刷新只替换这个容器，绝不整页重载
	-- （整页重载会在用户点下一个区块时打乱页面，点击落到已选中的区块上就变成"取消"）
	------------------------------------------------------------------
	A("<div id='wcm-panel'>" .. BuildSelectionPanel(Path, Base, P, WInfo, SelList) .. "</div>")

	if InfoStale then
		local PanelUrl = Base .. QueryString(P, "panel=1")
		-- 注意：不能直接把相对路径丢给 fetch()。如果用户是用
		-- http://user:pass@host/... 打开的页面，相对路径会连同 userinfo 一起解析成绝对 URL，
		-- 而 fetch() 拒绝带凭据的 URL（TypeError: Request cannot be constructed from a URL
		-- that includes credentials）。用 location.origin（不含 userinfo）拼绝对地址。
		-- ⚠ WebAdmin 会把插件标签页的响应**一律**裹进模板页：template.lua 的 ShowPage 无条件
		-- 拼上 <html><head>…<div class="columns">…，本版本也没有可用于绕过的 WebAdmin 请求钩子。
		-- 所以 fetch 回来的是**整页 HTML**，直接 innerHTML 就会把整个 WebAdmin 再嵌一层。
		-- 因此在浏览器侧用 DOMParser 解析这页，只取其中的 #wcm-panel。
		A("<script>setTimeout(function(){fetch(location.origin + '" .. JsStr(PanelUrl) .. "')"
			.. ".then(function(r){return r.text()})"
			.. ".then(function(t){"
			.. "var d=new DOMParser().parseFromString(t,'text/html');"
			.. "var n=d.getElementById('wcm-panel');"
			.. "var e=document.getElementById('wcm-panel');"
			.. "if(n&&e){e.innerHTML=n.innerHTML}})"
			.. ".catch(function(){});}," .. W.PanelRefresh .. ");</script>")
	end


	return concat(Out)
end

----------------------------------------------------------------------
-- 入口
----------------------------------------------------------------------

function W.HandleRequest(Request, UrlPath)
	local WorldName = ResolveWorldName(Request)
	if (WorldName == nil) then
		return "<p>世界信息还在初始化（由 tick 线程登记），请稍候刷新。</p>", "text/html"
	end
	local WInfo = WCM_Render.GetWorldInfo(WorldName)

	local Mode = tostring(Param(Request, "mode") or W.DefaultMode)
	if ((Mode ~= "topo") and (Mode ~= "biome") and (Mode ~= "chunks")) then
		Mode = "topo"
	end

	local SelRaw = Param(Request, "sel") or ""
	local _, SelList = ParseSelection(SelRaw)

	local Opts = {
		Mode = Mode,
		SizeChunks = IntParam(Request, "size", W.DefaultSize, 1, WCM_Render.Config.MaxSizeChunks),
		Scale = IntParam(Request, "scale", W.DefaultScale, 1, 4),
		CenterX = IntParam(Request, "cx", WInfo.SpawnX, -30000000, 30000000),
		CenterZ = IntParam(Request, "cz", WInfo.SpawnZ, -30000000, 30000000),
	}

	-- 纯计算：几何参数 + 缓存键，都不碰世界数据
	local Plan = WCM_Render.Plan(Opts, WInfo.SpawnX, WInfo.SpawnZ)
	local CacheKey = WCM_Render.PlanKey(WorldName, Plan)
	local Png, Meta, Age = WCM_Render.GetCached(CacheKey)
	local NoCache = (Param(Request, "nocache") == "1")

	--------------------------------------------------------------------
	-- 管理操作：只入队，真正执行在 tick 线程
	--------------------------------------------------------------------
	local Notice = nil
	local ActionQueued = false   -- 用户点了操作按钮，页面值得刷新一次
	local Action = Param(Request, "action")

	if (Action ~= nil) and (Action ~= "") then
		if (#SelList == 0) then
			Notice = "<b style='color:#a00'>请先在地图上点选至少一个区块。</b>"
		elseif (Action == "forget") then
			-- 纯 Lua 操作，可以就地执行
			local N = 0
			for _, C in ipairs(SelList) do
				if WCM_Render.ForgetTile(WorldName, C.CX, C.CZ) then
					N = N + 1
				end
			end
			WCM_Render.FlushCache()
			Notice = "已清除 " .. N .. " 个区块的记忆快照。"
		elseif (Action == "regen") then
			if (Param(Request, "confirm") ~= "1") then
				Notice = "<b style='color:#a00'>重新生成会永久删除这些区块里的所有方块，请先勾选确认框。</b>"
			else
				local Chunks = {}
				for i, C in ipairs(SelList) do
					if (i > 64) then break end
					Chunks[#Chunks + 1] = { C.CX, C.CZ }
					WCM_Render.ForgetTile(WorldName, C.CX, C.CZ)
					-- 详情缓存也要立刻作废，否则 10 秒内看到的还是旧状态
					WCM_Render.ForgetChunkInfo(WorldName, C.CX, C.CZ)
				end
				WCM_Render.Enqueue({ Kind = "regen", WorldName = WorldName, Chunks = Chunks })
				WCM_Render.FlushCache()
				Notice = "已把 " .. #Chunks .. " 个区块加入重新生成队列。"
					.. "未加载的区块会被加载一次以完成重生成并重建快照（否则地图上会留下空白洞）。"
				ActionQueued = true
			end
		elseif (Action == "teleport") then
			local Target = Param(Request, "player") or ""
			local First = SelList[1]
			WCM_Render.Enqueue({
				Kind = "teleport", WorldName = WorldName,
				Player = Target, X = First.CX * 16 + 8, Z = First.CZ * 16 + 8,
			})
			Notice = "已把传送 " .. Esc(Target) .. " 到区块 (" .. First.CX .. ", " .. First.CZ .. ") 的任务排队。"
			ActionQueued = true
		elseif (Action == "load") then
			local Chunks = {}
			for i, C in ipairs(SelList) do
				if (i > W.MaxWarmChunks) then break end
				Chunks[#Chunks + 1] = { C.CX, C.CZ }
			end
			WCM_Render.Enqueue({
				Kind = "load", WorldName = WorldName,
				Chunks = Chunks,
				Opts = {
					Mode = Plan.Mode, SizeChunks = Plan.SizeChunks, Scale = Plan.Scale,
					CenterX = Plan.CenterX, CenterZ = Plan.CenterZ,
				},
			})
			Notice = "已排队加载 " .. #Chunks .. " 个区块。"
			ActionQueued = true
		end
	end

	--------------------------------------------------------------------
	-- warm=1：只补"从未见过"的，其次才是"记忆中"的
	--------------------------------------------------------------------
	if (Action == nil) or (Action == "") then
		if (Param(Request, "warm") == "1") and (Meta == nil or Meta.WarmMissing > 0) then
			WCM_Render.Enqueue({
				Kind = "load", WorldName = WorldName,
				Opts = {
					Mode = Plan.Mode, SizeChunks = Plan.SizeChunks, Scale = Plan.Scale,
					CenterX = Plan.CenterX, CenterZ = Plan.CenterZ,
				},
				IncludeRemembered = true,
				MaxChunks = W.MaxWarmChunks,
			})
			Notice = "已排队加载视野内未加载的区块（优先从未见过的）。"
			ActionQueued = true
		end
	end

	--------------------------------------------------------------------
	-- 选中的区块详情：读缓存，过期就排刷新任务
	--------------------------------------------------------------------
	local InfoStale = false
	if (#SelList > 0) then
		local T = WCM_Render.Now()
		local List = {}
		for i, C in ipairs(SelList) do
			if (i > 64) then break end
			List[#List + 1] = { C.CX, C.CZ }
			local Info = WCM_Render.GetChunkInfo(WorldName, C.CX, C.CZ)
			if (Info == nil) or ((T - Info.Time) > W.InfoTTL) then
				InfoStale = true
			end
		end
		if InfoStale then
			-- 只是把详情面板填上，不重绘地图、也不整页刷新
			WCM_Render.Enqueue({ Kind = "info", WorldName = WorldName, Chunks = List })
		end
	end

	--------------------------------------------------------------------
	-- 图片：命中缓存直接给；否则排一个渲染任务，本次先用占位页
	--------------------------------------------------------------------
	-- TTL 只决定"要不要在后台更新缓存"，绝不决定"这次请求能不能用缓存"。
	-- 命中但过期的图照旧先发出去（stale-while-revalidate）：页面不阻塞、不跳转。
	local ImageStale = (Png ~= nil) and (Age > WCM_Render.Config.CacheTTL)
	local QueuedRender = false
	if (Png == nil) or ImageStale or NoCache then
		WCM_Render.Enqueue({
			Kind = "render", WorldName = WorldName,
			Opts = {
				Mode = Plan.Mode, SizeChunks = Plan.SizeChunks, Scale = Plan.Scale,
				CenterX = Plan.CenterX, CenterZ = Plan.CenterZ,
				NoCache = NoCache,
			},
		})
		QueuedRender = true
	end

	if (Meta == nil) then
		Meta = SyntheticMeta(Plan, WInfo, WorldName)
	else
		-- 这个 Meta 就是从图片缓存里拿出来的，页面上的耗时/命中标记要按命中算
		Meta.CacheHit = true
	end

	if ((Param(Request, "format") or "html") == "png") then
		if (Png == nil) then
			return "<p>图片还在后台渲染，请稍候刷新。</p>", "text/html"
		end
		return Png, "image/png"
	end

	-- 页面用的实际生效参数
	local P = {
		world = WorldName,
		mode = Meta.Mode,
		sel = SelRaw,
		cx = Meta.CenterBlockX,
		cz = Meta.CenterBlockZ,
		size = Meta.SizeChunks,
		scale = Meta.Scale,
	}

	-- 只在"用户确实在等新东西"时整页自动刷新：还没有第一张图 / 明确要求重绘 / 点了操作按钮。
	-- TTL 到期属于后台更新，选中区块属于纯前端行为 —— 两者都不该刷新页面。
	-- 页面只在"用户确实在等新东西"时整页自动刷新。
	-- 选中区块的详情走 ?panel=1 局部 fetch，绝不整页重载 ——
	-- 整页重载会在用户点下一个区块时打乱页面，点击落到已选区块上就变成了"取消"。
	local RefreshDelay = nil
	if (Png == nil) or NoCache or ActionQueued then
		RefreshDelay = W.RenderRefresh
	end

	-- ?panel=1：只回详情面板那一段，供页面用 fetch() 局部替换（不整页重载）
	if (Param(Request, "panel") == "1") then
		local PanelPath = RequestPath(Request)
		return BuildSelectionPanel(PanelPath, PanelPath .. "?", P, WInfo, SelList), "text/html"
	end

	return BuildPage(Request, P, WInfo, Meta, Png, Notice, RefreshDelay, InfoStale, QueuedRender), "text/html"
end
