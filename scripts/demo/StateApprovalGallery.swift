import AppKit
import SwiftUI
import PacerCore

struct ReviewCase: Identifiable {
    let id: String, title: String, explanation: String, symbol: String, zh: String, en: String
    var count = 2
    var rate = 61.0
    var tint: Color = .mint
    var label: String { L10n.language == .english ? en : zh }
}

let reviewCases: [ReviewCase] = [
    .init(id:"two", title:"两个任务运行", explanation:"数量明确写成“2 个任务”；收起图标跟随最新更新的任务。可以切换哪一个示例任务更新。", symbol:"circle.fill", zh:"2 个任务", en:"2 tasks"),
    .init(id:"one", title:"单个任务思考", explanation:"只有一个任务时用当前状态文字，多个任务时才显示数量。", symbol:"brain", zh:"思考中", en:"Thinking", count:1),
    .init(id:"tool", title:"执行工具", explanation:"任务仍在运行，但工具阻塞期间的生成速度为零。", symbol:"gearshape.2.fill", zh:"执行工具", en:"Using tools", count:1, rate:0),
    .init(id:"replying", title:"正在输出回复", explanation:"回复图标表示正在输出，任务数量和即时速率仍可见。", symbol:"text.bubble.fill", zh:"正在回复", en:"Replying", count:1, rate:73),
    .init(id:"starting", title:"任务刚开始／尚无速度", explanation:"有任务，但没有足够的 token 样本；不编造零速度。", symbol:"hourglass", zh:"正在处理", en:"Starting", count:1, rate:-1),
    .init(id:"stale-rate", title:"速度暂未更新", explanation:"灰色速度表示最近一次估计，不把它误认为当前实测速率。", symbol:"brain", zh:"思考中", en:"Thinking", count:1),
    .init(id:"idle", title:"空闲", explanation:"没有正在进行的任务，保留额度信息，不显示无意义的速度。", symbol:"tray", zh:"空闲", en:"Idle", count:0, rate:-1, tint:.secondary),
    .init(id:"blocking", title:"等待用户回复", explanation:"当前任务已暂停，等用户回复；速度隐藏。", symbol:"questionmark.bubble.fill", zh:"待你回复", en:"Reply needed", count:1, rate:-1, tint:.orange),
    .init(id:"async", title:"异步待回复＋继续运行", explanation:"问题等你回复，两个任务仍继续运行；待回复数量和速度同时显示。", symbol:"questionmark.bubble.fill", zh:"待你回复", en:"Reply needed", tint:.orange),
    .init(id:"approval", title:"等待审批", explanation:"用盾牌区分审批与普通问题，点击展开后处理具体请求。", symbol:"checkmark.shield.fill", zh:"待你审批", en:"Approval needed", tint:.orange),
    .init(id:"multi-input", title:"多个待回复请求", explanation:"待回复标记直接放在对应任务行内，不单独展示请求列表。", symbol:"questionmark.bubble.fill", zh:"待你回复", en:"Reply needed", count:3, tint:.orange),
    .init(id:"mixed-wait", title:"等待回复＋另一任务运行", explanation:"优先提示待回复；另一个任务的生成速度继续显示。", symbol:"questionmark.bubble.fill", zh:"待你回复", en:"Reply needed", tint:.orange),
    .init(id:"complete", title:"本轮完成／未读", explanation:"未读完成提示持续保留；没有其他运行任务时不显示速度。", symbol:"checkmark.circle.fill", zh:"1 已完成", en:"1 done", count:1, rate:-1),
    .init(id:"interrupted", title:"本轮中断", explanation:"中断与正常完成使用不同图标和文字。", symbol:"pause.circle.fill", zh:"1 已中断", en:"1 stopped", count:1, rate:-1, tint:.orange),
    .init(id:"failed", title:"任务失败", explanation:"失败事件的独立呈现方案，供审批；正式版当前将失败归入中断。", symbol:"xmark.circle.fill", zh:"任务失败", en:"Failed", count:1, rate:-1, tint:.red),
    .init(id:"complete-running", title:"已完成＋其他任务运行", explanation:"优先显示未读完成，同时保留另一个任务的速度。", symbol:"checkmark.circle.fill", zh:"1 已完成", en:"1 done"),
    .init(id:"complete-offline", title:"已完成＋连接异常", explanation:"完成提醒保持正常展示，不在灵动岛头部或任务区添加连接异常图标。", symbol:"checkmark.circle.fill", zh:"1 已完成", en:"1 done", count:1, rate:-1),
    .init(id:"local-offline", title:"本机订阅断连", explanation:"额度读取独立正常，任务状态订阅失联；展开后显示具体来源。", symbol:"network.slash", zh:"本机断连", en:"Local offline", tint:.orange),
    .init(id:"ssh-offline", title:"一个 SSH 来源断连", explanation:"其他任务正常运行；展开后显示哪个示例来源失联。", symbol:"network", zh:"1 来源异常", en:"1 offline", tint:.orange),
    .init(id:"many-offline", title:"多个 SSH 来源断连", explanation:"用来源数量表示连接问题，区别于任务或待回复数量。", symbol:"network", zh:"2 来源异常", en:"2 offline", tint:.orange),
    .init(id:"unknown", title:"任务状态未知", explanation:"不能确认运行状态时明确显示未知，不假装任务仍运行。", symbol:"questionmark.diamond", zh:"状态未知", en:"Unknown", count:1, rate:-1, tint:.secondary),
    .init(id:"quota-loading", title:"额度首次加载", explanation:"额度尚无读数时显示缺失值，展开面板显示加载状态。", symbol:"tray", zh:"空闲", en:"Idle", count:0, rate:-1, tint:.secondary),
    .init(id:"quota-error", title:"额度读取失败", explanation:"任务订阅仍可正常运行；额度失败单独提示，不混为任务失败。", symbol:"circle.fill", zh:"2 个任务", en:"2 tasks"),
    .init(id:"quota-stale", title:"额度读数过期", explanation:"保留旧值与时钟标记，明确提示更新时间。", symbol:"circle.fill", zh:"2 个任务", en:"2 tasks"),
    .init(id:"quota-expired", title:"额度周期已过期", explanation:"已结束的窗口不再被当作有效当前额度或配速。", symbol:"tray", zh:"空闲", en:"Idle", count:0, rate:-1, tint:.secondary),
    .init(id:"low", title:"低额度", explanation:"低额度告警只放在右侧，左侧保持正常任务图标、数量和速度。", symbol:"brain", zh:"2 个任务", en:"2 tasks"),
    .init(id:"empty", title:"额度用尽", explanation:"额度为 0% 时在右侧告警；左侧继续正常呈现任务或空闲。", symbol:"tray", zh:"空闲", en:"Idle", count:0, rate:-1, tint:.secondary),
    .init(id:"many", title:"多任务／较高速率", explanation:"数量有单位，高速率采用 k 缩写；检查刘海两侧空间。", symbol:"circle.fill", zh:"12 个任务", en:"12 tasks", count:12, rate:12400),
    .init(id:"pace-max", title:"配速模式／最长右侧读数", explanation:"右侧改为 1000% 配速，验证最宽读数不会挤掉左侧任务文字。", symbol:"circle.fill", zh:"2 个任务", en:"2 tasks"),
    .init(id:"input-low", title:"待回复＋低额度", explanation:"左侧保持待回复状态；额度告警只放在右侧，待回复信息直接标在对应任务行。", symbol:"questionmark.bubble.fill", zh:"待你回复", en:"Reply needed", tint:.orange)
].filter { !["local-offline","ssh-offline","many-offline","unknown"].contains($0.id) }

