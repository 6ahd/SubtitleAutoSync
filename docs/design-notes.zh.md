# EplayerX 字幕自动同步实现指南

Oct 1, 2026 · @Ahmed Alrufaidy

最好的做法：用视频里自带的内嵌字幕做“标准答案”，只读容器索引拿到它每一行的开始时间，再只按时间把外挂字幕对上去（偏移加帧率比例），把握不够就不改。EplayerX 基于 FFmpeg，可以直接从播放器自己的索引读出这些时间（已用 FFmpeg 6.1 实测），附带的 Swift 模块 SubtitleAutoSync 实现了其余部分并已通过测试。视频里没有内嵌字幕时，再用音频对齐作为后备。

本文依据两个已经在用的实现：DexWorld 的 Kodi 字幕插件（service.subtitles.dexworld 5.7.3）和 NuvioTV Reshaped（Android TV，版本 1.1.0-beta.3-autosync.1）。

## 两个项目的做法

两个项目思路相同：先从视频的容器索引读出内嵌字幕的时间轴，只按时间对齐外挂字幕，只在把握很高时才应用。NuvioTV 在此基础上多了结构对齐和音频后备，代价是代码量大很多（AutoSync 和 AudioSync 合计约 1.8 万行 Kotlin）。

| 项目 | DexWorld 字幕插件 | NuvioTV Reshaped |
| --- | --- | --- |
| 平台与语言 | Kodi 插件，Python | Android TV 播放器，Kotlin（Media3） |
| 参照来源 | MKV 的 Cues 索引；没有文字字幕时用 PGS 的显示和清除时间 | MKV 的 Cues 和 MP4 的样本表；都不行时抓播放器解复用出来的字幕；再不行就听音频 |
| 读取量 | 通常不到 2 MB、2 到 3 个请求；上限 24 MB、16 个请求、25 秒 | 上限 24 MB、16 个请求、7 秒 |
| 对齐用的特征 | 每行的开始时间 | 每行显示的时间区间（500 ms 和 100 ms 两级位图），再用动态规划把字幕行按组对应 |
| 能纠正什么 | 整体偏移；7 种帧率比例；最小二乘微调比例 | 偏移；帧率比例；每组字幕的小幅修正（拆行、合行） |
| 不做什么 | 片中有剪辑差异时：两段长度相近会放弃；一段占七成以上时仍按多数段整体偏移，少数段继续不同步 | 片中有剪辑时直接拒绝，不做分段同步（代码注释写明） |
| 安全规则 | 匹配 ≥ 45%，比第二名高 ≥ 20 个百分点，至少 20 行；移动不到 250 ms 视为本来就同步 | 多道门槛：覆盖率至少 84%（自动发现比例时 90%）、前中后三段一致、平均代价、最长未匹配段等 |
| 结果怎么用 | 改写字幕文件的时间戳（原编码逐字节不变），交给 Kodi 重新加载 | 改写内存里的字幕 cue 列表，由自己的字幕渲染器显示 |
| 音频后备 | 没有 | 有：Silero VAD 语音检测加 FFT 相关；可选英语语音识别 |
| 代码许可 | DexWorld 自有代码，已移植成附带的 Swift 模块 | GPL-3.0：闭源 App 只能借鉴思路，不能复制代码 |

## 整体流程

&#91;embedded content: 自动同步流程 · 6 步，3 个保留原字幕的出口\]

只有安全决策全部通过才会改动字幕；任何一步不满足，都保留原字幕，播放始终不受影响。

## 参照时间轴从哪里来

参照就是视频里某条内嵌字幕每一行的开始时间。只读容器索引就能拿到，不解码视频，也不下载整个文件。

### MKV：只读 Cues 索引

mkvmerge 和 FFmpeg 封装 MKV 时，会给文字字幕的每一行写一个 CuePoint，并带上 CueDuration。我们用 mkvmerge v82 和 FFmpeg 6.1 各封装了一个 349 行字幕的文件，两个都得到 349 个 CuePoint，时长也全部存在。

要读的元素：EBML 头、Segment、SeekHead、Info（TimestampScale）、Tracks（TrackType 17 是字幕）、Cues（CueTime 加 CueTrackPositions 里的 CueTrack 和 CueDuration）。DexWorld 的读法：

