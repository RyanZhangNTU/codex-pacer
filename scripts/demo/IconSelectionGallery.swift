import AppKit
import SwiftUI
import PacerCore

struct IconOption: Identifiable {
    let symbol: String
    let label: String
    var id: String { symbol }
}

struct IconGroup: Identifiable {
    let id: String
    let title: String
    let caseID: String
    let placement: String
    let options: [IconOption]
    var available: [IconOption] { options.filter { NSImage(systemSymbolName:$0.symbol, accessibilityDescription:nil) != nil } }
    var isQuota: Bool { ["low","empty","freshness"].contains(id) }
}

let iconGroups: [IconGroup] = [
    .init(id:"thinking",title:"思考",caseID:"one",placement:"左侧状态与任务行",options:[
        .init(symbol:"brain",label:"大脑轮廓"), .init(symbol:"brain.head.profile",label:"侧脸与大脑"), .init(symbol:"ellipsis.bubble",label:"思考气泡")]),
    .init(id:"tool",title:"执行工具",caseID:"tool",placement:"左侧状态与任务行",options:[
        .init(symbol:"gearshape.2.fill",label:"双齿轮"), .init(symbol:"terminal",label:"终端窗口"), .init(symbol:"hammer.fill",label:"工具锤")]),
    .init(id:"replying",title:"输出回复",caseID:"replying",placement:"左侧状态与任务行",options:[
        .init(symbol:"text.bubble.fill",label:"文字气泡"), .init(symbol:"text.alignleft",label:"文本行"), .init(symbol:"quote.bubble",label:"引用气泡")]),
    .init(id:"starting",title:"刚开始／等待采样",caseID:"starting",placement:"左侧状态与任务行",options:[
        .init(symbol:"hourglass",label:"沙漏"), .init(symbol:"clock",label:"时钟"), .init(symbol:"play.circle",label:"开始播放")]),
    .init(id:"idle",title:"空闲",caseID:"idle",placement:"左侧状态；没有任务行",options:[
        .init(symbol:"tray",label:"空托盘"), .init(symbol:"moon.zzz",label:"休息月亮"), .init(symbol:"circle.dotted",label:"虚线圆")]),
    .init(id:"input",title:"待你回复",caseID:"async",placement:"左侧提示与对应任务行",options:[
        .init(symbol:"questionmark.bubble.fill",label:"问号气泡"), .init(symbol:"bubble.left.and.text.bubble.right",label:"双对话气泡"), .init(symbol:"person.crop.circle.badge.questionmark",label:"人物与问号")]),
    .init(id:"approval",title:"待你审批",caseID:"approval",placement:"左侧提示与对应任务行",options:[
        .init(symbol:"checkmark.shield.fill",label:"勾选盾牌"), .init(symbol:"hand.raised.fill",label:"举手等待"), .init(symbol:"lock.shield",label:"锁与盾牌")]),
    .init(id:"complete",title:"本轮完成",caseID:"complete",placement:"左侧提醒与任务行",options:[
        .init(symbol:"checkmark.circle.fill",label:"圆形勾选"), .init(symbol:"checkmark.seal.fill",label:"勾选徽章"), .init(symbol:"checkmark",label:"简洁勾选")]),
    .init(id:"interrupted",title:"本轮中断",caseID:"interrupted",placement:"左侧提醒与任务行",options:[
        .init(symbol:"pause.circle.fill",label:"圆形暂停"), .init(symbol:"stop.circle.fill",label:"圆形停止"), .init(symbol:"hand.raised",label:"停止手势")]),
    .init(id:"failed",title:"任务失败",caseID:"failed",placement:"左侧提醒与任务行（失败状态方案）",options:[
        .init(symbol:"xmark.circle.fill",label:"圆形叉号"), .init(symbol:"exclamationmark.octagon.fill",label:"八角警示"), .init(symbol:"bolt.slash",label:"断开闪电")]),
    .init(id:"low",title:"低额度",caseID:"low",placement:"仅右侧额度旁，左侧任务不变",options:[
        .init(symbol:"exclamationmark.triangle.fill",label:"三角警示"), .init(symbol:"exclamationmark.circle.fill",label:"圆形警示"), .init(symbol:"battery.25percent",label:"低电量")]),
    .init(id:"empty",title:"额度用尽",caseID:"empty",placement:"仅右侧额度旁，左侧空闲不变",options:[
        .init(symbol:"nosign",label:"禁止符号"), .init(symbol:"battery.0percent",label:"空电量"), .init(symbol:"xmark.circle",label:"空心圆叉")]),
    .init(id:"freshness",title:"额度待更新／读取异常",caseID:"quota-stale",placement:"仅右侧额度旁；文字说明原因",options:[
        .init(symbol:"clock",label:"时钟"), .init(symbol:"clock.badge.exclamationmark",label:"时钟警示"), .init(symbol:"arrow.clockwise.circle",label:"刷新圆环")])
]