@MainActor final class ReviewController: ObservableObject {
    @Published var iconMode = true
    @Published var iconIndex = 0
    @Published var selectedSymbols: [String: String] = [:]
    @Published var iconPreviews: [IconPreview] = []
    @Published var iconSaveError: String?
    @Published var index = 0
    @Published var english = false
    @Published var expanded = false
    @Published var expandedNotch = true
    @Published var thinkingLatest = false
    @Published var revisionNotice: String?
    @Published var decisions: [String:String] = [:]
    @Published var comment = ""
    @Published var saveError: String?
    @Published var notch: IslandModel!
    @Published var floating: IslandModel!
    @Published var notchOpen: IslandModel!
    @Published var floatingOpen: IslandModel!
    let receipt: URL
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    var current: ReviewCase { reviewCases[index] }
    var approved: Int { reviewCases.filter { decisions[$0.id] == "approved" }.count }
    init(receipt: URL) {
        self.receipt = receipt
        if let data = try? Data(contentsOf:receipt), let saved = try? JSONDecoder().decode(Saved.self,from:data), [1, 2, 3].contains(saved.schema) {
            decisions = saved.decisions; notes = saved.notes
            if saved.schema < 3 {
                for id in ["stale-rate","complete-running","quota-loading","quota-expired","quota-error","quota-stale","many","pace-max"] where decisions[id] == "approved" { decisions[id] = "recheck" }
                revisionNotice = "已更新最新任务图标、待处理文字与右侧额度告警，移除 4 个连接／未知独立状态；受影响的已通过项需复核。"
            }
            index = reviewCases.firstIndex { decisions[$0.id] != "approved" } ?? 0
        }
        loadIcons()
        apply()
        refreshIcons()
    }
    func select(_ value:Int) { index = value; expanded = false; comment = ""; apply() }
    func languageChanged() {
        UserDefaults.standard.set(english ? "en" : "zh-Hans", forKey:"appLanguage")
        apply()
        refreshIcons()
    }
    func apply() {
        UserDefaults.standard.set(current.id == "pace-max" ? "pace" : "remaining",forKey:"compactMetric")
        notch = model(attached:true, open:false); floating = model(attached:false, open:false)
        notchOpen = model(attached:true, open:true); floatingOpen = model(attached:false, open:true)
    }
    func model(attached:Bool, open:Bool, caseOverride:ReviewCase? = nil, symbols:[String:String]? = nil) -> IslandModel {
        let c=caseOverride ?? current, chosen=defaultIconSymbols.merging(symbols ?? selectedSymbols){_,selected in selected}, model=IslandModel(demo:true, demoClock:{ [now] in now })
        model.now=now; model.isAttached=attached; model.notchWidth=attached ? 180 : 0; model.topHeight=attached ? 36 : 38
        model.reviewLabel=c.label; model.reviewSymbol=c.symbol; model.reviewTint=c.tint
        var status=RuntimeStreamStatus(); status.connected=true; status.attachedThreads=c.count
        model.streamStatuses=["local":status]
        var initial=(0..<c.count).map { task($0, kind:"running", scale:c.rate > 0 ? c.rate / Double(max(1,c.count)) / 61 : 1) }
        if c.id == "two" {
            initial=[task(0,kind:"running", latestAgo:thinkingLatest ? 0 : -5), task(1,kind:"tool", latestAgo:thinkingLatest ? -5 : 0)]
        }
        model.reviewActivities(initial)
        var tasks=initial
        if ["complete","interrupted","failed","complete-running","complete-offline"].contains(c.id) {
            tasks[0]=task(0,kind:c.id == "interrupted" ? "interrupted" : c.id == "failed" ? "failed" : "completed")
        } else if c.id == "unknown" { tasks=[SessionActivity(id:"019a0000-0000-7000-8000-000000000001",project:"示例任务 A")] }
        else if c.id == "blocking" { tasks=[task(0,kind:"waiting")] }
        else if c.id == "approval" { tasks[0]=task(0,kind:"approval") }
        else if c.id == "mixed-wait" { tasks[0]=task(0,kind:"waiting") }
        else if c.id == "tool" { tasks=[task(0,kind:"tool")] }
        else if c.id == "replying" { tasks=[task(0,kind:"responding",scale:73/61)] }
        else if c.id == "starting" { tasks=[task(0,kind:"starting")] }
        else if c.id == "stale-rate" { tasks=[task(0,kind:"stale")] }
        model.reviewActivities(tasks)
        if ["two","one","tool","replying","starting","stale-rate","many","quota-error","quota-stale"].contains(c.id),
           let latest=tasks.max(by:{ ($0.lastObserved ?? .distantPast) < ($1.lastObserved ?? .distantPast) }) {
            switch latest.stage {
            case .thinking: model.reviewSymbol="brain"
            case .tool: model.reviewSymbol="gearshape.2.fill"
            case .responding: model.reviewSymbol="text.bubble.fill"
            case .starting: model.reviewSymbol="hourglass"
            }
        }
        model.reviewHidesConnectionIcon = true
        model.reviewQuotaWarning = ["low","empty","input-low"].contains(c.id)
        if ["blocking","async","approval","multi-input","mixed-wait","input-low"].contains(c.id) {
            let n=c.id == "multi-input" ? 3 : 1
            model.observeAttentionRequests((0..<n).map { PendingAttentionRequest(id:"review-\($0)",threadID:String(format:"019a0000-0000-7000-8000-%012d",$0+1),sourceHostID:nil,sourceName:"示例任务",kind:c.id == "approval" ? .approval : .input,detectedAt:now) })
        }
        model.reviewSymbols=chosen
        let iconKey=iconKeyForCase(c.id, symbol:model.reviewSymbol ?? c.symbol)
        model.reviewSymbol=chosen[iconKey] ?? model.reviewSymbol
        if c.id == "failed" { model.reviewRowOverride=chosen["failed"] ?? c.symbol }
        if c.id == "local-offline" { status.connected=false; model.streamStatuses["local"]=status }
        if ["ssh-offline","complete-offline"].contains(c.id) { model.unavailableSSH=["示例 SSH A"] }
        if c.id == "many-offline" { model.unavailableSSH=["示例 SSH A","示例 SSH B"] }
        let remaining=["low","input-low"].contains(c.id) ? 12.0 : c.id == "empty" ? 0 : c.id == "pace-max" ? 100 : 44
        let reset=now.addingTimeInterval(c.id == "quota-expired" ? -60 : c.id == "pace-max" ? 3600 : 72*3600)
        var history=QuotaCycleHistory()
        let start=reset.addingTimeInterval(-7*86400)
        for i in 0...48 {
            let capture=start.addingTimeInterval(now.timeIntervalSince(start)*Double(i)/48)
            history.record(quota(at:capture,remaining:100-(100-remaining)*Double(i)/48,reset:reset))
        }
        model.history=history; model.quota=quota(at:c.id == "quota-stale" ? now.addingTimeInterval(-3600) : now,remaining:remaining,reset:reset)
        if c.id == "quota-loading" { model.quota=nil; model.refreshing=true }
        if c.id == "quota-error" { model.quota=nil; model.errorMessage="示例：额度服务暂时不可用" }

        model.onLayoutChange={ [weak self, weak model] in
            if !open, model?.expanded == true { self?.expandedNotch=attached; self?.expanded=true }
            if open { model?.objectWillChange.send() }
        }
        model.onOpenActivity={ _ in "这是合成的演示会话。" }
        model.onQuit={ NSApp.terminate(nil) }
        model.expanded=open; model.pinned=open
        return model
    }
    func task(_ index:Int, kind:String, scale:Double=1, latestAgo:Double=0) -> SessionActivity {
        let tid=String(format:"019a0000-0000-7000-8000-%012d",index+1)
        func e(_ method:String,_ ago:Double,_ extra:[String:Any]=[:]) -> [String:Any] {
            ["method":method,"threadId":tid,"turnId":"review-turn","at":now.addingTimeInterval(ago).timeIntervalSince1970].merging(extra){_,new in new}
        }
        let delay=kind == "stale" ? -25.0 : latestAgo
        var events=[e("metadata",-30+delay,["name":"示例任务 \(index+1)","model":"Codex"]),e("turn/started",-30+delay)]
        if kind != "starting" { events.append(e("item/started",-28+delay,["itemId":"thinking","itemType":"reasoning"])) }
        if kind != "starting" {
            events += [e("thread/tokenUsage/updated",-25+delay,["outputTokens":Int(300*scale)]),e("thread/tokenUsage/updated",-14+delay,["outputTokens":Int(965*scale)]),e("thread/tokenUsage/updated",delay,["outputTokens":Int(1815*scale)])]
        }
        if kind == "tool" { events.append(e("item/started",delay,["itemId":"tool","itemType":"commandExecution"])) }
        if kind == "responding" { events += [e("item/started",-5,["itemId":"answer","itemType":"agentMessage"]),e("item/agentMessage/delta",0,["itemId":"answer"])] }
        if ["waiting","approval"].contains(kind) { events.append(e("thread/status/changed",0,["status":"active","flags":[kind == "approval" ? "waitingOnApproval" : "waitingOnUserInput"]])) }
        if ["completed","interrupted","failed"].contains(kind) { events.append(e("turn/completed",0,["status":kind])) }
        return ReviewRuntimeFixtures.activities(events)[0]
    }
    func quota(at date:Date,remaining:Double,reset:Date) -> QuotaSnapshot {
        let raw:[String:Any]=["rateLimits":["limitId":"codex","secondary":["usedPercent":100-remaining,"windowDurationMins":10080,"resetsAt":reset.timeIntervalSince1970]]]
        var value=try! QuotaSnapshot.decode(JSONSerialization.data(withJSONObject:raw),capturedAt:date); value.accountScope="synthetic-state-review"; return value
    }
    struct Saved: Codable { let schema:Int; let decisions:[String:String]; let notes:[String:String] }
    private var notes:[String:String]=[:]
    var previousNote:String? { notes[current.id] }
    func decide(_ value:String) {
        decisions[current.id]=value; notes[current.id]=comment
        do {
            let saved=Saved(schema:3,decisions:decisions,notes:notes)
            try JSONEncoder().encode(saved).write(to:receipt,options:.atomic); saveError=nil
            if index+1<reviewCases.count { select(index+1) }
        } catch { saveError="审批记录未保存：\(error.localizedDescription)" }
    }
}

