import MarkdownUI
import SwiftUI

extension Theme {
    /// Summary rendering matched to the karaoke transcript's type spec
    /// (system 17pt medium, 6pt line spacing, 12pt paragraph spacing,
    /// semibold accents). Built from an empty `Theme` so no style paints
    /// an opaque background — the summary sits on the same translucent
    /// surface as the transcript layers.
    @MainActor static let transcride = Theme()
        .text {
            FontSize(17)
            FontWeight(.medium)
            ForegroundColor(.primary)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            BackgroundColor(Color(nsColor: .quaternarySystemFill))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .heading1 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 16, bottom: 12)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.25))
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 16, bottom: 12)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.12))
                }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 16, bottom: 12)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 16, bottom: 12)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 16, bottom: 12)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 16, bottom: 12)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    ForegroundColor(.secondary)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.35))
                .markdownMargin(top: 0, bottom: 12)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .separatorColor))
                    .relativeFrame(width: .em(0.2))
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 0, bottom: 12)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.225))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(12)
            }
            .background(Color(nsColor: .quaternarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 0, bottom: 12)
        }
        .listItem { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.35))
                .markdownMargin(top: .em(0.25))
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: Color(nsColor: .separatorColor)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.clear, Color(nsColor: .quaternarySystemFill))
                )
                .markdownMargin(top: 0, bottom: 12)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 13)
                .relativeLineSpacing(.em(0.25))
        }
        .thematicBreak {
            Divider()
                .overlay(Color(nsColor: .separatorColor))
                .markdownMargin(top: 16, bottom: 16)
        }
}
