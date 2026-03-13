import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - UITextView subclass

final class PasteTextView: UITextView {
    var onPasteNonText: (() -> Void)?

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.textColor = .tertiaryLabel
        label.font = UIFont.preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var placeholder: String = "" {
        didSet {
            placeholderLabel.text = placeholder
        }
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            let pb = UIPasteboard.general
            if pb.hasImages || pb.types.contains(UTType.fileURL.identifier) {
                return true
            }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        let hasNonText = pb.hasImages || pb.types.contains(UTType.fileURL.identifier)
        let hasPlainText = pb.hasStrings

        if hasNonText && !hasPlainText {
            onPasteNonText?()
            return
        }
        super.paste(sender)
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return size
    }
}

// MARK: - UIViewRepresentable

struct PasteInterceptingTextInput: UIViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var isDisabled: Bool
    var placeholder: String
    var onPasteNonText: (() -> Void)?
    @Binding var dynamicHeight: CGFloat

    func makeUIView(context: Context) -> PasteTextView {
        let textView = PasteTextView()
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.updatePlaceholderVisibility()
        return textView
    }

    func updateUIView(_ textView: PasteTextView, context: Context) {
        if textView.text != text {
            textView.text = text
            textView.updatePlaceholderVisibility()
        }
        textView.isUserInteractionEnabled = !isDisabled
        textView.placeholder = placeholder
        textView.onPasteNonText = onPasteNonText

        // Only manage first responder when the user isn't actively editing,
        // to avoid resignFirstResponder being called mid-typing due to SwiftUI
        // re-renders before FocusState has propagated.
        guard !context.coordinator.isEditing else { return }
        let shouldFocus = isFocused.wrappedValue
        if shouldFocus && !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !shouldFocus && textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteInterceptingTextInput
        var isEditing = false
        private let maxHeight: CGFloat = 120

        init(_ parent: PasteInterceptingTextInput) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? PasteTextView)?.updatePlaceholderVisibility()

            let fitsSize = textView.sizeThatFits(CGSize(width: textView.frame.width, height: .infinity))
            let newHeight = min(fitsSize.height, maxHeight)
            if newHeight != parent.dynamicHeight {
                parent.dynamicHeight = newHeight
            }
            textView.isScrollEnabled = fitsSize.height > maxHeight
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            parent.isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            parent.isFocused.wrappedValue = false
        }
    }
}
