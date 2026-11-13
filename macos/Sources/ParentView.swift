import SwiftUI

struct ParentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var changingKey = false
    @State private var confirmClear = false
    init(model:AppModel,initialTab:Int=0) {self.model=model;_tab=State(initialValue:initialTab)}
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 7) { Text("故事屋设置").font(.system(size: 22, weight: .medium)); EmptyView() }; Spacer(); Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13)).padding(7) }.buttonStyle(.plain) }
            Picker("家长管理", selection: $tab) { Text("记忆小花园").tag(0); Text("陪伴与声音").tag(1); Text("连接与数据").tag(2) }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.error.isEmpty { Text(model.error).font(.system(size: 15)).foregroundStyle(.orange) }
                    if tab == 0 { memoryTab }
                    if tab == 1 { settingsTab }
                    if tab == 2 { dataTab }
                }.padding(.vertical, 6)
            }
        }.padding(28).frame(width: 780, height: 650).background(Color.paper).foregroundStyle(Color.ink)
        .onAppear { if !model.cloudAvailable { tab = 2 } }
        .alert("清空本机记忆与故事？", isPresented: $confirmClear) { Button("先留着", role: .cancel) {}; Button("确认清空", role: .destructive) { model.clearData() } } message: { Text("这会结束当前对话。今日调用计数和连接配置会保留。") }
    }
    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: 17) {
            note("模型提出的候选，经你确认后才会在以后聊天中使用。兴趣与词汇可以留下，身份信息和能力标签不保存。", icon: "leaf")
            section("等待确认", count: model.memories.filter { $0.status == "pending" }.count)
            ForEach(model.memories.filter { $0.status == "pending" }) { memory in NativeMemoryRow(memory: memory, onSave: model.updateMemory, onDelete: { model.removeMemory(memory) }) }
            if !model.memories.contains(where: { $0.status == "pending" }) { empty("还没有候选记忆。莉莉会在合适的时候留下一个小线索。") }
            section("已经记住", count: model.memories.filter { $0.status == "approved" }.count)
            ForEach(model.memories.filter { $0.status == "approved" }) { memory in NativeMemoryRow(memory: memory, onSave: model.updateMemory, onDelete: { model.removeMemory(memory) }) }
            if !model.memories.contains(where: { $0.status == "approved" }) { empty("这里还是一片空白，慢慢了解就好。") }
            Text("确认、修改或删除记忆后会开启新对话，防止旧上下文继续引用已经纠正的信息。").font(.system(size: 14)).lineSpacing(5).foregroundStyle(Color.quiet)
        }
    }
    private var settingsTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            row("莉莉的声音", detail: "可以试听；通话中的更换在下次接通时生效。") {
                Picker("声音", selection: Binding(get: { model.settings.voiceStyle }, set: { var s = model.settings; s.voiceStyle = $0;s.voiceBackend="auto"; model.updateSettings(s) })) {
                    ForEach(VoiceStyle.ids,id:\.self) {Text(VoiceStyle.title($0)).tag($0)}
                }.labelsHidden().frame(width: 180)
            }
            row("朗读方式", detail: "老师声音在本机生成，首次准备需要几秒；电话交流仍需联网。") { Picker("声音引擎", selection: Binding(get: { model.settings.voiceBackend }, set: { var s = model.settings; s.voiceBackend = $0; model.updateSettings(s) })) { Text("跟随莉莉的声音").tag("auto"); Text("旧版本机声音").tag("local-f5"); Text("系统声音 · 低延迟").tag("system") }.labelsHidden().frame(width: 200) }
            VoiceStatusView(voice: model.voice,inCall:model.inCall)
            row("显示桌宠", detail: "") { Toggle("显示桌宠", isOn: Binding(get: { model.settings.desktopPetEnabled }, set: { var s = model.settings; s.desktopPetEnabled = $0; model.updateSettings(s) })).labelsHidden().toggleStyle(.switch) }
            row("桌宠形象", detail: "") { Picker("伙伴形象", selection: Binding(get: { model.settings.petID }, set: { var s = model.settings; s.petID = $0; model.updateSettings(s) })) { ForEach(PetCatalog.choices()) { pet in Text(pet.name).tag(pet.id) } }.labelsHidden().frame(width: 185) }
            row("靠近时回应", detail: "") { Toggle("目光跟随鼠标", isOn: Binding(get: { model.settings.petFollowsPointer }, set: { var s = model.settings; s.petFollowsPointer = $0; model.updateSettings(s) })).labelsHidden().toggleStyle(.switch) }
            row("空闲小动作", detail: "看书、伸懒腰、玩星星；关闭后安静陪伴。") { Toggle("空闲小动作", isOn: Binding(get: { model.settings.petAmbientEnabled }, set: { var s = model.settings; s.petAmbientEnabled = $0; model.updateSettings(s) })).labelsHidden().toggleStyle(.switch) }
            row("每段对话", detail: "时间设置对新对话生效。") { Picker("时长", selection: Binding(get: { model.settings.sessionMinutes }, set: { var s = model.settings; s.sessionMinutes = $0; model.updateSettings(s) })) { Text("5 分钟").tag(5); Text("10 分钟").tag(10); Text("15 分钟").tag(15) }.labelsHidden().frame(width: 135) }
            row("一点点英语", detail: "自然带入相关的词，不考试、不用汉字谐音教发音。") { Toggle("英语", isOn: Binding(get: { model.settings.english }, set: { var s = model.settings; s.english = $0; model.updateSettings(s) })).labelsHidden().toggleStyle(.switch) }
            row("自动朗读", detail: "") { Toggle("自动朗读", isOn: Binding(get: { model.settings.speaks }, set: { var s = model.settings; s.speaks = $0; model.updateSettings(s) })).labelsHidden().toggleStyle(.switch) }
            row("记忆小花园", detail: "关闭后不再读取确认记忆或新增候选。") { Toggle("记忆", isOn: Binding(get: { model.settings.memoryEnabled }, set: { var s = model.settings; s.memoryEnabled = $0; model.updateSettings(s) })).labelsHidden().toggleStyle(.switch) }
            HStack { Text("今日云端调用").font(.system(size: 16)); Spacer(); Text("\(model.operations) 次").font(.system(size: 21, design: .rounded)).foregroundStyle(Color.sage) }
        }
    }
    private var dataTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            note("当前仅供成人用虚构内容研究。真实儿童个人数据的使用条件和项目零数据保留状态尚未核实。", icon: "hand.raised")
            HStack {
                Text(model.cloudAvailable ? "已连接莉莉" : "连接莉莉").font(.system(size: 23, weight: .bold, design: .rounded))
                Spacer()
                if model.cloudAvailable { Button(changingKey ? "收起" : "更换连接") { changingKey.toggle() }.font(.system(size: 16)) }
            }
            Text(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil ? "当前使用临时测试配置。" : model.cloudAvailable ? "这台 Mac 会记住连接，重新打开就能聊。" : "保存一次连接，以后打开就能聊。").font(.system(size: 16)).foregroundStyle(Color.quiet)
            if !model.cloudAvailable || changingKey {
                HStack { SecureField("OpenAI 密钥", text: $key).textFieldStyle(.roundedBorder); Button("保存连接") { do { try model.saveKey(key); key = ""; changingKey = false; keyMessage = "已保存，这台 Mac 会自动连接。" } catch { keyMessage = error.localizedDescription } }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.font(.system(size: 16))
                if !model.cloudAvailable { Button("恢复已保存的连接") { model.reconnectSavedKey() }.font(.system(size: 16)) }
            }
            if !keyMessage.isEmpty { Text(keyMessage).font(.system(size: 14)).foregroundStyle(Color.quiet) }
            if changingKey { Button("删除已保存的连接", role: .destructive) { do { try model.forgetKey(); keyMessage = "已删除本机连接。" } catch { keyMessage = error.localizedDescription } }.font(.system(size: 16)) }
            Divider().padding(.vertical, 4)
            Text("本机数据").font(.system(size: 23, weight: .bold, design: .rounded))
            Text("记忆、虚构故事摘要和设置保存在应用支持目录。原始聊天只在当前进程的有时限会话中，录音只在内存中处理，不写入录音文件。").font(.system(size: 15)).lineSpacing(6).foregroundStyle(Color.quiet)
            HStack { Button("导出本机数据…") { model.exportData() }; Button("清空记忆与故事…", role: .destructive) { confirmClear = true } }
            Text("本机删除不等于删除云端留存。配置保存在本机，普通对话不需要重复确认。").font(.system(size: 14)).lineSpacing(5).foregroundStyle(Color.quiet)
        }
    }
    private func note(_ text: String, icon: String) -> some View { HStack(alignment: .top, spacing: 10) { Image(systemName: icon).foregroundStyle(Color.sage); Text(text).font(.system(size: 15)).lineSpacing(6).foregroundStyle(Color.quiet) }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Color.softSage.opacity(0.55), in: RoundedRectangle(cornerRadius: 9)) }
    private func section(_ title: String, count: Int) -> some View { HStack { Text(title).font(.system(size: 16, weight: .medium)); Text("\(count)").font(.system(size: 14)).foregroundStyle(Color.quiet) } }
    private func empty(_ text: String) -> some View { Text(text).font(.system(size: 15)).foregroundStyle(Color.quiet.opacity(0.85)).padding(.vertical, 9) }
    private func row<V: View>(_ title: String, detail: String, @ViewBuilder content: () -> V) -> some View { HStack { VStack(alignment: .leading, spacing: 8) { Text(title).font(.system(size: 16, weight: .medium)); if !detail.isEmpty { Text(detail).font(.system(size: 14)).foregroundStyle(Color.quiet) } }; Spacer(); content() } }
}
struct VoiceStatusView: View {
    @ObservedObject var voice: NativeVoice
    var inCall=false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(voice.backendStatus).font(.system(size: 14)).foregroundStyle(Color.quiet); Spacer(); Button(inCall ? "通话结束后试听" : voice.speaking || voice.preparing ? "停止试听" : "试听这个声音") { if voice.speaking || voice.preparing { voice.stopSpeaking() } else { voice.speak(VoiceStyle.sample) } }.font(.system(size: 14)).disabled(inCall) }
            if !voice.voiceNotice.isEmpty { Text(voice.voiceNotice).font(.system(size: 14)).foregroundStyle(.orange) }
        }.padding(12).background(Color.softSage.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
struct NativeMemoryRow: View {
    var memory: Memory
    var onSave: (Memory) -> Void
    var onDelete: () -> Void
    @State private var editing = false
    @State private var draft = ""
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(memory.status == "approved" ? Color.sage.opacity(0.7) : Color.orange.opacity(0.5)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 7) { if editing { TextField("修改记忆", text: $draft).textFieldStyle(.roundedBorder) } else { Text(memory.text).font(.system(size: 16)) }; Text(memory.status == "approved" ? "已确认 · 以后聊天可以用到" : "原话依据：\(memory.evidence)").font(.system(size: 13)).foregroundStyle(Color.quiet) }
            Spacer()
            if editing { Button("保存") { var m = memory; m.text = draft; onSave(m); editing = false } }
            else { Button { draft = memory.text; editing = true } label: { Image(systemName: "pencil").font(.system(size: 16)) }.buttonStyle(.plain); if memory.status == "pending" { Button("记住") { var m = memory; m.status = "approved"; onSave(m) } } }
            Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(Color.quiet) }.buttonStyle(.plain)
        }.padding(.vertical, 10)
    }
}
