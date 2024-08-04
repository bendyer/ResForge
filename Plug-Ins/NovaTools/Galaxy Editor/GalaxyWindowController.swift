import AppKit
import RFSupport
import OrderedCollections

class GalaxyWindowController: AbstractEditor, ResourceEditor {
    static let supportedTypes = ["glxÿ"]
    let resource: Resource
    let manager: RFEditorManager

    @IBOutlet var systemTable: NSTableView!
    @IBOutlet var galaxyView: GalaxyView!
    private(set) var systemViews: OrderedDictionary<Int, SystemView> = [:]
    private(set) var nebulae: [Int: (name: String, area: NSRect)] = [:]
    private(set) var nebImages: [Int: NSImage] = [:]
    private var systemList: [Resource] = []
    private var isSelectingSystems = false

    required init(resource: Resource, manager: RFEditorManager) {
        self.resource = resource
        self.manager = manager
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func saveResource(_ sender: Any) {}
    func revertResource(_ sender: Any) {}
}

extension GalaxyWindowController {
    override var windowNibName: String {
        "GalaxyWindow"
    }
    var windowTitle: String {
        "Galaxy Map"
    }

    override func windowDidLoad() {
        NotificationCenter.default.addObserver(self, selector: #selector(resourceListChanged(_:)), name: .DocumentDidAddResources, object: manager.document)
        NotificationCenter.default.addObserver(self, selector: #selector(resourceListChanged(_:)), name: .DocumentDidRemoveResources, object: manager.document)
        NotificationCenter.default.addObserver(self, selector: #selector(resourceIDChanged(_:)), name: .ResourceIDDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resourceNameChanged(_:)), name: .ResourceNameDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resourceDataChanged(_:)), name: .ResourceDataDidChange, object: nil)

        // Workaround a bug in interface builder that prevents setting the column width correctly
        systemTable.tableColumns[1].width = systemTable.frame.width - 2 - systemTable.tableColumns[0].width - systemTable.intercellSpacing.width

        // Scroll to galaxy center
        if var documentRect = galaxyView.enclosingScrollView?.documentVisibleRect {
            documentRect.origin.y *= -1 // Workaround an issue where the clip view is initially misplaced
            galaxyView.scroll(NSPoint(x: galaxyView.frame.midX - documentRect.midX, y: galaxyView.frame.midY - documentRect.midY))
        }

        self.reload()
    }

    private func reload() {
        systemViews = [:]
        nebulae = [:]
        nebImages = [:]

        let systs = manager.allResources(ofType: ResourceType("sÿst"), currentDocumentOnly: false)
        for system in systs {
            if systemViews[system.id] == nil {
                self.read(system: system)
            }
        }

        let nebus = manager.allResources(ofType: ResourceType("nëbu"), currentDocumentOnly: false)
        for nebula in nebus {
            if nebulae[nebula.id] == nil {
                self.read(nebula: nebula)
            }
        }

        self.updateSystemList()
    }

    private func updateSystemList() {
        // Reverse list so first draws on top
        galaxyView.subviews = Array(systemViews.values).reversed()
        systemList = manager.allResources(ofType: ResourceType("sÿst"), currentDocumentOnly: true)
        systemTable.reloadData()
    }

    private func read(system: Resource) {
        if let view = systemViews[system.id] {
            try? view.read()
        } else if let view = SystemView(system, isEnabled: system.document == manager.document) {
            systemViews[system.id] = view
        }
    }

    private func read(nebula: Resource) {
        let reader = BinaryDataReader(nebula.data)
        do {
            let rect = NSRect(
                x: Double(try reader.read() as Int16),
                y: Double(try reader.read() as Int16),
                width: Double(try reader.read() as Int16),
                height: Double(try reader.read() as Int16)
            )
            nebulae[nebula.id] = (nebula.name, rect)
        } catch {}

        if nebImages[nebula.id] == nil {
            // Find the largest available image
            let first = (nebula.id - 128) * 7 + 9500
            for id in (first..<first+7).reversed() {
                if let pict = manager.findResource(type: ResourceType("PICT"), id: id, currentDocumentOnly: false) {
                    pict.preview {
                        self.nebImages[nebula.id] = $0
                        self.galaxyView.needsDisplay = true
                    }
                    break
                }
            }
        }
    }

    @IBAction func zoomIn(_ sender: Any) {
        galaxyView.zoomIn(sender)
    }

    @IBAction func zoomOut(_ sender: Any) {
        galaxyView.zoomOut(sender)
    }

    // MARK: - Notifications

    @objc func resourceListChanged(_ notification: Notification) {
        guard let resources = notification.userInfo?["resources"] as? [Resource] else {
            return
        }
        let shouldReload = resources.contains {
            !$0.data.isEmpty && ($0.typeCode == "sÿst" || $0.typeCode == "nëbu")
        }
        if shouldReload {
            self.reload()
        }
    }

    @objc func resourceIDChanged(_ notification: Notification) {
        guard let resource = notification.object as? Resource else {
            return
        }
        if resource.typeCode == "sÿst" || resource.typeCode == "nëbu" {
            self.reload()
        }
    }

    @objc func resourceNameChanged(_ notification: Notification) {
        guard let resource = notification.object as? Resource else {
            return
        }
        if resource.typeCode == "sÿst" {
            systemViews[resource.id]?.updateFrame()
            if let idx = systemList.firstIndex(of: resource) {
                systemTable.reloadData(forRowIndexes: [idx + 1], columnIndexes: [1])
            }
        } else if resource.typeCode == "nëbu" {
            galaxyView.needsDisplay = true
        }
    }

    @objc func resourceDataChanged(_ notification: Notification) {
        guard let resource = notification.object as? Resource else {
            return
        }
        if resource.typeCode == "sÿst" {
            self.read(system: resource)
            self.updateSystemList()
            self.syncSelectionFromView()
        } else if resource.typeCode == "nëbu" {
            self.read(nebula: resource)
            galaxyView.needsDisplay = true
        }
    }
}

extension GalaxyWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        systemList.count + 1
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        row == 0
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row != 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("HeaderCell")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as! NSTableCellView
        if let tableColumn {
            let system = systemList[row - 1]
            switch tableColumn.identifier.rawValue {
            case "id":
                view.textField?.stringValue = "\(system.id)"
            case "name":
                view.textField?.stringValue = system.name
            default:
                break
            }
        } else {
            view.textField?.stringValue = manager.document?.displayName ?? ""
        }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingSystems else {
            return
        }
        self.syncSelectionToView()
        galaxyView.restackSystems()

        // Scroll to last selected system, unless selected all
        if systemTable.selectedRow > 0 && systemTable.selectedRowIndexes.count < systemList.count {
            let system = systemList[systemTable.selectedRow - 1]
            if let view = systemViews[system.id] {
                view.scrollToVisible(view.bounds.insetBy(dx: -4, dy: -4))
            }
        }
    }

    func syncSelectionToView() {
        for (i, system) in systemList.enumerated() {
            systemViews[system.id]?.isHighlighted = systemTable.isRowSelected(i + 1)
        }
    }

    func syncSelectionFromView(clicked: SystemView? = nil) {
        var scrollRow: Int?
        var indexes = IndexSet()
        for (i, system) in systemList.enumerated() {
            if let view = systemViews[system.id], view.isHighlighted {
                indexes.insert(i + 1)
                if view == clicked {
                    scrollRow = i + 1
                }
            }
        }
        isSelectingSystems = true
        systemTable.selectRowIndexes(indexes, byExtendingSelection: false)
        isSelectingSystems = false
        if let scrollRow {
            systemTable.scrollRowToVisible(scrollRow)
        }
    }

    @IBAction func doubleClickSystem(_ sender: Any) {
        guard systemTable.clickedRow != 0 else {
            return
        }
        for i in systemTable.selectedRowIndexes {
            manager.open(resource: systemList[i - 1])
        }
    }
}
