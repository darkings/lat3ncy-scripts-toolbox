# 任务计划：切换播放器自动连接 AirPods 完善

## 2026-11-22 设置恢复配置文件

下一步补齐统一设置的恢复入口，替代手工改名 JSON。腾讯优先、Google 静默保底与四份个人配置保持，不自动合并草稿 PR #3。

1. [x] 原生窗口提供“预览 TOML 设置”及明确未保存提示；保存才恢复，重新加载/关闭可放弃，支持键盘访问及异步状态。
2. [x] 重置复用 OS 写锁、修订与原子替换，只清除偏好覆盖，不固定当前 TOML 值；预览后编辑保存差异，相关配置变化和并发保存拒绝覆盖。
3. [x] 新增 8 项行为回归，含真实 CLI、真实双进程重置/保存竞争、TOML 变化、写失败和隐私；18 项偏好测试通过。
4. [x] 完整源码构建、原生加载/预览/关闭两轮生命周期、含空格路径干净候选、正式部署及健康/配置保护检查。
5. 提交推送，核对精确 SHA 的 PR / push CI，更新草稿 PR；最终远端状态以 PR #3 记录为准。

真实偏好不做测试保存；原生探针仅预览不写入，不宣称物理点击通过。

191 项 Python、完整 AHK/WinUI 与最终干净候选三阶段均通过，五个修改源码的散列一致。正式部署源戳 bc93b2bf1a90eefc6549f25ed3184f0d3a1c84d3ab5c0e70a06403e957fb739c，常驻诊断 ok，四份个人配置与偏好均未改。证据 .tmp/settings-reset-final-full.log、.tmp/validation/20261122-settings-reset-final/、.tmp/settings-reset-deploy.json、.tmp/settings-reset-protection.json。Computer Use 可读“预览 TOML 设置”，点击先遇窗口边界变化，刷新重试为 coordinate input geometry is unavailable；截图与目标不符，未用它判定视觉通过。测试设置窗口已关闭。

## 2026-11-22 翻译私有任务文件回收

下一步处理长文检查点在强杀/断电后的遗留。原弱归属的平铺临时文件不做自动删除；新任务在 TEMP 下按规范仓库身份隔离目录，PID + 创建时间 + 随机编号标记、完整仓库归属元数据和独占 lease 共同保护。目录句柄不开放写/删除共享，打开 reparse point 本身并拒绝跟随。只删除已知文件，永不递归删除。

1. [x] 独占任务目录与常驻/按需扫描；清理前后核对 PID 创建时间，活动/未知归属、陌生内容和目录链接全部保留。每次最多 64 项、100ms 入口预算、每目录最多 32 项。
2. [x] 长文重试转移检查点 lease；新尝试使用不同输入/结果目录，旧回调迟到清理不碰新请求。取消和退出共用既有 Job 与清理预算。
3. [x] 完整 AHK/干净候选及真实联动，验证强杀后的清理、PID 复用、真实 junction、未知内容、并发重试和句柄回收。
4. 提交、正式重载及精确 SHA CI / PR 核对；保留四份个人配置，PR #3 不合并。

183 项 Python 不变；完整 AHK 与新增宿主强杀/目录链接/归属、重试清理交错验证均通过，含空格路径干净候选三阶段通过，源码散列一致。已正式重载，常驻诊断 ok；实际在生产受管目录写入固定输入/检查点并强制结束宿主，重载前遗留存在，重载后启动入口回收 1、延期 0，目录已删除。真实 OCR 在线联动 10 项通过，Google cached=0，受管文件、句柄和目录清理通过。

证据 .tmp/validation/20261122-translation-owned-files/、.tmp/integration/20261122-owned-files-restart/、.tmp/integration/20261122-translation-owned-files-live/。四份个人配置字节未变。持续外部锁、异常目录或预算耗尽只保留待后续扫描，不宣称立即清理；CLI 自选路径由调用者管理。首个异常分配若尚未发布归属元数据，尚未写入正文，仅可能留下空目录/不完整元数据。最后的提交推送与精确 SHA CI 统一记录于草稿 PR #3，不合并。

## 2026-11-22 Google 回退链路排查与逐引擎诊断

本节工作已完成：fc96fd8 的 PR / push CI 全部成功，新任务见上节。

用户要求继续下一步，优先解决上一批的未解释 Google 失败，不合并草稿 PR、不改四份个人配置。

1. [x] 核对仓库/PR/运行状态；固定 Google 请求采样短句和长段成功，另一次 12 秒参数请求仍 SSLEOFError（非超时）。只能判断存在间歇 TLS 中断，不能定位到代理或服务端。
2. [x] 新增显式固定文本 Google 探针及每个引擎的白名单摘要：调用/失败/缓存/跳过/耗时和 TLS 等固定分类；保留首选与回退顺序，不把腾讯缺密钥冒充 Google 失败原因。
3. [x] 完整 AHK/离线/干净候选、摘要归属与清理、真实服务采样及部署验证。
4. 提交推送、精确 SHA CI 与草稿 PR 更新；最终远端结果以 PR #3 最新 SHA 记录为准。

原成功结果协议保持；诊断使用有请求编号的独立原子文件，不含正文、密钥、异常原文或代理地址。普通 doctor 与分享包保留每个引擎的最近路线和独立失败历史，历史失败不改变当前环境健康。新增翻译 12、validation 4 项，总计 Python 183 项；Google 显式探针本次两项成功，仅代表当前采样。

干净候选发现旧设置锁的锁前初始化竞争。确定性真实子进程回归先复现 flush PermissionError，再删除锁前写入，直接锁空文件范围；修复后的全部模块测试与 40 轮真实双进程并发保存通过，保留 CAS 冲突语义，不修改实际偏好。

