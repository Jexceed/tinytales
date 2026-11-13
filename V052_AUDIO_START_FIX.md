# 0.5.2：修复通话音频启动失败

用户在内置麦克风和扬声器上接通电话时遇到“通话音频没有启动”。系统日志记录了 VoiceProcessingIO 初始化错误 `-10875`；同次启动中，麦克风客户端为 44.1 kHz、播放端为 24 kHz，硬件为 48 kHz。

## 修改

- 以输出设备采样率建立统一的单声道语音处理输入和输出。本机实际为 48 kHz；保留回声消除。
- 模型的 24 kHz 音频先经过混音器转换到设备格式；麦克风输入独立转换为 24 kHz PCM16 后交给通话连接。
- 先确认本机音频可以启动，再创建云端会话。启动失败会清理资源，保留可重试状态，不占用本地云端调用名额。
- 挂断时使旧麦克风回调失效，阻止排队的音频进入下一次通话。
- 修复在麦克风授权等待期间挂断后，旧连接仍可能继续启动的竞态。

## 验证结果

- 原生测试：31/31 通过。
- 通话状态测试：12/12 通过，新增音频启动失败后重试、权限拒绝、权限等待时挂断、连接准备期间不上传音频四项。
- 安装后的 0.5.2 在本机内置设备上连续三轮真实硬件检查通过：每轮收到 23 个输入包，500 ms 静音播放完成，回声消除开启，停止后残留输入包为 0。
- 新构建的麦克风权限通过 macOS 正常授权窗口恢复，硬件测试报告中的权限状态为 authorized。
- 检测没有创建云端连接，没有保存录音。播放使用静音 PCM，验证了实际播放回调与时间推进；未评价听感和回声抑制效果，也未测试蓝牙、USB 或通话中切换设备。

证据：

- `artifacts/v052-audio-before-system.log`：修复前的系统格式与初始化错误。
- `artifacts/v052-audio-hardware.json`：安装包真实硬件三轮检查、输入输出格式、播放完成和停止状态。
- `artifacts/v052-installed-launch.json`：正常用户资料的启动和连接状态。

本机硬件检查命令（只统计音频帧，不上传或落盘）：

```sh
open -n "/Applications/小小故事屋.app" --args \
  --verify-audio /tmp/tinytales-audio-hardware.json
```

若 macOS 尚未授权，报告会返回权限状态且不会采集。需要经过系统授权窗口时显式加 `--request-microphone`。

音频引擎和设备格式的参考：[Apple 输出节点说明](https://developer.apple.com/documentation/avfaudio/avaudioengine/outputnode)、[Apple 主混音器说明](https://developer.apple.com/documentation/avfaudio/avaudioengine/mainmixernode)。
