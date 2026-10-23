import UIKit

@objc(ProbeAppDelegate)
final class ProbeAppDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    private var snapshotWindow: UIWindow?
    private var snapshotTimer: Timer?
    private var fixtureWindows: [UIWindow] = []

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProbeViewController()
        window.makeKeyAndVisible()
        self.window = window
        if ProcessInfo.processInfo.environment["LOOKIN_EDGE_FIXTURE"] == "1" {
            let edgeWindow = EdgeProbeWindow(frame: window.bounds)
            edgeWindow.rootViewController = EdgeProbeViewController()
            edgeWindow.windowLevel = UIWindow.Level(rawValue: 1)
            edgeWindow.makeKeyAndVisible()
            fixtureWindows.append(edgeWindow)
        }
        if ProcessInfo.processInfo.environment["LOOKIN_STRESS_FIXTURE"] == "1" {
            let stressWindow = StressProbeWindow(frame: window.bounds)
            stressWindow.rootViewController = StressProbeViewController()
            stressWindow.windowLevel = UIWindow.Level(rawValue: 2)
            stressWindow.makeKeyAndVisible()
            fixtureWindows.append(stressWindow)
        }
        if ProcessInfo.processInfo.environment["LOOKIN_HYPERION_FIXTURE"] == "1" {
            startChangingSnapshot(for: window)
        }
        return true
    }

    private func startChangingSnapshot(for sourceWindow: UIWindow) {
        let snapshotWindow = HyperionSnapshotProbeWindow(frame: sourceWindow.bounds)
        snapshotWindow.rootViewController = UIViewController()
        let container = snapshotWindow.rootViewController!.view!
        container.frame = sourceWindow.bounds
        snapshotWindow.windowLevel = UIWindow.Level(rawValue: -1)
        snapshotWindow.isHidden = false
        self.snapshotWindow = snapshotWindow
        // Моделируем фоновое окно Hyperion с постоянно заменяемым snapshot.
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak sourceWindow, weak container] _ in
            guard let sourceWindow, let container,
                  let snapshot = sourceWindow.snapshotView(afterScreenUpdates: false) else { return }
            container.subviews.forEach { $0.removeFromSuperview() }
            container.addSubview(snapshot)
        }
    }
}

@objc(HYPSnapshotDebuggingWindow)
private final class HyperionSnapshotProbeWindow: UIWindow {}

final class ProbeViewController: UIViewController {
    let probeLabel = ProbeLabel()
    let probeButton = UIButton(type: .system)
    let probeField = UITextField()
    let probeTextView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        probeLabel.text = "Lookin MCP · Server 1.2.8"
        probeLabel.accessibilityIdentifier = "lookin-probe-label"
        probeLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        probeLabel.textAlignment = .center
        probeLabel.numberOfLines = 0
        probeLabel.translatesAutoresizingMaskIntoConstraints = false
        probeButton.setTitle("Breakpoint injection verified", for: .normal)
        probeButton.accessibilityIdentifier = "lookin-probe-button"
        probeButton.translatesAutoresizingMaskIntoConstraints = false
        probeField.text = "MCP field value"
        probeField.placeholder = "MCP placeholder"
        probeField.borderStyle = .roundedRect
        probeField.translatesAutoresizingMaskIntoConstraints = false
        probeTextView.text = "MCP multiline text"
        probeTextView.font = .systemFont(ofSize: 17)
        probeTextView.textContainerInset = UIEdgeInsets(top: 5, left: 7, bottom: 11, right: 13)
        probeTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(probeLabel)
        view.addSubview(probeButton)
        view.addSubview(probeField)
        view.addSubview(probeTextView)
        NSLayoutConstraint.activate([
            probeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            probeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            probeLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            probeButton.topAnchor.constraint(equalTo: probeLabel.bottomAnchor, constant: 24),
            probeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            probeField.topAnchor.constraint(equalTo: probeButton.bottomAnchor, constant: 20),
            probeField.leadingAnchor.constraint(equalTo: probeLabel.leadingAnchor),
            probeField.trailingAnchor.constraint(equalTo: probeLabel.trailingAnchor),
            probeField.heightAnchor.constraint(equalToConstant: 40),
            probeTextView.topAnchor.constraint(equalTo: probeField.bottomAnchor, constant: 12),
            probeTextView.leadingAnchor.constraint(equalTo: probeLabel.leadingAnchor),
            probeTextView.trailingAnchor.constraint(equalTo: probeLabel.trailingAnchor),
            probeTextView.heightAnchor.constraint(equalToConstant: 80)
        ])
        if ProcessInfo.processInfo.environment["LOOKIN_HYBRID_FIXTURE"] == "1" {
            let fixture = HybridProbeContainer(frame: .zero)
            fixture.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(fixture)
            NSLayoutConstraint.activate([
                fixture.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                fixture.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                fixture.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                fixture.heightAnchor.constraint(equalToConstant: 220)
            ])
        }
    }
}