最终候选 .tmp/validation/20261122-engine-routes-final/ 三阶段均通过，183 项 Python、完整 AHK/WinUI 与源码散列核对完成。已正式重载（WinUI 源戳未变，C# 未改），常驻诊断 ok。真实固定图片在线联动 10 项通过，本次 engine=google_gtx、cached=0，摘要记录腾讯 credentials 跳过与 Google 一次成功，所有 Job/任务/trace 文件清理；.tmp/integration/20261122-engine-routes-live/ 保留证据。四份个人配置散列与起始相同。剩余最终提交推送和精确 SHA CI 核对，不自动合并。

## 2026-11-22 已批准的连续长任务

本批已完成并部署，26bd452 的 PR / push CI 全部成功；以下保留阶段记录，新任务进度见上节。

用户确认首批 1–7，阶段完成后自主继续，不要求逐次回复“下一步”。保持腾讯优先、Google 静默保底，保留四份个人配置，不自动合并草稿 PR #3。

1. [x] 发布候选说明、兼容性、验收矩阵与回滚材料。
2. [x] 统一 WinUI 设置入口：非敏感偏好与凭证分离，校验和原子保存，翻译方向/引擎/回退和朗读参数。
3. [x] 腾讯鉴权失败跨进程冷却，过期及凭证/配置变化后恢复试探。
4. [x] 长文分段、进度、取消、失败段重试与完整复制。
5. [x] 面板重试、目标语言切换、原文/译文朗读。
6. [x] 仅含白名单元数据的诊断包，耗时/缓存/回退统计。
7. 自动回归、干净候选构建及部署已完成，功能提交 c72452a；正在推送和最终 SHA CI / PR 核对。远端最终状态统一记录于 PR #3，避免为回写文档再制造另一个待核对 SHA。

当前阶段：代码已提交、完成最终干净验证和正式部署，收尾远端精确 SHA 验证。设置使用仓库身份隔离的本地非敏感偏好覆盖，不改含凭证 TOML；腾讯鉴权冷却 300 秒，凭证/腾讯配置变化及过期会试探恢复。长文显式开启，20000 字符 / 200 段 / 120 秒上限，失败段重试文件由面板上下文拥有。

已完成的阶段验证：65 项翻译测试（新增 7 冷却、10 长文）、36 项 TTS、36 项 validation（新增 7 设置、5 诊断包）；WinUI 源码构建自测及完整 AHK 核心断言通过。AHK 覆盖自有进程进度、部分失败、重试补全、归属拒绝与关闭清理。设置窗口的标准控件、异步 JSON 桥接、并发保存冲突、面板更多菜单及统计/脱敏包已实现，仍需新增动作和实际窗口生命周期联动检查。证据 .tmp/long-task-full-2.log、.tmp/long-task-doctor.json、.tmp/long-task-support.zip；诊断为旧部署常驻状态，不代表本批已部署。

剩余顺序：补足快捷切换/原文朗读/设置窗口生命周期与隐私测试；审查并修复输出分段/取消清理边界；完善发布、使用及回滚文档；最终完整/干净候选验证；正式部署，自动固定文本探针；阶段提交推送、最终 SHA CI 和 PR #3 更新。四份配置散列以长任务开始记录为准，必须再核对。

综合验证增量：Python 167 项通过（67 翻译、36 TTS、20 OCR、6 RGB、38 validation）。真实 2943 字符长文两段完成，实际末级 MyMemory，Google 本次未返回可用结果，不宣称本次 Google 成功。设置 UIA 全部字段及“已读取当前设置”可读，但点击仍 GetCursorPos 0x80070005，成功输入为零。

生命周期探针发现最后一个 XAML 设置窗口关闭会结束 HUD，已改显式关闭；新增不占用 HUD 的独立设置窗口循环探针，两次加载/关闭后继续调度已通过。Raycast 启动改为无 shell、无控制台直接创建进程，避免后台 ShellExecute 启动挂起。收尾修正的重新构建、干净候选及部署已通过；正式常驻两轮设置加载/关闭 HUD PID 均不变，诊断 ok；固定 OCR 在线联动 10 项通过。最终源戳 9deac2fd723112e590d44afe5d3c6dd62d388c9ea4c8a49ba7b8d0ac9691c5a7，四份个人配置仍为起始散列；剩余提交说明和远端核对，PR #3 保持草稿不合并。

首次远端 857b5a8 的 offline 暴露临时目录短路径与规范路径不一致（两个设置用例），本地普通 TEMP 未复现。偏好身份及配置比较统一 resolve，再新增路径别名回归；实际独立翻译/TTS 共读仍保留。修复后 Python 167 项、离线套件及最后的干净候选三阶段均通过；修正提交后按新 SHA 检查 CI，不把失败的旧 SHA 记为通过。

桌面输入此前因 GetCursorPos 0x80070005 失败；真实点击、视觉和新增音频验收保留待办，不冒充通过，也不阻塞其他任务。历史/收藏、离线翻译引擎不在本批范围。

## 2026-11-22 翻译任务取消与正常退出

- 复现翻译任务缺少退出回收：正常工作依赖定时器，退出观察器中任务/输入/结果仍在、句柄未关闭。补齐首次任务启动时的 OnExit 注册，并在 TextWorkflow 关闭时调用同一幂等 Shutdown。
- 翻译任务强制绑定 Windows Job；关闭时停结果定时器、拒绝新请求、撤销当前身份并取消全部在途任务。轮询与文件重试共用 1.5 秒预算，剩余 Job 最终 Dispose，仅删除该批已知输入/结果文件；不交付结果或发退出通知。
- 新增独立 AHK 子进程生命周期验收，固定 Python 后端持有输入句柄并启动休眠子进程，观察器在宿主真正结束前检查回收，避免外层 Job 自动清理掩盖缺口。退出、普通取消、重复关闭/迟到请求及预算耗尽强制回收均通过。
- Python 仍为 134 项；完整 AHK/WinUI 及含空格路径干净候选三阶段通过，最终源码哈希一致。已正式重载并验证 PING/归属与只读诊断，四份个人配置字节未变，无测试工作进程遗留。证据 .tmp/validation/20261122-translation-shutdown/。
- 不承诺断电、强杀宿主或持续外部文件锁下必然删除，未完成记 cleanup=incomplete。实机待办不变，PR #3 保持草稿；提交后核对最终 SHA 的远端 CI。