@MainActor struct PreviewIsland: View {
    @ObservedObject var model:IslandModel
    @StateObject private var presentation=IslandPresentation()
    let open:Bool
    var width:CGFloat { open ? (model.isAttached ? 480 : 440) : model.isAttached ? 480 : 300 }
    var height:CGFloat { open ? model.topHeight + model.panelContentHeight : model.topHeight }
    var body: some View {
        IslandView(model:model,presentation:presentation).frame(width:width,height:height)
            .onAppear { sync() }.onChange(of:model.expanded){_,_ in sync()}.onChange(of:height){_,_ in sync()}
    }
    func sync() {
        presentation.canvas=CGSize(width:width,height:height)
        presentation.sample=IslandTransition.Sample.resting(at:CGRect(x:0,y:0,width:width,height:height),expanded:open,hasBlackHeader:model.isAttached)
    }
}

@MainActor private struct Gallery:View {
    @ObservedObject var review:ReviewController
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                Text("状态逐项审批").font(.title3.bold())
                Text("已通过 \(review.approved) / \(reviewCases.count)").foregroundStyle(.secondary)
                List(Array(reviewCases.enumerated()),id:\.element.id) { index,c in
                    Button { review.select(index) } label: {
                        HStack {
                            Image(systemName:review.decisions[c.id] == "approved" ? "checkmark.circle.fill" : review.decisions[c.id] == "changes" ? "pencil.circle" : "circle")
                                .foregroundStyle(review.decisions[c.id] == "approved" ? .green : .secondary)
                            Text("\(index+1). \(c.title)").font(.system(size:12))
                            Spacer()
                        }.padding(.vertical,3).background(review.index == index ? Color.accentColor.opacity(0.12) : .clear)
                    }.buttonStyle(.plain)
                }
            }.padding(16).frame(width:230)
            Divider()
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("\(review.index+1) / \(reviewCases.count) · \(review.current.title)").font(.title2.bold())
                    Spacer(); Toggle("English",isOn:$review.english).toggleStyle(.switch).onChange(of:review.english){_,_ in review.languageChanged()}
                }
                Text(review.current.explanation).font(.system(size:13)).foregroundStyle(.secondary)
                if let notice=review.revisionNotice { Text(notice).font(.system(size:11)).foregroundStyle(.orange) }
                if let note=review.previousNote, !note.isEmpty { Text("你的上一轮意见："+note).font(.system(size:12)).foregroundStyle(.orange) }
                if review.current.id == "two" { Button(review.thinkingLatest ? "让工具任务更新" : "让思考任务更新") { review.thinkingLatest.toggle(); review.apply() } }
                Text("合成数据 · 原生控件 · 未应用到正式版本").font(.system(size:11)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        VStack(alignment:.leading,spacing:8) {
                            Text("刘海 · 收起 · 480 pt（含相机预留区）").font(.system(size:12)).foregroundStyle(.secondary)
                            PreviewIsland(model:review.notch,open:false).id("notch-\(review.index)-\(review.english)")
                        }
                        VStack(alignment:.leading,spacing:8) {
                            Text("悬浮 · 收起 · 300 pt").font(.system(size:12)).foregroundStyle(.secondary)
                            PreviewIsland(model:review.floating,open:false).id("floating-\(review.index)-\(review.english)")
                        }
                        HStack {
                            Toggle("展开预览",isOn:$review.expanded)
                            if review.expanded {
                                Picker("模式",selection:$review.expandedNotch) { Text("刘海").tag(true);Text("悬浮").tag(false) }.pickerStyle(.segmented).frame(width:160)
                            }
                        }
                        if review.expanded { PreviewIsland(model:review.expandedNotch ? review.notchOpen : review.floatingOpen,open:true).id("expanded-\(review.index)-\(review.expandedNotch)-\(review.english)") }
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                }.background(Color(nsColor:.underPageBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12))
                TextField("本项修改意见（选填）",text:$review.comment).textFieldStyle(.roundedBorder)
                if let error=review.saveError { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("上一项") { review.select(max(0,review.index-1)) }.disabled(review.index == 0)
                    Button("下一项预览") { review.select(min(reviewCases.count-1,review.index+1)) }.disabled(review.index+1 == reviewCases.count)
                    Spacer()
                    Button("需要修改") { review.decide("changes") }
                    Button("通过本项并继续") { review.decide("approved") }.buttonStyle(.borderedProminent)
                }
            }.padding(20).frame(minWidth:600)
        }.preferredColorScheme(.dark)
    }
}

