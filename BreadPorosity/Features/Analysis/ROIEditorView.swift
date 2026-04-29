import SwiftUI
import UIKit

struct ROIEditorView: View {
    @Binding var normalizedRect: CGRect

    let image: UIImage
    var gridSpec: GridSpec? = nil

    @State private var dragStartRect: CGRect?

    private let minNormalizedSize: CGFloat = 0.12

    var body: some View {
        GeometryReader { geometry in
            let imageRect = aspectFitRect(for: image.size, in: geometry.size)
            let clampedRect = normalizedRect.clampedToUnit(minSize: minNormalizedSize)
            let selectionRect = clampedRect.denormalized(in: imageRect)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.03)

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                Path { path in
                    path.addRect(imageRect)
                    path.addRect(selectionRect)
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))

                Rectangle()
                    .path(in: selectionRect)
                    .stroke(.white, lineWidth: 2)

                if let gridSpec {
                    gridPath(in: selectionRect, gridSpec: gridSpec)
                        .stroke(.white.opacity(0.75), lineWidth: 1.5)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .position(x: selectionRect.midX, y: selectionRect.midY)
                    .gesture(dragGesture(for: .move, in: imageRect))

                handle(at: CGPoint(x: selectionRect.minX, y: selectionRect.minY), kind: .topLeft, in: imageRect)
                handle(at: CGPoint(x: selectionRect.maxX, y: selectionRect.minY), kind: .topRight, in: imageRect)
                handle(at: CGPoint(x: selectionRect.minX, y: selectionRect.maxY), kind: .bottomLeft, in: imageRect)
                handle(at: CGPoint(x: selectionRect.maxX, y: selectionRect.maxY), kind: .bottomRight, in: imageRect)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func handle(at point: CGPoint, kind: DragHandle, in imageRect: CGRect) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 22, height: 22)
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            .position(point)
            .gesture(dragGesture(for: kind, in: imageRect))
    }

    private func gridPath(in rect: CGRect, gridSpec: GridSpec) -> Path {
        var path = Path()
        let cellWidth = rect.width / CGFloat(gridSpec.columns)
        let cellHeight = rect.height / CGFloat(gridSpec.rows)

        for row in 1..<gridSpec.rows {
            let y = rect.minY + CGFloat(row) * cellHeight
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        for column in 1..<gridSpec.columns {
            let x = rect.minX + CGFloat(column) * cellWidth
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }

        return path
    }

    private func dragGesture(for handle: DragHandle, in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startingRect = dragStartRect ?? normalizedRect.clampedToUnit(minSize: minNormalizedSize)
                if dragStartRect == nil {
                    dragStartRect = startingRect
                }

                normalizedRect = updatedRect(
                    from: startingRect,
                    translation: value.translation,
                    handle: handle,
                    imageRect: imageRect
                )
            }
            .onEnded { _ in
                dragStartRect = nil
                normalizedRect = normalizedRect.clampedToUnit(minSize: minNormalizedSize)
            }
    }

    private func updatedRect(
        from startRect: CGRect,
        translation: CGSize,
        handle: DragHandle,
        imageRect: CGRect
    ) -> CGRect {
        let width = max(imageRect.width, 1)
        let height = max(imageRect.height, 1)
        let dx = translation.width / width
        let dy = translation.height / height

        switch handle {
        case .move:
            var movedRect = startRect.offsetBy(dx: dx, dy: dy)
            movedRect.origin.x = clamp(movedRect.origin.x, min: 0, max: 1 - movedRect.width)
            movedRect.origin.y = clamp(movedRect.origin.y, min: 0, max: 1 - movedRect.height)
            return movedRect.clampedToUnit(minSize: minNormalizedSize)

        case .topLeft:
            let maxX = startRect.maxX
            let maxY = startRect.maxY
            let minX = clamp(startRect.minX + dx, min: 0, max: maxX - minNormalizedSize)
            let minY = clamp(startRect.minY + dy, min: 0, max: maxY - minNormalizedSize)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .clampedToUnit(minSize: minNormalizedSize)

        case .topRight:
            let minX = startRect.minX
            let maxY = startRect.maxY
            let maxX = clamp(startRect.maxX + dx, min: minX + minNormalizedSize, max: 1)
            let minY = clamp(startRect.minY + dy, min: 0, max: maxY - minNormalizedSize)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .clampedToUnit(minSize: minNormalizedSize)

        case .bottomLeft:
            let maxX = startRect.maxX
            let minY = startRect.minY
            let minX = clamp(startRect.minX + dx, min: 0, max: maxX - minNormalizedSize)
            let maxY = clamp(startRect.maxY + dy, min: minY + minNormalizedSize, max: 1)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .clampedToUnit(minSize: minNormalizedSize)

        case .bottomRight:
            let minX = startRect.minX
            let minY = startRect.minY
            let maxX = clamp(startRect.maxX + dx, min: minX + minNormalizedSize, max: 1)
            let maxY = clamp(startRect.maxY + dy, min: minY + minNormalizedSize, max: 1)
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .clampedToUnit(minSize: minNormalizedSize)
        }
    }

    private func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fittedWidth = imageSize.width * scale
        let fittedHeight = imageSize.height * scale

        return CGRect(
            x: (containerSize.width - fittedWidth) / 2,
            y: (containerSize.height - fittedHeight) / 2,
            width: fittedWidth,
            height: fittedHeight
        )
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(value, maxValue))
    }
}

private extension ROIEditorView {
    enum DragHandle {
        case move
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }
}