## 2026-11-22 回退与交付诊断

- 统一离线诊断新增翻译缺密钥/鉴权回退布尔开关的检查与展示，非法值仅报告固定字段名，不读取或验证密钥。
- 记录 lastFallbackEvent 的首选/实际引擎、固定原因和时间；它独立于 lastTerminalEvent / lastFailure，不将回退日志误当作交付成功或当前故障。成功终态包含实际引擎、缓存布尔和 panel/popup 位置。
- 识别 delivery-failed 与 start-failed 为内部失败，分别标记 delivery/launch 阶段；补齐 auth、I/O、输入等固定错误类别。普通 CLI 同样显示回退策略、历史路线和失败阶段，不输出正文/异常原文或发通知。
- 新增 5 项离线行为回归，Python 共 134 项；含空格路径干净候选的离线、助手构建、完整 AHK/WinUI 三阶段通过，源码哈希与候选一致。真实既有 Google 回退日志解析及当前只读诊断 ok；四份个人配置字节未变。证据 .tmp/validation/20261122-diagnostic-history/。
- 诊断按需读取，无须重载常驻；继续保留实机验收待办与草稿 PR #3。提交后核对最终 SHA 远端 CI。

## 2026-11-22 无需实机的复核与 Computer Use 重试

- 用户不在电脑旁，实机项目保留待办，PR #3 保持草稿。按用户要求实际使用 computer-use：WinUI 目标仍未暴露，启动重试超时；普通测试 GUI 可读控件树，但截图 CreateForMonitor 0x80070057，鼠标及激活均 GetCursorPos 0x80070005。未执行成功的点击/按键，无视觉、快捷键或听感通过声明；只清理自有测试窗口，不改桌面安全/权限设置。
- 自动复现并修复协议边界问题：ParseField 仅从 text 之前读取元数据，正文中的 request_id / preferred_engine 等不再冒充请求归属或回退信息，正文原样保留。
- 自动复现并修复结果回调异常：定时器捕获显示/通知边界异常，仅记固定 internal 分类；始终 finally 清理输入与结果文件，完成任务不会遗留或再次执行，不记录异常中的私有正文。
- 新增头部/正文边界、OCR 正文伪造归属拒绝和 UI 回调故障注入回归；129 项 Python 与完整 AHK/WinUI、含空格路径干净候选三阶段通过。已重载 AHK，HUD PING/归属健康；四份个人配置字节未变。证据 .tmp/validation/20261122-protocol-cleanup/、.tmp/computer-use-20261122/。
- 后续同步本轮修复与最终 SHA CI；输入桌面可操作后继续真实点击验收，不因此阻塞自动开发。

## 2026-11-21 腾讯首选与 Google 静默保底

- 用户确认腾讯云配置好密钥后优先使用，并明确密钥有问题时直接回退 Google，不用系统通知。当前个人配置仅按授权修改 engine=tencent、fallback_without_credentials=true、fallback_on_auth_error=true；其余设置和另外三份配置保持。
- 新增显式鉴权回退开关，默认 false 保留兼容；开启后缺密钥跳过腾讯，鉴权失败或网络问题尝试 Google，再沿用 MyMemory 末级回退。恢复腾讯后优先取腾讯结果，不被免费缓存遮住。
- 成功回退额外交付固定 preferred_engine / fallback_reason，text 仍在最后，缓存不保存旧回退原因。AHK 仅记固定枚举诊断，不发系统通知；所有引擎均失败时保留原有错误处理。
- 翻译 48 项回归通过，Python 总数 129；真实在线联动 10 项通过，确认 Google 缓存未命中并返回译文，日志 reason=credentials。鉴权失败路径用隔离桩验证，不发送伪造密钥。证据 .tmp/integration/20261121-google-fallback-silent/。
- 干净候选及全量回归通过，已通过正式入口重载 AHK，PING 与诊断正常；提交后核对最终 SHA 远端 CI。无需重新提供密钥来维持 Google 可用。

## 2026-11-21 连续联动验收

- 新增可显式运行的 text_workflow_smoke.py / text-workflow-pipeline.ahk：固定图片 → 实际 OCR Job → 生产 AHK 轮询 → 实际翻译进程 → WinUI 结果及朗读/停止/关闭回传。语音用计数器替代，不截图、不读取剪贴板或模拟按键。
- 默认 identity 模式的 10 项检查通过，覆盖取消实际 Job、OCR 输入失败、真实翻译配置失败保留原文、任务清理和句柄关闭；包含空格路径及 HUD 可执行文件归属校验。测试环境/缓存隔离，不启动或重载生产常驻，不修改四份个人配置。
- 在线测试如实失败：免费接口 TLS 握手超时，当前配置引擎在新请求进程中没有可用腾讯云密钥。默认 identity 只验证交付，不代替在线成功；原生框选、菜单和按钮点击/声音仍保留手工验收。
- 新增 6 项报告/隐私/输出隔离测试，Python 共 124 项；干净候选离线、助手构建、完整 WinUI/AHK 三阶段通过。提交后核对最终 SHA 远端 CI；下一步先恢复可用的在线翻译配置并复测，不继续堆叠新引擎。

## 2026-11-21 中英语言策略扩展

