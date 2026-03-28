import SwiftUI

/// Loads and displays an image from the server using authenticated API calls.
/// Supports:
/// - Tap to view full screen with pinch-to-zoom
/// - Long press context menu with Copy and Share options
struct AuthenticatedImageView: View {
    let fileId: String
    let apiClient: APIClient?

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var hasError = false
    @State private var showFullScreen = false
    /// Incrementing trigger to force `.task` re-evaluation on retry.
    /// Changing this value causes SwiftUI to cancel the old task and
    /// start a new one, which re-runs `loadImage()`.
    @State private var retryTrigger: Int = 0

    @Environment(\.theme) private var theme

    /// In-memory cache for file-based images. Prevents re-fetching when
    /// scrolling back through the chat, which causes layout shifts and
    /// scroll position jumps in the LazyVStack.
    private static let imageCache = NSCache<NSString, UIImage>()
    static func configureCache() {
        imageCache.countLimit = 80
        imageCache.totalCostLimit = 60 * 1024 * 1024 // 60 MB
    }

    var body: some View {
        // Use a fixed-height container for ALL states (loading, loaded, error)
        // to prevent layout shifts that cause scroll position jumps.
        // The image is constrained to the same height as the placeholder
        // so the scroll view never needs to re-layout when images finish loading.
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onTapGesture {
                        showFullScreen = true
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.image = image
                            Haptics.notify(.success)
                        } label: {
                            Label("Copy Image", systemImage: "doc.on.doc")
                        }

                        Button {
                            shareImage(image)
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            showFullScreen = true
                        } label: {
                            Label("View Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
            } else if isLoading {
                RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous)
                    .fill(theme.surfaceContainer)
                    .frame(height: placeholderHeight)
                    .overlay(
                        ProgressView()
                            .controlSize(.regular)
                            .tint(theme.brandPrimary)
                    )
            } else if hasError {
                // Tap-to-retry error state — tapping bumps the retryTrigger
                // which causes the `.task(id:)` to re-fire and attempt loading again.
                VStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.clockwise.circle")
                        .scaledFont(size: 28)
                        .foregroundStyle(theme.brandPrimary.opacity(0.7))
                    Text("Tap to retry")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(height: placeholderHeight)
                .frame(maxWidth: .infinity)
                .background(theme.surfaceContainer.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))
                .onTapGesture {
                    retryTrigger += 1
                }
            }
        }
        // Combine fileId + retryTrigger so that:
        // 1. A new fileId triggers a fresh load (normal case)
        // 2. Incrementing retryTrigger forces a retry for the same fileId (tap-to-retry / foreground recovery)
        .task(id: "\(fileId)_\(retryTrigger)") {
            await loadImage()
        }
        // When the app returns to the foreground, retry any failed images automatically.
        // This handles the case where images failed because the app was backgrounded
        // during generation (slow network, tool-generated images not yet available).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if hasError && loadedImage == nil {
                retryTrigger += 1
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let image = loadedImage {
                FullScreenImageView(image: image)
            }
        }
    }

    /// Consistent placeholder height used for loading and error states.
    /// Prevents the view from jumping between 0 → 200 → actual image height
    /// which causes scroll position shifts (bouncing).
    private var placeholderHeight: CGFloat { 200 }

    /// Maximum number of automatic retry attempts before showing the error state.
    /// Each attempt uses exponential backoff (1s, 2s, 4s) to avoid hammering
    /// the server while still recovering quickly from transient failures.
    private static let maxAutoRetries = 3

    private func loadImage() async {
        // Check in-memory cache first — if the image is cached, display it
        // instantly without resetting to the loading placeholder. This prevents
        // the height change (200px placeholder → actual image) that causes
        // scroll position jumps when scrolling up through a LazyVStack.
        if let cached = Self.imageCache.object(forKey: fileId as NSString) {
            if loadedImage !== cached {
                loadedImage = cached
            }
            isLoading = false
            hasError = false
            return
        }

        // Only show loading state if we don't already have an image.
        // When .task(id:) re-fires for the same fileId (e.g., scrolling back),
        // keeping the previous image prevents a flash to the placeholder.
        if loadedImage == nil {
            isLoading = true
        }
        hasError = false

        guard let apiClient else {
            hasError = true
            isLoading = false
            return
        }

        // Retry with exponential backoff — handles transient network failures,
        // app returning from background, and tool-generated images that aren't
        // immediately available on the server.
        for attempt in 0..<Self.maxAutoRetries {
            // Check for cancellation between retries (e.g., view disappeared)
            guard !Task.isCancelled else { break }

            do {
                let (data, _) = try await apiClient.getFileContent(id: fileId)
                if let uiImage = UIImage(data: data) {
                    // Cache for future scroll-backs
                    let cost = data.count
                    Self.imageCache.setObject(uiImage, forKey: fileId as NSString, cost: cost)
                    loadedImage = uiImage
                    hasError = false
                    isLoading = false
                    return
                }
            } catch {
                // On last attempt, fall through to error state.
                // Otherwise wait with exponential backoff before retrying.
                if attempt < Self.maxAutoRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000 // 1s, 2s, 4s
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        // All retries exhausted — show tap-to-retry error state
        hasError = true
        isLoading = false
    }

    private func shareImage(_ image: UIImage) {
        let activityVC = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            // Find the topmost presented view controller
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
    }
}

// MARK: - Full Screen Image Viewer

/// A full-screen image viewer with pinch-to-zoom, double-tap-to-zoom,
/// dismiss gesture, and share button.
struct FullScreenImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Zoomable image using UIScrollView for proper pinch-to-zoom
            ZoomableImageView(image: image)
                .ignoresSafeArea()

            // Top bar with close and share buttons
            VStack {
                HStack {
                    Spacer()

                    // Share button
                    Button {
                        shareImage()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .scaledFont(size: 18, weight: .medium)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }

                    // Close button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .scaledFont(size: 16, weight: .bold)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Spacer()
            }
        }
        .statusBarHidden()
    }

    private func shareImage() {
        let activityVC = UIActivityViewController(
            activityItems: [image],
            applicationActivities: nil
        )
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            activityVC.popoverPresentationController?.sourceView = topVC.view
            topVC.present(activityVC, animated: true)
        }
    }
}