@objc(HybridProbeContainer)
final class HybridProbeContainer: UIView {

    // MARK: - Properties

    private let backCard = UIView(frame: CGRect(x: 8, y: 40, width: 180, height: 110))
    private var frontCard = UIView(frame: CGRect(x: 110, y: 75, width: 160, height: 80))
    private let stateLabel = UILabel(frame: CGRect(x: 8, y: 4, width: 300, height: 30))
    private let captionLabel = UILabel(frame: CGRect(x: 8, y: 12, width: 150, height: 30))
    private var revision = 0
    private var gestureCount = 0
    private var caption = "Hybrid caption 0"

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureFixture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureFixture()
    }
}

private extension HybridProbeContainer {

    // MARK: - Private Methods

    func configureFixture() {
        accessibilityIdentifier = "lookin-hybrid-container"
        backgroundColor = .clear
        backCard.accessibilityIdentifier = "lookin-hybrid-back"
        configureFrontCard()
        stateLabel.accessibilityIdentifier = "lookin-hybrid-state"
        stateLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        captionLabel.accessibilityIdentifier = "lookin-hybrid-caption"
        captionLabel.font = .systemFont(ofSize: 15)
        addSubview(backCard)
        addSubview(frontCard)
        backCard.addSubview(captionLabel)
        addSubview(stateLabel)
        let actions: [(String, Selector)] = [
            ("Mutate", #selector(mutateFixture)),
            ("Remove/add", #selector(toggleFrontCard)),
            ("Reset", #selector(resetFixture))
        ]
        for (index, action) in actions.enumerated() {
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 8 + index * 100, y: 172, width: 96, height: 40)
            button.setTitle(action.0, for: .normal)
            button.accessibilityIdentifier = "lookin-hybrid-control-\(index)"
            button.addTarget(self, action: action.1, for: .touchUpInside)
            addSubview(button)
        }
        backCard.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(recordTap)))
        updateFixture()
    }

    func updateFixture() {
        backCard.backgroundColor = revision == 0 ? .red : .green
        backCard.frame.origin.x = revision == 0 ? 8 : 18.5
        captionLabel.text = caption
        stateLabel.text = "Hybrid r\(revision) · front \(frontCard.superview == nil ? "absent" : "present") · taps \(gestureCount)"
    }

    func configureFrontCard() {
        frontCard.accessibilityIdentifier = "lookin-hybrid-front"
        frontCard.backgroundColor = UIColor(red: 0, green: 0, blue: 1, alpha: 0.65)
        frontCard.layer.cornerRadius = 12
    }

    @objc func mutateFixture() {
        revision = revision == 0 ? 1 : 0
        caption = "Hybrid caption \(revision)"
        updateFixture()
    }

    @objc func toggleFrontCard() {
        if frontCard.superview == nil {
            insertSubview(frontCard, aboveSubview: backCard)
        } else {
            frontCard.removeFromSuperview()
            // Освобождаем прежний объект, чтобы проверить weak-registry и устаревшие oid.
            frontCard = UIView(frame: CGRect(x: 110, y: 75, width: 160, height: 80))
            configureFrontCard()
        }
        updateFixture()
    }

    @objc func resetFixture() {
        revision = 0
        gestureCount = 0
        caption = "Hybrid caption 0"
        if frontCard.superview == nil {
            insertSubview(frontCard, aboveSubview: backCard)
        }
        updateFixture()
    }

    @objc func recordTap() {
        gestureCount += 1
        updateFixture()
    }
}

extension HybridProbeContainer {

    // MARK: - Public Methods