- 共用翻译后端新增顶层 source_language / target_language 和本次 CLI 覆盖；默认 auto / auto 保持原有中英自动互译，支持固定译中文/英文、显式方向及 zh-CN / zh-Hans 别名。
- 同语种返回 identity 原文，不读取凭证或缓存、不请求服务；数字/符号、字数上限、鉴权失败不回退及 text 最后交付约定保持。不同方向缓存隔离，等价方向复用旧缓存。
- 本轮范围限定中英，其他语言代码直接 config 错误，不扩充供应商和 OCR/TTS 语言承诺。诊断仅输出规范枚举，非法值只报告字段名；新增不含密钥的 config.example.toml，未覆盖任何个人配置。
- 翻译 43 项及诊断/验证 13 项测试通过，合计 Python 回归 118 项；真实文件入口的固定中文 identity 交付、换行/emoji 和输入文件回收通过。干净候选的离线、助手构建、完整 AHK/WinUI 三阶段已通过；提交后核对最终 SHA 的远端 CI。按需后端无需重载 AHK。

## 2026-11-21 文本工作流扩展

- 基础可靠性 PR #2 已合并 main（9d6ad01），当前分支 `codex/text-workflow-20261121`；四份个人配置仍保留，不提交或覆盖。
- 本轮实现：Caps+I / Raycast Screenshot Translate → 本地 RapidOCR → 直接调用翻译文本入口 → WinUI 面板手动朗读/停止译文。OCR 文本不写剪贴板，不模拟热键；截图使用 ms-screenclip URI。面板操作只传请求编号，AHK 保留文本与任务归属。
- 新增 `ocr_workflow.py` / `Run-OcrWorkflow.ps1`、AHK `TextWorkflow`；拆分纯 OCR 提取和 SpeakText/TranslateText 调用，复用 Job、超时与取消。面板关闭/新请求取消自己的工作，不能终止后来独立发起的朗读；翻译失败保留识别原文。
- OCR 15 个现有实测包版本全部固定为 requirements.in/lock，Python 3.14 + 哈希安装，`install-deps.py --check` 实际导入及版本检查返回 ready，未更换当前环境包或配置。可选 mobile 模型改显式参数且不改配置。诊断已加入 OCR 全锁版本比较。
- 106 项 Python、完整 AHK/WinUI 回归及含空格路径的干净候选三阶段通过；受管翻译后端、全新哈希锁安装及真实模型固定图片交付通过。真实 WinUI → UIAccess AHK 测试定位并修复消息权限阻断，仅对自有窗口放行一条无文本消息；朗读/停止/关闭回传通过。
- 正式部署已备份替换，最终回归、重载及只读诊断通过；本轮提交后核对远端 CI；四份配置保持原字节。Computer Use 未暴露 WinUI 工具窗口，按钮视觉/实际点击及 Caps+I 原生框选新流程仍待手工确认，不用基础功能的既有验收替代。
- 后续优先：完成新工作流的实际框选/播放验收，再考虑可配置输入与输出语言、离线翻译引擎适配及统一命令入口；历史记录/批处理应在明确存储和清理策略后单独设计。

## 2026-11-21 当前进展

- 用户已确认 OCR、翻译、朗读基础使用正常，不再等待基础功能/听感确认；专项异常、多屏、物理设备仍按矩阵保留。
- 下一步已实施统一离线诊断入口 `tools/diagnostics/doctor.py`：常驻身份、模块解释器/依赖、配置语法、日志位置与固定错误类别汇总。不自动修复，不读取剪贴板或调用服务。
- 发布说明、安装/重载与回滚流程和 PR #2 已准备。合并前复核修复主题通知与诊断探针交付两项，补齐主题/OCR 宿主测试；97 项 Python 及干净候选完整套件通过，进入按最终 SHA 核对 CI 和合并的流程。实际合并状态以 PR #2 为准；未发布 tag 或安装包。

## 目标
将 `Caps+D` 的 `G27Q2 ↔ AirPods 立体声` 一键切换从“能用”提升到“稳、快、可观测、可配置”：未建链时自动 `Enable A2DP + WSASetService` 拉起 AirPods 并仅在 `ACTIVE` 后 `SetDefault`，已连时秒切，失败有分级提示，支持 TTS 播前预热与可配置的首选设备。

## 当前阶段
阶段 6（免手动一键直连）

## 各阶段

### 阶段 1：需求与发现
- [x] 梳理现有链路 `ahk/features/audio-switcher.ahk -> tools/audio-switcher/AudioSwitcher.cs: TogglePreferredOutputs/ConnectPreferredHeadset`
- [x] 确认痛点：WASAPI 找不到未建链终点、Hands-Free 误判、非 ACTIVE 误设 0xE000020B、Raycast/TTS 输出乱码(BOM)
- [x] 将发现记录到 findings.md
- **状态：** complete

### 阶段 2：规划与结构
- [x] 冻结配置与协议：首选设备规则、超时/轮询、日志与通知分级
- [x] 确定不改动点：只标 A2DP Sink `0000110B/0000110D`（2026-11-02 修正：允许在“服务已启用但链路卡死”时做一次 Disable→Enable 重协商，见 findings）
- [x] 输出详细设计（时序图、状态机、配置表）到 findings.md
- **状态：** complete

