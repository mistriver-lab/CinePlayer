import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

private enum AboutAppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }
}

private enum AboutLinks {
    static let repository = "https://github.com/mistriver-lab/GlassMPV"
}

struct AboutPage: View {
    #if !os(macOS)
        @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        #if os(macOS)
            macBody
                .navigationTitle("关于")
        #else
            mobileBody
                .navigationTitle("关于")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
            #endif
        #endif
    }

    #if os(macOS)
        private var macBody: some View {
            VStack(spacing: 0) {
                headerView
                    .padding(.bottom, 18)

                infoCard

                Spacer(minLength: 80)

                footerLinks
            }
            .padding(.top, 30)
            .padding(.bottom, 42)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    #else
        private var mobileBody: some View {
            VStack(spacing: 18) {
                Spacer()

                headerView

                Spacer()

                infoCard
                footerLinks
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .frame(maxHeight: .infinity)
        }
    #endif

    private var headerView: some View {
        VStack(spacing: 8) {
            Image("CinePlayerIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.black.opacity(0.2), radius: 18, y: 8)
                .padding(.bottom, 8)

            Text(verbatim: "GlassMPV")
                .font(.system(size: 24, weight: .semibold))

            Text(verbatim: "版本号: \(AboutAppInfo.version) (\(AboutAppInfo.build))")
                .f13r()
                .foregroundStyle(.secondary)
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .frame(width: 30, height: 30)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "GlassMPV for iOS")
                        .f13r()
                    Text(verbatim: "iOS 高性能本地视频播放器（支持 Anime4K / MetalFX / 光流 / RIFE 补帧）")
                        .f12r()
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
        }
        .background(Color.primary.opacity(0.015))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(lineWidth: 1)
                .foregroundStyle(.quaternary)
        }
    }

    private var footerLinks: some View {
        VStack(spacing: 8) {
            Button {
                openExternal(AboutLinks.repository)
            } label: {
                Text(verbatim: "GitHub 开源仓库：mistriver-lab/GlassMPV")
                    .f12r()
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
    }

    private func openExternal(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }
        #if os(macOS)
            NSWorkspace.shared.open(url)
        #else
            openURL(url)
        #endif
    }
}

#Preview {
    NavigationStack {
        AboutPage()
    }
}
