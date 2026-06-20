import SwiftUI

// MARK: - PreviewStage (issue 7) — the large photo stage
//
// .dc.html `pvBig` (~213) + overlays (~214-217). flex:1 photo stage, radius 12,
// inner vignette (`inset 0 0 140px rgba(0,0,0,.35)`) + 1px white hairline.
//   • ‹ › nav arrows  — 40×56, rgba(12,12,14,.55) + blur, centred vertically.
//   • ★ AI BEST badge — bottom-left, only on the Keeper (green #54cf93 / #072014).
//   • zoom tag        — bottom-right "{n}%" subtle grey, while zoomed.
//
// Zoom & pan (free-form): the mouse WHEEL (or trackpad two-finger scroll) zooms
// 1×…6× TOWARD THE POINTER, a DRAG pans the magnified image (cursor → grab hand),
// a DOUBLE-CLICK toggles fit ↔ 2.4×, and the `Z` key (model flag `zoomed`) snaps to
// 2.4×. Drag/double-click are plain SwiftUI gestures; the wheel + the hover/grab
// cursor need AppKit (macOS 14 SwiftUI has neither), handled by the transparent
// `StageInteractionCatcher` — it never hit-tests (so clicks reach the buttons
// below), scopes a local scroll monitor to its own bounds (so the filmstrip never
// zooms), and shows an open-hand cursor while a zoomed photo is hovered. Zoom/pan
// are transient view state and reset on frame change.
struct PreviewStage: View {
    let display: FrameDisplay
    /// Model-driven snap flag (the `Z` key). Drives a fit ↔ 2.4× snap; continuous
    /// wheel/drag then refine from there.
    let zoomed: Bool
    let onPrev: () -> Void
    let onNext: () -> Void

    /// For resolving the frame's file (source root + rel path) to decode it at
    /// native resolution while zoomed — same seam `ThumbnailImage` uses.
    @Environment(AppModel.self) private var model
    /// Native-resolution decode of the current frame, loaded only while zoomed so
    /// 1:1 detail is real pixels, not an upscaled thumbnail. `nil` at fit (the
    /// small byte-budgeted thumbnail is shown then) and during the brief load.
    @State private var fullRes: CGImage?

    private let radius: CGFloat = Metrics.Radius.cardLarge // 12
    private let snapScale: CGFloat = 2.4 // prototype's 240% background-size
    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 6

    /// Current magnification (1 = fit). Pans are only meaningful while > 1.
    @State private var scale: CGFloat = 1
    /// Pan in points of the stage, clamped so the image edge never crosses centre.
    @State private var offset: CGSize = .zero
    /// Offset captured at the start of a drag (so each drag is additive, not jumpy).
    @State private var panBase: CGSize = .zero
    @State private var panning = false

    private var isZoomed: Bool { scale > minScale + 0.001 }

    var body: some View {
        GeometryReader { geo in
            stageImage
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                // No vignette over the photo: this is a culling tool, so the stage
                // must show true tones (and match the histogram). The hairline frame
                // stays for definition.
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                // Transparent catcher — pass-through clicks, scoped wheel zoom-to-
                // pointer, open-hand hover cursor while zoomed.
                .overlay(
                    StageInteractionCatcher(zoomActive: isZoomed) { factor, point in
                        zoomBy(factor, at: point, in: geo.size)
                    }
                )
                .overlay(alignment: .leading) { navArrow(Icon.chevronLeft, action: onPrev).padding(.leading, 10) }
                .overlay(alignment: .trailing) { navArrow(Icon.chevronRight, action: onNext).padding(.trailing, 10) }
                .overlay(alignment: .bottomLeading) { bestBadge.padding(14) }
                .overlay(alignment: .bottomTrailing) { zoomTag.padding(14) }
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .gesture(panGesture(in: geo.size))
                .onTapGesture(count: 2) { toggleZoom() }
        }
        // Reset zoom/pan when the previewed frame changes …
        .onChange(of: display.frame.id) { resetZoom() }
        // … and snap when the `Z` key flips the model flag.
        .onChange(of: zoomed) { _, z in
            withAnimation(.easeOut(duration: 0.18)) {
                scale = z ? snapScale : minScale
                offset = .zero
            }
        }
        // Load the native-resolution frame once zoom crosses fit, drop it on
        // un-zoom or frame change (keyed on both so it re-fires correctly).
        .task(id: FullResRequest(id: display.frame.id, wanted: wantsFullRes)) {
            await updateFullRes()
        }
    }

    // MARK: Stage image — thumbnail at fit, native decode while zoomed

    /// Whether the stage is magnified enough to want true 1:1 pixels.
    private var wantsFullRes: Bool { scale > minScale + 0.01 }