### 阶段 3：实现
- [x] 3.1 加固 `AudioSwitcher.cs`：`PKEY_Device_DeviceDesc` 兜底、`AddRememberedHeadsetIds` 注册表找回、`IsPreferredHeadset` 排除 Hands-Free/iPhone、前置 `BluetoothGetDeviceInfo` 刷新（已存在，抽配置化）
- [x] 3.2 连接链路：`EnableAirPodsA2dpOnRadio` + `ConnectAirPodsAudioProfile(WSALookupServiceBegin->WSASetService)` 双路径 + 仅对 `ACTIVE` 设默认（已存在）
- [x] 3.3 交互与可观测：`audio-switcher.ahk` 700ms 防抖 + `ProcessNoWindow` 协议 `SWITCHED|ONLY_ONE|NO_DEVICE|ERROR` -> `Notify.Success/Info/Error`，`0xE000020B` 映射 `耳机未就绪`（已存在）
- [x] 3.4 TTS 联动（可选）：`speak-selected-text.ahk` 播前可选预热 `audio-switcher.exe --ensure-headset`，失败不阻塞朗读（已实现，`#Include run-nowindow`）
- [x] 3.5 编码与通知统一：`tools/raycast-scripts/*.ps1` 补 `UTF-8 BOM`，`_lib/notify.ps1` 统一 `OutputEncoding=UTF8`，`toast.ps1 duration=short~7s`（已完成）
- [x] 3.6 配置化：新增 `tools/audio-switcher/config.toml`（preferred/behavior/tts），`AudioSwitcher.cs` 动态加载关键词与 `connect_wait_ms/poll_ms`，新增 `--ensure-headset` 供 TTS 预热
- **状态：** complete

### 阶段 4：测试与验证
- [x] 单元/契约：`ahk/tests/run-tests.ahk:483` 11 项断言（A2DP/Hands-Free/ACTIVE/AddRemembered/WSASetService 等）全绿（`run-tests.ps1 PASS: core assertions`）
- [x] 独立加载：14 个 `*.ahk` + 14 个 `*.ps1` AST 解析全绿（含修复后 `speak-selected-text.ahk catch{}` 空块）
- [x] 手测：`audio-switcher.exe --list/--ensure-headset` 在无 AirPods 机器正确报 `耳机未就绪`，`--toggle` 逻辑保持
- [x] 回归：编译产物 `audio-switcher.exe` Framework 25KB 单文件可用，`config.toml` 热加载验证
- [x] 将测试结果记录到 progress.md
- **状态：** complete

### 阶段 5：交付
- [x] 配置与产物：`tools/audio-switcher/config.toml` 示例已创建，`audio-switcher.exe` 已用 Framework csc 重编译为 25KB 单文件
- [x] 编码校验：`raycast/*.ps1` 已补 `EF BB BF`，`speak-selected-text.ahk` 已 `PASS` 独立加载
- [x] 更新 `README.md`：补 `Caps+D` 默认快捷键、新增 `## Audio Switcher` 章节（含 config.toml 示例与 --ensure-headset）、TTS 增加耳机预热说明、仓库结构补 `audio-switcher/`
- [x] 全量回归：`run-tests.ps1` 14+14+core 全绿，`audio-switcher.exe --list/--ensure` 验证
- **状态：** complete

### 阶段 6：免手动一键直连（新增）
- [x] 6.1 强化建链：`TryFindAirPodsAddress` 与 `EnableAirPodsA2dpOnRadio` 先 `BluetoothGetDeviceInfo` 刷新再判 `IsPreferredHeadset`，空 `szName` 时用刷新后的名回退，避免离线时漏判
- [x] 6.2 加大容忍：`connect_wait_ms` 默认 8000→12000，`poll_ms` 保持 200，`config.toml` 可调；`fIssueInquiry=0` 保持不扫描以免卡顿
- [x] 6.3 语义对齐：`Caps+D` 的“切扬声器”即“想用耳机”，`Toggle` 在 `headset==null` 时必走 `ConnectPreferredHeadset+Wait`
- [x] 6.4 提权兜底（历史方案已收敛）：早期曾双试 PNP + 在 `ERROR|耳机未就绪` 时自动 `sudo --inline`。当前生产：`pnp_fallback=false`，`auto_elevate=false`；AHK 仅在配置显式打开且错误详情明确为权限问题时才 sudo。普通「耳机未就绪」不提权，提权重试与普通执行共用 18s 总预算
- **状态：** complete

## 关键问题
1. 是否需要让 TTS 默认自动预热 AirPods？默认建议 `opt-in` 配置项 `auto_switch_before_tts=false`
2. 首选设备是否可配置化（当前硬编码 `AirPods + G27Q2/NVIDIA`）？已抽到 `tools/audio-switcher/config.toml`
3. `ConnectWaitMs=8s` 是否需按蓝牙环境自适应？已改为 12s，可观测后调优

## 已做决策
| 决策 | 理由 |
|------|------|
| 永不 Disable 蓝牙服务，仅 Enable A2DP | 避免回切显示器时把 AirPods 踢掉，下次秒连 |
| 只对 ACTIVE 终点 SetDefault | 非 ACTIVE 会抛 0xE000020B，且不会建链，WSASetService 才是建链路径 |
| 用 DeviceDesc 兜底 + 注册表找回已记住 ID | WASAPI 未建链时 FriendlyName 为空，注册表仍有 AirPods 立体声节点 |
| 700ms 防抖 + Busy 互斥 + ProcessNoWindow | RunWait 期间防重入，700ms 内连按忽略，无黑窗 |
| 排程通知统一为系统 Toast short ~7s，BOM 统一 UTF-8 | 修复 Raycast 乱码，错误统一收敛到系统通知 |

## 遇到的错误
| 错误 | 尝试次数 | 解决方案 |
|------|---------|---------|
| Raycast 显示 `鈭?宸查噸杞?` 乱码 | 1 | `restart-autohotkey.ps1` 误用 `√` 且无 BOM，已改为 `✓` 并补 `EF BB BF` 到 6 个 raycast 脚本 |
| `screenshot-ocr` 报错走 Raycast 气泡而非系统 Toast | 1 | `trap` 与前置校验 `exit 1->0`，统一 `Show-SystemToast` 并补 `OCR 已取消` 分支 |
| WASAPI 找不到未建链 AirPods | 1 | 增加 `DeviceStateMaskAll+DeviceDesc+AddRememberedHeadsetIds` |

## 备注
- 阶段状态：pending → in_progress → complete，做重大决策前重读此文件
- 外部网页/搜索结果仅写入 findings.md，不写入本文件