    @objc func lookin_customDebugInfos() -> [String: Any] {
        let captionSetter: @convention(block) (String?) -> Void = { [weak self] value in
            guard let self else { return }
            self.caption = value ?? ""
            self.updateFixture()
        }
        let properties: [[String: Any]] = [
            ["section": "Hybrid Fixture", "title": "Caption", "valueType": "string", "value": caption,
             "retainedSetter": unsafeBitCast(captionSetter, to: AnyObject.self)],
            ["section": "Hybrid Fixture", "title": "Revision", "valueType": "number", "value": revision],
            ["section": "Hybrid Fixture", "title": "FrontPresent", "valueType": "bool", "value": frontCard.superview != nil],
            ["section": "Hybrid Fixture", "title": "GestureCount", "valueType": "number", "value": gestureCount]
        ]
        return [
            "title": "Hybrid Fixture",
            "properties": properties,
            "subviews": [[
                "title": "Hybrid Virtual Parent", "subtitle": "Revision \(revision)",
                "frameInWindow": NSValue(cgRect: convert(backCard.frame, to: nil)),
                "properties": properties,
                "subviews": [[
                    "title": "Hybrid Virtual Child",
                    "frameInWindow": NSValue(cgRect: convert(CGRect(x: 20, y: 60, width: 40, height: 30), to: nil)),
                    "properties": [["section": "Hybrid Fixture", "title": "ReadOnly", "valueType": "string", "value": "virtual leaf"]]
                ]]
            ]]
        ]
    }
}

final class ProbeLabel: UILabel {
    // Runtime-discovered inspection data; this probe still has no Lookin linkage.
    @objc func lookin_customDebugInfos() -> [String: Any] {
        ["properties": [
            ["section": "MCP Regression", "title": "Text", "valueType": "string", "value": "MCP custom text"],
            ["section": "MCP Regression", "title": "FontName", "valueType": "string", "value": "SentinelFontOnly"],
            ["section": "MCP Regression", "title": "ProbeRect", "valueType": "rect", "value": NSValue(cgRect: CGRect(x: -3.5, y: 7.25, width: 42, height: 19))],
            ["section": "MCP Regression", "title": "ProbePoint", "valueType": "point", "value": NSValue(cgPoint: CGPoint(x: -2, y: 9.5))],
            ["section": "MCP Regression", "title": "ProbeSize", "valueType": "size", "value": NSValue(cgSize: CGSize(width: 17, height: 29))],
            ["section": "MCP Regression", "title": "ProbeInsets", "valueType": "insets", "value": NSValue(uiEdgeInsets: UIEdgeInsets(top: 2, left: 3, bottom: 5, right: 7))],
            ["section": "MCP Regression", "title": "ProbeShadow", "valueType": "shadow", "value": [
                "color": UIColor.red, "opacity": 0.5, "radius": 2.5, "offset": NSValue(cgSize: CGSize(width: -7, height: 11))
            ]]
        ]]
    }
}

@objc(EdgeProbeWindow)
private final class EdgeProbeWindow: UIWindow {}

@objc(StressProbeWindow)
private final class StressProbeWindow: UIWindow {}

@objc(EdgeVirtualOnlyLeaf)
final class EdgeVirtualOnlyLeaf: UIView {

    // MARK: - Properties

    private let virtualCaption = "Leaf with virtual children only"
}

extension EdgeVirtualOnlyLeaf {

    // MARK: - Public Methods

    @objc func lookin_customDebugInfos() -> [String: Any] {
        [
            "title": "Edge Virtual Only Leaf",
            "properties": [
                ["section": "Edge Fixture", "title": "UIKitChildCount", "valueType": "number", "value": subviews.count],
                ["section": "Edge Fixture", "title": "LayerChildCount", "valueType": "number", "value": layer.sublayers?.count ?? 0]
            ],
            "subviews": [[
                "title": "Edge Virtual Child",
                "frameInWindow": NSValue(cgRect: convert(CGRect(x: 8, y: 8, width: 54, height: 38), to: nil)),
                "properties": [["section": "Edge Fixture", "title": "Caption", "valueType": "string", "value": virtualCaption]],
                "subviews": [["title": "Edge Virtual Grandchild", "frameInWindow": NSValue(cgRect: convert(CGRect(x: 15, y: 16, width: 20, height: 16), to: nil))]]
            ]]
        ]
    }
}

