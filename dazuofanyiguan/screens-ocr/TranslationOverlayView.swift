import SwiftUI

struct TranslationOverlayView: View {
    let text: String
    var lines: [VisionOCRService.OCRLine] = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )

            if !lines.isEmpty {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        ForEach(lines) { line in
                            let rect = lineRect(line.boundingBox, size: geo.size)
                            let fontSize = clampFontSize(rect.height >= 28 ? rect.height * 0.45 : rect.height * 0.82)

                            Text(line.text)
                                .font(.system(size: fontSize, weight: .semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)
                                .minimumScaleFactor(0.6)
                                .allowsTightening(true)
                                .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                    .padding(10)
                }
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
    }

    private func lineRect(_ boundingBox: CGRect, size: CGSize) -> CGRect {
        let x = boundingBox.minX * size.width
        let y = (1 - boundingBox.maxY) * size.height
        let w = boundingBox.width * size.width
        let h = boundingBox.height * size.height
        return CGRect(x: x, y: y, width: max(8, w), height: max(10, h))
    }

    private func clampFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, 11), 22)
    }
}
