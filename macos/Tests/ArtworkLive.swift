import Foundation
import AppKit

@MainActor func artworkComparisonLive() async {
    guard let key = Credentials.load() else { print("No saved connection is available."); exit(1) }
    let args = CommandLine.arguments
    let label = args.last ?? "flare-high"
    let directory = URL(fileURLWithPath:"artifacts/v014-artwork",isDirectory:true)
    let client=OpenAIClient(key:key)
    client.onArtworkPlan={text in try? (text ?? "").write(to:directory.appendingPathComponent(label+"-plan.txt"),atomically:true,encoding:.utf8)}
    var report:[String:Any] = ["syntheticOnly":true,"microphoneOpened":false,"label":label]
    do {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let store=try fixture();defer{remove(store)}
        if label == "flare-medium" {client.artworkConfiguration.quality="medium"}
        if label == "previous-medium" {client.artworkConfiguration=ArtworkConfiguration(model:"gpt-image-2.5-flare",quality:"medium",complexity:nil,format:"png")}
        var requests=0,progress:[[String:Any]]=[]
        let start=Date()
                client.onAPIFailure={path,status,code,param in report["apiFailure"]=["path":path,"status":status,"code":code,"param":param]}
        let engine=CompanionEngine(store:store,model:client)
        client.onArtworkRequest={requests+=1;try store.recordCloudOperation()}
        engine.onActivity={state in progress.append(["state":state,"seconds":Date().timeIntervalSince(start)])}
        engine.seedHistory([
            ["role":"user","content":"给我讲一个会唱歌的小火车的故事。小火车是红色的，只有一辆。"],
            ["role":"assistant","content":"红色小火车从森林车站慢慢出发，圆圆的脸上挂着笑容。前面有一座小石桥，桥下平静的水像镜子。小火车唱着歌，稳稳地从桥上开过去，清晨的阳光穿过树叶。你想让它遇见小鸭子，还是去会回声的山谷呢？"]
        ])
        let result=try await engine.turn(label == "semantic" ? "整一张会唱歌的小火车的画给我瞧瞧" : "我说你画图吧，还是我要看一张图。")
        guard let art=result.artwork else {throw PartnerError.message("Missing artwork")};defer{ArtworkArchive.remove(art)}
        let file=label+"."+art.fileExtension
        try Data(contentsOf:art.url).write(to:directory.appendingPathComponent(file))
        report.merge(["success":true,"file":file,"title":art.title,"source":art.storyText,"caption":art.caption,"artworkRequests":requests,"progress":progress,"seconds":Date().timeIntervalSince(start),"diagnostics":client.artworkDiagnostics,"savedStoryRequired":false,"storedStories":try store.stories().count]){_,new in new}
        print("PASS actual conversation -> artwork \(label), \(String(format:"%.2f",Date().timeIntervalSince(start))) seconds")
    } catch {
        report["success"]=false;report["error"]=error.localizedDescription;report["diagnostics"]=client.artworkDiagnostics
        print("Artwork comparison failed: \(label): \(error.localizedDescription)")
    }
    do {try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent(label+".json"))}catch{print("Could not write report")}
    if report["success"] as? Bool != true {exit(1)}
}
