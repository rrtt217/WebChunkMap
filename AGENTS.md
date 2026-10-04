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

### 已加载区块的总量阀门（内存防护，别拆）

**区块是内存大头**：实测约 **150~200 KB/个**，由 Cuberite 的 chunkmap 持有。
插件通过 `ChunkStay` 不停地往里灌，而且**从不检查已经加载了多少** ——
在一台 426 MiB 的树莓派上，"正常用半天"能堆到 5965 个（1133 MiB）。

`[Cache] MaxLoadedChunks`（0 = 不限）就是这道闸。装在 **`RunLoadJob`** 里，
一次覆盖自动补全 / `warm=1` / 「加载这些区块」三条路径。

- **不是一刀切拒绝，而是按剩余额度截断**：额度剩 3 就只加载 3 个（实测：上限 = 当前+3，
  请求 8 个，实际只涨 3）。截断保留队列**前部** —— 队列本来就是"从未见过优先"，
  留下的正是最有价值的。
- **`LoadAfterRegen` 故意不走这道闸**：那是用户明确要求的重新生成的后续，
  挡掉就又变回"地图留空白洞"（见第 3 节）。一次最多 64 个，不构成风险。
- **两道检查**：HTTP 线程用 `R.WorldCache` 里缓存的 `LoadedChunks` **预判**
  （读缓存不碰 cWorld，铁律一安全），到顶就不排队、直接给提示；
  tick 线程的 `RunLoadJob` 是**真正的执行闸**（数量随时会变）。
- **拒绝必须可见**：`R.LastLoadRefusal`（tick 写 / HTTP 读的纯 Lua 表）供页面显示，
  日志另外限流到每分钟一条，免得自动补全每次渲染都刷屏。

> 加这道闸的教训：`R.LastAction` 那套只写不读，是死代码 —— 别照抄。

### ChunkStay 的两个坑（读引擎源码确认，别再踩）

**根因**：`src/ChunkGeneratorThread.cpp`

    // Skip the chunk if the generator is overloaded:
    if (SkipEnabled && !m_ChunkSink->HasChunkAnyClients(item.m_Coords))
    {
        LOGWARNING("Chunk generator overloaded, skipping chunk %s", ...);
        item.m_Callback->Call(item.m_Coords, false);   // false = 没生成
        continue;
    }

而 `cChunk::HasAnyClients()` 就是 `return !m_LoadedByClient.empty();` ——
**只有玩家算 client**。所以 **ChunkStay 要的区块一个 client 都没有，过载时正是被丢的那批**。

被丢之后 `cChunk::MarkLoadFailed()` 会 MarkDirty() 再 QueueGenerateChunk()：区块**被反复重排**，
只要生成器还在过载就反复被 skip（日志里那几千条 warning 就是重试风暴）。它永远拿不到
IsValid()，于是 **ChunkAvailable 永不调用 -> OnAllChunksAvailable 永不触发**，
而这些区块被 Stay(true) 标记、**永不参与卸载**。

**后果（实测）**：一次要 625 个区块 -> 生成器跳过 123 个（日志正好 123 条）->
整批 625 个（含已加载好的 502 个）被永久钉住，完成回调永不执行。
**这就是"用半天堆到 5965 个区块、从不释放"的根因。**

**两道防护（都别拆）**：
1. `STAY_BATCH = 64`（`LoadInBatches`）：把单次 stay 的规模压到生成器吃得下的水平。
   实测 400 个区块分 7 批加载，**过载告警一条都没新增**，且加载完后**区块被正常释放**。
2. 看门狗 + 黑名单（`R.CheckStays` / `R.BadChunks`）：45 秒没回来的批次就拉黑并跳过，
   把损失限制在一批以内。黑名单**带 600 秒过期**——因为引擎其实会重排，过载缓解后是有救的。
   统计出口是 `WebChunkMap_MemStats()` 的 StayStarted/StayDone/StayInFlight/BadChunks。

