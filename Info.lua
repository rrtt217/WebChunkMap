-- Info.lua
-- WebChunkMap: 在 WebAdmin 里加一个"区块地图"标签页。
-- 插件名必须与文件夹名（WebChunkMap）一致，否则 ReloadPlugin / UnloadPlugin 无法按文件夹定位。

g_PluginInfo =
{
	Name = "WebChunkMap",
	Version = "0.1",
	Date = "2026-10-01",
	Description = [[给 WebAdmin 增加一个"区块地图"标签页：服务端把某个世界的
区块数据渲染成 PNG 图片（纯 Lua 编码，无外部依赖），页面上可以直接平移 / 缩放。

三种模式：
  topo   —— 俯视地表，按顶层方块上色，附带高度差阴影，并标出在线玩家与出生点；
  biome  —— 按生物群系上色（未加载的区块也能画，因为群系可由生成器给出）；
  chunks —— 区块加载状态图（绿色 = 已加载，深色 = 未加载）。

视野里还有未加载的区块时可以点「加载可见区块」：插件用 cWorld:ChunkStay 把它们排进
加载队列，就绪后在回调里重绘并写入缓存，页面随后自动刷新（URL 参数保持不变）。

图片带 TTL 缓存，避免每次翻页都重新扫描区块；玩家 / 出生点会作为标记画在地图上。

命令：
  /chunkmap            显示 WebAdmin 地图地址与缓存状态
  chunkmap status      同上（控制台）
  chunkmap flush       清空渲染缓存
  chunkmap render [world] [cx] [cz] [size] [scale]   强制渲染一次并打印耗时]],


	-- 下面两条命令在 Initialize() 里手动 BindCommand / BindConsoleCommand 注册，
	-- 这里仅作为文档说明（引擎不会自动注册 Info.lua 里的 Commands）。
	Commands =
	{
		["/chunkmap"] = { HelpString = "显示 WebAdmin 区块地图的地址与缓存状态" },
	},
	ConsoleCommands =
	{
		["chunkmap"] = { HelpString = "chunkmap status | flush | render <world> <cx> <cz> [size] [scale]" },
	},
	Permissions = { },       -- 使用空权限：命令只暴露一个 URL，不需要额外授权
}