@MainActor private final class GalleryDelegate:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        let defaults=UserDefaults.standard
        defaults.set("zh-Hans",forKey:"appLanguage");defaults.set(false,forKey:"systemNotifications");defaults.set(false,forKey:"monitorSSH")
        defaults.set("/private/tmp/pacer-state-review-home",forKey:"codexHome")
        defaults.set(true,forKey:"inputReminder");defaults.set(true,forKey:"completionReminder");defaults.set(30,forKey:"completedRetentionMinutes")
        defaults.set("codex/secondary",forKey:"quotaWindowID");defaults.set("liquidGlass",forKey:"islandAppearance")
        let path=Bundle.main.object(forInfoDictionaryKey:"StateReviewReceipt") as? String ?? NSTemporaryDirectory()+"pacer-state-approvals.json"
        let controller=ReviewController(receipt:URL(fileURLWithPath:path))
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Codex Pacer · 状态审批 Demo";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:ReviewWorkspace(review:controller));window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        let menu=NSMenu(), item=NSMenuItem(), appMenu=NSMenu();appMenu.addItem(withTitle:"退出状态 Demo",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=appMenu;menu.addItem(item);NSApp.mainMenu=menu
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
@MainActor private struct ReviewWorkspace: View {
    @ObservedObject var review: ReviewController
    var body: some View {
        VStack(spacing: 0) {
            Picker("预览内容",selection:$review.iconMode) { Text("图标选择").tag(true); Text("状态复核").tag(false) }
                .pickerStyle(.segmented).frame(width:240).padding(12)
            Divider()
            if review.iconMode { IconSelectionGallery(review:review) }
            else { Gallery(review:review) }
        }.preferredColorScheme(.dark)
    }
}
@main struct StateReviewMain {
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=GalleryDelegate();app.delegate=delegate
        withExtendedLifetime(delegate){app.run()}
    }
}