1. 读文件开头 512 KB，找到 Segment 和 SeekHead。
2. 按 SeekHead 找到 Info、Tracks、Cues 的位置，最多跟进 4 个 SeekHead。
3. 读 Cues（一般在文件末尾），按字幕轨号取出每行的开始时间和时长。
4. SeekHead 里没有 Cues 的位置时，读最后 4 MB，从后往前找 Cues 的 ID（0x1C53BB6B）。
5. 没有 CueDuration 时，结束时间按到下一行的间隔估计，最多 4 秒。

实际通常 2 到 3 个 Range 请求、不到 2 MB，文件有几十 GB 也一样。预算上限是 24 MB、16 个请求、25 秒（NuvioTV 是 7 秒）。服务器忽略 Range 返回 200 时立即停止，绝不下载整部电影。

PGS 图片字幕也能当参照：索引里有每行“显示”和“清除”两个时间，不需要识别图片（DexWorld 5.7.1 起）。蓝光原盘转封的文件往往只有 PGS，这一点很有用。

### EplayerX 的捷径：直接读 FFmpeg 的索引

FFmpeg 的 matroska 解复用器在第一次 seek 时解析 Cues，并把每一条记录加进对应 AVStream 的索引，字幕轨也一样（源码里是 matroska\_read\_seek、matroska\_parse\_cues、matroska\_add\_index\_entries）。所以在打开文件后、开始播放前 seek 一次，就能用 avformat\_index\_get\_entries\_count 和 avformat\_index\_get\_entry 读出全部开始时间：不用另开连接，也不用自己解析 EBML。网络源上这次 seek 会让 FFmpeg 自己多发 2 到 3 个 Range 请求（跳到文件末尾读 Cues 再跳回来）。

MP4 更简单：mov 解复用器打开时就建好了全部样本索引，只需要过滤 tx3g 的空样本（2 字节，表示两行字幕之间的空白）。

用 FFmpeg 6.1 实测（代码就是附带的 FFmpegSubtitleIndex.swift；当前 FFmpeg 主干源码是同样的逻辑，EplayerX 用的 FFmpeg 版本更新，接入前请用自己的构建再测一次）：

| 测试文件 | seek 前条目数 | seek 后条目数 | 与真实字幕比较 |
| --- | --- | --- | --- |
| mkvmerge 封装的 MKV，349 行英文 SRT | 0 | 349 | 完全一致 |
| FFmpeg 封装的 MKV，同一字幕 | 0 | 349 | 完全一致 |
| 多轨 MKV：阿语 ASS（forced，20 行）、英文 SDH（432 行）、英文（349 行） | 0 | 20、432、349 | 自动选中英文轨，完全一致 |
| MP4，mov\_text 字幕 | 349（打开即有，已过滤 349 个空样本） | 不需要 seek | 完全一致 |
| 没有写字幕 Cue 的 MKV | 0 | 0 | 无参照，保留原字幕 |

```swift
// 在解复用线程上，avformat_find_stream_info 之后调用
avformat_seek_file(fmt, -1, Int64.min, 0, Int64.max, 0)   // 让 MKV 的 Cues 被解析

let st = fmt.pointee.streams[Int(subtitleIndex)]!
let tb = st.pointee.time_base
var startsMs: [Int] = []
for i in 0..<avformat_index_get_entries_count(st) {
    guard let e = avformat_index_get_entry(st, i) else { continue }
    if isMP4 && e.pointee.size <= 2 { continue }   // tx3g 空样本
    let ms = Double(e.pointee.timestamp) * Double(tb.num) * 1000 / Double(tb.den)
    startsMs.append(Int(ms.rounded()))
}
```

注意事项：

- AVFormatContext 不是线程安全的，必须在解复用线程上调用，不能和 av\_read\_frame 并发。
- 这次 seek 会把解复用位置移到 0 点，所以要在开始播放之前做。如果恢复播放进度时本来就会 seek，那次 seek 已经触发了 Cues 解析，不用再 seek 一次。
- 只在这次 seek 之后读一次并保存，不要在播放中途再读：解复用器会把读到的字幕块也加进索引，字幕轨没有 Cues 记录的 MKV 在播放中途读到的只是已播放的一段，看起来却像合格的参照。附带代码会检查第一行到最后一行至少覆盖片长的一半。
- 自定义 AVIOContext 必须可 seek（AVIO\_SEEKABLE\_NORMAL），打开时也不要设 AVFMT\_FLAG\_IGNIDX，否则不会有索引。
- 索引里只有开始时间，没有时长；DexWorld 的对齐算法本来就只用开始时间。
- 如果播放器的时间轴从 0 开始，要减去 fmt.start\_time（MKV 通常是 0）。