> **修正一个曾经的误判**：我一开始按黑盒实验以为"列表里含已加载区块会让 stay 悬住"。
> 读源码否定了：`cChunkMap::AddChunkStay` 对已经 valid 的区块**会**逐个调 ChunkAvailable。
> 当时"4 个区块只回调 1 次"真正的原因是那 4 个里有 3 个处于 queued 状态并被 skip 了。
> **教训：黑盒现象要先读源码再下结论**（源码在 raspi 的 ~/compile-cuberite/cuberite/src/）。

两个可调的量（都在 `[Cache]`）：`MaxLoadedChunks`（总量阀门）、`MaxWarmChunks`
（手动按钮单次上限，默认 512，**约 100 MB 常驻内存**）。后者原来硬编码在 `web.lua`，
raspi 上想单独调小都做不到，现在挪进了配置。`AutoLoadMaxChunks` 管的是自动补全。

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
| `settings.ini.example` | 配置模板（进版本库）。`settings.ini` 由 `EnsureSettingsFile()` 在首次启动时复制生成，**被 .gitignore 忽略** |

---

## 3. 渲染管线

```
请求参数 --R.Plan(Opts, SpawnX, SpawnZ)--> 几何参数（含像素预算收缩，只落到 R.SizeSteps 档位）
        --R.PlanKey(WorldName, Plan)--> 图片缓存键（不依赖世界数据，HTTP 线程可算）
        --R.Render(World, Opts)-------> PNG + Meta（只在 tick 线程调用）
```

合成阶段（不写进快照，改配置不用重建快照）：山体阴影（跨区块连续）、区块网格线、玩家 / 出生点标记。

**TTL 的语义**（曾经搞错过一次）：`CacheTTL` **只决定"什么时候在后台重绘缓存"，
绝不决定"这次请求能不能用缓存"**。命中但过期的图要照旧先发出去（stale-while-revalidate），
否则超过 TTL 的每一次交互 —— 包括**点选区块** —— 都会触发一次重绘 + 整页自动刷新。

- 选中高亮是**纯前端**的（`web.lua` 输出绝对定位的 `<span class="wcm-sel">`），
  `R.PlanKey()` 里**没有** `sel`，所以选区变化永远不该导致重绘。
- 只有 `ActionQueued`（用户点了操作按钮）、`Png == nil`、`NoCache` 才值得**整页**自动刷新。
- `InfoStale`（详情面板缺数据）走 `?panel=1` + `fetch()` **局部替换 `#wcm-panel`**，
  既不重绘地图也不重载页面 —— 整页重载会在用户点下一个区块时打乱页面，
  点击落到已选中的区块上就变成了"取消"，表现为"选第二个区块时全被取消"。

### 结构位置（唯一的跨插件调用）

地图上的结构标记来自 **VanillaFeatureComplement** 的 Locate API（**v3**），走
`cPluginManager:CallPlugin("VanillaFeatureComplement", …)`：

| 函数 | 说明 |
| --- | --- |
| `StructureLocateAPIVersion()` | 返回 3；低于 `STRUCTURE_API_VERSION` 就整个不启用 |
| `StructureLocateKinds()` | 7 种结构名 |
| `StructureLocateFindAll(World, Kind, MinX, MinZ, MaxX, MaxZ, RefX, RefZ, Biomes)` | `{Ok=true, Count, ConfirmedCount, Items={{Kind,Display,X,Y,Z,Distance,Confirmed,Detail,OriginX,OriginZ},…}}` / `{Ok=false, Error}` / **nil**（插件没装或函数名不对） |

**v1 的 `StructureLocateFind` 已经不存在了**（对方改成 `FindNearest` / `FindAll`，并加了 `Biomes`）。
我们只用 `FindAll`：它按矩形返回**该种结构的全部实例**（按距离排序），
所以一个视野里有俩村庄时两个都会画出来；旧写法一圈只能画最近的一个。