## 2026-11-19：二次评审修复后的下一步计划

当前状态：16 项修复及正式回归完成；阶段 1/2 已实施，阶段 3 已补真实 OCR 与 TTS 在线恢复证据，阶段 4 已通过干净本地 clone 的构建/全量测试并进入模块提交与远端 CI 验证。最新进展见 2026-11-20 记录，旧日期中的“未提交/未安装”仅描述当时状态。物理设备、真实播放和本地低完整性语音仍有待办。

### 2026-11-20：真实集成、干净 clone 与 TTS 恢复

#### TTS 生命周期闭环

- AHK 持有必需的进程组任务、退出码和请求归属，拒绝无进程组启动；取消与正常退出回收父子进程，不再使用全局音频关闭指令。
- 固定字段终态协议 v1，不含文本；校验 request id/generation、字段和退出码。失败向用户反馈，主动取消安静，旧结果不覆盖新任务。
- 每片合成 30 秒、Python 总预算 1795 秒、AHK 硬上限 1800 秒；取消待完成合成并清理残片。文件清理按随机 request id 归属，PID 创建时间用于判断旧请求是否可回收。
- 验证已包含真实父子进程取消、句柄回收、禁止无 Job 启动、正常退出清理、PID 复用、过期/矛盾结果、下载及总预算超时。真实 MCI 静音播放与播放中进程取消通过；未朗读或更改音量/设备设置。
- 真实在线合成、自动回退、文件解码以及新终态协议通过；本地低完整性 SAPI 限制仍保留为 partial。证据在 `.tmp/integration/20261120-*lifecycle*` 及 `20261120-silent-playback/`。

下一步按顺序推进：先在真实编辑器验收连续朗读/打断及听感，再补翻译与 OCR 的真实剪贴板、多屏/DPI 矩阵；随后根据实测失败确定是否需要独立的普通完整性本地语音宿主。物理设备测试另安排可观察窗口，完成前不扩展队列、播放控制或更多语音引擎。

#### 2026-11-20：桌面验收增量

- 可见原生编辑控件中，真实常驻 Caps+S 连续三轮：前两轮播放中替换并退出，第三轮两段 MCI 播放成功；进程、请求文件清理及完整 ClipboardAll 恢复通过。
- 真实 HUD 协议复制 7397 UTF-16 代码单元的固定译文（emoji/竖线/换行/末尾标记）完全一致，空结果不覆盖，关闭后迟到结果不重开。复制按钮点击与翻译后端未据此标为通过。
- 修复实测发现的 UTF-8 BOM 输入问题，BOM/空白不再误报成功；新增行为回归。
- 当前单屏，HUD DPI=192；多屏、浏览器/终端选区、听感和物理设备继续待办。下一优先项为本地语音普通完整性宿主的可行性验证，保留独立依赖环境和在线回退，避免修改仓库 ACL。

#### 2026-11-20：普通完整性宿主与离线合成完成

- Windows 安装默认改为用户目录、按模块路径隔离的锁定环境；owner/ready 校验后由 AHK 优先选择，安装失败撤销 ready，旧 `.venv` 与全局解释器回退保留。未修改 ACL 或个人配置。
- `auto` 的本地音色路径新增 WinRT → SAPI WAV → Edge；SAPI stdin JSON/SSML 转义、同语言声音选择、独立缓存、子进程取消与残片清理落地。
- 新宿主实测 medium/RID 8192；中英文 WAV、参数/转义、禁用在线的实际流水线和 AHK 必需 Job 下的 pythonw 均成功，onlineCalls=0。真实 Edge 联合探针也通过；WinRT 依赖仍缺失，旧 Low 环境没有被改造。
- 下一步转回跨应用与硬件矩阵：浏览器选区/锚点、OCR 真实剪贴板交付优先；新本地音色听感、复制按钮点击、多屏和设备状态变化仍需各自实测，不继续增加播放队列或引擎。

#### 2026-11-20：OCR 真实交付与通知顺序修复

- 真实剪贴板固定图片→生产轮询→实际模型→生产复制已通过；发现“已复制”通知先触发，已改为复制完成后通知。复制失败返回错误而不误报成功，诊断文件写失败仍保留成功交付。
- 显式探针用父进程内存 ClipboardAll/序列号保护、必需 Job 和有界等待，空白与无新图取消不覆盖，正常结束恢复原内容。通知展示和截图框选不据此标为通过。
- 浏览器接口连续超时，随后 Computer Use 因无法确认当前 URL 停止；静态固定选区页面保留用于后续手动/受支持工具验证，浏览器选区及锚点仍待验收。
- 下一步先恢复受支持的浏览器验收入口，再执行跨应用选区/锚点；真实 Toast/Raycast 交付、听感、多屏和设备矩阵保持独立待办。

#### 2026-11-20：OCR 通知宿主修复

- 真实对照确认旧 Low 宿主在 CreateToastNotifier 失败（0x80073D54），同版本基础 Medium 宿主能够提交并读回测试通知。RapidOCR 入口改用同版基础解释器、-I -S 与原依赖目录，验证版本/基础目录；无包安装、ACL/注册/个人配置变更，声明不可用时保留旧入口。
- 同步/异步通知、Unicode 参数、子进程异常/10 秒超时清理通过；无窗口 Medium 宿主的真实模型和抑制横幅的系统 Toast 提交/历史记录通过，横幅展示仍待验收。
- 新宿主剪贴板复测遇到原始快照/原生 OpenClipboard 拒绝访问，保护入口在写入前退出，保持待办。浏览器接口仍不可用，Chromium 设备未连接；待环境恢复后执行这些实测，不靠增加离线断言替代。

