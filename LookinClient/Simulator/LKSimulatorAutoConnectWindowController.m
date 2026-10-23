#import "LKSimulatorAutoConnectWindowController.h"
#import "LKSimulatorAutoConnect.h"

@interface LKSimulatorAutoConnectWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate>
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) NSSearchField *search;
@property(nonatomic, strong) NSTextField *bundleInput;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, copy) NSArray<NSDictionary *> *rows;
@end

@implementation LKSimulatorAutoConnectWindowController

+ (void)show {
    static LKSimulatorAutoConnectWindowController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [self new]; });
    LKSimulatorAutoConnect.sharedInstance.catalogVisible = YES;
    [controller rebuild];
    [controller showWindow:nil];
    [controller.window makeKeyAndOrderFront:nil];
    [LKSimulatorAutoConnect.sharedInstance refresh];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 780, 480)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        window.title = NSLocalizedString(@"Simulator Auto-Connect", nil);
        window.minSize = NSMakeSize(700, 440);
        window.delegate = self;
        [window center];
        NSView *content = window.contentView;
        NSTextField *description = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Remember apps on every Simulator, including after reinstalling. Lookin must be open before you launch the app. Restart an already running app once after enabling it.", nil)];
        self.search = [NSSearchField new];
        self.search.placeholderString = NSLocalizedString(@"Filter by app name or bundle ID", nil);
        self.search.delegate = self;
        NSButton *refresh = [NSButton buttonWithTitle:NSLocalizedString(@"Refresh", nil) target:self action:@selector(refresh)];
        self.table = [NSTableView new];
        self.table.delegate = self;
        self.table.dataSource = self;
        self.table.rowHeight = 34;
        self.table.usesAlternatingRowBackgroundColors = YES;
        NSArray *columns = @[@[@"enabled", NSLocalizedString(@"Auto", nil), @50],
                              @[@"name", NSLocalizedString(@"Application", nil), @180],
                              @[@"bundleID", NSLocalizedString(@"Bundle ID", nil), @260],
                              @[@"simulators", NSLocalizedString(@"Installed on", nil), @230]];
        for (NSArray *values in columns) {
            NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:values[0]];
            column.title = values[1];
            column.width = [values[2] doubleValue];
            [self.table addTableColumn:column];
        }
        NSScrollView *scroll = [NSScrollView new];
        scroll.documentView = self.table;
        scroll.hasVerticalScroller = YES;
        scroll.hasHorizontalScroller = YES;
        scroll.borderType = NSBezelBorder;
        self.bundleInput = [NSTextField new];
        self.bundleInput.placeholderString = NSLocalizedString(@"Or enter an app bundle ID", nil);
        self.bundleInput.target = self;
        self.bundleInput.action = @selector(addBundleID);
        NSButton *add = [NSButton buttonWithTitle:NSLocalizedString(@"Remember", nil) target:self action:@selector(addBundleID)];
        self.status = [NSTextField wrappingLabelWithString:@""];
        self.status.font = [NSFont systemFontOfSize:12];
        self.status.textColor = NSColor.secondaryLabelColor;
        self.status.maximumNumberOfLines = 3;
        NSTextField *footnote = [NSTextField wrappingLabelWithString:NSLocalizedString(@"Uncheck an app to stop future automatic connections. A server already loaded into an app remains until that app quits.", nil)];
        footnote.font = [NSFont systemFontOfSize:11];
        footnote.textColor = NSColor.secondaryLabelColor;
        for (NSView *view in @[description, self.search, refresh, scroll, self.bundleInput, add, self.status, footnote]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [content addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [description.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:20],
            [description.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-20],
            [description.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
            [self.search.topAnchor constraintEqualToAnchor:description.bottomAnchor constant:14],
            [self.search.leadingAnchor constraintEqualToAnchor:description.leadingAnchor],
            [self.search.trailingAnchor constraintEqualToAnchor:refresh.leadingAnchor constant:-10],
            [refresh.trailingAnchor constraintEqualToAnchor:description.trailingAnchor],
            [refresh.centerYAnchor constraintEqualToAnchor:self.search.centerYAnchor],
            [scroll.topAnchor constraintEqualToAnchor:self.search.bottomAnchor constant:12],
            [scroll.leadingAnchor constraintEqualToAnchor:description.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:description.trailingAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:self.bundleInput.topAnchor constant:-12],
            [self.bundleInput.leadingAnchor constraintEqualToAnchor:description.leadingAnchor],
            [self.bundleInput.trailingAnchor constraintEqualToAnchor:add.leadingAnchor constant:-10],
            [add.trailingAnchor constraintEqualToAnchor:description.trailingAnchor],
            [add.centerYAnchor constraintEqualToAnchor:self.bundleInput.centerYAnchor],
            [self.status.topAnchor constraintEqualToAnchor:self.bundleInput.bottomAnchor constant:10],
            [self.status.leadingAnchor constraintEqualToAnchor:description.leadingAnchor],
            [self.status.trailingAnchor constraintEqualToAnchor:description.trailingAnchor],
            [footnote.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:8],
            [footnote.leadingAnchor constraintEqualToAnchor:description.leadingAnchor],
            [footnote.trailingAnchor constraintEqualToAnchor:description.trailingAnchor],
            [footnote.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16]
        ]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(rebuild) name:LKSimulatorAutoConnectDidChangeNotification object:nil];
    }
    return self;
}