只有拿不到 AVFormatContext 的引擎（比如走 AVPlayer 的路径）才用模块里的 MatroskaCues 加 HTTPRangeSource 自己读，带上播放用的请求头（Emby、Jellyfin、Plex 的 token）。它和播放并行，可以在打开视频的同时预取（NuvioTV 就是这样做的），但只支持 MKV。有 FFmpeg 的引擎即使索引里没有可用参照，也不要再走 HTTP Range：结果不会更好，还会多开一个连接。

### 选哪条内嵌字幕做参照

对齐只看时间，所以参照的语言不影响结果：阿拉伯语或中文字幕可以对着英文字幕对齐。但参照必须是完整对白。

- DexWorld：文字字幕优先于图片字幕；英语优先；forced（只翻招牌和外语对白）和评论字幕排到最后；SRT 优先于 ASS；SDH 稍降权；行数多的优先。至少 30 行、跨度 2 分钟，图片字幕要 60 个事件。
- NuvioTV：不预先只选一条，每条合格的都试。合格标准是至少 8 行、每分钟至少 2 行、跨度 45 秒、从播放器抓到的字幕还要至少 45% 的行像对白（只读索引时没有文字，这一条不适用），forced 轨只作后备；有 3 条以上时互相投票，和别人都对不上的那条剔除。

### 读不了索引的情况

HLS 和 DASH 播放列表、直播、碎片化 MP4、不支持 Range 的服务器：跳过自动同步，保留原字幕。IPTV（例如 Xtream）往往只允许一个连接，第二个连接可能被拒绝，或把正在播放的连接挤掉。NuvioTV 只对自己的直播频道跳过预取；DexWorld 只对 Kodi 开播时自己加载的字幕跳过 Xtream 链接，用户手选、手动按钮和它自己的自动下载仍会读。EplayerX 走 FFmpeg 索引不需要另开连接；HTTP Range 这条路对这类源应该关闭（模块里设 isLive）。

## 外挂字幕的时间

外挂字幕只取每行的开始时间。少于 30 行就不做（发网络请求前先做这个检查），去重后不足 30 行的在对齐时也会放弃。改写时只动时间戳，其他字节一个不变。

- 格式：SRT、WebVTT（包括 MM:SS.mmm 短格式）、ASS 和 SSA。ASS 只取 Dialogue 行，跳过 Comment；结束早于开始的行忽略。NuvioTV 还支持 TTML（含按帧写的时间）。
- 不重新编码：DexWorld 直接在原始字节上用正则匹配时间戳（Swift 版把字节按 ISO-8859-1 一对一看成字符，效果相同），只会命中 ASCII 的时间戳，替换后其余字节原样写回。UTF-16 文件按 BOM 解码，改完再按原字节序和 BOM 写回；没有 BOM 的 UTF-16 读不到时间戳。
- 好处：Windows-1256 的阿拉伯语、GBK 和 Big5 的中文、带 BOM 的 UTF-8 都不会乱码，样式、换行和 ASS 特效也不变。这些编码的双字节字符里不会出现数字或冒号，所以时间戳不会被误匹配。
- 格式保持原样：原来用逗号还是点、带不带小时、ASS 的百分之一秒（995 ms 以上进位）都照旧。
- 反例：从代码看，NuvioTV 的 AutoSync 用响应头里的 charset 解码字幕，没有声明就当 UTF-8，而且同一份文字也拿去显示。没有声明编码的 Windows-1256 字幕，阿拉伯字母会变成替换字符，再被 SubtitleMojibakeSanitizer 删掉，显示出来基本是空行；不开 AutoSync 时走带 Windows-1256 识别的 SubtitleCharsetDetector，没有这个问题。EplayerX 的阿拉伯语和中文用户多，同步流程里不要重新解码文字。

## 对齐与安全决策

能自动修的不同步只有两种：整体差几秒（片头、厂牌、剪辑起点不同），或帧率不同导致越往后差越多。例如 25 与 23.976 帧差 4.27%，两小时的片子到结尾差约 5 分钟。所以要找的就是一条直线：新时间 = 旧时间 × 比例 + 偏移。

第三种是版本不同（导演剪辑版、删减、片中插入），不同段落偏移不一样，一条直线修不好。NuvioTV 会直接拒绝；DexWorld 只在两段长度相近时因“第二名差距”不够而放弃，一段占七成以上时仍按多数段整体偏移，少数段继续不同步（实测：在 70% 和 80% 处插入 5 秒都会被应用）。所以附带的 Swift 模块加了第 6 步的三段一致性检查。

