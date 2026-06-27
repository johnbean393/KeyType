import AutocompleteCore
import ApplicationServices
import CoreGraphics

struct CapturedCaretGeometry: Equatable {
    var rect: CGRect?
    var source: String?
    var quality: CaretGeometryQuality

    init(rect: CGRect?, source: String?, quality: CaretGeometryQuality) {
        self.rect = rect
        self.source = source
        self.quality = quality
    }

    init(_ result: AXCaretGeometryResult?) {
        self.init(
            rect: result?.rect,
            source: result?.source,
            quality: FocusedFieldReader.caretQuality(from: result?.qualityLabel)
        )
    }
}

protocol AppCaretGeometryFallback {
    static func caretGeometry(
        target: AppTarget,
        beforeCursor: String,
        afterCursor: String,
        element: AXUIElement?,
        fieldRect: CGRect?,
        current: CapturedCaretGeometry
    ) -> CapturedCaretGeometry?
}
