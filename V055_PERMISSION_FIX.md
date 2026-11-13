# 0.5.5：消除日常文件授权弹窗

## 触发原因

截图中的“文稿”授权由自动朗读触发。旧版会查找并执行 `~/Documents/Projects/playground/local-tts/.venv/bin/python`，从这个开发目录读取模型、依赖和参考资源。进程检查确认了这个访问路径。应用原先每次构建使用 ad-hoc 签名，更新后的代码身份也会变化。

## 改动

- Python、依赖、F5 模型和声码器已迁入 `~/Library/Application Support/com.jexceed.tinytales/local-tts`。Python 基础运行时也一并复制，不再依赖 Codex 缓存中的解释器。原项目保持原状。
- 安装采用 APFS 文件克隆；后续更新检测到完整资源后直接复用。App 只查找自己目录中的安装标记，不扫描文稿或其他开发项目。
- 朗读进程固定工作目录，使用隔离的 Python 启动模式和最小环境变量，缓存写入故事屋目录。没有安装本地模型时使用系统声音。
- Codex 自定义桌宠在安装时导入，运行时只读取已导入的素材；默认独角兽直接读取 App 内置资源。
- 更新复用同一份本机签名证书。指定要求同时绑定应用标识和证书指纹，代码与资源完整性仍需验证；没有修改系统证书信任或隐私数据库。它是本机开发签名，不是 Developer ID 公证。
- 已授权的麦克风直接复用，已拒绝时不重复申请；并发首次请求合并成一个系统请求。
- 原生诊断报告放在 `/tmp`，需要归档时由开发工具复制到工作区，避免诊断本身触发文稿授权。

## 验证

- 原生回归 42/42，电话与权限状态回归 15/15。
- 对文稿、桌面、下载以及原 Python 缓存施加读写禁止；控制探针确认拒绝有效。安装后的 App 仍成功生成约 4.9 秒本地语音，完整链路约 10.1 秒。没有采集麦克风或调用云端。
- 两个不同的签名构建保持相同的证书绑定要求，篡改仍会被系统签名检查发现。
- 麦克风授权跨更新实机验证通过：更新前、修改构建内容并重新签名后、恢复正式版本后，系统均返回 authorized（3）。更新后的检查没有申请新权限，全程没有打开麦克风采集。测试结束后已恢复正式 Info.plist，并验证不存在临时探针字段。

证据：

- `artifacts/v055-isolated-tts.json`
- `artifacts/v055-packaged-runtime-access.json`
- `artifacts/v055-signature-stability.json`
- `artifacts/v055-install-check.json`
- `artifacts/v055-permission-reuse.json`

参考：[Apple 指定要求与签名身份](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)、[签名工具发布版本](https://github.com/indygreg/apple-platform-rs/releases/tag/apple-codesign/0.29.0)。

签名私钥、密码和 API 连接配置均位于当前用户的私有支持目录，不打包进 App。构建脚本不会静默更换证书或退回临时签名。