@objc(EdgeExcludedScreenshotView)
final class EdgeExcludedScreenshotView: UIView {}

extension EdgeExcludedScreenshotView {

    // MARK: - Public Methods

    @objc func lookin_shouldCaptureImage() -> Bool { false }
}

@objc(EdgeProbeViewController)
final class EdgeProbeViewController: UIViewController {

    // MARK: - Properties

    private let virtualOnlyLeaf = EdgeVirtualOnlyLeaf()
    private let zeroContainer = UIView()
    private let zeroVisibleChild = UIView(frame: CGRect(x: 8, y: 8, width: 24, height: 24))
    private let zeroHiddenChild = UIView(frame: CGRect(x: 40, y: 8, width: 24, height: 24))
    private let offsetContainer = UIView()
    private let exclusionView = EdgeExcludedScreenshotView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .light))
    private let tabBar = UITabBar()
    private let stateLabel = UILabel()
    private let revealButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private var isZeroExpanded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureFixture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top + 12
        let width = max(280, view.bounds.width - 40)
        stateLabel.frame = CGRect(x: 20, y: top, width: width, height: 44)
        virtualOnlyLeaf.frame = CGRect(x: 20, y: top + 60, width: 130, height: 72)
        exclusionView.frame = CGRect(x: 175, y: top + 60, width: 100, height: 72)
        zeroContainer.frame = CGRect(x: 20, y: top + 162, width: isZeroExpanded ? 120 : 0, height: isZeroExpanded ? 52 : 0)
        offsetContainer.frame = CGRect(x: 175, y: top + 150, width: 130, height: 76)
        offsetContainer.bounds.origin = CGPoint(x: 9.5, y: -4.25)
        blurView.frame = CGRect(x: 20, y: top + 252, width: width, height: 78)
        tabBar.frame = CGRect(x: 20, y: top + 350, width: width, height: 60)
        revealButton.frame = CGRect(x: 20, y: top + 430, width: 160, height: 44)
        resetButton.frame = CGRect(x: 200, y: top + 430, width: 100, height: 44)
    }
}

private extension EdgeProbeViewController {

    // MARK: - Private Methods

