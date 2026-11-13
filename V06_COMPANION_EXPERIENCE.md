# 0.6：莉莉、动态通话和共同编故事

伙伴正式改名为“莉莉”，主窗口、桌宠、菜单、文字提示和模型人设一并更新。已有故事保留原内容；模型知道旧对话中的“栗栗”是伙伴旧称。

## 通话状态

倾听为绿色麦克风与输入波形，思考为金色旋转环，说话为粉色扬声器与扩散环，静音为灰色斜线麦克风。主窗口和桌宠共用状态；桌宠电话保持居中，红色小电话标记表示挂断。输入波形使用 PCM 音量，输出音量随播放缓冲完成更新。减少动态效果的系统设置仍受尊重。

## 声音

默认从 Marin 换成 Coral，并调整为柔和自然的中文表达。设置提供“轻柔 Coral、温暖 Cedar、明亮 Marin”，可以试听；通话中的声音修改在下一次接通生效。自动文字朗读也使用同一声音风格，仍可选择本机 F5 或系统声音。

文字亲和朗读使用联网的语音接口，会产生 API 用量。F5 的独立运行环境和模型继续保存在 Application Support，运行时不读取文稿。VoiceStyle 缺省自动迁移到 Coral，原有设置继续保留。

## 新故事

“新故事”和欢迎页“编个故事”先显示创作页。三个预设选题为小恐龙的旅行、去月亮做客、会发光的种子。选择只填入题目，孩子也可自行输入；按“开始编故事”才发送。返回聊天会恢复之前未发送的草稿。

确认后发送的是孩子选定或输入的主题，创作意图作为模型上下文提供，用户消息中不再自动塞入一整段指令。通话中也可以确认新的故事选题。

## 流式输出

文字使用真正的 Responses SSE，解析 `response.output_text.delta` 和 `response.completed`。只从不完整的 JSON 中提取 reply，不显示结构字段或残缺转义。完整句子通过检查后立即更新同一条回复，最终结果和工具写入仍需完整复核；取消或失败会清理临时回复。

通话字幕随 `response.output_audio_transcript.delta` 更新，最终转写合并到同一条消息；打断后停止旧消息的生成指示，并忽略迟到的旧转写。

## 验证

0.6.0 已安装。实际更新与恢复正式包后麦克风仍为 authorized，更新检查没有重新申请授权；现有 API 连接配置正常复用。

- 原生回归 47/47，通话回归 18/18。
- 真实文字流式测试收到 3 次通过检查的逐句前缀，首次约 7.4 秒，最终约 11.1 秒；并生成、解码了 10.35 秒 Coral 声音样例。
- 真实 Realtime 测试使用合成音频，验证新声音、多轮回复、自动 VAD 和流式字幕，没有打开物理麦克风。
- 欢迎页、选题页、对话和动态状态组件完成原生渲染检查，包含最小窗口。此轮未评价所有声音的主观听感，可在设置试听调整。

证据：`artifacts/v06-experience-live.json`、`artifacts/phone-live.json`、`artifacts/v06-story-choice.png`、`artifacts/v06-call-states.png`、`artifacts/v06-voice-coral.wav`。

参考：[OpenAI 流式回复](https://developers.openai.com/api/docs/guides/streaming-responses)、[实时声音选项](https://developers.openai.com/api/docs/guides/realtime-conversations#voice-options)、[文字转语音](https://developers.openai.com/api/docs/guides/text-to-speech)。
