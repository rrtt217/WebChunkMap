-- blocks.lua
-- 方块 / 生物群系 -> 颜色 的映射表，以及未知方块的回退上色。
-- 所有常量都通过 _G 查表获得：缺失的常量只会让对应条目被跳过，不会让插件加载失败。

WCM_Blocks = {}

local B = WCM_Blocks

B.Colors     = {}   -- 方块类型 -> {R, G, B}
B.MetaColors = {}   -- 方块类型 -> { [meta] = {R, G, B} }
B.Biomes     = {}   -- 生物群系 -> {R, G, B}
B.IsLiquid   = {}   -- 方块类型 -> true

B.Placeholder = { 150, 110, 150 }               -- 取不到方块时的颜色
B.Unloaded    = { 34, 36, 46 }                  -- 未加载区块

-- 未知方块用的回退调色板（按类型号取模，稳定且彼此可区分）
B.AutoPalette = {
	{ 126, 120, 110 }, { 140, 132, 104 }, { 110, 124, 132 }, { 150, 138, 120 },
	{ 118, 128, 110 }, { 132, 116, 128 }, { 144, 124,  96 }, { 100, 116, 120 },
	{ 160, 148, 140 }, { 122, 134, 100 }, { 138, 110,  96 }, { 108, 108, 124 },
}