**`Biomes` 是我们这侧的独门数据**：`{["blockX,blockZ"] = biomeId}`，对方**只在引擎答不出来时**
（区块没加载）才用，引擎自己的答案永远优先 —— 给错了也只会被忽略，不会被当真。
我们每个区块快照里都存了 16x16 的群系，正好补这个洞。

四条硬约束：

1. **只能在 tick 线程调用**。对方内部要读世界（判断区块是否已生成），从 WebAdmin 的
   HTTP 线程调就会锁序反转 —— 所以它放在 `R.Render` 里，不在 `web.lua` 里。
2. **失败一律静默**（页面层面）。`Ok=false` / nil / 抛错都当作"没有结构"，页面上不冒错误。
   查询次数限流：`StructApi()` 最多每 60 秒探一次，免得对方每次渲染都往日志写 "Function not found"。
   **例外**：*我们自己内部*抛异常时每分钟记一条控制台日志 —— 全静默会让 bug 也查不出来
   （这条是踩过才加的：一个真 bug 因为被 pcall 吞掉，查了十几轮）。
3. **`Biomes` 必须小**。跨插件的表是**拷贝**的，铺满视野代价不可接受
   （size=16 是 256x256 = 65536 项 × 7 种结构，每项还要在对方状态里新建一个键字符串）。
   所以走**两趟**：先不带群系跑一趟，把"不确定"的收上来，第二趟只补这些坐标 ——
   非村庄类只需**原点方块**一项，村庄需要原点区块的**256 列**（它要拿整块地判 pool 的 AllowedBiomes）。
   实测村庄那次供了 256 项，其余种类通常是 0 项（没有快照就干脆不供）。
4. **第二趟的结果整体替换第一趟**（而不是合并）。更准确的答案可能把"不确定"变成"否"——
   实测那个 `?` 村庄就是这样被正确否掉的（网格候选点，但当地群系不满足 AllowedBiomes），
   也就是**之前画的是假阳性**。

代价：一次渲染最多 7 次（有需要时 14 次）跨插件调用。要关掉就把 `[Render] DrawStructures` 设 0。

### 渲染热点在哪里（实测，别再猜）

装了分阶段计时，用跨插件出口读：`WebChunkMap_ProfDump()` / `WebChunkMap_ProfReset()`。

48x48 视野（768x768 = 589824 个方块列，scale=1）的实测：

**优化前**：

| 阶段 | 耗时 | 占比 |
| --- | --- | --- |
| **像素合成** | **380 ms** | 73% |
| ├─ **山体阴影** | **181 ms** | **占像素阶段的 48%，全场最大单项** |
| ├─ 区块网格线 | 20 ms | |
| └─ 取色 / 合成 | 179 ms | |
| **PNG 编码** | **117 ms** | 23% |
| └─ **CRC32** | **~100 ms** | 纯 Lua 逐字节（每字节 2 次 Xor32） |
| 网格采集 | 2 ms | |
| 结构（跨插件 7~14 次调用） | 7 ms | |
| 玩家 / 出生点标记 | 0 ms | |

**优化后**（三轮优化，每次都用"固定视图 PNG 逐字节不变"验证过画面没动）：

| 阶段 | 优化前 | 优化后 | 变化 |
| --- | --- | --- | --- |
| 像素合成 | 380 ms | **245 ms** | −36% |
| PNG 编码 | 117 ms | **59 ms** | −50% |
| **合计** | **~500 ms** | **296 ms** | **−41%** |

三轮改动分别是：
1. **山体阴影**：明暗系数查表（F 被夹在 [0.62,1.35]，整数高度差只有十几二十种取值）；
   `bx/16` / `bx%16` 从每像素两次除法两次取模改成递增计数器 + 区块边界批量取
   Tile/State；高度改成"每像素行每区块"一次 `sub` 出 16 列，两行轮换（PrevRow/CurRow）。
