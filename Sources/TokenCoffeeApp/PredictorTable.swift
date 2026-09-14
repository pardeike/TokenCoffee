import AppKit
import SwiftUI

/// A native table supplies insertion feedback and local-only, identity-based moves.
struct PredictorTable: NSViewRepresentable {
    let items: [Predictor]
    let selected: UUID?
    let canMove: Bool
    let subtitle: (Predictor) -> String
    let select: (UUID?) -> Void
    let move: (IndexSet, Int, UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("predictor"))
        column.width = 270
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 48
        table.intercellSpacing = .zero
        table.style = .inset
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes([Coordinator.pasteboardType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setAccessibilityIdentifier("management.predictors")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let subtitles = items.map(subtitle)
        let changed = coordinator.parent.items != items || coordinator.displayedSubtitles != subtitles
        coordinator.parent = self
        coordinator.displayedSubtitles = subtitles
        coordinator.updating = true
        if changed || coordinator.table?.numberOfRows != items.count { coordinator.table?.reloadData() }
        coordinator.restoreSelection()
        coordinator.updating = false
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let pasteboardType = NSPasteboard.PasteboardType("com.pardeike.TokenCoffee.predictor-order")
        var parent: PredictorTable
        weak var table: NSTableView?
        var updating = false
        var displayedSubtitles: [String] = []
        init(_ parent: PredictorTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.items.indices.contains(row) else { return nil }
            let item = parent.items[row]
            let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("predictorCell"), owner: self)
                as? PredictorCell) ?? PredictorCell()
            cell.textField?.stringValue = item.name
            cell.subtitle.stringValue = parent.subtitle(item)
            cell.swatch.layer?.backgroundColor = NSColor(item.color.value).cgColor
            cell.setAccessibilityIdentifier("predictor.row." + item.id.uuidString)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let id = parent.items.indices.contains(table.selectedRow) ? parent.items[table.selectedRow].id : nil
            guard id != parent.selected else { return }
            // Keep the old selection until an unsaved-edits decision has completed.
            updating = true
            restoreSelection()
            updating = false
            parent.select(id)
        }

        func restoreSelection() {
            let index = parent.items.firstIndex { $0.id == parent.selected }
            table?.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.canMove, parent.items.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            item.setString(parent.items[row].id.uuidString, forType: Self.pasteboardType)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.canMove, let source = info.draggingSource as? NSTableView, source === tableView,
                  (0...parent.items.count).contains(row) else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard parent.canMove, let source = info.draggingSource as? NSTableView, source === tableView,
                  let raw = info.draggingPasteboard.string(forType: Self.pasteboardType), let id = UUID(uuidString: raw),
                  let index = parent.items.firstIndex(where: { $0.id == id }), (0...parent.items.count).contains(row) else { return false }
            parent.move(IndexSet(integer: index), row, id)
            return true
        }
    }
}

private final class PredictorCell: NSTableCellView {
    let subtitle = NSTextField(labelWithString: "")
    let swatch = NSView()

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("predictorCell")
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 12)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        subtitle.maximumNumberOfLines = 1
        textField = title
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4.5
        [swatch, title, subtitle].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 9), swatch.heightAnchor.constraint(equalToConstant: 9),
            title.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