--- 未知方块的回退颜色。
function B.AutoColor(Bt)
	if (Bt == nil) then
		return B.Placeholder
	end
	return B.AutoPalette[(Bt % #B.AutoPalette) + 1]
end

--- 查询一个方块顶面的颜色（考虑 meta，用于羊毛 / 混凝土等）。
function B.ColorFor(Bt, Meta)
	if (Bt == nil) then
		return B.Placeholder
	end
	local ByMeta = B.MetaColors[Bt]
	if (ByMeta ~= nil) then
		local C = ByMeta[Meta or 0]
		if (C ~= nil) then
			return C
		end
	end
	local C = B.Colors[Bt]
	if (C ~= nil) then
		return C
	end
	return B.AutoColor(Bt)
end

local function Blk(Name, R, G, Bc)
	local Id = _G[Name]
	if (type(Id) == "number") then
		B.Colors[Id] = { R, G, Bc }
	end
end

local function Liquid(Name)
	local Id = _G[Name]
	if (type(Id) == "number") then
		B.IsLiquid[Id] = true
	end
end

local function Bm(Name, R, G, Bc)
	local Id = _G[Name]
	if (type(Id) == "number") then
		B.Biomes[Id] = { R, G, Bc }
	end
end

----------------------------------------------------------------------
-- 方块颜色
----------------------------------------------------------------------

-- 地表
Blk("E_BLOCK_GRASS",          106, 170,  64)
Blk("E_BLOCK_GRASS_PATH",     148, 122,  76)
Blk("E_BLOCK_DIRT",           134,  96,  67)
Blk("E_BLOCK_FARMLAND",       126,  86,  58)
Blk("E_BLOCK_MYCELIUM",       130, 108, 122)
Blk("E_BLOCK_PODZOL",         104,  78,  48)
Blk("E_BLOCK_STONE",          128, 128, 128)
Blk("E_BLOCK_COBBLESTONE",    110, 110, 110)
Blk("E_BLOCK_MOSSY_COBBLESTONE", 92, 120,  80)
Blk("E_BLOCK_BEDROCK",         58,  58,  58)
Blk("E_BLOCK_GRAVEL",         136, 126, 126)
Blk("E_BLOCK_CLAY",           162, 168, 180)
Blk("E_BLOCK_SAND",           219, 207, 163)
Blk("E_BLOCK_SANDSTONE",      216, 203, 155)
Blk("E_BLOCK_RED_SANDSTONE",  190, 102,  40)
Blk("E_BLOCK_HARDENED_CLAY",  150, 116,  90)
Blk("E_BLOCK_STAINED_CLAY",   150, 116,  90)
Blk("E_BLOCK_TERRACOTTA",     150, 116,  90)
Blk("E_BLOCK_SNOW",           242, 244, 250)
Blk("E_BLOCK_SNOW_BLOCK",     242, 244, 250)
Blk("E_BLOCK_ICE",            160, 200, 244)
Blk("E_BLOCK_PACKED_ICE",     150, 186, 232)
Blk("E_BLOCK_FROSTED_ICE",    170, 210, 244)
Blk("E_BLOCK_OBSIDIAN",        22,  20,  34)
Blk("E_BLOCK_NETHERRACK",     111,  54,  52)
Blk("E_BLOCK_SOULSAND",        84,  66,  55)
Blk("E_BLOCK_NETHER_BRICK",    44,  22,  26)
Blk("E_BLOCK_RED_NETHER_BRICK", 70,  30,  34)
Blk("E_BLOCK_END_STONE",      220, 220, 160)
Blk("E_BLOCK_END_BRICKS",     216, 224, 172)
Blk("E_BLOCK_PURPUR_BLOCK",   170, 122, 170)
Blk("E_BLOCK_PRISMARINE_BLOCK", 96, 178, 162)
Blk("E_BLOCK_BRICK",          150,  80,  60)
Blk("E_BLOCK_STONE_BRICKS",   122, 122, 122)
Blk("E_BLOCK_QUARTZ_BLOCK",   236, 232, 226)

-- 液体
Blk("E_BLOCK_WATER",           62, 108, 200)
Blk("E_BLOCK_STATIONARY_WATER",62, 108, 200)
Blk("E_BLOCK_LAVA",           220, 108,  30)
Blk("E_BLOCK_STATIONARY_LAVA",220, 108,  30)

-- 植被
Blk("E_BLOCK_LOG",            102,  81,  50)
Blk("E_BLOCK_NEW_LOG",        104,  86,  56)
Blk("E_BLOCK_LEAVES",          58, 116,  48)
Blk("E_BLOCK_NEW_LEAVES",      62, 122,  52)
Blk("E_BLOCK_TALL_GRASS",     106, 170,  64)
Blk("E_BLOCK_DEAD_BUSH",      132, 112,  62)
Blk("E_BLOCK_CACTUS",          86, 132,  62)
Blk("E_BLOCK_REEDS",          152, 182,  92)
Blk("E_BLOCK_SUGARCANE",      152, 182,  92)
Blk("E_BLOCK_VINES",           58, 116,  48)
Blk("E_BLOCK_LILY_PAD",        52, 116,  52)
Blk("E_BLOCK_WHEAT",          172, 176,  96)
Blk("E_BLOCK_CARROTS",        104, 156,  56)
Blk("E_BLOCK_POTATOES",       104, 156,  56)
Blk("E_BLOCK_BEETROOTS",      126, 156,  66)
Blk("E_BLOCK_PUMPKIN",        220, 150,  40)
Blk("E_BLOCK_MELON",          130, 180,  60)
Blk("E_BLOCK_HAY_BALE",       190, 162,  44)
Blk("E_BLOCK_BROWN_MUSHROOM", 140, 112,  84)
Blk("E_BLOCK_RED_MUSHROOM",   196,  62,  58)
Blk("E_BLOCK_HUGE_BROWN_MUSHROOM", 140, 112,  84)
Blk("E_BLOCK_HUGE_RED_MUSHROOM",   196,  62,  58)

-- 花与装饰
Blk("E_BLOCK_FLOWER",         214,  88,  88)
Blk("E_BLOCK_RED_ROSE",       200,  56,  56)
Blk("E_BLOCK_DANDELION",      236, 220,  70)
Blk("E_BLOCK_YELLOW_FLOWER",  236, 220,  70)
Blk("E_BLOCK_BIG_FLOWER",     208, 120, 160)
Blk("E_BLOCK_SAPLING",         96, 152,  64)

-- 建筑与功能方块
Blk("E_BLOCK_PLANKS",         162, 130,  78)
Blk("E_BLOCK_WOODEN_SLAB",    162, 130,  78)
Blk("E_BLOCK_DOUBLE_WOODEN_SLAB", 162, 130, 78)
Blk("E_BLOCK_OAK_WOOD_STAIRS",162, 130,  78)
Blk("E_BLOCK_BOOKCASE",       150, 118,  70)
Blk("E_BLOCK_CRAFTING_TABLE", 158, 126,  74)
Blk("E_BLOCK_WORKBENCH",      158, 126,  74)
Blk("E_BLOCK_FURNACE",        118, 118, 118)
Blk("E_BLOCK_BURNING_FURNACE",118, 100,  90)
Blk("E_BLOCK_LIT_FURNACE",    118, 100,  90)
Blk("E_BLOCK_CHEST",          150, 116,  62)
Blk("E_BLOCK_TRAPPED_CHEST",  156, 112,  58)
Blk("E_BLOCK_ENDER_CHEST",     44,  66,  62)
Blk("E_BLOCK_GLASS",          198, 220, 232)
Blk("E_BLOCK_GLASS_PANE",     198, 220, 232)
Blk("E_BLOCK_STAINED_GLASS",  198, 220, 232)
Blk("E_BLOCK_GLOWSTONE",      236, 214, 128)
Blk("E_BLOCK_SEA_LANTERN",    168, 214, 202)
Blk("E_BLOCK_JACK_O_LANTERN", 226, 156,  44)
Blk("E_BLOCK_TORCH",          240, 200,  90)
Blk("E_BLOCK_REDSTONE_TORCH_ON", 226,  70,  50)
Blk("E_BLOCK_REDSTONE_WIRE",  180,  40,  34)
Blk("E_BLOCK_REDSTONE_LAMP_ON", 200, 150,  70)
Blk("E_BLOCK_TNT",            190,  70,  50)
Blk("E_BLOCK_SLIME_BLOCK",    124, 190, 106)
Blk("E_BLOCK_SPONGE",         196, 196,  80)
Blk("E_BLOCK_WOOL",           222, 222, 222)
Blk("E_BLOCK_CARPET",         222, 222, 222)
Blk("E_BLOCK_CONCRETE",       222, 222, 222)
Blk("E_BLOCK_CONCRETE_POWDER",210, 210, 210)
Blk("E_BLOCK_MINECART_TRACKS", 170, 170, 170)
Blk("E_BLOCK_RAIL",           170, 170, 170)
Blk("E_BLOCK_POWERED_RAIL",   186, 160,  90)
Blk("E_BLOCK_DETECTOR_RAIL",  170, 160, 150)
Blk("E_BLOCK_ACTIVATOR_RAIL", 178,  90,  70)
Blk("E_BLOCK_IRON_BARS",      150, 150, 150)

-- 矿物与金属块
Blk("E_BLOCK_COAL_ORE",       104, 104, 104)
Blk("E_BLOCK_IRON_ORE",       172, 152, 130)
Blk("E_BLOCK_GOLD_ORE",       200, 176,  92)
Blk("E_BLOCK_DIAMOND_ORE",    110, 190, 190)
Blk("E_BLOCK_EMERALD_ORE",    100, 178, 110)
Blk("E_BLOCK_LAPIS_ORE",      90, 110, 176)
Blk("E_BLOCK_REDSTONE_ORE",   170,  80,  80)
Blk("E_BLOCK_NETHER_QUARTZ_ORE", 200, 196, 190)
Blk("E_BLOCK_BLOCK_OF_COAL",   40,  40,  40)
Blk("E_BLOCK_IRON_BLOCK",     216, 216, 216)
Blk("E_BLOCK_GOLD_BLOCK",     246, 214,  92)
Blk("E_BLOCK_DIAMOND_BLOCK",  100, 216, 214)
Blk("E_BLOCK_EMERALD_BLOCK",   84, 200, 110)
Blk("E_BLOCK_LAPIS_BLOCK",     62,  86, 172)
Blk("E_BLOCK_BLOCK_OF_REDSTONE", 170, 40, 36)
Blk("E_BLOCK_BEACON",         140, 220, 214)
Blk("E_BLOCK_DRAGON_EGG",      22,  18,  30)
Blk("E_BLOCK_BONE_BLOCK",     226, 222, 200)
Blk("E_BLOCK_NETHER_WART_BLOCK", 130,  20,  26)

----------------------------------------------------------------------
-- 按 meta 上色的方块（16 种染料色）
----------------------------------------------------------------------

local DyePalette = {
	{ 233, 236, 236 },  -- 0  white
	{ 240, 118,  19 },  -- 1  orange
	{ 189,  68, 179 },  -- 2  magenta
	{  58, 175, 217 },  -- 3  light blue
	{ 248, 198,  39 },  -- 4  yellow
	{ 112, 185,  25 },  -- 5  lime
	{ 237, 141, 172 },  -- 6  pink
	{  62,  68,  71 },  -- 7  gray
	{ 142, 142, 134 },  -- 8  light gray
	{  21, 137, 145 },  -- 9  cyan
	{ 121,  42, 172 },  -- 10 purple
	{  53,  57, 157 },  -- 11 blue
	{ 114,  71,  40 },  -- 12 brown
	{  84, 109,  27 },  -- 13 green
	{ 161,  39,  34 },  -- 14 red
	{  20,  21,  25 },  -- 15 black
}

local function MetaPalette(BlockName)
	local Id = _G[BlockName]
	if (type(Id) ~= "number") then
		return
	end
	local Map = {}
	for Meta = 0, 15 do
		Map[Meta] = DyePalette[Meta + 1]
	end
	B.MetaColors[Id] = Map
end

MetaPalette("E_BLOCK_WOOL")
MetaPalette("E_BLOCK_CARPET")
MetaPalette("E_BLOCK_STAINED_CLAY")
MetaPalette("E_BLOCK_CONCRETE")
MetaPalette("E_BLOCK_CONCRETE_POWDER")

-- 液体判定（用于跳过山体阴影）
Liquid("E_BLOCK_WATER")
Liquid("E_BLOCK_STATIONARY_WATER")
Liquid("E_BLOCK_LAVA")
Liquid("E_BLOCK_STATIONARY_LAVA")

----------------------------------------------------------------------
-- 生物群系颜色
----------------------------------------------------------------------

Bm("biOcean",               48,  88, 168)
Bm("biDeepOcean",           36,  68, 140)
Bm("biFrozenOcean",        120, 150, 190)
Bm("biRiver",               56, 106, 190)
Bm("biFrozenRiver",        150, 176, 210)
Bm("biBeach",              219, 207, 163)
Bm("biColdBeach",          210, 210, 200)
Bm("biStoneBeach",         140, 140, 140)
Bm("biPlains",             120, 170,  76)
Bm("biSunflowerPlains",    138, 184,  84)
Bm("biForest",              86, 146,  66)
Bm("biForestHills",         78, 138,  60)
Bm("biFlowerForest",       112, 164,  82)
Bm("biBirchForest",        118, 168,  86)
Bm("biBirchForestHills",   110, 160,  80)
Bm("biBirchForestM",       124, 174,  92)
Bm("biRoofedForest",        64, 118,  52)
Bm("biTaiga",               96, 140, 100)
Bm("biTaigaHills",          88, 132,  94)
Bm("biColdTaiga",          150, 180, 170)
Bm("biMegaTaiga",           92, 132,  96)
Bm("biMegaSpruceTaiga",     84, 124,  88)
Bm("biExtremeHills",       130, 140, 120)
Bm("biExtremeHillsPlus",   120, 132, 110)
Bm("biExtremeHillsEdge",   132, 150, 112)
Bm("biIceMountains",       226, 234, 240)
Bm("biIcePlains",          236, 240, 246)
Bm("biIcePlainsSpikes",    220, 232, 240)
Bm("biTundra",             200, 210, 214)
Bm("biDesert",             224, 210, 152)
Bm("biDesertHills",        214, 198, 140)
Bm("biDesertM",            232, 216, 160)
Bm("biSavanna",            178, 178,  96)
Bm("biSavannaPlateau",     188, 178, 106)
Bm("biMesa",               182, 100,  52)
Bm("biMesaPlateau",        196, 116,  62)
Bm("biMesaBryce",          206, 132,  76)
Bm("biJungle",              70, 148,  52)
Bm("biJungleHills",         62, 140,  46)
Bm("biJungleEdge",          92, 156,  66)
Bm("biSwampland",           96, 122,  72)
Bm("biMushroomIsland",     150, 140, 150)
Bm("biMushroomShore",      164, 152, 158)
Bm("biNether",             120,  40,  38)
Bm("biHell",               120,  40,  38)
Bm("biSky",                 96,  74, 130)
Bm("biEnd",                214, 214, 172)
