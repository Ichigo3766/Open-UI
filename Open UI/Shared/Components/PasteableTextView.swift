import SwiftUI
import UIKit
import UniformTypeIdentifiers
import GameController

// MARK: - Pasteable Text View

/// A UITextView wrapper that intercepts paste operations to detect images and files
/// on the clipboard, converting them into `ChatAttachment` objects.
///
/// Standard SwiftUI `TextField` / `TextEditor` don't expose paste events,
/// so we drop to UIKit to override `paste(_:)` on a custom UITextView subclass.
struct PasteableTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: UIFont
    var placeholderFont: UIFont?
    var textColor: UIColor
    var placeholderColor: UIColor
    var tintColor: UIColor
    var isEnabled: Bool
    var onPasteAttachments: (([ChatAttachment]) -> Void)?
    var onSubmit: (() -> Void)?

    /// Called when the user types `#` at a word boundary. The parameter is
    /// the filter query text after the `#` (may be empty on initial trigger).
    var onHashTrigger: ((String) -> Void)?

    /// Called when the `#` context is dismissed (e.g., cursor moved away,
    /// backspace deleted the `#`, or whitespace ended the token).
    var onHashDismiss: (() -> Void)?

    /// Called when the user types `@` at a word boundary. The parameter is
    /// the filter query text after the `@` (may be empty on initial trigger).
    var onAtTrigger: ((String) -> Void)?

    /// Called when the `@` context is dismissed (e.g., cursor moved away,
    /// backspace deleted the `@`, or whitespace ended the token).
    var onAtDismiss: (() -> Void)?

    /// Called when the user types `/` at a word boundary. The parameter is
    /// the filter query text after the `/` (may be empty on initial trigger).
    var onSlashTrigger: ((String) -> Void)?

    /// Called when the `/` context is dismissed (e.g., cursor moved away,
    /// backspace deleted the `/`, or whitespace ended the token).
    var onSlashDismiss: (() -> Void)?

    /// Whether pressing Return sends the message (vs inserting a newline).
    var sendOnReturn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PasteInterceptingTextView {
        let textView = PasteInterceptingTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.backgroundColor = .clear
        // Start with scrolling OFF so the view sizes to its content.
        // We toggle it on in updateUIView when content exceeds max height.
        textView.isScrollEnabled = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)

        // Wire the paste callback
        textView.onPasteAttachments = { [weak textView] attachments in
            guard let textView else { return }
            // Dispatch to main to stay in sync with SwiftUI
            DispatchQueue.main.async {
                context.coordinator.parent.onPasteAttachments?(attachments)
                // Trigger a text update in case paste also included text
                context.coordinator.parent.text = textView.text
            }
        }

        textView.onReturnKey = {
            context.coordinator.parent.onSubmit?()
        }
        textView.sendOnReturn = sendOnReturn

        // Placeholder
        textView.placeholderLabel.text = placeholder
        textView.placeholderLabel.font = placeholderFont ?? font
        textView.placeholderLabel.textColor = placeholderColor
        textView.placeholderLabel.isHidden = !text.isEmpty

        return textView
    }

    func updateUIView(_ textView: PasteInterceptingTextView, context: Context) {
        // Only update text if it actually changed (avoids cursor jump)
        if textView.text != text {
            textView.text = text
        }
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.font = font
        textView.textColor = textColor
        textView.tintColor = tintColor
        textView.placeholderLabel.isHidden = !text.isEmpty
        textView.placeholderLabel.text = placeholder
        textView.placeholderLabel.font = placeholderFont ?? font
        textView.placeholderLabel.textColor = placeholderColor
        textView.sendOnReturn = sendOnReturn

        // Re-assign closures so they always capture the latest parent state.
        // Without this, stale closures from makeUIView are called when
        // onPasteAttachments or onSubmit capture different state.
        textView.onPasteAttachments = { [weak textView] attachments in
            guard let textView else { return }
            DispatchQueue.main.async {
                context.coordinator.parent.onPasteAttachments?(attachments)
                context.coordinator.parent.text = textView.text
            }
        }
        textView.onReturnKey = {
            context.coordinator.parent.onSubmit?()
        }

        // Recalculate sizing: toggle scroll when content exceeds max height
        PasteableTextView.recalculateHeight(textView)
    }

    /// Recalculates the text view height and toggles scrolling appropriately.
    /// When content fits, scrolling is OFF so intrinsicContentSize drives layout.
    /// When content overflows, scrolling is ON so the user can scroll within the fixed frame.
    static func recalculateHeight(_ textView: PasteInterceptingTextView) {
        let maxHeight = textView.maxContentHeight
        let fittingSize = textView.sizeThatFits(CGSize(
            width: textView.frame.width > 0 ? textView.frame.width : UIScreen.main.bounds.width - 100,
            height: .greatestFiniteMagnitude
        ))
        let shouldScroll = fittingSize.height > maxHeight
        if textView.isScrollEnabled != shouldScroll {
            textView.isScrollEnabled = shouldScroll
        }
        textView.invalidateIntrinsicContentSize()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteableTextView

        init(parent: PasteableTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            if let ptv = textView as? PasteInterceptingTextView {
                ptv.placeholderLabel.isHidden = !textView.text.isEmpty
                // Recalculate height as user types so the view grows/shrinks
                PasteableTextView.recalculateHeight(ptv)
            }

            // Detect `#` trigger for knowledge base picker
            detectHashTrigger(in: textView)

            // Detect `@` trigger for model mention picker
            detectAtTrigger(in: textView)

            // Detect `/` trigger for prompt library picker
            detectSlashTrigger(in: textView)
        }

        /// Scans backwards from the cursor to find a `#` token.
        ///
        /// Triggers `onHashTrigger` with the filter query (text after `#`)
        /// when the cursor is inside a `#word` token at a word boundary.
        /// Triggers `onHashDismiss` when the `#` context is lost.
        private func detectHashTrigger(in textView: UITextView) {
            guard parent.onHashTrigger != nil else { return }

            let text = textView.text ?? ""
            guard let selectedRange = textView.selectedTextRange else {
                parent.onHashDismiss?()
                return
            }

            let cursorOffset = textView.offset(from: textView.beginningOfDocument, to: selectedRange.start)
            let prefix = String(text.prefix(cursorOffset))

            // Find the last `#` that's at a word boundary (start of text, or preceded by whitespace)
            if let hashIndex = prefix.lastIndex(of: "#") {
                let hashPos = prefix.distance(from: prefix.startIndex, to: hashIndex)

                // Check word boundary: `#` must be at start or preceded by whitespace/newline
                let isAtStart = hashPos == 0
                let precededBySpace = hashPos > 0 && {
                    let beforeIdx = prefix.index(before: hashIndex)
                    let ch = prefix[beforeIdx]
                    return ch.isWhitespace || ch.isNewline
                }()

                if isAtStart || precededBySpace {
                    let afterHash = String(prefix[prefix.index(after: hashIndex)...])
                    // The query must not contain whitespace (it's a single token)
                    if !afterHash.contains(where: { $0.isWhitespace || $0.isNewline }) {
                        parent.onHashTrigger?(afterHash)
                        return
                    }
                }
            }

            parent.onHashDismiss?()
        }

        /// Scans backwards from the cursor to find an `@` token.
        ///
        /// Triggers `onAtTrigger` with the filter query (text after `@`)
        /// when the cursor is inside an `@word` token at a word boundary.
        /// Triggers `onAtDismiss` when the `@` context is lost.
        private func detectAtTrigger(in textView: UITextView) {
            guard parent.onAtTrigger != nil else { return }

            let text = textView.text ?? ""
            guard let selectedRange = textView.selectedTextRange else {
                parent.onAtDismiss?()
                return
            }

            let cursorOffset = textView.offset(from: textView.beginningOfDocument, to: selectedRange.start)
            let prefix = String(text.prefix(cursorOffset))

            // Find the last `@` that's at a word boundary (start of text, or preceded by whitespace)
            if let atIndex = prefix.lastIndex(of: "@") {
                let atPos = prefix.distance(from: prefix.startIndex, to: atIndex)

                // Check word boundary: `@` must be at start or preceded by whitespace/newline
                let isAtStart = atPos == 0
                let precededBySpace = atPos > 0 && {
                    let beforeIdx = prefix.index(before: atIndex)
                    let ch = prefix[beforeIdx]
                    return ch.isWhitespace || ch.isNewline
                }()

                if isAtStart || precededBySpace {
                    let afterAt = String(prefix[prefix.index(after: atIndex)...])
                    // The query must not contain whitespace (it's a single token)
                    if !afterAt.contains(where: { $0.isWhitespace || $0.isNewline }) {
                        parent.onAtTrigger?(afterAt)
                        return
                    }
                }
            }

            parent.onAtDismiss?()
        }

        /// Scans backwards from the cursor to find a `/` token.
        ///
        /// Triggers `onSlashTrigger` with the filter query (text after `/`)
        /// when the cursor is inside a `/word` token at a word boundary.
        /// Triggers `onSlashDismiss` when the `/` context is lost.
        ///
        /// This enables the slash command feature for the prompt library,
        /// following the same pattern as `#` (knowledge) and `@` (model) triggers.
        private func detectSlashTrigger(in textView: UITextView) {
            guard parent.onSlashTrigger != nil else { return }

            let text = textView.text ?? ""
            guard let selectedRange = textView.selectedTextRange else {
                parent.onSlashDismiss?()
                return
            }

            let cursorOffset = textView.offset(from: textView.beginningOfDocument, to: selectedRange.start)
            let prefix = String(text.prefix(cursorOffset))

            // Find the last `/` that's at a word boundary (start of text, or preceded by whitespace)
            if let slashIndex = prefix.lastIndex(of: "/") {
                let slashPos = prefix.distance(from: prefix.startIndex, to: slashIndex)

                // Check word boundary: `/` must be at start or preceded by whitespace/newline
                let isAtStart = slashPos == 0
                let precededBySpace = slashPos > 0 && {
                    let beforeIdx = prefix.index(before: slashIndex)
                    let ch = prefix[beforeIdx]
                    return ch.isWhitespace || ch.isNewline
                }()

                if isAtStart || precededBySpace {
                    let afterSlash = String(prefix[prefix.index(after: slashIndex)...])
                    // The query must not contain whitespace (it's a single token)
                    if !afterSlash.contains(where: { $0.isWhitespace || $0.isNewline }) {
                        parent.onSlashTrigger?(afterSlash)
                        return
                    }
                }
            }

            parent.onSlashDismiss?()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if let ptv = textView as? PasteInterceptingTextView {
                ptv.placeholderLabel.isHidden = !textView.text.isEmpty
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if let ptv = textView as? PasteInterceptingTextView {
                ptv.placeholderLabel.isHidden = !textView.text.isEmpty
            }
        }
    }
}

