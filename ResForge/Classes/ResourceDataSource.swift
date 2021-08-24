import Cocoa
import RFSupport

class ResourceDataSource: NSObject, NSOutlineViewDelegate, NSOutlineViewDataSource, NSSplitViewDelegate {
    @IBOutlet var splitView: NSSplitView!
    @IBOutlet var typeList: NSOutlineView!
    @IBOutlet var scrollView: NSScrollView!
    @IBOutlet var outlineView: NSOutlineView!
    @IBOutlet var collectionView: NSCollectionView!
    @IBOutlet var outlineController: OutlineController!
    @IBOutlet var collectionController: CollectionController!
    @IBOutlet var attributesHolder: NSView!
    @IBOutlet var attributesDisplay: NSTextField!
    @IBOutlet weak var document: ResourceDocument!
    
    private(set) var useTypeList = UserDefaults.standard.bool(forKey: RFDefaults.showSidebar)
    private(set) var currentType: ResourceType?
    private var resourcesView: ResourcesView!
    
    override func awakeFromNib() {
        super.awakeFromNib()
        NotificationCenter.default.addObserver(self, selector: #selector(resourceTypeDidChange(_:)), name: .ResourceTypeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resourceDidUpdate(_:)), name: .DirectoryDidUpdateResource, object: document.directory)

        resourcesView = outlineController
        if useTypeList {
            // Attempt to select first type by default
            typeList.selectRowIndexes([1], byExtendingSelection: false)
        }
        self.updateSidebar()
    }
    
    @objc func resourceTypeDidChange(_ notification: Notification) {
        guard
            let document = document,
            let resource = notification.object as? Resource,
            resource.document === document
        else {
            return
        }
        self.reload(selecting: [resource], withUndo: false)
    }
    
    @objc func resourceDidUpdate(_ notification: Notification) {
        let resource = notification.userInfo!["resource"] as! Resource
        if !useTypeList || resource.type == resourcesView.selectedType() {
            if document.directory.filter.isEmpty {
                resourcesView.updated(resource: resource, oldIndex: notification.userInfo!["oldIndex"] as! Int, newIndex: notification.userInfo!["newIndex"] as! Int)
            } else {
                // If filter is active we need to refresh it
                self.updateFilter()
            }
        }
    }
    
    @IBAction func filter(_ sender: Any) {
        if let field = sender as? NSSearchField {
            self.updateFilter(field.stringValue)
        }
    }
    
    /// Reload the resources view, attempting to preserve the current selection.
    private func updateFilter(_ filter: String? = nil) {
        let selection = self.selectedResources()
        if let filter = filter {
            document.directory.filter = filter
        }
        resourcesView.reload()
        if selection.count != 0 {
            resourcesView.select(selection)
        }
        if self.selectionCount() == 0 {
            // No selection was made, we need to post a notification anyway
            NotificationCenter.default.post(name: .DocumentSelectionDidChange, object: document)
        }
    }
    
    func toggleBulkMode() {
        if currentType != nil, let bulk = BulkController(document: document) {
            let selected = self.selectedResources()
            resourcesView = bulk
            scrollView.documentView = bulk.outlineView
            resourcesView.select(selected)
            scrollView.window?.makeFirstResponder(scrollView.documentView)
        }
    }
    
    // MARK: - Resource management
    
    /// Reload the data source after performing a given operation. The resources returned from the operation will be selected.
    ///
    /// This function is important for managing undo operations when adding/removing resources. It creates an undo group and ensures that the data source is always reloaded after the operation is peformed, even when undoing/redoing.
    func reload(after operation: () -> [Resource]) {
        document.undoManager?.beginUndoGrouping()
        self.willReload()
        self.reload(selecting: operation())
        document.undoManager?.endUndoGrouping()
    }
    
    /// Register intent to reload the data source before performing changes.
    private func willReload(_ resources: [Resource] = []) {
        document.undoManager?.registerUndo(withTarget: self, handler: { $0.reload(selecting: resources) })
    }
    
    /// Reload the view and select the given resources.
    func reload(selecting resources: [Resource] = [], withUndo: Bool = true) {
        typeList.reloadData()
        if useTypeList, !document.directory.allTypes.isEmpty {
            // Select the first available type if nothing else selected (-1 becomes 1)
            let i = abs(typeList.row(forItem: resources.first?.type ?? currentType))
            typeList.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            resourcesView = outlineController
            currentType = nil
            resourcesView.reload()
            scrollView.documentView = outlineView
        }
        resourcesView.select(resources)
        if withUndo {
            document.undoManager?.registerUndo(withTarget: self, handler: { $0.willReload(resources) })
        }
    }
    
    /// Return the number of selected items.
    func selectionCount() -> Int {
        return resourcesView.selectionCount()
    }
    
    /// Return a flat list of all resources in the current selection, optionally including resources within selected type lists.
    func selectedResources(deep: Bool = false) -> [Resource] {
        return resourcesView.selectedResources(deep: deep)
    }
    
    /// Return the currently selected type.
    func selectedType() -> ResourceType? {
        return resourcesView.selectedType()
    }

    // MARK: - Sidebar functions
    
    func toggleSidebar() {
        useTypeList = !useTypeList
        self.updateSidebar()
        self.reload(selecting: self.selectedResources(), withUndo: false)
        UserDefaults.standard.set(useTypeList, forKey: RFDefaults.showSidebar)
    }
    
    private func updateSidebar() {
        if !useTypeList {
            attributesHolder.isHidden = true
        }
        outlineView.indentationPerLevel = useTypeList ? 0 : 1
        outlineView.tableColumns[0].width = useTypeList ? 60 : 70
        splitView.setPosition(useTypeList ? 110 : 0, ofDividerAt: 0)
    }
    
    // Prevent dragging the divider
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        return NSZeroRect
    }
    