- 真实 OCR：专用 3.14 环境的 RapidOCR 成功识别合成文字图片，空白图片无文字；仅捕获剪贴板交付，不修改用户实际剪贴板。
- 真实 TTS：7.2.8 返回 403；模块独立环境升级并锁定 7.3.1 与全部传递依赖/SHA-256 后，在线合成与中英文 auto 恢复都生成可解码 MP3。用户明确允许本地失败后在线回退；显式 winrt 保持离线。
- 本地原因：全局 Python 令牌 medium/RID 8192，SAPI 文件合成通过；venv Python 令牌 low/RID 4096，SAPI 枚举成功但合成失败、TEMP 写入拒绝。两者均非 AppContainer/restricted token。当前 Python 3.15 无旧 winsdk；没有提权、调整 ACL 或宣称本地合成已恢复。
- 标签来源已读回：仓库 Low 标签以 OI/CI 继承，venv 两个解释器均继承 Low，而全局解释器无此标签；与实际进程 RID 对照一致。采用已授权的在线恢复及可写缓存，保持当前完整性边界。
- 修复低完整性缓存写入：先探测 AppData 缓存可写性，不可写时使用被忽略且有 LRU 上限的模块 .cache。AHK 优先选模块 venv，安装/检查均以锁文件为准，避免全局旧包误判。
- 修复错误语义：MCI/SAPI 失败返回 false，所有后备路径失败时 TTS 非零退出；不会再将无声失败记为成功。
- 干净 clone 验证：候选源码、HEAD 配置、不含旧 out/obj/venv，在带空格的新本地 clone 中完成离线、C# 助手编译、WinUI 源码构建及 AHK 全量回归。修复了测试错误依赖生产 out 的假设；PS5.1 子进程隔离 PS7 模块路径。
- 新增可复用 validation 入口、进程上下文诊断及独立 WinUI 构建入口；CI 增加独立 WinUI job（.NET 10.0.404）。本机已通过，后续按模块提交并获取远端 CI 结果。
- 真实 SAPI、播放/取消、UIA/多屏/剪贴板及物理设备矩阵仍有待办；真实 smoke 总体保留 partial，不把在线恢复等同于本地或播放验收。
- 证据：`.tmp/integration/20261120-*`、`.tmp/validation/20261120-release-candidate/`。个人 config.toml 改动保留，不加入模块提交。

### 本轮执行结果（2026-11-19 15:55，Asia/Shanghai）

- **阶段 1 完成**：心跳身份含绝对脚本/仓库、PID 创建 FILETIME、启动时源码/配置指纹。普通权限看护返回 running / heartbeat；隔离覆盖旧心跳、PID 复用、其他 checkout、损坏 JSON、进程缺失、旧源码。受控正常停止后，看门狗确认 not-running 并恢复新 PID；连续两次健康巡检无日志增长。未强杀提权实例。
- **阶段 2 完成当前发布范围**：正式 `tools/startup/Deploy-Toolbox.ps1` 部署已验证 HUD 产物、重载 AHK，支持预览、幂等、强制重载、manifest/备份和显式回滚。健康失败桩验证恢复旧字节并重新启动；维护互斥体跨 checkout 隔离、崩溃自动释放。AHK/PowerPolicy/Python 源码或个人配置不属于产物回滚范围。
- **阶段 2 引擎完成**：PowerPolicy 安装及现有任务改用系统 Windows PowerShell 5.1，已从该路径实际启动。普通权限不能改 Highest 任务的 action，迁移由已有提权常驻在启动时校验并更新本仓库 action；保留原 principal、triggers、settings。正式 `Restart-PowerPolicy.ps1` 校验身份、优雅退出、原任务重启、当前指纹与原生注册。
- **阶段 3 已准备，设备实测待办**：矩阵在 `tools/startup/README.md`，明确离线通过与真机未测。合盖、睡眠、蓝牙/HID 断连、真实 OCR/TTS/剪贴板及跨 DPI 场景不填为已验收。
- **阶段 4 部分完成**：保存本轮前 402 文件基线；按模块记录提交边界；新增 Windows 离线 runner 和 Actions workflow，已本机执行。尚未提交推送，远端 CI 未运行，未自动暂存个人配置。
- **阶段 5 待办**：协议契约、依赖固定和性能优化需结合设备失败项逐模块确定，未做大规模升级或重构。
- 最新运行实例：AHK 16800、HUD 49024、光标助手 33392；PowerPolicy 21376（系统 PowerShell），四路原生注册错误 0、Caffeine=true、requestBalance=1。瞬时 PID 仅作本次证据。
- 正式全量套件、55 项 Python 行为测试及新增发布/心跳测试通过；证据与本轮增量在 `.tmp/next-step-20261119/`。操作说明及真机矩阵见 `tools/startup/README.md`。

### 继续执行记录（2026-11-19 16:09，Asia/Shanghai）

- 发布加固：隔离复现了准备备份后目标文件被更新仍遭覆盖的问题。新增停进程前完整预检、停止后和逐文件写入前再次核对；候选/目标变化和新文件碰撞均拒绝覆盖。
- 自动失败恢复仅处理本次尝试写入的文件。若文件已被其他写入或删除，先检查所有待恢复项并报告冲突，保留现场与备份；不覆盖后续变更。显式用户回滚仍按所选备份恢复。manifest 写入改为原子替换。
- 长期测试增加：停进程前失败不停止实例、停止窗口出现变更、部分写入后的候选变化、新文件碰撞、自动回滚冲突；均通过。此处为步骤间变更检测，不宣称对任意外部写入实现跨进程原子 CAS。
- 阶段 4 补来源追溯：新增 `tools/build/Build-ManagedHelpers.ps1` 与验证入口，实际隔离编译锚点/音频助手成功，记录源码、产物、编译器、引用程序集及参数哈希。来源漂移/产物漂移/组件及路径故障桩纳入全量与离线套件；Windows CI 增加真实编译步骤。
- 候选构建未替换生产助手，既有生产 exe 不因新 manifest 自动获得来源证明。后续发布新助手时须将新产物及其 manifest 一起核对。
- 阶段 3 增加真实只读音频证据：生产/候选 --get 与 --list 一致，1 个活动设备，默认 Realtek 扬声器查询前后不变。未进行 AirPods 建链/切换/恢复，也未执行睡眠/合盖/HID 断连。
- 验证：64 个 PowerShell 文件 AST/BOM、55 个 Python 行为测试、全量 AHK/WinUI/锚点套件、发布/来源新增故障测试通过。证据在 `.tmp/continue-20261119/`；未 stage/commit/push，远端 CI 待运行。