// MARK: - Paste-Intercepting UITextView

/// Custom UITextView subclass that overrides `paste(_:)` to detect images
/// and files on the system pasteboard before falling through to normal text paste.
final class PasteInterceptingTextView: UITextView {

    /// Called when pasted content contains images or files.
    var onPasteAttachments: (([ChatAttachment]) -> Void)?

    /// Called when the user presses Return and `sendOnReturn` is true.
    var onReturnKey: (() -> Void)?

    /// Whether Return key sends the message instead of inserting a newline.
    var sendOnReturn: Bool = true

    /// Tracks whether the Shift key is currently held on a hardware keyboard.
    private var isShiftHeld: Bool = false

    /// Placeholder label shown when the text view is empty.
    lazy var placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        return label
    }()

    /// Maximum content height (~8 lines).
    var maxContentHeight: CGFloat {
        (font?.lineHeight ?? 20) * 8 + textContainerInset.top + textContainerInset.bottom
    }

    /// Returns intrinsic size capped at maxContentHeight.
    /// When isScrollEnabled is false, UITextView reports its full content height
    /// as intrinsic — we cap it so the view never grows past 8 lines.
    override var intrinsicContentSize: CGSize {
        let fittingSize = sizeThatFits(CGSize(
            width: frame.width > 0 ? frame.width : UIScreen.main.bounds.width - 100,
            height: .greatestFiniteMagnitude
        ))
        let height = min(fittingSize.height, maxContentHeight)
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    // MARK: - Paste Override

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        var pastedAttachments: [ChatAttachment] = []

        // 1. Check for images (PNG, JPEG, TIFF, GIF, HEIC, WebP)
        if let images = pb.images, !images.isEmpty {
            for (index, image) in images.enumerated() {
                let data = resizedJPEGData(for: image)
                let attachment = ChatAttachment(
                    type: .image,
                    name: "Pasted_Image_\(Int(Date.now.timeIntervalSince1970))_\(index).jpg",
                    thumbnail: Image(uiImage: image),
                    data: data
                )
                pastedAttachments.append(attachment)
            }
        } else if pb.hasImages, let image = pb.image {
            // Single image fallback
            let data = resizedJPEGData(for: image)
            let attachment = ChatAttachment(
                type: .image,
                name: "Pasted_Image_\(Int(Date.now.timeIntervalSince1970)).jpg",
                thumbnail: Image(uiImage: image),
                data: data
            )
            pastedAttachments.append(attachment)
        }

        // 2. Check for file URLs (e.g., files copied from Files.app)
        if let urls = pb.urls {
            for url in urls where url.isFileURL {
                if let data = try? Data(contentsOf: url) {
                    let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
                    if isImage {
                        // Only add as image if we didn't already get it from pb.images
                        if pastedAttachments.isEmpty {
                            let thumbnail: Image? = UIImage(data: data).map { Image(uiImage: $0) }
                            let attachment = ChatAttachment(
                                type: .image,
                                name: url.lastPathComponent,
                                thumbnail: thumbnail,
                                data: data
                            )
                            pastedAttachments.append(attachment)
                        }
                    } else {
                        let attachment = ChatAttachment(
                            type: .file,
                            name: url.lastPathComponent,
                            thumbnail: nil,
                            data: data
                        )
                        pastedAttachments.append(attachment)
                    }
                }
            }
        }

        // 3. Check for raw image data in specific UTTypes (PNG/JPEG data without UIImage)
        if pastedAttachments.isEmpty {
            for typeId in [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier, UTType.tiff.identifier] {
                if let data = pb.data(forPasteboardType: typeId), let uiImage = UIImage(data: data) {
                    let attachment = ChatAttachment(
                        type: .image,
                        name: "Pasted_Image_\(Int(Date.now.timeIntervalSince1970)).jpg",
                        thumbnail: Image(uiImage: uiImage),
                        data: resizedJPEGData(for: uiImage)
                    )
                    pastedAttachments.append(attachment)
                    break // Only need one
                }
            }
        }

        // Deliver attachments if we found any
        if !pastedAttachments.isEmpty {
            onPasteAttachments?(pastedAttachments)

            // If the pasteboard ALSO has text, paste it normally
            if pb.hasStrings {
                super.paste(sender)
            }
            return
        }

        // No attachments detected — fall through to normal text paste
        super.paste(sender)
    }

    // MARK: - Hardware Keyboard Detection

    /// Returns true when a physical keyboard is connected to the device.
    private var isHardwareKeyboardConnected: Bool {
        GCKeyboard.coalesced != nil
    }

    // MARK: - Modifier Key Tracking

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key {
                if key.keyCode == .keyboardLeftShift || key.keyCode == .keyboardRightShift {
                    isShiftHeld = true
                }
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key {
                if key.keyCode == .keyboardLeftShift || key.keyCode == .keyboardRightShift {
                    isShiftHeld = false
                }
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key {
                if key.keyCode == .keyboardLeftShift || key.keyCode == .keyboardRightShift {
                    isShiftHeld = false
                }
            }
        }
        super.pressesCancelled(presses, with: event)
    }

    // MARK: - Return Key Handling

    override func insertText(_ text: String) {
        if text == "\n" && sendOnReturn {
            if isHardwareKeyboardConnected {
                // Hardware keyboard: Shift+Enter inserts a newline, bare Enter sends.
                if isShiftHeld {
                    super.insertText(text)
                } else {
                    onReturnKey?()
                }
            } else {
                // Software keyboard: honour the sendOnReturn preference (existing behaviour).
                onReturnKey?()
            }
            return
        }
        super.insertText(text)
    }

    // MARK: - Can Paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            // Always allow paste — we handle images, files, AND text
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: - Helpers

    /// Downsamples an image to ≤ 2 MP and encodes as JPEG.
    /// Delegates to `FileAttachmentService.downsampleForUpload` which
    /// guarantees the output stays under the API's 5 MB image limit.
    private func resizedJPEGData(for image: UIImage) -> Data? {
        let data = FileAttachmentService.downsampleForUpload(image: image)
        return data.isEmpty ? nil : data
    }
}
