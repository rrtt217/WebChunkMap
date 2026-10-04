# WebChunkMap

给 Cuberite **WebAdmin** 加一个「区块地图」标签页：俯视世界的地形，可平移、缩放、切换图层，
也能点选区块做管理。渲染在浏览器里做，换视野不占服务器 tick。

![界面](docs/canvas-page.png)

## 使用

在服务器根目录 `settings.ini` 的 `[Plugins]` 段加一行 `WebChunkMap=1`，然后打开：

```
http://<服务器>:<WebAdmin 端口>/webadmin/WebChunkMap/map
```

端口取 `webadmin.ini` 的 `[WebAdmin] Ports`，登录账号看同文件的 `[User:*]`。
找不到地址就在游戏里执行 `/chunkmap`，或控制台执行 `chunkmap status`。

浏览器需要支持 `DecompressionStream`（Chrome 80+ / Firefox 113+ / Safari 16.4+）；
不支持时页面会提示，并给出改用服务端 PNG 的链接。

## 三种图层

| 图层 | 说明 |
| --- | --- |
| **地表** | 俯视地表，按顶层方块上色，带高度差阴影，标出在线玩家与出生点 |
| **生物群系** | 按群系上色 |
| **区块状态** | 已加载 / 记忆中的快照 / 从未见过 |

每 16 格有一条暗色区块边界线。

## "曾经加载过"的地形会留下来

区块被加载过一次就会留下很小的渲染快照（约 1.25 KiB，只存顶面颜色、地表高度和群系），
之后即使区块被卸载，地图上依然画得出来。快照存在 `cache/tiles.bin`，重启后仍在。
清掉某个世界：控制台 `chunkmap forget <世界名> all`。

> 刚打开时地图上大部分是暗的，这属正常 —— Cuberite 只在玩家附近保持区块加载。

## 平移与自动补全

页面顶部有 北 / 南 / 西 / 东 / 缩小 / 放大 / 回到出生点。

- **自动补全**：每次渲染后自动把视野里"从未见过"的区块排进加载队列，一路平移过去地图会自己补全。
- **⏬ 加载可见区块**：手动触发，同样是从未见过的优先。

> 自动补全会真的生成新地形，和玩家走过去一样有 CPU 开销。不想要就把
> `[Cache] AutoLoadOnView` 设 0。

## 点选区块做管理

点击地图上的区块即可选中 / 取消（可多选）。选中的区块会高亮，并在下方列出坐标、状态、
生物群系、地表高度、顶层方块、实体与玩家数，并提供：

**定位** · **加载这些区块** · **清除记忆** · **重新生成**（需勾选确认）· **传送到第 1 个选中区块**

"清除记忆"只删本地快照，不动世界数据。

## 配置

首次启动时会从 [settings.ini.example](settings.ini.example) 复制出一份 `settings.ini`
（不进版本库，每台机器各改各的）。文件内有逐项注释，最常用的几项：

| 段 | 键 | 作用 |
| --- | --- | --- |
| `[Web]` | `TabTitle` | 标签页名称 |
| | `DefaultSizeChunks` / `DefaultScale` / `DefaultMode` | 打开时的默认视野 |
| `[Render]` | `CacheTTL` | 缓存的后台刷新阈值（秒）；不影响页面响应，想立刻更新就勾「强制重绘」|
| | `CanvasOnly` | 只要画布数据、不出 PNG；设 0 退回服务端画图 |
| | `DrawChunkGrid` / `HillShading` / `DrawPlayers` / `DrawStructures` | 图层元素开关 |
| `[Cache]` | `RememberChunks` | 是否记住曾经加载过的区块 |
| | `MaxChunks` | 快照数量上限 |
| | `MaxLoadedChunks` | **已加载区块总量阀门**（0 = 不限）；小内存机器务必设置 |
| | `MaxWarmChunks` | 手动「加载可见区块」单次上限（默认 512 ≈ 100 MB；树莓派建议 32~64）|
| | `AutoLoadOnView` | 平移时是否自动补全地形 |

## 命令

- 玩家：`/chunkmap` —— 显示地图地址与快照状态
- 控制台：`chunkmap status | flush | save | forget <世界名> all | render [世界名] [cx] [cz] [视野] [缩放]`

---

改代码前请先读 [AGENTS.md](AGENTS.md)：里面有**两条会导致整个服务器 abort 的线程规则**。