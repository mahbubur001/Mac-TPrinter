import Foundation

/// The one place labels are printed from (editor, dashboard, history, batch), so every job lands in
/// the history and posts a notification. Utility jobs (test print, alignment, calibration) go
/// straight to the printer and aren't recorded.
@MainActor
final class PrintCenter: ObservableObject {
    let printer: PrinterBluetoothManager
    let history: PrintHistory
    let notices: NoticeCenter

    init(printer: PrinterBluetoothManager, history: PrintHistory, notices: NoticeCenter) {
        self.printer = printer
        self.history = history
        self.notices = notices
    }

    var canPrint: Bool { printer.connection.isReady && !printer.isSending && !printer.isQueueRunning }

    private var printerName: String {
        if case .ready(let name) = printer.connection { return name }
        return "Printer"
    }

    /// Prints `document.copies` labels, one job each (the RP310 misplaces labels in multi-label jobs).
    func printLabel(_ document: LabelDocument, name: String, completion: ((String?) -> Void)? = nil) {
        let copies = max(document.copies, 1)
        let printerName = printerName
        printer.sendQueue(count: copies) { index in
            try LabelPrintService.job(for: document.advancingCounters(by: index))
        } completion: { [weak self] error in
            guard let self else { return }
            record(name: name, document: document, labels: error == nil ? copies : printer.lastQueueDone, total: copies,
                   printer: printerName, error: error, kind: .single)
            completion?(error)
        }
    }

    /// Prints `count` labels made on demand (PDF pages …), one job each, recorded as one batch.
    /// `makeDocument(i)` builds label i just before it's sent.
    func printLabels(count: Int, name: String, sample: LabelDocument, kind: PrintRecord.Kind = .batch,
                     makeDocument: @escaping (Int) throws -> LabelDocument,
                     completion: ((Int, String?) -> Void)? = nil) {
        let printerName = printerName
        printer.sendQueue(count: count) { index in
            try LabelPrintService.job(for: makeDocument(index))
        } completion: { [weak self] error in
            guard let self else { return }
            let printed = printer.lastQueueDone
            record(name: name, document: sample, labels: error == nil ? count : printed, total: count,
                   printer: printerName, error: error, kind: kind)
            completion?(printed, error)
        }
    }

    /// Records a finished batch (the batch model runs the queue itself so it can fill each row).
    func recordBatch(name: String, template: LabelDocument, labels: Int, printed: Int, error: String?) {
        record(name: name, document: template, labels: error == nil ? labels : printed, total: labels,
               printer: printerName, error: error, kind: .batch)
    }

    /// - Parameters: labels: jobs that printed; total: jobs asked for.
    private func record(name: String, document: LabelDocument, labels: Int, total: Int, printer: String, error: String?,
                        kind: PrintRecord.Kind) {
        let batch = kind != .single
        let result: PrintRecord.Result = error == nil ? .printed : (error == "stopped" ? .stopped : .failed)
        // Labels, not jobs: a row of a multi-label arrangement is one job.
        let stopped = PrinterBluetoothManager.stoppedText(after: labels * document.arrangement.cellCount,
                                                          of: total * document.arrangement.cellCount)
        history.add(PrintRecord(date: Date(), templateName: name, labels: labels * document.arrangement.cellCount,
                                mediaName: document.mediaTitle, printer: printer, result: result,
                                detail: error == "stopped" ? stopped : (error ?? ""), wasBatch: batch,
                                template: try? LabelTemplate.encode(document), kind: kind))
        let count = labels * document.arrangement.cellCount
        switch result {
        case .printed:
            notices.post(.success, batch ? "Batch “\(name)” finished" : "Printed “\(name)”",
                         "\(count) label\(count == 1 ? "" : "s") on \(printer)", topic: .prints)
        case .stopped:
            notices.post(.warning, "Printing “\(name)” stopped", stopped, topic: .prints)
        case .failed:
            notices.post(.problem, "Couldn't print “\(name)”", error ?? "", topic: .prints)
        }
    }
}