let defaultIconSymbols = Dictionary(uniqueKeysWithValues:iconGroups.map { ($0.id,$0.options[0].symbol) })

func iconKeyForCase(_ id:String, symbol:String) -> String {
    if ["blocking","async","multi-input","mixed-wait","input-low"].contains(id) { return "input" }
    if id == "approval" { return "approval" }
    if ["complete","complete-running","complete-offline"].contains(id) { return "complete" }
    if id == "interrupted" { return "interrupted" }
    if id == "failed" { return "failed" }
    if ["idle","empty","quota-loading","quota-expired"].contains(id) { return "idle" }
    switch symbol {
    case "gearshape.2.fill": return "tool"
    case "text.bubble.fill": return "replying"
    case "hourglass": return "starting"
    default: return "thinking"
    }
}

struct IconPreview: Identifiable {
    let option: IconOption
    let notch: IslandModel
    let floating: IslandModel
    var id:String { option.id }
}

extension ReviewController {
    var iconReceipt:URL { receipt.deletingLastPathComponent().appendingPathComponent("icon-selections.json") }
    var iconGroup:IconGroup { iconGroups[iconIndex] }
    var chosenIconCount:Int { iconGroups.filter { selectedSymbols[$0.id] != nil }.count }
    struct IconSaved:Codable { let schema:Int; let selections:[String:String] }
    func loadIcons() {
        guard let data=try? Data(contentsOf:iconReceipt), let saved=try? JSONDecoder().decode(IconSaved.self,from:data), saved.schema == 1 else { return }
        selectedSymbols=saved.selections.filter { key,value in iconGroups.first(where:{$0.id == key})?.available.contains(where:{$0.symbol == value}) == true }
    }
    func selectIconGroup(_ index:Int) { iconIndex=index; refreshIcons() }
    func refreshIcons() {
        guard let sample=reviewCases.first(where:{$0.id == iconGroup.caseID}) else { iconPreviews=[]; return }
        iconPreviews=iconGroup.available.map { option in
            var symbols=selectedSymbols; symbols[iconGroup.id]=option.symbol
            return IconPreview(option:option,notch:model(attached:true,open:false,caseOverride:sample,symbols:symbols),floating:model(attached:false,open:false,caseOverride:sample,symbols:symbols))
        }
    }
    func chooseIcon(_ option:IconOption) {
        guard iconGroup.available.contains(where:{$0.id == option.id}) else { return }
        var proposed=selectedSymbols; proposed[iconGroup.id]=option.symbol
        do {
            try JSONEncoder().encode(IconSaved(schema:1,selections:proposed)).write(to:iconReceipt,options:.atomic)
            selectedSymbols=proposed; iconSaveError=nil; apply(); refreshIcons()
        } catch { iconSaveError="图标选择未保存：\(error.localizedDescription)" }
    }
}