DexWorld 的算法（附带的 Swift 模块与它逐项一致）：

1. 去重：40 ms 以内算同一行。参照或字幕少于 30 行就放弃。
2. 投票找候选：对 7 个比例（1、25/23.976、23.976/25、25/24、24/25、24/23.976、23.976/24），每隔 ⌊行数 ÷ 400⌋ 行取一行字幕参与投票（不到 800 行时全部参与）。每行和 ±300 秒内的每个参照开始时间算差值，按 100 ms 一格投票。三格平滑后，每个比例取票数最高、彼此相距超过 1 秒的 4 个峰，再加上“不变”，最多 29 个候选。
3. 精修每个候选：变换后的字幕开始时间找最近的参照开始时间，差 350 ms 以内算匹配。用残差中位数修正偏移两次，再用最小二乘拟合比例和偏移；比例在 0.94 到 1.07 之间、匹配的行不减少才采用，然后再修正一次。
4. 打分：匹配的行数。“第二名”是在开头、中间、结尾任一点和第一名相差超过 1.5 秒的最好候选。
5. 决策：匹配率 ≥ 45%（可设置）、比第二名高 ≥ 20 个百分点、至少 20 行匹配，才应用。三点的最大移动不到 250 ms 视为本来就同步，不改。
6. 三段一致性检查（Swift 版新增，DexWorld 原版没有）：把字幕的时间范围分成前、中、后三段，每段单独投票。如果某个离全局至少 1 秒的偏移能让某一段匹配得差不多好（不低于全局减 0.10，且至少 0.30），就判定为剪辑版本不同，不应用。参照缺一段时那一段任何偏移都对不上，不会被误判。
7. 应用：每个时间戳按直线换算，取整到毫秒，负数归 0，结束至少比开始晚 1 ms。

&#91;embedded content: 由附带测试数据计算：ref\_en.srt 的 349 行参照与 310 行 25 帧字幕，投票方法与 dexalign.py 相同\]

比例对了，几乎每一行都投到同一个偏移；比例不对时，票被漂移摊平，最高也只有几十票。所以不用先猜帧率：7 个比例各投一次票，峰最高的候选通常就是答案，再由后面的精修、打分和决策确认。

这些规则各自防什么：

- 投票：正确的比例下，大量行投到同一格，形成尖峰；比例不对时票会散开。所以比例和平移一次就能一起找到。
- 第二名差距：两段长度相近的剪辑差异会出现两个差不多高的解；节奏规律的字幕也可能错位一整句。差距不够就不改。一段明显更长时它挡不住，要靠三段检查。
- 至少 20 行和 45%：挑掉别的片子或别的版本的字幕。无关字幕的测试结果是匹配 14%、第二名也是 14%，被正确拒绝。
- 250 ms：更小的移动看不出来，改了反而可能把对的改坏。

合成测试：用 ref\_en.srt 的时间生成一份 25 帧版本的字幕（延后 2.5 秒、删掉九分之一的行、每行随机抖动 ±60 ms），对 23.976 帧的 MKV：比例 1.04271，偏移约 −2.6 秒，匹配 100%，第二名约 20% 到 35%（每次略有不同），应用。两小时、约 1500 行的对齐在 Linux x86 测试机上约 10 到 15 ms（release），Apple TV 上请自测。

## 第二版可以加的 NuvioTV 做法

NuvioTV 的对齐更细，适合在第一版稳定后逐项加入。它的源码是 GPL-3.0，请按下面的描述自己实现，不要复制代码。