    /// Re-decode key: the frame plus whether full-res is currently wanted.
    private struct FullResRequest: Equatable {
        let id: String
        let wanted: Bool
    }

    /// At fit (or while the native decode is loading) show the small, byte-budgeted
    /// thumbnail; once the full-resolution frame is ready show it instead, on the
    /// same dark matte so the swap is seamless (identical fit geometry, just crisp).
    @ViewBuilder private var stageImage: some View {
        if let fullRes {
            ZStack {
                Palette.panelDeepAlt
                Image(decoded: fullRes)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ThumbnailImage(frame: display.frame, contentMode: .fit)
        }
    }

    /// Load or drop the native-resolution decode for the current frame. Bounded to
    /// a single frame by `ImageCache.fullResolution`, so memory stays flat.
    private func updateFullRes() async {
        guard wantsFullRes else { fullRes = nil; return }
        guard let root = model.sourceURL else { return }
        let url = root.appending(path: display.frame.relPath)
        let image = await ImageCache.shared.fullResolution(forFrameID: display.frame.id, url: url)
        // Ignore a late delivery if the user has un-zoomed since.
        if wantsFullRes { fullRes = image }
    }

    // MARK: Zoom / pan

    /// Multiply the scale (wheel) about the pointer, so the content under the
    /// cursor stays put: `offset' = c − (c − offset)·(s'/s)`, where `c` is the
    /// cursor relative to the stage centre. Re-clamps to the new scale.
    private func zoomBy(_ factor: CGFloat, at point: CGPoint, in size: CGSize) {
        let next = min(maxScale, max(minScale, scale * factor))
        guard next != scale, size.width > 0, size.height > 0 else { return }
        let ratio = next / scale
        let cx = point.x - size.width / 2
        let cy = point.y - size.height / 2
        let raw = CGSize(
            width: cx - (cx - offset.width) * ratio,
            height: cy - (cy - offset.height) * ratio
        )
        scale = next
        offset = clampedOffset(raw, scale: next, in: size)
    }

    /// Drag-pan. SwiftUI's translation is +x right / +y down — the same sense as
    /// `offset` — so the image tracks the cursor on both axes. Shows the grab hand
    /// for the duration of the drag (`.set()` persists through the drag loop).
    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard isZoomed else { return }
                if !panning { panBase = offset; panning = true }
                NSCursor.closedHand.set()
                let raw = CGSize(
                    width: panBase.width + value.translation.width,
                    height: panBase.height + value.translation.height
                )
                offset = clampedOffset(raw, scale: scale, in: size)
            }
            .onEnded { _ in
                panning = false
                if isZoomed { NSCursor.openHand.set() }
            }
    }

    /// Double-click: fit ↔ 2.4×.
    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.18)) {
            if isZoomed { resetZoom() } else { scale = snapScale }
        }
    }

    private func resetZoom() {
        scale = minScale
        offset = .zero
        panning = false
    }

    /// Clamp pan so the magnified image always covers the stage — half the
    /// overflow on each axis is the limit.
    private func clampedOffset(_ o: CGSize, scale: CGFloat, in size: CGSize) -> CGSize {
        let maxX = (size.width  * (scale - 1)) / 2
        let maxY = (size.height * (scale - 1)) / 2
        return CGSize(
            width: min(maxX, max(-maxX, o.width)),
            height: min(maxY, max(-maxY, o.height))
        )
    }

    // MARK: ‹ › nav arrows (translucent, blur)

    private func navArrow(_ icon: String, action: @escaping () -> Void) -> some View {
        NavArrowButton(icon: icon, action: action)
    }

    // MARK: ★ AI BEST badge — Keeper only

    @ViewBuilder private var bestBadge: some View {
        if display.isKeeper {
            HStack(spacing: 4) {
                Image(systemName: Icon.star).font(.system(size: 9, weight: .bold))
                Text("AI BEST")
            }
            .font(Typography.ui(11, weight: .bold))
            .foregroundStyle(Color(hex: "#072014"))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                    .fill(Palette.markBest)
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: Zoom tag — while zoomed, a subtle live-magnification readout

    @ViewBuilder private var zoomTag: some View {
        if isZoomed {
            Text("\(Int((scale * 100).rounded()))%")
                .font(Typography.mono(11, weight: .medium))
                .foregroundStyle(Palette.textTertiary)
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                        .fill(Color.black.opacity(0.45))
                )
                .allowsHitTesting(false)
        }
    }
}

// MARK: - EndOfBurstStage — the one-stop "end of burst" interstitial
//
// Shown after → from the last displayed frame (AppModel.previewAtBurstEnd). It
// mirrors the photo stage's dark rounded surface + inner vignette + ‹ › arrows
// so the stop reads as part of the same viewer rather than a context switch:
//   • ‹ (onPrev)     — back onto the last frame
//   • › (onNext)     — wrap to the first frame (the deliberate second step)
//   • "Next burst"   — jump to the next group (↓)
struct EndOfBurstStage: View {
    let burstLabel: String
    let count: Int
    let onPrev: () -> Void
    let onNext: () -> Void
    let onNextBurst: () -> Void