### 首次部署时的基线（历史）

- AHK PID 28080，实例互斥体存在；HUD PID 5168，生产 PING 成功。
- 光标助手 PID 36004，仅一个，OwnerPid=28080。
- PowerPolicy PID 44404，新心跳有效，四路注册无错误；Caffeine=true，requestBalance=1。
- WinUI 生产 DLL SHA-256：`76DB512AD768DA156B349886C3F5A9649AAF06CA007CA5FEF15EBA3E38AD40E0`；与已测试的 test-out 相同。
- 差异产物已备份；原始部署/验证 JSON 在 `.tmp/deploy-review-20261119/`。RGB Ambient 当时未运行。

### 阶段 1：最高优先级，修复跨权限的看护识别

**依据**：业务进程正常，但 `startup.log` 在 15:16、15:21、15:26 持续记录 PowerShell command line unreadable；直接调用 Get-ToolboxPowerPolicySnapshot 也返回 query-failed。不能用“让看护全部提权”替代身份契约。

- 给 PowerPolicy 启动心跳补充实际脚本绝对路径/仓库身份、PID 创建时间和启动时源码指纹。
- 看护优先使用新鲜心跳 + 活进程创建时间 + 对应仓库身份确认实例，再按需要查询 CIM。PID 复用、其他 checkout、旧心跳、损坏 JSON 均不能算健康。
- 将“运行健康”“运行旧代码”“确定不存在”“无法判断”分开；未知状态不重复拉起，旧代码不冒充崩溃。
- **验收**：普通权限下识别当前提权实例为 running，正常轮询不再写错误日志；故障桩覆盖 stale / reused PID / foreign checkout / missing process。真实崩溃恢复需在受控重启窗口验证。

### 阶段 2：P1 固化发布、回滚和环境定位

**依据**：本次需要临时脚本串联 source-stamp、三文件差异备份、AHK 停止、HUD QUIT、替换和心跳验证。PowerPolicy 任务绑定的 pwsh.exe 位于具体版本的 Codex runtime 安装目录；当前路径可用，但不由本仓库控制生命周期。

- 将本次经过验证的流程整理成正式部署入口：源码/产物一致性检查 → 备份与 manifest → 按仓库精确停止 → 替换 → 重载 → PING/心跳 → 失败回滚。
- manifest 记录组件源码/产物哈希、使用的引擎、部署时间和回滚位置；不要将含个人配置或敏感内容的文件混入发布包。
- 任务启动引擎改用用户明确安装、可稳定解析的 PowerShell，或提供统一的启动时解析器；移除对 Codex 版本目录的绑定。
- **验收**：连续部署同一版本幂等；中途故障能恢复旧产物与常驻服务；其他 checkout 不受影响；引擎路径失效时有明确诊断且可修复任务。

### 阶段 3：P1 补真实集成与设备回归

**依据**：离线桩已验证失败路径，不能代替 Windows UIA、蓝牙、电源和真实剪贴板行为。

- 通知/翻译：Chromium、传统编辑控件、终端；多显示器/不同 DPI；5000+ 长译文完整复制；面板关闭后迟到结果不重开。
- OCR/TTS：OCR 识别成功/空结果/取消/模型失败，剪贴板交付与通知顺序；TTS 连续打断、下载失败和本地兜底。
- 电源：Caffeine 开/关、到期、停止、解锁/恢复后的状态；真实合盖/睡眠只在用户可观察的设备测试窗口进行。
- RGB/音频：SDK/设备断连、重连、退出；AirPods 未取出、立体声恢复和超时。
- **验收**：形成环境、步骤、预期、实际结果与证据的矩阵；先闭合失败项，再继续增加功能。

### 阶段 4：P1 整理可追溯的源码与测试基线

**依据**：本次检查时工作区有 85 个 modified/untracked 条目，混合了前序功能、两轮修复、二进制和文档，尚未形成清晰提交边界。

- 按通知/翻译、电源/启动、Python/RGB、测试/文档拆分审阅和提交；不覆盖原有修改，不自动提交个人配置。
- 为 source-built 二进制记录编译入口与对应源版本，保留评审发现 → 修复 → 行为测试的映射。
- 将离线测试放入 Windows 自动化检查，真实硬件测试维持独立人工入口；逐步用行为测试替换只搜索源码字符串的断言。
- **验收**：新 checkout 可复现构建和测试；提交中不含运行日志/恢复档/本机密钥；测试明确区分跳过、离线通过与设备实测。

### 阶段 5：P2 小步收口配置、协议和维护成本

- 先列出跨语言协议/超时预算/配置字段的唯一契约，再逐个模块统一，避免一次重写整个工具箱。
- 固定 Python 依赖与随仓库版本，保留 OpenRGB 本地补丁及回归检查，明确第三方与自有代码边界。
- 依据测量再优化翻译日志全量读取/重写等性能项；不把已记录的设计决策重新当作缺陷改动。
- **验收**：契约变更能被测试捕获，依赖升级可重复且本地补丁不会丢失，性能改动有前后数据。

建议执行顺序：保存当前验证基线 → 阶段 1 看护识别 → 阶段 2 发布流程 → 阶段 3 真机矩阵；阶段 4 的提交整理同步推进，阶段 5 按收益逐项开展。当前不建议先做大规模目录重构或增加新功能。