1. 按“显示区间”对齐，而不只是开始时间。把每行的显示区间画成 500 ms（粗）和 100 ms（细）一格的位图，用 64 位整数的 AND 和 popcount 一次比较 64 格。得分 = (0.72 × 精确率 + 0.28 × 召回率) × (0.85 + 0.15 × 可见比例)，可见比例是字幕显示时间里落在参照时间范围内的比例。偏移每 500 ms 试一次，范围 ±180 秒；比例在 7 个固定值之外再加“参照跨度 / 字幕跨度”，限制在 0.94 到 1.06。
2. 密集对白的修正。对白一句接一句时，粗格得分在 −1.5 到 0 秒之间几乎一样高，最高点落到平台边上，把本来同步的字幕提前了 1.5 秒（真实报告，Ludwig 第 2 季第 4 集）。修法：在整个平台上（得分差 0.01 以内，最多 ±3 秒）用 100 ms 细搜，得分差 0.005 以内时用“开始时间对上的程度”裁决。
3. 纯偏移的三段验证。比例与 1 相差不超过 0.0015 时，把字幕分成前、中、后三段，每段在全局偏移 ±1 秒内找最好得分：要 ≥ 0.68，而且在 ±500 ms 内就能达到（差不超过 0.005）；全局得分 ≥ 0.78。三段都通过才按单一偏移应用，否则改走比例加动态规划。
4. 结构对齐（动态规划）。在 ±28 行的带宽里允许 1:1、1:2、2:1、1:3、3:1、2:2 的分组，处理拆行和合行。每组移到参照的开始时间、保留原时长；某组偏离前后各 3 组的中位数超过 250 ms 就用中位数代替。实际使用的门槛：覆盖率 ≥ 0.90、平均代价 ≤ 1.10、三段的覆盖率都至少 72%、简单分组占比 ≥ 0.55。
5. 多条参照。所有合格的内嵌字幕都试；时间几乎相同的轨（100 ms 位图的 Jaccard ≥ 0.90，例如简体和繁体中文）算同一个来源，不能互相投票。两条参照的结论相差超过 300 ms 时，取每组残差中位数更小的那条。
6. 在同语言的多份外挂字幕里找最合适的。只在播放器自动选字幕时这样做，可以换成匹配更好的那份；用户手选的只同步、不替换。只差一个固定偏移的文件只算一次；有 3 个独立来源都对不上的字幕直接放弃。
7. 不含文字的时间日志。把开始时间差和时长写成紧凑的文本，用户报告问题时可以离线重放成回归测试，又不涉及字幕内容。

建议顺序：三段一致性检查附带模块里已经有了（做法和 3 不同，见上文第 6 步）；先加 7（日志），再加 5，最后才考虑 1、2、4，它们等于换一套对齐引擎。

## 在 EplayerX 里应用

播放永远不等同步：先显示原字幕，后台算完再热替换；用户中途换了字幕就丢弃结果。

- 时机：外挂字幕开始显示后启动，自动选的和手选的都做。DexWorld 5.7.3 起对任何来源的外挂字幕都做，包括别的字幕插件和视频旁边的文件。
- 参照：有 FFmpeg 的引擎只用 FFmpeg 索引；字幕先到时等索引结果，索引里没有可用参照就保留原字幕，不回退到 HTTP Range。拿不到 AVFormatContext 的引擎才走 HTTP Range，读到的参照缓存 30 分钟（确定失败 10 分钟，临时错误 60 秒），换字幕不重复读。
- 最后一次选择为准：每次选择递增一个序号。结果回来时序号变了、当前字幕不是这份、或字幕被关掉，就不应用。
- 应用方式二选一：用改好时间的文件替换当前字幕（最通用，libass 也适用，模块直接给出改好的 Data）；或者不改文件，在取字幕的时钟上换算：字幕时间 = (播放时间 − 偏移) ÷ 比例。
- 手动延迟：应用后把用户手动调的字幕延迟清零，之后的手动微调仍然叠加（NuvioTV 的做法）。
- 副字幕：双字幕的每个槽位单独同步，共用同一份参照。
- 缓存结果：按“字幕内容哈希 + 视频的稳定 ID”缓存（Emby、Plex 的地址带临时 token，要用 itemId 之类做键），同一份字幕再次选择立即生效。模块的缓存只在内存里，要跨次播放保留由 App 自己存。
- 提示：用户手选的字幕，任何结果都提示；自动选的只在真正同步了才提示。同步过的字幕在列表里加“已自动同步”标记。
- 手动按钮：字幕菜单最上面放“同步当前字幕”（DexWorld 5.7.3），忽略上次“未同步”的记录，重新算一次（模块里是 syncNow）。
- 设置：总开关（默认开）、最低匹配率（默认 45%，可调 20% 到 95%）、成功提示、未同步原因提示。

提示文案（模块里的 AutoSyncMessages 会生成）：