@MainActor struct IconSelectionGallery:View {
    @ObservedObject var review:ReviewController
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:10) {
                Text("选择状态图标").font(.title3.bold())
                Text("已选 \(review.chosenIconCount) / \(iconGroups.count)").foregroundStyle(.secondary)
                List(Array(iconGroups.enumerated()),id:\.element.id) { index,group in
                    Button { review.selectIconGroup(index) } label: {
                        HStack(spacing:8) {
                            Image(systemName:review.selectedSymbols[group.id] ?? group.options[0].symbol).frame(width:22)
                            Text(group.title).font(.system(size:12))
                            Spacer(minLength:2)
                            if review.selectedSymbols[group.id] != nil { Image(systemName:"checkmark").foregroundStyle(.green) }
                        }.padding(.vertical,6).background(review.iconIndex == index ? Color.accentColor.opacity(0.12) : .clear)
                    }.buttonStyle(.plain)
                }
                Text("同一种状态在组合场景中共用图标。\n仅保存你的选择，不安装或发布。").font(.system(size:11)).foregroundStyle(.secondary)
            }.padding(16).frame(width:230)
            Divider()
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    Text("\(review.iconIndex+1) / \(iconGroups.count) · \(review.iconGroup.title)").font(.title2.bold())
                    Spacer()
                    Toggle("English",isOn:$review.english).toggleStyle(.switch).onChange(of:review.english){_,_ in review.languageChanged()}
                }
                Text("\(review.iconGroup.placement)。每项均显示放大图、刘海／悬浮实际尺寸；任务图标还显示原生任务行。").font(.system(size:12)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        ForEach(Array(review.iconPreviews.enumerated()),id:\.element.id) { index,preview in
                            optionCard(preview,index:index)
                        }
                    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                }.background(Color(nsColor:.underPageBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12))
                if let error=review.iconSaveError { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("上一类") { review.selectIconGroup(max(0,review.iconIndex-1)) }.disabled(review.iconIndex == 0)
                    Button("下一类") { review.selectIconGroup(min(iconGroups.count-1,review.iconIndex+1)) }.disabled(review.iconIndex+1 == iconGroups.count)
                    Spacer()
                    Text("可改选；未点击选择的类别保持未定。").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.padding(20).frame(minWidth:600)
        }
    }
    private func optionCard(_ preview:IconPreview,index:Int) -> some View {
        let letter=["A","B","C"][index]
        let selected=review.selectedSymbols[review.iconGroup.id] == preview.option.symbol
        let tint:Color=review.iconGroup.id == "empty" || review.iconGroup.id == "failed" ? .red : ["input","approval","interrupted","low"].contains(review.iconGroup.id) ? .orange : ["idle","freshness"].contains(review.iconGroup.id) ? .secondary : .mint
        return VStack(alignment:.leading,spacing:10) {
            HStack(spacing:12) {
                Image(systemName:preview.option.symbol).font(.system(size:28,weight:.medium)).foregroundStyle(tint).frame(width:44,height:40)
                VStack(alignment:.leading,spacing:3) {
                    Text("\(letter) · \(preview.option.label)").font(.system(size:14,weight:.semibold))
                    Text(preview.option.symbol).font(.system(size:11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(selected ? "已选 \(letter)" : "选择 \(letter)") { review.chooseIcon(preview.option) }.buttonStyle(.borderedProminent)
                    .tint(selected ? .green : .accentColor)
                    .accessibilityLabel("\(review.iconGroup.title)：\(selected ? "已选" : "选择") \(letter)，\(preview.option.label)")
            }
            PreviewIsland(model:preview.notch,open:false).frame(width:480).allowsHitTesting(false)
            PreviewIsland(model:preview.floating,open:false).frame(width:300).allowsHitTesting(false)
            if !review.iconGroup.isQuota, let activity=preview.floating.visibleActivities.first {
                TaskRowView(reviewSymbols:preview.floating.reviewSymbols,reviewSymbolOverride:preview.option.symbol,
                    attention:preview.floating.pendingInputRequests.first(where:{$0.activity.id == activity.id})?.kind,
                    activity:activity,name:"示例任务",now:review.now,enabled:true,unread:false,accent:.mint,action:{})
                    .frame(width:480).background(.black,in:RoundedRectangle(cornerRadius:10)).allowsHitTesting(false)
            }
        }.padding(14).background(RoundedRectangle(cornerRadius:12).stroke(selected ? Color.green : Color.white.opacity(0.12),lineWidth:selected ? 2 : 1))
    }
}
