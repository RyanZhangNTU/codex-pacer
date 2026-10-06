#!/usr/bin/env python3
"""Build an isolated native state-review gallery without changing shipped sources."""
import json, pathlib, plistlib, shutil, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
work = pathlib.Path(tempfile.mkdtemp(prefix='pacer-state-review.', dir='/private/tmp'))
shutil.copytree(root/'native', work/'native', ignore=shutil.ignore_patterns('.build', '.swiftpm'))
shutil.copytree(root/'scripts/native', work/'scripts/native')
main = work/'native/Sources/PacerIsland/PacerMain.swift'
main.unlink()
shutil.copy2(root/'scripts/demo/StateApprovalGallery.swift', main)
shutil.copy2(root/'scripts/demo/IconSelectionGallery.swift', main.parent/'IconSelectionGallery.swift')
(work/'native/Sources/PacerCore/ReviewRuntimeFixtures.swift').write_text("""import Foundation
public enum ReviewRuntimeFixtures {
    public static func activities(_ events: [[String: Any]]) -> [SessionActivity] {
        var state = RuntimeEventState(sourceID: nil, sourceName: nil)
        state.consume(["kind": "status", "connected": true, "attached": 1])
        state.consume(["kind": "runtimeBatch", "events": events])
        return state.activities
    }
}
""")
model = work/'native/Sources/PacerIsland/IslandModel.swift'
s = model.read_text().replace('    var headerStatus: String {', '    var reviewLabel: String?\n    var reviewSymbol: String?\n    var reviewTint: Color = .mint\n    var reviewHidesConnectionIcon = false\n    var reviewQuotaWarning = false\n    func reviewActivities(_ values: [SessionActivity]) {\n        completionInbox.observe(values, at: now, retention: completedRetention)\n        activities = values\n    }\n    var headerStatus: String {\n        if let reviewLabel { return reviewLabel }')
s=s.replace('    var headerSymbol: String {', '    var headerSymbol: String {\n        if let reviewSymbol { return reviewSymbol }')
s=s.replace('    var headerTint: Color {', '    var headerTint: Color {\n        if reviewSymbol != nil { return reviewTint }')
s=s.replace('    var quotaWarningSymbol: String? {', '    var quotaWarningSymbol: String? {\n        if reviewQuotaWarning { return (remaining ?? 100) <= 0 ? (reviewSymbols["empty"] ?? StatusSymbols.empty) : (reviewSymbols["low"] ?? StatusSymbols.low) }')
s=s.replace('    var reviewSymbol: String?', '    var reviewSymbols: [String: String] = [:]\n    var reviewRowOverride: String?\n    var reviewSymbol: String?')
s=s.replace('let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]\n            .appendingPathComponent("CodexPacerIsland/CurrentCycle", isDirectory: true)', 'let directory = URL(fileURLWithPath: "'+str(work/'cache')+'")')
model.write_text(s)
view=work/'native/Sources/PacerIsland/IslandView.swift'
s=view.read_text().replace('StatusSymbols.freshness', '(model.reviewSymbols["freshness"] ?? StatusSymbols.freshness)')
view.write_text(s)
pager=work/'native/Sources/PacerIsland/TaskPagerView.swift'
s=pager.read_text().replace('TaskRowView(attention:', 'TaskRowView(reviewSymbols: model.reviewSymbols, reviewSymbolOverride: model.reviewRowOverride, attention:')
pager.write_text(s)
row=work/'native/Sources/PacerIsland/TaskRowView.swift'
s=row.read_text().replace('    var attention:', '    var reviewSymbols: [String: String] = [:]\n    var reviewSymbolOverride: String? = nil\n    var attention:')
s=s.replace('    private var symbol: String {', '''    private var symbol: String {
        if let reviewSymbolOverride { return reviewSymbolOverride }
        let key: String
        if let attention { key = attention == .approval ? "approval" : "input" }
        else {
            switch phase {
            case .running: key = activity.stage == .tool ? "tool" : activity.stage == .thinking ? "thinking" : activity.stage == .responding ? "replying" : "starting"
            case .waitingForInput: key = activity.waitingForApproval ? "approval" : "input"
            case .completed: key = "complete"
            case .interrupted: key = activity.turnFailed ? "failed" : "interrupted"
            default: key = "idle"
            }
        }
        if let selected = reviewSymbols[key] { return selected }
        return
''')
row.write_text(s)
info=work/'native/Info.plist'; data=plistlib.loads(info.read_bytes())
data.update(CFBundleIdentifier='com.codexpacer.stateapproval.qa', CFBundleName='Pacer State Review', CFBundleDisplayName='Pacer State Review', CFBundleExecutable='PacerStateReview', LSUIElement=False, SUEnableAutomaticChecks=False)
receipts=root/'output/state-approval-2.2.0'; receipts.mkdir(parents=True, exist_ok=True)
data['StateReviewReceipt']=str(receipts/'approvals.json')
info.write_bytes(plistlib.dumps(data))
localization=work/'native/Sources/PacerCore/Localization.swift'
localization.write_text(localization.read_text().replace('public static let language = LanguagePreference.load().resolved()', 'public static var language: AppLanguage { LanguagePreference.load().resolved() }'))
app=work/'Pacer State Review.app'
subprocess.run(['bash', str(work/'scripts/native/build-island.sh'), str(app)], check=True)
binary=app/'Contents/MacOS/CodexPacerIsland'; binary.rename(app/'Contents/MacOS/PacerStateReview')
subprocess.run(['codesign','--force','--sign','-',str(app)], check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)], check=True)
receipt={'app':str(app),'work':str(work),'approvals':str(receipts/'approvals.json'),'isolation':'Synthetic models only; separate bundle/preferences/cache; no CLI, SSH, notifications or updater started.'}
(receipts/'build.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('STATE_REVIEW_APP='+str(app), flush=True)
