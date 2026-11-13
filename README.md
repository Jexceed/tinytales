# 小小故事屋 · TinyTales

原生 macOS AI 故事伙伴，围绕彩虹独角兽莉莉持续交流。对话是主入口，故事、看图和词汇按需融入；默认使用用户已确认的 A「温柔老师」中文声音。

安装位置：`/Applications/小小故事屋.app`。Apple Silicon、macOS 14+；更新复用持久本机签名身份。用户运行 App 不需要网页或 Node 服务。

## 当前规格与开发方式

- [产品基线](specs/product.md)：角色、会话、入口、声音、内容、数据与授权等持续约束。
- [双工倾听与自然话轮](specs/001-natural-voice-turns/spec.md)：语音决策、实现边界及验收证据。
- [莉莉的桌面陪伴行为](specs/002-lily-pet-behaviors/spec.md)：空闲动作、摸摸回应、安静陪伴及验收证据。
- [莉莉的人物描述](specs/003-lily-persona/spec.md)：文字与电话共用的性情、表达和相处方式。
- [对话里的画图](specs/004-conversation-artwork/spec.md)：无需先保存故事，直接从对话或指定主体出图，含画质与耗时验证。
- [轻量 SDD 约定](AGENTS.md)：先更新相关规格，再实现和验证；一个功能维护一份当前 `spec.md`。

验收 ID 对应可运行的回归测试。构建和测试前检查规格链接及测试追踪，避免重要决定只存在于聊天记录或过期说明里。

## 怎么用

- 打字后发送，回复逐步出现。首次文字入口有少量备选话题，选择后填草稿；直接语音入口不显示选题。
- “新对话”先打开空白输入区，实际首条消息才创建会话。点击、切换、刷新不重排侧边栏，选中状态清晰。
- 点电话接通，之后直接说话。绿色表示接听，金色表示思考，粉色表示讲话；挂断立即停止采集和播放。
- 通话中边讲边听。“嗯、好的”等附和不抢话；重要的新问题、纠正、分享和停止请求及时接话，不需要先说特定口令或等整段结束。桌宠可见实时识别文字和独立收音反馈。
- 默认老师声音在本机生成，首次准备可能需要几秒，接听不会等模型加载。电话、自动朗读、试听共用声线；设置里保留「明亮老师」和兼容声音。
- 主窗口和桌宠共享会话，桌宠电话居中。`⌘N` 开启新对话，`⌘,` 打开设置，`⌘⇧L` 接通或挂断。
- 莉莉空闲时会看书、张望、伸懒腰、轻轻摇摆、玩星星，休息久了会眯一小会儿。靠近会招呼，鼠标在身上轻轻来回移动可以摸摸她；右键也能“摸摸莉莉”“一起玩星星”。单击聊天、双击打开对话、拖动摆放。
- 右键“安静陪伴”或关闭设置里的“空闲小动作”，可停止自发动作。通话和聊天状态优先；动作不会自动出声或发送消息，并遵循系统“减少动态效果”。
- 可以自然要求续讲、画刚才的故事、看图库或解释词汇，不需要切换产品模式。
- 说“你画图吧”或指定想看的主体，就会实际生成图片，不要求先讲完并保存故事。默认提供精细绘本画面，生成期间显示进度；主窗口直接显示成图，桌宠聊天里也能预览。

连接保存一次后复用，更新不重复索要密钥或麦克风授权。没有账号登录或日常算术验证。普通聊天不要求先找大人；云端调用只统计，没有每日 60 次上限。

## 构建与验证

开发机需要 Xcode 命令行工具、Node.js 24.13+、Python 3 和 `uv`。首次安装准备固定版本的中文声音运行库与模型，之后复用已有组件。

```sh
npm ci
npm run spec:check
npm run mac:test
npm run mac:test:phone
npm run mac:build
npm run mac:install
```

电话回归覆盖录放、识别、话轮、段落交接、停止、异步事件、静音与授权。数量和结果以命令输出及当前规格的验证记录为准。

真实接口检查复用已获授权的连接，使用虚构文本和固定合成音频，不打开物理麦克风：

```sh
build/native/PhoneTests --duplex-live
build/native/PhoneTests --voice-intent-live
build/native/PhoneTests --voice-eval interrupt --teacher
build/native/NativeTests --teacher-live
build/native/NativeTests --artwork-eval flare-high
build/native/PhoneTests --artwork-live
```

真实接口回放、物理设备和用户听感分别记录，不把合成测试当作全部现场条件的验收。若终端代理与 GUI 不同，应使用与 GUI 一致的网络设置。

原生窗口诊断：

```sh
open -n "/Applications/小小故事屋.app" --args \
  --verify-launch /tmp/tinytales-window-check.json \
  --capture /tmp/tinytales-main-window.png
```

诊断写 `/tmp`，再由开发工具归档到 `artifacts/`；App 不为诊断访问文稿。`--verify-launch` 使用独立临时数据，不调用真实接口。`--verify-teacher-voice /tmp/teacher.json` 验证本机生成组件；`--verify-audio /tmp/permission.json --permission-only` 只检查已有麦克风授权。

仓库不包含密钥、签名私钥、数据库、模型、安装包或 `artifacts/` 中的本机历史证据。干净克隆时，规格检查会提示本机证据未生成；其它文档链接和验收测试对应关系仍严格检查。默认独角兽资源随代码提供，早期从本机 Codex 导入的可选 Hoots 图片不随仓库分发；图集兼容测试使用程序生成的图片。

## 实现与数据

文字使用 OpenAI Responses，电话使用 OpenAI Realtime、语义 VAD 与转写；默认中文声音由本机 Qwen3-TTS 流式生成。连续 AVAudioEngine 负责录放及回声消除；声音检测与打断决策分开管理。

应用资源和模型在自身包或 `~/Library/Application Support/com.jexceed.tinytales/`。SQLite 保存设置、记忆、虚构故事摘要和统计；原始聊天在进程会话中，常规录音不落盘。凭据独立存为 0600 文件，不进入数据库、导出或安装包。

安装脚本复用 `build-signing` 中的身份，不重新生成证书或改回临时签名。内部更新沿用现有身份；当前没有外部分发公证。

## 历史记录

[产品探索](PRODUCT_PLAN.md) 中的远期设想、旧角色和旧入口不覆盖当前规格。各次交付记录继续保留：

- [中文老师声音](V011_MANDARIN_TEACHER_VOICE.md)、[语音轮次修复](V010_VOICE_TURNS.md)
- [会话排序](V094_STABLE_CONVERSATION_ORDER.md)、[会话生命周期](V093_CONVERSATION_LIFECYCLE.md)、[对话优先](V09_CONVERSATION_FIRST.md)
- [内容质量](V08_CONTENT_AND_QUALITY.md)、[语音与配图](V07_VOICE_AND_STORY_GROUNDING.md)、[权限修复](V055_PERMISSION_FIX.md)
- [桌宠与本机语音探索](DESKTOP_PET_AND_VOICE.md)、[原生初版](MACOS_COMPANION.md)、[早期网页实验](WEB_PROTOTYPE.md)