2. **CRC32**：把状态拆成四个字节变量、按字节平面展开更新式，每字节从 2 次 Xor32
   （约 25 条运算）降到 8 次查表 + 5 条算术。
3. **标记查找**：结构 / 玩家 / 出生点标记按像素行分组一次（它们本来就很稀疏），
   于是每像素从两次哈希查找降到一次 nil 判断。

**还没做的**：区块网格线（20 ms）可以只在 `tx == 0` 时处理；取色/合成那 179 ms 里还有
每像素的取色与分支。但收益已经不大，注意别为了小钱破坏"逐字节不变"这个验证优势。

**两个反直觉的发现**：

1. **山体阴影还间接拖累了 PNG**：关掉它之后 PNG 从 117 ms 降到 44 ms ——
   因为画面变平、压缩率变高、IDAT 变小，而 CRC32 是**按压缩后字节数**算的。
   也就是说"阴影"的 181 ms 之外，还有约 70 ms 记在 PNG 账上。
2. **CRC32 才是 PNG 的大头**，不是压缩（ZLIB 是原生 C++，只占 3 ms）。
   而 PNG 行滤波已经证明是纯负担（见下），所以剩下的优化空间就在 CRC 上。

**验证手法（重要）**：这三轮改动全程用"固定视图 PNG 逐字节一致"来证明画面没动。
之所以这个判据成立：山体阴影和标记都是确定性的，CRC 又是 PNG 输出的组成部分，
所以任何一处写错都会立刻反映在字节上 —— 比肉眼比对可靠得多，而且不用人盯着看。
基线值记在提交信息里（257954 字节 / sha256 919ac2060fc17227）。

**如果以后还要提速**，剩下的位置是：区块网格线（20 ms，可以先只在 tx == 0 时处理）、
以及取色/合成那部分里的每像素分支。收益已经不大，**优先保住"逐字节不变"这个验证优势**。

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
   **推论：插件标签页永远拿不到"裸响应"。** `webadmin/template.lua` 的 `ShowPage` 无条件拼上
   `<html><head>…<div class="columns">…`，本版本也没有 `HOOK_WEBADMIN_REQUEST` 可以绕过。
   所以用 `fetch()` 做局部刷新（例如 `?panel=1`）时返回的**仍是整页 HTML**；
   直接 `innerHTML = t` 会让整个 WebAdmin 再嵌套一层（页面上出现两个 Cuberite 顶栏、两个 .header）。
   正确做法是在浏览器侧解析后只取目标容器：

   ```js
   var d = new DOMParser().parseFromString(t, 'text/html');
   document.getElementById('wcm-panel').innerHTML = d.getElementById('wcm-panel').innerHTML;
   ```
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
10. **`sel` 里的分隔符必须写成 `%3B`，不能留裸 `;`。** Cuberite 自己解析裸 `;` 没问题
    （直连 `:8080` 一直正常），但**中间的代理会把它吃掉**：Tailscale 的 Go 反向代理按
    `net/url` 的规则处理查询串，裸 `;` 会让**整个参数被丢弃**。实测：

    | 路径 | 请求里的 sel | 服务器收到 | 选中数 |
    | --- | --- | --- | --- |
    | 直连 `:8080` | `5:-1;6:-1` | `5:-1;6:-1` | 2 |
    | tailnet | `5:-1;6:-1` | *（空）* | **0** |
    | tailnet | `5:-1%3B6:-1` | `5:-1;6:-1` | **2** |

    症状是"页面加载出来是 选中的区块（0）"。`QueryString` 里已经做了 `gsub(";", "%%3B")`。
11. **`settings.ini` 不是仓库文件**（只有 `settings.ini.example` 是）。改它不会出现在
    `git status` 里，别的机器也看不到；要改**默认值**请改 `settings.ini.example` 并推送。

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
