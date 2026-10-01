# AGENTS.md — WebChunkMap 开发须知

面向在本目录改代码的 agent / 开发者。**用户文档在 [README.md](README.md)。**

---

## 1. ⚠ 两条线程铁律（违反会 abort 整个服务器）

这个插件在开发过程中**让服务器崩过两次**，两次都是锁序反转（DeadlockDetect 直接 SIGABRT）。
下面的规则不是理论洁癖，是踩出来的。

### 铁律一：HTTP 线程只读缓存 + 入队，绝不碰 `cWorld`

WebAdmin 的标签页回调跑在 **HTTP 线程**上，并且**此刻持有本插件的 Lua 锁**。
在那里调用任何 `cWorld` 接口，就会和 tick 线程形成锁序反转：

```
HTTP 线程：持 Lua 锁         -> 等 world chunkmap
tick 线程：持 world chunkmap ->（区块 / 钩子回调）等 Lua 锁
```

崩溃日志长这样：

```
World world chunkmap: RecursionCount = 1, ThreadIDHash = 4e12ca7db848bb41
cLuaState plugin WebChunkMap: RecursionCount = 1, ThreadIDHash = 96e0956b974aac2a
```

区块生成越多越容易撞上 —— 自动补全功能会把概率推到 100%。

**`web.lua` 里只允许做三件事：**

1. 读纯 Lua 缓存：`WCM_Render.GetCached / GetWorldInfo / GetChunkInfo`、`KnownWorlds`、`DefaultWorldName`
2. 纯计算：`WCM_Render.Plan / PlanKey / ForgetTile / FlushCache / Now`
3. 入队：`WCM_Render.Enqueue`

连 `cRoot:Get():GetWorld()` 都不要用 —— 世界名由 tick 线程登记进 `WCM_Render.KnownWorlds`，
HTTP 线程只认名字（`ResolveWorldName`），压根不拿 `cWorld` 对象。

### 铁律二：世界 tick 里绝不能"跨世界"

`HOOK_WORLD_TICK` 是**每个世界各触发一次、跑在各自世界的 tick 线程上**的。
在该回调里调用 `cRoot` 上任何会遍历 / 汇总世界的接口，等于让 A 世界的 tick 线程去锁 B 世界的 chunkmap：

```
world_nether 线程：RefreshWorldCache -> GetTotalChunkCount() -> 想锁 world 的 chunkmap
world        线程：持 world chunkmap -> 等 WebChunkMap 的 Lua 锁（nether 线程正持有）
```

第二次崩溃就是这么来的（日志：`World world chunkmap: RecursionCount = 1` +
`cLuaState plugin WebChunkMap: RecursionCount = 2`），触发条件是"连续重新生成 8 个区块"——
重新生成让 `world` 的 chunkmap 被长时间持有，nether 线程必然撞上。

**禁止清单（都真实踩过）：**

| 禁止 | 正确做法 |
| --- | --- |
| `cRoot:Get():GetTotalChunkCount()` | 只用 `World:GetNumChunks()` |
| `cRoot:Get():ForEachPlayer(...)` | `World:ForEachPlayer(...)` |
| 控制台命令里 `cRoot:Get():GetWorld()` + `W:GetSpawnX()` | 只传世界名入队，坐标缺省交给 tick 线程补 |
| `cRoot:Get():GetServerUpTime()` 当时间源 | `os.time()`（兜底用 `R.TickCount`） |

目前唯一允许的 `cRoot` 用法是 `cRoot:Get():GetWebAdmin()`（只读 webadmin 单例，不涉及 chunkmap）。

### 任务队列（世界访问的唯一入口）

`main.lua` 的 `OnWorldTick`：

```
RefreshWorldCache(World)            -- 世界信息缓存（出生点 / 已加载区块数 / 玩家）
while Budget > 0 and RunOneJob(World) do ... end   -- 每 tick 最多 1 个任务
MaybeSave()                          -- 到点且有改动才把快照落盘
```

任务类型：`render` / `load` / `info` / `regen` / `teleport`，都带 `WorldName`，
`RunOneJob` 只处理属于当前世界的任务（队头不是本世界的就直接返回）。

**代价**：渲染是异步的 —— 缓存未命中时页面先显示「正在后台渲染…」，2 秒后自动刷新。

---

## 2. 文件结构

| 文件 | 职责 |
| --- | --- |
| `Info.lua` | 插件元数据（Name 必须等于文件夹名） |
| `main.lua` | 读配置、载入快照、注册 WebAdmin 标签页与命令、HOOK_WORLD_TICK 任务执行 |
| `png.lua` | 极简 PNG 编码器（8 位 RGB、Sub 滤波、CRC32 查表） |
| `blocks.lua` | 方块 / 生物群系 -> 颜色表，未知方块有稳定回退色 |
| `render.lua` | `Plan`（纯几何）+ `PlanKey` + 区域渲染 + 快照缓存与持久化 + 任务队列 + 世界/区块信息缓存 |
| `web.lua` | WebAdmin 标签页（只读缓存 + 入队），HTML 用 WebAdmin 自带样式 |

---

## 3. 渲染管线

```
请求参数 --R.Plan(Opts, SpawnX, SpawnZ)--> 几何参数（含像素预算收缩，只落到 R.SizeSteps 档位）
        --R.PlanKey(WorldName, Plan)--> 图片缓存键（不依赖世界数据，HTTP 线程可算）
        --R.Render(World, Opts)-------> PNG + Meta（只在 tick 线程调用）
```

合成阶段（不写进快照，改配置不用重建快照）：山体阴影（跨区块连续）、区块网格线、玩家 / 出生点标记。

