import SwiftUI
import UIKit

private struct CardContent {
    let title: String
    let readings: [Reading]
    let tags: String?
    let qr: CGImage?
}

private struct ShareCard: View {
    static let width: CGFloat = 360
    static let height: CGFloat = 480

    let content: CardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("app.fullName")).font(.system(size: 15, weight: .semibold)).opacity(0.88)
            Text(content.title)
                .font(.system(size: 37, weight: .semibold).monospacedDigit())
                .lineLimit(3)
                .minimumScaleFactor(0.55)
            Spacer(minLength: 6)
            ForEach(content.readings) { reading in
                Divider().overlay(.white.opacity(0.25))
                HStack {
                    Text(reading.unit.title).font(.system(size: 15)).opacity(0.88)
                    Spacer(minLength: 8)
                    Text(reading.text)
                        .font(.system(size: 23, weight: .semibold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            Divider().overlay(.white.opacity(0.25))
            HStack(alignment: .center) {
                if let tags = content.tags {
                    Text(tags).font(.system(size: 14)).opacity(0.88)
                }
                Spacer(minLength: 4)
                VStack(spacing: 4) {
                    if let qr = content.qr {
                        Image(decorative: qr, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 70, height: 70)
                        Text(L.t("share.download"))
                    } else {
                        Image(systemName: "qrcode")
                            .font(.system(size: 36))
                            .frame(width: 70, height: 55)
                            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityHidden(true)
                        Text(L.t("share.qrPending"))
                    }
                }
                .font(.system(size: 11))
            }
        }
        .foregroundStyle(Color.white)
        .padding(23)
        .frame(width: Self.width, height: Self.height)
        .background(Design.green)
    }

    @MainActor
    func image() -> UIImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 3
        renderer.isOpaque = true
        guard let image = renderer.uiImage, let pixels = image.cgImage,
              pixels.width == 1080, pixels.height == 1440 else { return nil }
        return image
    }
}

struct ShareView: View {
    private enum Mode: String, Identifiable {
        case card, code, milestone
        var id: String { rawValue }
        var title: String { L.t("share." + rawValue) }
    }

    @ObservedObject var model: AppModel
    let startsOnMilestone: Bool
    @State private var mode = Mode.card
    @State private var qr: CGImage?
    @State private var qrAttempted = false

    private let downloadURL = ShareAssets.storeURL(id: Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String ?? "")
    @State private var activity: ShareActivity?
    @State private var requested = false
    @State private var copied = false
    @State private var preparing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text(L.t(startsOnMilestone ? "share.milestone" : "share.title"))
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(L.t("common.close")) { model.panel = nil }
                        .buttonStyle(ActionStyle())
                        .accessibilityIdentifier("panel.close")
                }
                if !startsOnMilestone {
                    Picker(L.t("share.title"), selection: $mode) {
                        ForEach(model.stats.milestone ? [Mode.card, .code, .milestone] : [.card, .code]) { item in
                            Text(item.title).tag(item).accessibilityIdentifier("share." + item.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("share.mode")
                }
                if selected == .code {
                    PresetLabel(name: model.sharePayload.name, selection: model.sharePayload.selection)
                        .padding(16)
                        .cardSurface(14)
                    if let code = try? model.sharePayload.code() {
                        Text(code).font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(L.t("share.copyCode")) {
                            model.copy(code)
                            copied = true
                        }
                        .buttonStyle(ActionStyle())
                        .accessibilityIdentifier("share.copyCode")
                        if copied { Text(L.t("common.copied")).font(.footnote) }
                    }
                } else if let card {
                    GeometryReader { geometry in
                        ShareCard(content: card)
                            .scaleEffect(geometry.size.width / ShareCard.width, anchor: .topLeading)
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 21))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("share.cardPreview")
                }

            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { sendBar }
        .background(Design.paper)
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: mode) { _, _ in
            requested = false
            copied = false
        }
        .task {
            guard let downloadURL else { return }
            qr = await Task.detached(priority: .utility) { ShareAssets.qr(for: downloadURL) }.value
            qrAttempted = true
        }
        .sheet(item: $activity) { prepared in
            ShareController(activity: prepared) { activity = nil }
        }
    }

    private var sendBar: some View {
        VStack(spacing: 4) {
            Button {
                Task { await send() }
            } label: {
                Text(L.t(selected == .code ? "share.sendFile" : "share.send")).frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionStyle(primary: true))
            .disabled(preparing || (selected != .code && (card == nil || (downloadURL != nil && !qrAttempted))))
            .accessibilityIdentifier("share.send")
            if requested {
                Text(L.t("share.requested"))
                    .font(.footnote)
                    .accessibilityIdentifier("share.requested")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Design.paper)
    }

    private var selected: Mode { startsOnMilestone ? .milestone : mode }

    private var card: CardContent? {
        if selected == .milestone {
            return CardContent(title: L.f("share.days", model.stats.days.count), readings: [], tags: nil, qr: qr)
        }
        guard let result = model.result else { return nil }
        return CardContent(title: L.f("share.question", result.source.text), readings: result.targets,
                           tags: L.t("share.tags"), qr: qr)
    }

    private func send() async {
        guard !preparing else { return }
        preparing = true
        requested = false
        defer { preparing = false }
        do {
            let prepared: ShareActivity
            switch selected {
            case .code:
                let payload = model.sharePayload
                let bytes = try payload.encoded()
                let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let file = folder.appendingPathComponent("UnitConv.unitpreset")
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    do { try bytes.write(to: file, options: .atomic) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                }.value
                prepared = ShareActivity(items: [file, L.f("share.fileMessage", payload.name)], temporaryDirectory: folder)
            case .card, .milestone:
                guard let card, let image = ShareCard(content: card).image() else {
                    model.message = L.t("share.failed")
                    return
                }
                let caption: String
                if selected == .card, let result = model.result {
                    caption = L.f("share.caption", result.source.text, ListFormatter.localizedString(byJoining: result.targets.map(\.text)),
                                  L.t("share.tags").replacingOccurrences(of: "\n", with: " "))
                } else {
                    caption = card.title
                }
                prepared = ShareActivity(items: [image, caption])
            }
            model.recordAction()
            if Launch.isTesting {
                requested = true
            } else {
                activity = prepared
            }
        } catch {
            model.message = L.t("share.failed")
        }
    }
}

private final class ShareActivity: Identifiable {
    let id = UUID()
    let items: [Any]
    let temporaryDirectory: URL?

    init(items: [Any], temporaryDirectory: URL? = nil) {
        self.items = items
        self.temporaryDirectory = temporaryDirectory
    }

    deinit {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

private struct ShareController: UIViewControllerRepresentable {
    let activity: ShareActivity
    let onCompletion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activity.items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onCompletion() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