- (void)refresh { [LKSimulatorAutoConnect.sharedInstance refresh]; }

- (void)rebuild {
    LKSimulatorAutoConnect *manager = LKSimulatorAutoConnect.sharedInstance;
    NSMutableDictionary *apps = [NSMutableDictionary dictionary];
    for (NSDictionary *app in manager.availableApps) apps[app[@"bundleID"]] = app;
    for (NSString *bundleID in manager.rememberedApps) {
        if (!apps[bundleID]) apps[bundleID] = @{@"bundleID": bundleID, @"name": manager.rememberedApps[bundleID], @"simulators": @[]};
    }
    NSString *query = self.search.stringValue;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *entry in apps.allValues) {
        if (!query.length || [entry[@"bundleID"] localizedCaseInsensitiveContainsString:query] || [entry[@"name"] localizedCaseInsensitiveContainsString:query]) [rows addObject:entry];
    }
    self.rows = [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        BOOL a = manager.rememberedApps[left[@"bundleID"]] != nil, b = manager.rememberedApps[right[@"bundleID"]] != nil;
        return a != b ? (a ? NSOrderedAscending : NSOrderedDescending) : [left[@"bundleID"] compare:right[@"bundleID"]];
    }];
    self.status.stringValue = manager.statusText;
    self.status.toolTip = manager.statusText;
    [self.table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.rows.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *app = self.rows[row];
    if ([column.identifier isEqualToString:@"enabled"]) {
        NSButton *button = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggle:)];
        button.state = LKSimulatorAutoConnect.sharedInstance.rememberedApps[app[@"bundleID"]] ? NSControlStateValueOn : NSControlStateValueOff;
        button.identifier = app[@"bundleID"];
        button.accessibilityLabel = [NSString stringWithFormat:NSLocalizedString(@"Auto-connect %@", nil), app[@"bundleID"]];
        return button;
    }
    NSString *text;
    if ([column.identifier isEqualToString:@"simulators"]) {
        text = [app[@"simulators"] count] ? [app[@"simulators"] componentsJoinedByString:@", "] : NSLocalizedString(@"Not on a booted Simulator", nil);
    } else text = app[column.identifier];
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.toolTip = text;
    return label;
}

- (void)toggle:(NSButton *)button {
    NSString *name = button.identifier;
    for (NSDictionary *app in self.rows) if ([app[@"bundleID"] isEqual:button.identifier]) name = app[@"name"];
    [LKSimulatorAutoConnect.sharedInstance setBundleID:button.identifier name:name enabled:button.state == NSControlStateValueOn];
}

- (void)addBundleID {
    NSString *bundleID = [self.bundleInput.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![LKSimulatorAutoConnect isValidBundleID:bundleID]) {
        self.status.stringValue = NSLocalizedString(@"Enter a bundle ID containing letters, digits, dots or hyphens.", nil);
        return;
    }
    [LKSimulatorAutoConnect.sharedInstance setBundleID:bundleID name:bundleID enabled:YES];
    self.bundleInput.stringValue = @"";
    self.search.stringValue = @"";
}

- (void)controlTextDidChange:(NSNotification *)notification { if (notification.object == self.search) [self rebuild]; }
- (void)windowWillClose:(NSNotification *)notification { LKSimulatorAutoConnect.sharedInstance.catalogVisible = NO; }
@end
