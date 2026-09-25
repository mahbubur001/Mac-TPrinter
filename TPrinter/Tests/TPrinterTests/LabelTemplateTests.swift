import Foundation
import Testing
@testable import TPrinter

struct LabelTemplateTests {
    @Test func roundTripsEveryField() throws {
        var document = LabelDocument()
        document.widthMM = 40
        document.copies = 3
        document.printMethod = .nativeTSPL
        document.elements[0].content = "Quote \" and ünïcode"
        document.elements[1].barcodeModuleDots = 2
        #expect(try LabelTemplate.decode(LabelTemplate.encode(document)) == document)
    }

    @Test func fileIsVersionedJSON() throws {
        let object = try JSONSerialization.jsonObject(with: LabelTemplate.encode(LabelDocument())) as? [String: Any]
        #expect(object?["format"] as? String == "tprinter-label")
        #expect(object?["version"] as? Int == 1)
        #expect(object?["label"] is [String: Any])
    }

    @Test func missingFieldsFallBackToDefaults() throws {
        let json = #"{"format":"tprinter-label","version":1,"label":{"widthMM":40,"elements":[{"kind":"text","content":"Hi"}]}}"#
        let document = try LabelTemplate.decode(Data(json.utf8))
        #expect(document.widthMM == 40)
        #expect(document.heightMM == LabelDocument().heightMM)
        #expect(document.elements.count == 1)
        #expect(document.elements[0].content == "Hi")
        #expect(document.elements[0].fontSizeMM == LabelElement.make(.text).fontSizeMM)
    }

    @Test func rejectsOtherJSONAndNewerVersions() {
        #expect(throws: LabelTemplate.TemplateError.self) { try LabelTemplate.decode(Data(#"{"widthMM":30}"#.utf8)) }
        #expect(throws: LabelTemplate.TemplateError.self) {
            try LabelTemplate.decode(Data(#"{"format":"tprinter-label","version":99,"label":{}}"#.utf8))
        }
    }
}

@MainActor
struct LabelSessionTests {
    private func makeSession() -> (LabelSession, UserDefaults) {
        let defaults = UserDefaults(suiteName: "TPrinterTests-\(UUID())")!
        return (LabelSession(defaults: defaults), defaults)
    }

    @Test func editingMarksDirtyAndSavingClearsIt() throws {
        let (session, _) = makeSession()
        #expect(!session.isDirty)
        session.document.copies = 5
        #expect(session.isDirty)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tprlabel")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(session.write(to: url))
        #expect(!session.isDirty)
        #expect(session.fileURL == url)
        #expect(session.displayName == url.deletingPathExtension().lastPathComponent)
        #expect(session.recentURLs.first == url)
    }

    @Test func loadingReplacesDocumentWithoutMarkingDirty() throws {
        let (session, _) = makeSession()
        var saved = LabelDocument()
        saved.widthMM = 55
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tprlabel")
        defer { try? FileManager.default.removeItem(at: url) }
        try LabelTemplate.encode(saved).write(to: url)

        let generation = session.generation
        session.load(url)
        #expect(session.document.widthMM == 55)
        #expect(!session.isDirty)
        #expect(session.generation == generation + 1)
    }

    @Test func workingCopyAndEditedStateSurviveRelaunch() {
        let (session, defaults) = makeSession()
        session.document.widthMM = 44
        let relaunched = LabelSession(defaults: defaults)
        #expect(relaunched.document.widthMM == 44)
        #expect(relaunched.isDirty)
    }

    @Test func badFileReportsErrorAndKeepsDocument() throws {
        let (session, _) = makeSession()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tprlabel")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let before = session.document
        session.load(url)
        #expect(session.errorMessage != nil)
        #expect(session.document == before)
    }
}

@MainActor
struct UndoTests {
    /// Session with a manual clock. Event grouping is off (no AppKit run loop in tests); the session
    /// opens its own group per undo step, which is what makes this work without one.
    private func makeSession() -> (LabelSession, UndoManager, (TimeInterval) -> Void) {
        let session = LabelSession(defaults: UserDefaults(suiteName: "TPrinterUndoTests-\(UUID())")!)
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        var clock = Date(timeIntervalSince1970: 1_000)
        session.now = { clock }
        return (session, undo, { clock.addTimeInterval($0) })
    }

    private func step(_ undo: UndoManager, _ change: () -> Void) {
        change()
        #expect(undo.groupingLevel == 0)
    }