自动补全：`render` 任务结束后，若 `Meta.WarmMissingUnknown > 0` 且到冷却期，就在 tick 线程直接
`ChunkStay` 排一批（从未见过的优先）。

---

## 4. 区块快照格式

每个区块 **1280 字节**，`cache/tiles.bin` 单文件，先写 `.tmp` 再 `os.rename`：

| 偏移 | 大小 | 内容 |
| --- | --- | --- |
| 0 | 768 | 16x16 顶面 RGB |
| 768 | 256 | 地表高度（h+1，0 = 未知） |
| 1024 | 256 | 生物群系（biome+1，0 = 未知） |

文件头：`"WCMT"` + u16 版本 + u32 记录数；每条记录 = u8 世界名长度 + 世界名 + i32 CX + i32 CZ + 1280 字节。
**改布局必须同时改 `VERSION`**，否则旧文件会被当成损坏数据读（加载器只比版本号）。

辅助函数：`R.TileHeightAt(Tile, Idx)` / `R.TileBiomeAt(Tile, Idx)`（Idx 是 0..255 的区块内下标）。

---

## 5. 其他踩过的坑

1. **WebAdmin 会把插件标签页的返回内容一律塞进模板 HTML**，不管 `ContentType` 是什么。
   所以图片只能以 `data:image/png;base64,...` 内联进页面，`<img src="...?format=png">` 拿到的是 HTML。
2. **`Request.Path` 是相对路径**（`webadmin/WebChunkMap/map`，没有前导斜杠），
   直接当 `href` / `action` 会被浏览器按当前目录解析成
   `/webadmin/WebChunkMap/webadmin/WebChunkMap/map`。
3. **`<script>` 是 raw text，HTML 实体不解码**：自动刷新 URL 不能用 `Esc()`，
   否则 `&amp;` 会让查询参数全部丢失。要用 `JsStr()`。
4. **`cWebAdmin.GetHTMLEscapedString` 运行时其实是实例方法**（点号调用报
   `argument #1 is 'string'; 'cWebAdmin' expected`），必须冒号调用。
5. **`GetBlockTypeMeta` 的标量重载已废弃**，逐列调用会往日志灌几万行警告 —— 用复用的 `Vector3i`。
6. **`GetBiomeAt` 对未加载的区块返回 -1**（文档说会走生成器，实测没有），所以群系必须存进快照，
   否则 `biome` 图层和详情面板在区块卸载后就废了。
7. **像素预算收缩视野时只能落到预设档位**（`R.SizeSteps`）。之前会收缩成 31，而 31 不在
   `<select>` 的选项里，浏览器就退回第一项 —— 表现为"视野总是自己变成 2 区块"。
   同时 `web.lua` 会把当前生效值补进选项列表兜底。
8. **`cStringCompression.CompressStringZLIB` 是静态方法**，点号调用。
9. 快照文件很大时（几千个区块）落盘会阻塞 tick 线程约 100 ms，所以靠 `SaveInterval` 限流。

---

## 6. 验证闭环

静态检查（在 `/home/david/Cuberite` 下）：

```sh
luacheck Plugins/WebChunkMap/          # 0 warnings 是基线
for f in Plugins/WebChunkMap/*.lua; do luac -p "$f"; done
```

再加 `cuberite_check`（plugin=WebChunkMap）确认没有未知类 / 方法 / 钩子。

运行时：**WebAdmin 端口和账号都是每次部署各自配置的，不要写死**。
端口取服务器根目录 `webadmin.ini` 的 `[WebAdmin] Ports`（可能是逗号分隔的多个），
账号取同文件的 `[User:*]` 段。所以测试前先从配置里读出来：

```sh
cd /home/david/Cuberite
PORT=$(awk -F= '/^\[WebAdmin\]/{f=1;next} /^\[/{f=0} f&&/^Ports=/{print $2;exit}' webadmin.ini | cut -d, -f1 | tr -d '[:space:]')
USERPASS=admin:admin          # 改成 webadmin.ini 里实际的账号
BASE="http://127.0.0.1:$PORT/webadmin/WebChunkMap/map"
echo "WebAdmin: $BASE"

# 冷缓存：第一次会返回"正在后台渲染…"，2~3 秒后再取就有图
curl -s -u "$USERPASS" "$BASE?size=8&scale=2" | grep -c 'data:image/png;base64,'

# 抽图验证 PNG 有效
curl -s -u "$USERPASS" "$BASE?size=8&scale=2" \
  | grep -o 'data:image/png;base64,[A-Za-z0-9+/=]*' | head -1 \
  | sed 's/^data:image\/png;base64,//' | base64 -d > /tmp/m.png && file /tmp/m.png
```

实在找不到端口时，控制台执行 `chunkmap status`——插件用 `cWebAdmin:GetPorts()` 读出真实端口后
会把完整地址打出来（`main.lua` 的 `GetMapURL()`，本来就与端口无关，别改成常量）。

控制台命令输出走日志：`chunkmap status | flush | save | forget <world> all | render ...`

**回归必测的两个崩溃场景**（改完 tick / 渲染相关代码后一定跑一遍）：

1. 连续 3 轮重新生成同一批 8 个区块（`"$BASE?...&action=regen&confirm=1"`），之后确认服务器还活着。
2. 多轮并发请求混合负载：跨未探索地形平移（`size=16`）+ `warm=1` + `regen` + `chunks` 图层。

跑完检查日志里**没有新增** `Deadlock detected`：

```sh
grep -n 'Deadlock detected' logs/cuberite-console.log   # 只应看到历史记录的时间戳
```

浏览器侧用 Playwright：点区块、点平移、看跳转 URL 是否保留了参数（历史上这里出过两次 bug）。
