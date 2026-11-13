# 桌宠、形象与本地语音：0.3 版

> 此文记录前一阶段。当前统一入口、彩虹独角兽品牌与连续语音电话见 [0.4 体验修正](V04_EXPERIENCE_FIXES.md)。

本轮根据用户的三个反馈，替换狐狸、补齐真正的桌宠，并调查和接入本机已有 TTS。

## 形象与桌宠

读取了本机 Codex 当前选择，结果是 **Hoots**。已将同一只戴眼镜的猫头鹰用于主界面、应用图标和桌宠；“大人请进 → 伙伴与声音”也可以选择本机 Codex 的“婉如”“婉如·花裙”等已有自定义人物。

桌宠使用独立的透明 NSPanel，浮在其他窗口上，跨桌面显示。点击打开轻聊，双击或展开按钮恢复完整故事屋，麦克风按钮直接进入同一段语音对话。支持拖动、记住位置、右键隐藏和菜单恢复；关闭主窗口仍可使用。桌宠与主窗口共享同一个 AppModel、上下文和记忆，不创建另一位伙伴或另一套聊天。

复用范围：

- 来自用户安装的 ChatGPT/Codex 包中的 Hoots 图集，来源与 SHA-256 记录在 `macos/Resources/Companions/provenance.json`。
- 图集布局 `1536 × 2288`、`192 × 208` 单元、9 种动画及 16 个顺时针观察方向，以及当前安装版的帧时长数据。
- 原生实现待机、目光跟随、拖动、挥手、跳跃、等待、工作、读故事、失败等状态。倾听、模型工作、准备声音、正在朗读分别映射到对应动作。
- 尊重 macOS“减少动态效果”；仅在拖动后记录桌宠的位置，不记录鼠标轨迹。

这是用户明确授权的本机原型复用；没有将这些素材声明为故事屋原创，也没有认定其可随商业软件再分发。自定义人物只从本机读取，不会上传给模型。当前没有修改 Codex 的宠物选择或设置。

浮动伙伴、轻聊和工作状态的设计参考 [OpenAI 官方 Pets 文档](https://learn.chatgpt.com/docs/pets)。TinyTales 的窗口、语音与 Agent 逻辑在本机独立实现，不依赖 Codex 正在运行。

## 本地 TTS 调查

| 方案 | 本机情况 | 本轮处理 |
| --- | --- | --- |
| F5-TTS | 已有完整约 1.35 GB 权重、Vocos、Python 环境；MPS 可用 | 已实际合成并接入 App |
| macOS 系统声音 | 可直接使用 | 优先选择已安装的较高质量中文声音，保留低延迟选项 |
| Edge TTS | 其他“小小”项目已有环境和生成素材 | 它需要联网，不算离线推理；本轮没有把它伪装成本地引擎 |
| Qwen3-TTS / MLX-Audio | 本机未发现安装或权重 | 查看了当前官方项目文档，作为后续对比候选，本轮未下载或声称实测 |

本机 F5 路径为 `~/Documents/Projects/playground/local-tts`，运行于 Apple Silicon 的 MPS；应用复用这份安装，不修改其依赖，也不重新下载模型。参考 [F5-TTS 官方项目](https://github.com/SWivid/F5-TTS)、[MLX-Audio 的 Qwen3-TTS 文档](https://github.com/Neywa-Labs/mlx-audio/blob/main/docs/models/tts/qwen3-tts.md)。

采用现有的合成音频作为中文参考，不使用家人录音。应用启动的语音子进程会移除 API key/token 环境变量，启用离线模式；文本通过 stdin 传入，WAV 通过 stdout 返回。实际朗读文本和输出音频不落盘，不经过网络语音服务。用于验证的虚构试听样例单独保存在 `artifacts/`。

声音设置有“自动优先本地神经语音”“本地 F5”“系统优质声音”三个选项，并提供试听和停止按钮。切换声音、外观或桌宠显示不会清掉当前对话。取消后迟到的语音数据不再播放，退出应用会关闭自有的 F5 子进程。

## 测试与实际等待

- **25 项原生检查通过**：在之前 18 项基础上增加旧设置迁移、外观/声音修改保留上下文、桌宠状态优先级、动画帧范围、减少动态效果、视线方向、实际图集解码、分句完整性。
- 实际原生窗口检查确认桌宠 `visible / floating / transparent / joinsAllSpaces` 均为 true；截图角落 alpha 为 0。记录见 [pet-launch.json](artifacts/pet-launch.json)。
- F5 Python 持续进程实测：加载 8.35 秒；两条约 5.63 秒的中文样例分别生成 9.58、6.59 秒。这是单样本，不是稳定性能统计。
- Swift 适配器端到端合成、WAV 解码及取消检查通过，一条 5.63 秒音频含加载等待约 10.84 秒；见 [native-local-voice.json](artifacts/native-local-voice.json)。

因此，本地 F5 是一个可试听的神经语音方案，**不代表已经解决低延迟**。当前听感是否优于系统声音仍请以实际试听判断；若等待优先，可选择系统优质声音。连续免按键语音和真实麦克风验收仍是后续工作。

产物：

- [桌宠动画预览](artifacts/desktop-pet-preview.gif)
- [真实桌宠窗口](artifacts/desktop-pet.png)
- [更换形象后的主窗口](artifacts/pet-main-window.png)
- [原生 F5 试听](artifacts/native-local-voice.wav)
- [本地语音基准](artifacts/local-tts-benchmark.json)

现有成人虚构内容研究限制保持不变；没有新增真实儿童个人数据测试。
