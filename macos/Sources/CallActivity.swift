import SwiftUI

enum CallVisualMode: String, CaseIterable {
    case idle, connecting, listening, thinking, speaking, muted
    var color: Color {
        switch self { case .idle, .connecting: return .sage; case .listening: return Color(red:0.12,green:0.60,blue:0.48); case .speaking: return Color(red:0.85,green:0.37,blue:0.51); case .thinking: return Color(red:0.78,green:0.53,blue:0.15); case .muted: return .quiet }
    }
    var icon: String {
        switch self { case .idle,.connecting: return "phone.fill"; case .listening: return "mic.fill"; case .speaking: return "speaker.wave.2.fill"; case .thinking: return "sparkles"; case .muted: return "mic.slash.fill" }
    }
    var label: String {
        switch self { case .idle: return "打电话"; case .connecting: return "正在接通"; case .listening: return "你说，莉莉在听"; case .speaking: return "莉莉正在讲"; case .thinking: return "莉莉在想"; case .muted: return "麦克风已静音" }
    }
    static func resolve(_ state: PhoneState?, muted: Bool) -> Self {
        if state == .speaking {return .speaking}
        if muted { return .muted }
        switch state { case .connecting: return .connecting; case .listening: return .listening; case .thinking: return .thinking; case .speaking: return .speaking; default: return .idle }
    }
}
extension AppModel {
    var callVisualMode: CallVisualMode { .resolve(phone?.state, muted: phone?.muted == true) }
    var callVisualLevel: Double { callVisualMode == .speaking ? phone?.outputLevel ?? 0 : phone?.inputLevel ?? 0 }
    var callStatusTitle:String {phone?.state == .speaking && phone?.muted != true ? "莉莉在讲，也在听" : callVisualMode.label}
}
struct DuplexLevels:View {
    var input:Double
    var output:Double
    var muted=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func bars(_ level:Double,_ color:Color)->some View {
        TimelineView(.animation(minimumInterval:1/24,paused:reduceMotion)) { time in
            HStack(spacing:2) {
                ForEach(0..<5) { index in
                    let phase=reduceMotion ? 0.5 : (sin(time.date.timeIntervalSinceReferenceDate*7+Double(index))+1)/2
                    Capsule().fill(color).frame(width:3,height:2+sqrt(max(0,min(1,level)))*14*(0.4+phase*0.6))
                }
            }.frame(width:26,height:18)
        }
    }
    var body:some View {
        HStack(spacing:12) {
            HStack(spacing:5) {Image(systemName:"speaker.wave.2.fill");bars(output,CallVisualMode.speaking.color)}.foregroundStyle(CallVisualMode.speaking.color)
            HStack(spacing:5) {Image(systemName:muted ? "mic.slash.fill" : "mic.fill");bars(muted ? 0 : input,muted ? .quiet : CallVisualMode.listening.color)}.foregroundStyle(muted ? Color.quiet : CallVisualMode.listening.color)
        }.font(.system(size:13,weight:.semibold)).accessibilityLabel(muted ? "莉莉在讲，麦克风已静音" : "莉莉在讲，也在听你的声音")
    }
}
struct CallActivityOrb: View {
    var mode: CallVisualMode
    var level: Double = 0
    var size: CGFloat = 48
    var hangupBadge = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1/24, paused: reduceMotion || mode == .idle || mode == .muted)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0.0 : (sin(time * (mode == .speaking ? 6 : 3))+1)/2
            ZStack {
                if mode == .listening || mode == .speaking {
                    Circle().stroke(mode.color.opacity(0.14 + pulse * 0.12), lineWidth: mode == .speaking ? 3 : 1.5).scaleEffect(1.03 + pulse * 0.13)
                    if mode == .speaking { Circle().stroke(mode.color.opacity(0.16),lineWidth:1).scaleEffect(1.17 + pulse * 0.12) }
                }
                Circle().fill(LinearGradient(colors:[mode.color.opacity(0.88),mode.color],startPoint:.topLeading,endPoint:.bottomTrailing))
                if mode == .connecting || mode == .thinking {
                    Circle().trim(from:0.05,to:0.72).stroke(.white.opacity(0.65),style:StrokeStyle(lineWidth:2,lineCap:.round)).padding(3).rotationEffect(.degrees(reduceMotion ? 0 : time * 115))
                }
                Image(systemName:mode.icon).font(.system(size:size * 0.36,weight:.semibold)).foregroundStyle(.white).offset(y:mode == .speaking || mode == .listening ? -size * 0.07 : 0)
                if mode == .listening || mode == .speaking {
                    HStack(spacing:2) {
                        ForEach(0..<5) { index in
                            let movement = reduceMotion ? 0.4 : (sin(time * 9 + Double(index) * 1.1)+1)/2
                            Capsule().fill(.white.opacity(0.9)).frame(width:2,height:3 + CGFloat(max(0.08,level)) * 9 * CGFloat(movement) + (mode == .speaking ? CGFloat(movement)*3 : 0))
                        }
                    }.offset(y:size * 0.25)
                }
            }.frame(width:size,height:size)
                .overlay(alignment:.bottomTrailing) {
                    if hangupBadge { Image(systemName:"phone.down.fill").font(.system(size:9,weight:.bold)).foregroundStyle(.white).frame(width:18,height:18).background(Color(red:0.82,green:0.24,blue:0.33),in:Circle()).overlay(Circle().stroke(Color.paper,lineWidth:2)).offset(x:3,y:3) }
                }
        }.accessibilityLabel(mode.label)
    }
}
struct CallActivityPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing:18) {
            CallActivityOrb(mode:model.callVisualMode,level:model.callVisualLevel,size:54)
            VStack(alignment:.leading,spacing:6) {
                Text(model.callStatusTitle).font(.system(size:21,weight:.bold,design:.rounded))
                if let phone=model.phone,phone.state == .speaking,!phone.listeningHint.isEmpty {
                    Text(phone.listeningHint).font(.system(size:16)).foregroundStyle(Color.quiet)
                } else if let phone=model.phone, !phone.inputTranscript.isEmpty {
                    Text("你说："+phone.inputTranscript).font(.system(size:16)).lineLimit(2)
                } else if let phone=model.phone,!phone.listeningHint.isEmpty {
                    Text(phone.listeningHint).font(.system(size:16)).foregroundStyle(Color.quiet)
                } else if model.callVisualMode == .listening || model.callVisualMode == .speaking {
                    ActivityWave(mode:model.callVisualMode,level:model.callVisualLevel).frame(width:140,height:20)
                }
            }
            Spacer()
            if model.callVisualMode == .speaking {DuplexLevels(input:model.phone?.inputLevel ?? 0,output:model.phone?.outputLevel ?? 0,muted:model.phone?.muted == true)}
            Button { model.phone?.toggleMute() } label: { Label(model.phone?.muted == true ? "开麦" : "静音",systemImage:model.phone?.muted == true ? "mic.slash.fill" : "mic.fill").font(.system(size:17,weight:.medium)).padding(11).background(.white.opacity(0.8),in:Capsule()) }.buttonStyle(.plain)
        }.padding(17).foregroundStyle(Color.ink).toyCard(model.callVisualMode.color.opacity(0.12),model.callVisualMode.color.opacity(0.5),radius:22)
    }
}
struct ActivityWave: View {
    let mode: CallVisualMode
    var level: Double
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        TimelineView(.animation(minimumInterval:1/24,paused:reduced || mode == .muted || mode == .idle)) { time in
            HStack(spacing:4) { ForEach(0..<17) { index in
                let phase = (mode == .muted || mode == .idle) ? 0 : reduced ? 0.4 : (sin(time.date.timeIntervalSinceReferenceDate*8 + Double(index)*0.7)+1)/2
                Capsule().fill(mode.color.opacity(0.75)).frame(width:4,height:3 + CGFloat(phase)*(4 + CGFloat(max(level,0.08))*13))
            }}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.leading)
        }.accessibilityHidden(true)
    }
}

struct ActivityGallery: View {
    var body: some View {
        HStack(spacing:48) {
            ForEach([CallVisualMode.listening,.thinking,.speaking,.muted],id: \.rawValue) { mode in
                VStack(spacing:24) {
                    CallActivityOrb(mode:mode,level:0.7,size:74,hangupBadge:true)
                    Text(mode.label).font(.system(size:19,weight:.semibold,design:.rounded))
                }
            }
        }.frame(width:760,height:260).foregroundStyle(Color.ink).background(Color.paper)
    }
}
