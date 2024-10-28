import AppKit
import RFSupport

class StellarView: NSView {
    let resource: Resource
    let manager: RFEditorManager
    let isEnabled: Bool
    private(set) var position = NSPoint.zero
    private(set) var image: NSImage? = nil
    private var attributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11)]
    }
    private var systemView: SystemMapView? {
        superview as? SystemMapView
    }
    var point = NSPoint.zero {
        didSet {
            frame.origin.x = point.x - frame.size.width / 2
            frame.origin.y = point.y - frame.size.height / 2
        }
    }
    var isHighlighted = false {
        didSet {
            if oldValue != isHighlighted {
                needsDisplay = true
            }
        }
    }
    var highlightCount = 1 {
        didSet {
            if oldValue != highlightCount {
                needsDisplay = true
            }
        }
    }

    init?(_ stellar: Resource, manager: RFEditorManager, isEnabled: Bool) {
        self.resource = stellar
        self.manager = manager
        self.isEnabled = isEnabled
        super.init(frame: .zero)
        do {
            try self.read()
        } catch {
            return nil
        }
    }

    func read() throws {
        let reader = BinaryDataReader(resource.data)
        position.x = Double(try reader.read() as Int16)
        position.y = Double(try reader.read() as Int16)

        let spinId = (Int)(try reader.read() as Int16) + 1000;
        if let spinResource = manager.findResource(type: ResourceType("spïn"), id: spinId, currentDocumentOnly: false) {
            let spinReader = BinaryDataReader(spinResource.data)
            let spriteId = (Int)(try spinReader.read() as Int16);

            // Use the preview provider to obtain an NSImage from the resources the spïn might point to -- try PICT then fall back to rlëD
            if let spriteResource = manager.findResource(type: ResourceType("PICT"), id: spriteId, currentDocumentOnly: false) ?? manager.findResource(type: ResourceType("rlëD"), id: spriteId, currentDocumentOnly: false) {
                spriteResource.preview({ img in
                    self.image = img
                    self.updateFrame()
                    self.needsDisplay = true
                })
            }
        }
    }

    override func updateTrackingAreas() {
        for trackingArea in self.trackingAreas {
            self.removeTrackingArea(trackingArea)
        }
        let tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        self.addTrackingArea(tracking)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateFrame() {
        if image != nil, let imageSize = systemView?.transform.transform(image!.size) {
            frame.size.width = imageSize.width
            frame.size.height = imageSize.height
        } else {
            frame.size.width = 12
            frame.size.height = 12
        }

        if let point = systemView?.transform.transform(position) {
            self.point = point
        }
    }

    func move(to newPos: NSPoint) {
        let curPos = position
        position = NSPoint(x: newPos.x.rounded(), y: newPos.y.rounded())
        self.updateFrame()
        self.save()
        undoManager?.registerUndo(withTarget: self) { $0.move(to: curPos) }
    }

    private func save() {
        guard resource.data.count >= 2 * 2 else {
            return
        }
        let writer = BinaryDataWriter()
        writer.data = resource.data
        writer.write(Int16(position.x), at: 0)
        writer.write(Int16(position.y), at: 2)
        systemView?.isSavingStellar = true
        resource.data = writer.data
        systemView?.isSavingStellar = false
        systemView?.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard dirtyRect.intersects(bounds) else {
            return
        }

        if image != nil {
            let imageSize = systemView?.transform.transform(image!.size) ?? image!.size
            let imageOrigin = NSPoint(x: frame.size.width / 2 - imageSize.width / 2, y: frame.size.height / 2 - imageSize.height / 2)
            image!.draw(in: NSRect(origin: imageOrigin, size: imageSize))
        } else {
            NSColor.black.setFill()
            if isEnabled {
                NSColor.blue.setStroke()
            } else {
                NSColor.gray.setStroke()
            }
            let circle = NSRect(x: 2, y: 2, width: 8, height: 8)
            let path = NSBezierPath(ovalIn: circle)
            path.fill()
            path.stroke()
        }

        if isHighlighted {
            // Highlight background
            NSColor.selectedContentBackgroundColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            outline.lineWidth = 3
            outline.stroke()
        }
    }

    // MARK: - Mouse events

    private var useRightMouse = false

    override func mouseDown(with event: NSEvent) {
        if isEnabled {
            useRightMouse = event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option)
            if useRightMouse {
                systemView?.rightMouseDown(stellar: self, with: event)
            } else {
                systemView?.mouseDown(stellar: self, with: event)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isEnabled {
            if useRightMouse {
                systemView?.rightMouseDragged(stellar: self, with: event)
            } else {
                systemView?.mouseDragged(stellar: self, with: event)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isEnabled {
            if useRightMouse {
                systemView?.rightMouseUp(stellar: self, with: event)
            } else {
                systemView?.mouseUp(stellar: self, with: event)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if isEnabled {
            window?.makeKeyAndOrderFront(self)
            systemView?.rightMouseDown(stellar: self, with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if isEnabled {
            systemView?.rightMouseDragged(stellar: self, with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if isEnabled {
            systemView?.rightMouseUp(stellar: self, with: event)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        systemView?.mouseEntered(stellar: self, with: event)
    }

    override func mouseExited(with event: NSEvent) {
        systemView?.mouseExited(stellar: self, with: event)
    }
}