| 结果 | 提示 |
| --- | --- |
| 已同步，帧率差 | 字幕已自动同步：已校正 23.976 与 25 帧率差（匹配 97%） |
| 已同步，偏移 | 字幕已自动同步：已提前 6.5 秒（匹配 100%） |
| 本来就同步 | 字幕本来就是同步的（匹配 98%） |
| 匹配不够 | 匹配只有 31%，低于要求的 45%，可能是其他版本的字幕，保留原字幕 |
| 剪辑版本不同 | 字幕和这个视频的剪辑版本不同（片中有一段对不上），保留原字幕 |
| 没有参照 | 视频里的内嵌字幕太少或不能作参照，保留原字幕 |

接入代码（完整示例见模块里的 AutoSyncCoordinator.swift，播放器只需实现 4 个方法）：

```swift
// 1. 打开视频（主线程）：参照来自 FFmpeg 索引；cacheKey 用服务器上的稳定 ID
coordinator.mediaDidOpen(MediaSource(url: streamURL, headers: playbackHeaders,
                                     cacheKey: "emby:\(itemId):\(mediaSourceId)",
                                     isLive: isLiveOrIPTV),
                         mode: .ffmpegIndex)

// 2. 解复用线程：avformat_find_stream_info 之后、开始播放之前
FFmpegSubtitleIndex.loadIndex(fmt)                          // 已经会 seek 到续播位置的话可以省略
let starts = FFmpegSubtitleIndex.reference(fmt)?.startsMs   // nil = 没有可用参照
Task { @MainActor in coordinator.setFFmpegReference(starts) }

// 3. 主线程：外挂字幕已经开始显示之后
coordinator.subtitleDidLoad(slot: 0, id: sub.id, data: sub.data, fileName: sub.fileName,
                            userInitiated: userPicked)

// 4. 字幕菜单里的“同步当前字幕”按钮
coordinator.syncNow(slot: 0, id: sub.id, data: sub.data, fileName: sub.fileName)

// 播放器实现 AutoSyncPlayer 协议：currentExternalSubtitleID(slot:)、
// replaceExternalSubtitle(slot:id:data:fileName:)、resetManualSubtitleDelay(slot:)、showToast(_:)
```

## 没有内嵌字幕时：音频对齐

只有视频里没有可用的内嵌字幕时，才需要听音频。NuvioTV 的 AudioSync 是目前最完整的参考，但工作量最大，建议放在最后做。

### NuvioTV AudioSync 的做法

1. 取音频：解复用时复制已选音轨的压缩包，另开一个解码器实例解码（系统允许多开时用系统解码器，否则用自带的 FFmpeg 软件解码），不抢播放器自己的解码器；这样能提前分析已缓冲的部分。不行时才在输出端截取正在播放的 PCM。
2. 统一格式：降混成单声道（多声道时中置声道权重 0.7），重采样到 16 kHz，每 512 个采样（32 ms）一帧。
3. 语音检测：Silero VAD v5（MIT 许可），用纯 Kotlin 重写，不依赖 ONNX Runtime；权重 487 KB（float16），每帧约 40 万次乘加。只保留每帧的语音概率，不先判断“有或没有”。
4. 对齐：把字幕“这一帧有没有字幕”画成同样 32 ms 一帧的曲线，和语音概率做带掩码的皮尔逊相关。用 FFT 一次算出 ±60 秒内所有偏移的相关值，峰值用抛物线插值细化，再减去 100 ms 的固定偏差（Silero 大约晚 45 ms 才反应，字幕又通常比说话稍早出现）。比例同样试 1 和几种帧率比。
5. 确认：至少 60 秒已知音频、20 行字幕、12 秒语音；峰值不在搜索边缘；峰值比 2.5 秒以外的最好值高 ≥ 0.12；音频分成前后两半各算一次，相差 ≤ 400 ms 才算锁定。早期估计要连续几次一致才应用，之后还能撤回。
6. 播放中跟踪：锁定后每 8 秒复查播放点前后 3 分钟；发现跳变并且下一次复查重复出现，就从跳变点起换新的偏移。所以音频路径能处理片中剪辑。
7. 提前取样：片长 20 分钟以上时，在片中挑 4 个对白密集、节奏不规则的 30 秒片段另开连接读取；目标 150 MB，默认只在不计流量的网络下，播放缓冲足够时才开新连接。
8. 可选语音识别：英语音频可以下载 74 MB 的 sherpa-onnx Zipformer 模型做词级对齐；非英语字幕先按时间“桥接”到一份英文字幕上。

### 在 Apple 平台上的对应做法

