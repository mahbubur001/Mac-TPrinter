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
            record(name: name, document: document, labels: copies, printer: printerName, error: error, batch: false)
            completion?(error)
        }
    }

    /// Records a finished batch (the batch model runs the queue itself so it can fill each row).
    func recordBatch(name: String, template: LabelDocument, labels: Int, printed: Int, error: String?) {
        record(name: name, document: template, labels: error == nil ? labels : printed, printer: printerName,
               error: error, batch: true)
    }

    private func record(name: String, document: LabelDocument, labels: Int, printer: String, error: String?, batch: Bool) {
        let result: PrintRecord.Result = error == nil ? .printed : (error == "stopped" ? .stopped : .failed)
        history.add(PrintRecord(date: Date(), templateName: name, labels: labels * document.arrangement.cellCount,
                                mediaName: document.mediaTitle, printer: printer, result: result,
                                detail: error == "stopped" ? "" : (error ?? ""), wasBatch: batch,
                                template: try? LabelTemplate.encode(document)))
        let count = labels * document.arrangement.cellCount
        switch result {
        case .printed:
            notices.post(.success, batch ? "Batch “\(name)” finished" : "Printed “\(name)”",
                         "\(count) label\(count == 1 ? "" : "s") on \(printer)", topic: .prints)
        case .stopped:
            notices.post(.warning, "Printing “\(name)” stopped", "\(count) label\(count == 1 ? "" : "s") printed before stopping", topic: .prints)
        case .failed:
            notices.post(.problem, "Couldn't print “\(name)”", error ?? "", topic: .prints)
        }
    }
}