    @Test func undoAndRedoRestoreTheDocument() {
        let (session, undo, advance) = makeSession()
        let original = session.document
        step(undo) { session.perform("Move") { $0.elements[0].x = 9 } }
        advance(5)
        #expect(undo.undoActionName == "Move")

        undo.undo()
        #expect(session.document == original)
        undo.redo()
        #expect(session.document.elements[0].x == 9)
    }

    @Test func rapidSameNamedChangesCoalesceIntoOneStep() {
        let (session, undo, advance) = makeSession()
        let original = session.document
        for x in [2.0, 2.5, 3.0] {
            step(undo) { session.perform("Move") { $0.elements[0].x = x } }
            advance(0.2)
        }
        undo.undo()
        #expect(session.document == original, "three quick nudges undo as one")
        #expect(!undo.canUndo)
    }

    @Test func pausesAndDifferentActionsAreSeparateSteps() {
        let (session, undo, advance) = makeSession()
        step(undo) { session.perform("Move") { $0.elements[0].x = 2 } }
        advance(5)
        step(undo) { session.perform("Move") { $0.elements[0].x = 4 } }
        advance(0.1)
        step(undo) { session.perform("Delete Element") { $0.elements.removeLast() } }

        undo.undo()
        #expect(session.document.elements.count == 3)
        #expect(session.document.elements[0].x == 4)
        undo.undo()
        #expect(session.document.elements[0].x == 2)
    }

    @Test func undoingBackToSavedStateClearsEdited() throws {
        let (session, undo, advance) = makeSession()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tprlabel")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(session.write(to: url))

        step(undo) { session.perform("Move") { $0.elements[0].x = 7 } }
        advance(5)
        #expect(session.isDirty)
        undo.undo()
        #expect(!session.isDirty)
    }

    @Test func openingATemplateClearsUndoHistory() throws {
        let (session, undo, _) = makeSession()
        step(undo) { session.perform("Move") { $0.elements[0].x = 7 } }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tprlabel")
        defer { try? FileManager.default.removeItem(at: url) }
        try LabelTemplate.encode(LabelDocument()).write(to: url)
        session.load(url)
        #expect(!undo.canUndo)
    }
}

struct NudgeTests {
    @Test func stepSizes() {
        #expect(ElementDragMath.nudgeStepMM(shift: false, option: false) == 0.5)
        #expect(ElementDragMath.nudgeStepMM(shift: true, option: false) == 5)
        #expect(ElementDragMath.nudgeStepMM(shift: false, option: true) == 0.125)
    }

    @Test func nudgeMovesExactlyOneStepAndStaysOnLabel() {
        let label = CGSize(width: 30, height: 15), size = CGSize(width: 10, height: 5)
        // Off-grid start keeps its fraction (no snapping on nudge).
        #expect(ElementDragMath.nudged(CGPoint(x: 1.3, y: 2), dx: 1, dy: 0, stepMM: 0.5, sizeMM: size, labelMM: label).x == 1.8)
        #expect(ElementDragMath.nudged(CGPoint(x: 0.2, y: 2), dx: -1, dy: 0, stepMM: 5, sizeMM: size, labelMM: label).x == 0)
        #expect(ElementDragMath.nudged(CGPoint(x: 5, y: 9.8), dx: 0, dy: 1, stepMM: 5, sizeMM: size, labelMM: label).y == 10)
    }
}

@MainActor
struct DashboardTests {
    private func session() -> LabelSession { LabelSession(defaults: UserDefaults(suiteName: "TPrinterDash-\(UUID())")!) }

    @Test func appStartsOnTheDashboard() {
        #expect(session().showsDashboard)
    }

    @Test func newLabelAtAPresetSizeIsBlankAndOpensTheEditor() {
        let s = session()
        s.newDocument(size: CGSize(width: 50, height: 30))
        #expect(!s.showsDashboard)
        #expect(s.document.widthMM == 50 && s.document.heightMM == 30)
        #expect(s.document.elements.isEmpty)
        #expect(!s.isDirty)
    }

    @Test func openingATemplateLeavesTheDashboard() throws {
        let s = session()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).tprlabel")
        defer { try? FileManager.default.removeItem(at: url) }
        try LabelTemplate.encode(LabelDocument()).write(to: url)
        s.load(url)
        #expect(!s.showsDashboard)
        s.showsDashboard = true
        s.open(url) // same, unchanged file: just returns to the editor
        #expect(!s.showsDashboard)
    }

    @Test func continueEditingKeepsTheCurrentLabel() {
        let s = session()
        s.document.copies = 4
        s.continueEditing()
        #expect(!s.showsDashboard)
        #expect(s.document.copies == 4)
    }
}