| 环节 | 建议 |
| --- | --- |
| 取音频 | EplayerX 自己解复用，把音频包复制一份给后台的 FFmpeg 软件解码器；Atmos 直通时也能这样做 |
| 重采样 | FFmpeg 的 swresample 或 AVAudioConverter，转成 16 kHz 单声道 |
| 语音检测 | 精确方案：Silero VAD v5（MIT），用 Accelerate 自己实现或转成 Core ML。快速原型：系统 SoundAnalysis 的内置分类器（iOS 和 tvOS 15 起）有 speech 类别，但窗口最短 0.5 秒，时间精度较粗 |
| 相关计算 | Accelerate 的 vDSP FFT |
| 语音识别（可选） | SpeechAnalyzer 和 SpeechTranscriber（iOS、tvOS、macOS 26 起）可以要求带 audioTimeRange 时间信息，是否可用取决于设备；旧的 SFSpeechRecognizer 不支持 tvOS。sherpa-onnx（Apache-2.0）有 iOS 版本，tvOS 需要自己验证 |

## 附带的 Swift 模块 SubtitleAutoSync

SubtitleAutoSync.zip 随本文一起发送。它是 DexWorld 引擎的 Swift 版，另加了三段一致性检查和接入用的协调器；没有第三方依赖，iOS 15、tvOS 15、macOS 12、visionOS 1 起可用，不含任何 NuvioTV 代码。

| 文件 | 作用 |
| --- | --- |
| SubtitleTiming.swift | 解析开始时间；按变换改写时间戳，保留原编码 |
| SubtitleAligner.swift | 对齐算法、安全决策、三段一致性检查 |
| MatroskaCues.swift | 只读 MKV 索引，选参照轨 |
| ByteRangeSource.swift | 本地文件和 HTTP Range 读取，带字节、请求数、时间预算 |
| AutoSyncEngine.swift | 引擎（actor）：缓存、并发去重、结果类型 |
| AutoSyncCoordinator.swift | 接到播放器上：参照模式、后台同步、最后一次选择为准、手动按钮、中文提示文案 |
| Integration/FFmpegSubtitleIndex.swift | 不在 Package 里：拷进 App 工程，把 import CFFmpeg 换成你的 FFmpeg 模块名 |

```swift
import SubtitleAutoSync

let engine = SubtitleAutoSyncEngine()
let outcome = await engine.synchronize(subtitle: srtData, fileName: "movie.ar.srt",
                                       media: MediaSource(url: streamURL, headers: playbackHeaders))
if case .synced(let s) = outcome {
    replaceCurrentSubtitle(with: s.data)   // 改好时间的字幕，原编码
    showToast(s.alignment.summaryZh)       // 例如“已校正 23.976 与 25 帧率差（匹配 97%）”
}
```

已经验证的内容（Linux，Swift 6.0.2）：

- 与 Python 原版对比 261 组对齐用例（偏移、帧率、混合、本来同步、无关字幕、半部字幕、带噪声、行数过少、重复行），比例、偏移、匹配行数、第二名、最大移动、决策全部一致。
- 三段一致性检查与它的 Python 参考实现逐项一致（210 组）：原版判为 sync 的 190 个正常用例一个都没有被误拒；在 30%、70%、80%、85% 处有剪辑差异的字幕全部拒绝；90% 以后（少数段不到一成）按多数段应用；参照缺一段、字幕多出一段歌词的情况照常应用。
- 7 个字幕文件乘 5 种变换，改写结果与原版逐字节一致：UTF-8 BOM 加 CRLF、Windows-1256、UTF-16 LE 和 BE、WebVTT 短时间戳、ASS 的 Comment 行和进位、三位数小时。
- MKV 读取：mkvmerge 和 FFmpeg 封装、多轨加 forced 和听障标记、SeekHead 里没有 Cues、没有字幕 Cue、MP4，结果和读取字节数、请求数都与原版相同。
- HTTP：Range、重定向、带 token 的请求头、服务器不支持 Range 时只读开头 512 KB、1 秒预算准时超时、任务取消 0.2 秒内结束。
- 协调器：FFmpeg 模式下字幕先到会等索引、不回退到 HTTP；没有参照时的提示；直播不做；最后一次选择为准；剪辑差异不应用；手动按钮的缓存语义。
- FFmpeg 6.1 索引读出的开始时间与真实字幕完全一致；播放 600 秒后才读的不完整索引（84 行，只覆盖前 10 分钟）被覆盖范围检查拒绝。
- Swift 6 语言模式（严格并发检查）编译无警告。