    private let radius: CGFloat = Metrics.Radius.cardLarge

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Palette.panelDeepAlt)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(vignette)
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .leading) { NavArrowButton(icon: Icon.chevronLeft, action: onPrev).padding(.leading, 10) }
        .overlay(alignment: .trailing) { NavArrowButton(icon: Icon.chevronRight, action: onNext).padding(.trailing, 10) }
    }

    private var content: some View {
        VStack(spacing: 16) {
            Image(systemName: Icon.check)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.markBest)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Palette.markBest.opacity(0.12)))

            VStack(spacing: 6) {
                Text("End of burst")
                    .font(Typography.ui(20, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text("You've reviewed all \(count) photo\(count == 1 ? "" : "s") in \(burstLabel).")
                    .font(Typography.ui(13))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                EndBurstAction(title: "Back to first photo", icon: Icon.arrowRight, prominent: true, action: onNext)
                EndBurstAction(title: "Next burst", icon: Icon.chevronExpanded, prominent: false, action: onNextBurst)
            }
            .padding(.top, 2)

            Text("→  first photo      ←  last photo      ↓  next burst")
                .font(Typography.mono(11))
                .foregroundStyle(Palette.textTertiary)
                .padding(.top, 2)
        }
        .padding(40)
    }

    private var vignette: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(
                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.35)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 520
                )
            )
            .allowsHitTesting(false)
    }
}

// MARK: - End-of-burst action button (prominent gold / neutral)

private struct EndBurstAction: View {
    let title: String
    let icon: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(Typography.ui(13, weight: .semibold))
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(prominent ? Palette.accentTextOnGold : Palette.textPrimaryAlt)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall).fill(background)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                        .strokeBorder(Palette.borderStrong, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Anim.hover, value: hovering)
    }

    private var background: Color {
        if prominent { return hovering ? Palette.accentGradientTop : Palette.accent }
        return hovering ? Palette.hoverRaisedStrong : Palette.hoverRaised
    }
}

// MARK: - Nav arrow button (40×56, translucent + blur)

private struct NavArrowButton: View {
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Palette.textPrimaryAlt)
                .frame(width: 40, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.button)
                        .fill(Color(hex: "#0c0c0e").opacity(hovering ? 0.8 : 0.55))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Metrics.Radius.button))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Stage interaction catcher (transparent)
//
// macOS 14 SwiftUI has no scroll-wheel gesture and no pre-15 cursor modifier, so a
// thin AppKit view supplies both while staying invisible to the mouse:
//   • `hitTest` → `nil`  — clicks/drags fall through to the SwiftUI controls below
//     (Back-to-grid, arrows, filmstrip all keep working).
//   • a local `scrollWheel` monitor, active only while in a window and only when
//     the pointer is within this view's bounds — so scrolling the filmstrip never
//     zooms the photo. Reports a multiplicative factor + the pointer in SwiftUI
//     (top-left, y-down) coordinates so the caller can zoom toward it.
//   • a `.cursorUpdate` tracking area — shows the open-hand cursor while a zoomed
//     photo is hovered (the closed/grab hand during a drag is set by the gesture).
private struct StageInteractionCatcher: NSViewRepresentable {
    /// Whether a zoomed photo is showing (drives the open-hand hover cursor).
    let zoomActive: Bool
    /// (multiplicative zoom step, pointer in SwiftUI coords).
    let onZoom: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherNSView {
        let v = CatcherNSView()
        v.onZoom = onZoom
        v.zoomActive = zoomActive
        return v
    }

    func updateNSView(_ nsView: CatcherNSView, context: Context) {
        nsView.onZoom = onZoom
        nsView.zoomActive = zoomActive
    }

    final class CatcherNSView: NSView {
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        var zoomActive = false
        private var monitor: Any?

        // Invisible to mouse hit-testing → every click falls through to SwiftUI.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate],
                owner: self
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            if zoomActive { NSCursor.openHand.set() } else { super.cursorUpdate(with: event) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                // NSView is non-flipped (y-up); flip to SwiftUI's top-left y-down.
                let inView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(inView) else { return event }
                let point = CGPoint(x: inView.x, y: self.bounds.height - inView.y)
                // Precise (trackpad) deltas are small; line (mouse) deltas coarse —
                // normalise; scroll up (+deltaY) zooms in.
                let delta = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaY * 8
                guard delta != 0 else { return event }
                self.onZoom?(exp(delta * 0.004), point)
                return nil
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