// MARK: - Zoomable Image View (UIKit-backed)

/// A `UIViewRepresentable` that wraps `UIScrollView` to provide native
/// pinch-to-zoom and double-tap-to-zoom for images.
///
/// - Minimum zoom: fits the image to the screen (aspect fit)
/// - Maximum zoom: 5×
/// - Double-tap toggles between 1× and 2.5× zoom
/// - Image is centered when zoomed out below the viewport size
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.tag = 100
        scrollView.addSubview(imageView)

        // Double-tap gesture to toggle zoom
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Recalculate zoom scales when the view size changes
        DispatchQueue.main.async {
            context.coordinator.updateZoomScale()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let image: UIImage
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private var hasSetInitialZoom = false

        init(image: UIImage) {
            self.image = image
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImageInScrollView()
        }

        func updateZoomScale() {
            guard let scrollView, let imageView else { return }
            let boundsSize = scrollView.bounds.size
            guard boundsSize.width > 0 && boundsSize.height > 0 else { return }

            let imageSize = image.size
            guard imageSize.width > 0 && imageSize.height > 0 else { return }

            // Calculate the scale that fits the image within the scroll view
            let xScale = boundsSize.width / imageSize.width
            let yScale = boundsSize.height / imageSize.height
            let minScale = min(xScale, yScale)

            scrollView.minimumZoomScale = minScale
            scrollView.maximumZoomScale = max(minScale * 5, 5.0)

            // Set the image view frame to the actual image size
            imageView.frame = CGRect(
                origin: .zero,
                size: imageSize
            )
            scrollView.contentSize = imageSize

            if !hasSetInitialZoom {
                hasSetInitialZoom = true
                scrollView.zoomScale = minScale
            }

            centerImageInScrollView()
        }

        /// Centers the image when it is smaller than the scroll view bounds.
        private func centerImageInScrollView() {
            guard let scrollView, let imageView else { return }
            let boundsSize = scrollView.bounds.size
            var frameToCenter = imageView.frame

            // Center horizontally
            if frameToCenter.size.width < boundsSize.width {
                frameToCenter.origin.x = (boundsSize.width - frameToCenter.size.width) / 2
            } else {
                frameToCenter.origin.x = 0
            }

            // Center vertically
            if frameToCenter.size.height < boundsSize.height {
                frameToCenter.origin.y = (boundsSize.height - frameToCenter.size.height) / 2
            } else {
                frameToCenter.origin.y = 0
            }

            imageView.frame = frameToCenter
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let minScale = scrollView.minimumZoomScale

            if scrollView.zoomScale > minScale {
                // Zoom out to fit
                scrollView.setZoomScale(minScale, animated: true)
            } else {
                // Zoom in to 2.5× at the tapped point
                let targetScale = min(minScale * 2.5, scrollView.maximumZoomScale)
                let location = gesture.location(in: scrollView.subviews.first)
                let zoomRect = zoomRectForScale(targetScale, center: location, in: scrollView)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        private func zoomRectForScale(
            _ scale: CGFloat,
            center: CGPoint,
            in scrollView: UIScrollView
        ) -> CGRect {
            let size = CGSize(
                width: scrollView.bounds.width / scale,
                height: scrollView.bounds.height / scale
            )
            let origin = CGPoint(
                x: center.x - size.width / 2,
                y: center.y - size.height / 2
            )
            return CGRect(origin: origin, size: size)
        }
    }
}