测试是在 Linux 上跑的，接入前请在 Xcode 里对 tvOS 和 iOS 再跑一遍：

```bash
# HTTP 相关测试需要本地 Range 服务器（参数：媒体目录、端口）
python3 Tests/Support/range_server.py Tests/SubtitleAutoSyncTests/Fixtures/media 8765 &

# macOS
RANGE_SERVER_URL=http://127.0.0.1:8765 swift test

# tvOS 模拟器（xcodebuild 会去掉 TEST_RUNNER_ 前缀再传给测试）
TEST_RUNNER_RANGE_SERVER_URL=http://127.0.0.1:8765 xcodebuild test -scheme SubtitleAutoSync \
  -destination 'platform=tvOS Simulator,name=Apple TV'
```

## 实施顺序

先做第一阶段就能覆盖带内嵌字幕的 MKV，这是收益最大的部分；音频后备放在最后。

1. 第一版：接入 SubtitleAutoSync（含三段一致性检查）；用 FFmpeg 索引做参照（MKV 开播前 seek 一次，MP4 打开即有）；后台同步、最后一次选择为准、热替换、提示文案。拿不到 AVFormatContext 的引擎才用 HTTP Range。
2. 补全：副字幕；“同步当前字幕”按钮（syncNow）；设置项；把结果缓存存到磁盘；不含文字的时间日志。
3. 加强：多条参照投票；之后视日志里被拒绝的情况，再考虑 NuvioTV 的区间位图和拆行合行。
4. 后备：没有内嵌字幕时的音频对齐。可以先用 SoundAnalysis 做原型看效果，再换成 Silero VAD。

## 参考与许可

NuvioTV Reshaped 使用 GPL-3.0：闭源并通过 App Store 发布的应用不能直接包含它的代码。本文只描述它的思路，附带模块的代码来自 DexWorld 自有实现。Silero VAD 是 MIT 许可，sherpa-onnx 是 Apache-2.0，语音识别模型文件另有许可，需要单独确认。

- [NuvioTV Reshaped 仓库](https://github.com/DavidVamaiotu/NuvioTV-Reshaped) 和 [发布页](https://github.com/DavidVamaiotu/NuvioTV-Reshaped/releases)（本文基于 1.1.0-beta.3-autosync.1，提交 b9408cd5）
- [EmbeddedSubtitleTimelineLoader.kt](https://github.com/DavidVamaiotu/NuvioTV-Reshaped/blob/b9408cd5729fd99e9afe56cc334973fe0725bc7d/app/src/main/java/com/nuvio/tv/ui/screens/player/autosync/EmbeddedSubtitleTimelineLoader.kt)：读 MKV Cues 和 MP4 样本表
- [AutoSyncTimelineRetime.kt](https://github.com/DavidVamaiotu/NuvioTV-Reshaped/blob/b9408cd5729fd99e9afe56cc334973fe0725bc7d/app/src/main/java/com/nuvio/tv/ui/screens/player/autosync/AutoSyncTimelineRetime.kt)：位图相关、三段验证、动态规划
- [AutomaticSubtitleSync.kt](https://github.com/DavidVamaiotu/NuvioTV-Reshaped/blob/b9408cd5729fd99e9afe56cc334973fe0725bc7d/app/src/main/java/com/nuvio/tv/ui/screens/player/autosync/AutomaticSubtitleSync.kt)：调度、选参照、候选字幕
- [audiosync 目录](https://github.com/DavidVamaiotu/NuvioTV-Reshaped/tree/b9408cd5729fd99e9afe56cc334973fe0725bc7d/app/src/main/java/com/nuvio/tv/ui/screens/player/audiosync)：音频对齐（SubtitleAudioAligner、AudioSyncTracker、SileroVad）
- DexWorld 字幕插件 service.subtitles.dexworld 5.7.3：autosync.py（流程）、dexcues.py（MKV 索引）、dexalign.py（对齐）、dexwatch.py（识别任意来源的外挂字幕）
- [FFmpeg matroskadec.c](https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/matroskadec.c)：Cues 在第一次 seek 时解析并加入各轨索引
- Apple 文档：[SNClassifierIdentifier](https://developer.apple.com/documentation/soundanalysis/snclassifieridentifier)、[SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)、[SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)、[SFSpeechRecognizer](https://developer.apple.com/documentation/speech/sfspeechrecognizer)
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
- [EplayerX 在 App Store](https://apps.apple.com/app/id6747369377)