    func configureFixture() {
        view.backgroundColor = .white
        view.accessibilityIdentifier = "lookin-edge-root"
        stateLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        stateLabel.numberOfLines = 2
        stateLabel.accessibilityIdentifier = "lookin-edge-state"
        virtualOnlyLeaf.backgroundColor = .purple
        virtualOnlyLeaf.accessibilityIdentifier = "lookin-edge-virtual-leaf"
        exclusionView.backgroundColor = .green
        exclusionView.accessibilityIdentifier = "lookin-edge-excluded"
        zeroContainer.backgroundColor = .orange
        zeroContainer.clipsToBounds = true
        zeroContainer.accessibilityIdentifier = "lookin-edge-zero-container"
        zeroVisibleChild.backgroundColor = .red
        zeroVisibleChild.accessibilityIdentifier = "lookin-edge-zero-visible-child"
        zeroHiddenChild.backgroundColor = .blue
        zeroHiddenChild.isHidden = true
        zeroHiddenChild.accessibilityIdentifier = "lookin-edge-zero-hidden-child"
        zeroContainer.addSubview(zeroVisibleChild)
        zeroContainer.addSubview(zeroHiddenChild)
        offsetContainer.backgroundColor = .cyan
        offsetContainer.accessibilityIdentifier = "lookin-edge-offset-container"
        let offsetChild = UIView(frame: CGRect(x: 20, y: 12, width: 50, height: 36))
        offsetChild.backgroundColor = .blue
        offsetChild.accessibilityIdentifier = "lookin-edge-offset-child"
        offsetContainer.addSubview(offsetChild)
        blurView.accessibilityIdentifier = "lookin-edge-blur"
        let blurLabel = UILabel(frame: CGRect(x: 12, y: 20, width: 220, height: 28))
        blurLabel.text = "UIVisualEffectView fixture"
        blurLabel.textColor = .black
        blurView.contentView.addSubview(blurLabel)
        tabBar.accessibilityIdentifier = "lookin-edge-tabbar"
        tabBar.items = [UITabBarItem(title: "Edge A", image: UIImage(systemName: "square"), tag: 0),
                        UITabBarItem(title: "Edge B", image: UIImage(systemName: "circle"), tag: 1)]
        tabBar.selectedItem = tabBar.items?.first
        revealButton.accessibilityIdentifier = "lookin-edge-toggle-zero"
        revealButton.addTarget(self, action: #selector(toggleZeroSize), for: .touchUpInside)
        resetButton.setTitle("Reset", for: .normal)
        resetButton.accessibilityIdentifier = "lookin-edge-reset"
        resetButton.addTarget(self, action: #selector(resetFixture), for: .touchUpInside)
        [stateLabel, virtualOnlyLeaf, exclusionView, zeroContainer, offsetContainer, blurView, tabBar, revealButton, resetButton].forEach(view.addSubview)
        updateState()
    }

    func updateState() {
        stateLabel.text = "Edge: zero \(isZeroExpanded ? "120×52" : "0×0")\nPurple: virtual only · green: capture excluded"
        revealButton.setTitle(isZeroExpanded ? "Make zero size" : "Reveal zero view", for: .normal)
        view.setNeedsLayout()
    }

    @objc func toggleZeroSize() {
        isZeroExpanded.toggle()
        updateState()
    }

    @objc func resetFixture() {
        isZeroExpanded = false
        tabBar.selectedItem = tabBar.items?.first
        updateState()
    }
}

@objc(StressProbeViewController)
final class StressProbeViewController: UIViewController {

    // MARK: - Properties

    private let tileCount = min(5000, max(1, Int(ProcessInfo.processInfo.environment["LOOKIN_STRESS_TILE_COUNT"] ?? "100") ?? 100))
    private lazy var tiles = (0..<tileCount).map { StressProbeTile(index: $0) }
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        view.accessibilityIdentifier = "lookin-stress-root"
        statusLabel.text = "Stress: \(tileCount) static tiles · native resolution"
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        statusLabel.numberOfLines = 2
        statusLabel.accessibilityIdentifier = "lookin-stress-status"
        tiles.forEach(view.addSubview)
        view.addSubview(statusLabel)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top + 12
        statusLabel.frame = CGRect(x: 20, y: top, width: view.bounds.width - 40, height: 44)
        let tileWidth = min(250, max(180, view.bounds.width - 120))
        for (index, tile) in tiles.enumerated() {
            if tileCount > 100 {
                let columns = 50
                tile.frame = CGRect(x: 10 + CGFloat(index % columns) * 7, y: top + 62 + CGFloat(index / columns) * 7, width: 6, height: 6)
            } else {
                tile.frame = CGRect(x: 20 + CGFloat(index % 10) * 7, y: top + 62 + CGFloat(index / 10) * 20, width: tileWidth, height: 240)
            }
        }
    }
}

@objc(StressProbeTile)
final class StressProbeTile: UIView {

    // MARK: - Properties

    private let index: Int

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        accessibilityIdentifier = "lookin-stress-tile-\(index)"
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        index = 0
        super.init(coder: coder)
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let drawingIndex = ProcessInfo.processInfo.environment["LOOKIN_STRESS_UNIQUE"] == "0" ? 0 : index
        if bounds.width < 10 {
            UIColor(red: CGFloat(drawingIndex % 251) / 250, green: CGFloat((drawingIndex / 251) % 251) / 250, blue: 0.5, alpha: 0.7).setFill()
            context.fill(bounds)
            return
        }
        // Фиксированный узор усложняет PNG-кодирование без таймеров и изменения качества снимка.
        for row in 0..<24 {
            for column in 0..<24 {
                let seed = (drawingIndex * 47 + row * 29 + column * 17) % 255
                UIColor(red: CGFloat(seed) / 255, green: CGFloat((seed * 3) % 255) / 255,
                        blue: CGFloat((seed * 7) % 255) / 255, alpha: 0.92).setFill()
                context.fill(CGRect(x: CGFloat(column) * bounds.width / 24, y: CGFloat(row) * bounds.height / 24,
                                    width: bounds.width / 24 + 0.5, height: bounds.height / 24 + 0.5))
            }
        }
        ("Tile \(drawingIndex)" as NSString).draw(at: CGPoint(x: 12, y: 12), withAttributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .bold), .foregroundColor: UIColor.black,
            .backgroundColor: UIColor.white
        ])
    }
}