    // Sidebar width should remain fixed
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        return splitView.subviews[1] === view
    }
    
    // Allow sidebar to collapse
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 2
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return splitView.subviews[0] === subview
    }
    
    // Hide divider when sidebar collapsed
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        return true
    }
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let view: NSTableCellView
        if let type = item as? ResourceType {
            let count = String(document.directory.resourcesByType[type]!.count)
            view = outlineView.makeView(withIdentifier: tableColumn!.identifier, owner: nil) as! NSTableCellView
            view.textField?.stringValue = type.code
            // Show a + indicator when the type has attributes
            (view.subviews[1] as? NSTextField)?.stringValue = type.attributes.isEmpty ? "" : "+"
            (view.subviews.last as? NSButton)?.title = count
        } else {
            view = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("HeaderCell"), owner: nil) as! NSTableCellView
        }
        if #available(OSX 11.0, *) {
            // Remove leading/trailing spacing on macOS 11
            for constraint in view.constraints {
                if constraint.firstAttribute == .leading || constraint.firstAttribute == .trailing {
                    constraint.constant = 0
                }
            }
        }
        return view
    }
    
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return document.directory.allTypes.count + 1
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if index == 0 {
            return "Types"
        } else {
            return document.directory.allTypes[index-1]
        }
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return false
    }
    
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        return !(item is ResourceType)
    }
    
    // Prevent deselection (using the allowsEmptySelection property results in undesirable selection changes)
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        return proposedSelectionIndexes.isEmpty || proposedSelectionIndexes == [0] ? outlineView.selectedRowIndexes : proposedSelectionIndexes
    }
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let type = typeList.selectedItem as! ResourceType
        // Check if type actually changed, rather than just being reselected after a reload
        if currentType != type {
            attributesHolder.isHidden = type.attributes.isEmpty
            attributesDisplay.stringValue = type.attributesDisplay
            if let provider = PluginRegistry.previewProviders[type.code] {
                let size = provider.previewSize(for: type.code)
                let layout = collectionView.collectionViewLayout as! NSCollectionViewFlowLayout
                layout.itemSize = NSSize(width: size+8, height: size+40)
                resourcesView = collectionController
                scrollView.documentView = collectionView
            } else {
                resourcesView = outlineController
                scrollView.documentView = outlineView
                outlineView.scrollToBeginningOfDocument(self)
            }
            currentType = type
            resourcesView.reload()
            // If the view changed we should make sure it is still first responder
            scrollView.window?.makeFirstResponder(scrollView.documentView)
            NotificationCenter.default.post(name: .DocumentSelectionDidChange, object: document)
        } else {
            resourcesView.reload()
        }
    }
}

// Prevent the source list from becoming first responder
class SourceList: NSOutlineView {
    override var acceptsFirstResponder: Bool { false }
}

// Pass badge click through to parent
class SourceCount: NSButton {
    override func mouseDown(with event: NSEvent) {
        self.superview?.mouseDown(with: event)
    }
}

// Common interface for the OutlineController and CollectionController
protocol ResourcesView {
    /// Reload the data in the view.
    func reload()
    
    /// Select the given resources.
    func select(_ resources: [Resource])
    
    /// Return the number of selected items.
    func selectionCount() -> Int
    
    /// Return a flat list of all resources in the current selection, optionally including resources within selected type lists.
    func selectedResources(deep: Bool) -> [Resource]
    
    /// Return the currently selcted type.
    func selectedType() -> ResourceType?
    
    /// Notify the view that a resource has been updated.
    func updated(resource: Resource, oldIndex: Int, newIndex: Int)
}
