import SwiftUI

/// Shared geometry and material for platform login, importing and result states.
struct TVDialog<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let title: String
  var subtitle: String? = nil
  let symbol: String
  var brand: String? = nil
  @ViewBuilder let content: () -> Content
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 18) {
          if let brand, let icon = BrandIcon.image(brand) {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 13))
          } else { Image(systemName: symbol).font(.system(size: 34)).frame(width: 52, height: 52) }
          VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 30, weight: .semibold))
            if let subtitle { Text(subtitle).font(.system(size: 16)).foregroundStyle(.secondary) }
          }
          Spacer(minLength: 0)
        }
        content()
      }.padding(30).frame(width: 940)
        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
        .tvPopupSurface(radius: 32)
    }
  }
}
