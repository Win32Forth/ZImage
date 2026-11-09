import AppKit
import CoreGraphics

/// One photograph per page. The frame is the paper. Each photo is fitted inside the printable area.
final class PhotoPageView: NSView {
    private let images: [CGImage]

    init(images: [CGImage]) {
        self.images = images
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PhotoPageView is created in code")
    }

    /// AppKit asks for the page count and requires the frame to be one sheet of paper.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        let size = (NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared).paperSize
        setFrameSize(size)
        range.pointee = NSRange(location: 1, length: images.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let size = (NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared).paperSize
        return NSRect(origin: .zero, size: size)
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let operation = NSPrintOperation.current else { return }
        let page = operation.currentPage
        guard page >= 1, page <= images.count else { return }
        let cgImage = images[page - 1]
        guard cgImage.width > 0, cgImage.height > 0 else { return }
        let box = operation.printInfo.imageablePageBounds
        let fitted = Self.fitted(pixelWidth: cgImage.width, pixelHeight: cgImage.height, in: box)
        NSGraphicsContext.current?.imageInterpolation = .high
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }

    private static func fitted(pixelWidth: Int, pixelHeight: Int, in box: NSRect) -> NSRect {
        guard pixelWidth > 0, pixelHeight > 0, box.width > 1, box.height > 1 else { return box }
        let imageAspect = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        let boxAspect = box.width / box.height
        let size: NSSize
        if imageAspect > boxAspect {
            size = NSSize(width: box.width, height: box.width / imageAspect)
        } else {
            size = NSSize(width: box.height * imageAspect, height: box.height)
        }
        return NSRect(
            x: box.minX + (box.width - size.width) / 2,
            y: box.minY + (box.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

enum PhotoPrinter {
    /// Shows the system print panel. One photo per page. Cancel returns false.
    static func run(images: [CGImage], jobName: String) -> Bool {
        guard !images.isEmpty else { return false }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let operation = NSPrintOperation(view: PhotoPageView(images: images), printInfo: info)
        operation.jobTitle = jobName
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.canSpawnSeparateThread = false
        return operation.run()
    }
}
