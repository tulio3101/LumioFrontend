#if canImport(SwiftUI)
import SwiftUI

struct FeatureStatusView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(message).font(.body)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
