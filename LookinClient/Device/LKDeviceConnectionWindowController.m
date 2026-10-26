#import "LKDeviceConnectionWindowController.h"
#import "LKDeviceConnection.h"

@interface LKDeviceConnectionWindowController ()
@property(nonatomic, strong) NSPopUpButton *devices;
@property(nonatomic, strong) NSPopUpButton *mode;
@property(nonatomic, strong) NSTextField *appPath;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSButton *connectButton;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *chooseButton;
@property(nonatomic, copy) NSArray<NSDictionary *> *rows;
@end

@implementation LKDeviceConnectionWindowController
+ (void)showXcodeIntegration {
    [LKDeviceConnection.sharedInstance xcodeIntegrationStatus:^(NSDictionary *state) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Xcode Integration";
        if (state[@"error"]) {
            alert.informativeText = state[@"error"];
            [alert runModal];
            return;
        }
        BOOL enabled = [state[@"enabled"] boolValue];
        alert.informativeText = [NSString stringWithFormat:@"%@\n\nEnable once with Xcode closed. Then reopen Xcode, use Run normally on an iOS device or Simulator, and select your app in Lookin. Keep Debug executable and breakpoints enabled. Xcode keeps its debugger connected.\n\nEnabled integration updates automatically when this dialog opens. Simulator Auto-Connect also supports launches outside Xcode.", enabled ? @"Integration is enabled." : @"Integration is disabled."];
        [alert addButtonWithTitle:enabled ? @"Disable" : @"Enable"];
        [alert addButtonWithTitle:@"Close"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        [LKDeviceConnection.sharedInstance setXcodeIntegrationEnabled:!enabled completion:^(NSDictionary *result) {
            NSAlert *finished = [NSAlert new];
            finished.messageText = @"Xcode Integration";
            finished.informativeText = result[@"error"] ?: result[@"message"] ?: @"Done.";
            [finished runModal];
        }];
    }];
}

+ (void)show {
    static LKDeviceConnectionWindowController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ controller = [self new]; });
    [controller showWindow:nil];
    [controller.window makeKeyAndOrderFront:nil];
    [controller refresh];
}

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 390) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        window.title = @"Connect Physical Device";
        [window center];
        NSTextField *intro = [NSTextField wrappingLabelWithString:@"Inspect a development app over USB without adding LookinServer to its project. Supports iPhone and iPad running iOS 14–16."];
        self.devices = [NSPopUpButton new];
        self.devices.accessibilityLabel = @"USB device";
        self.refreshButton = [NSButton buttonWithTitle:@"Refresh Devices" target:self action:@selector(refresh)];
        self.appPath = [NSTextField new];
        self.appPath.placeholderString = @"Path to a signed Debug-iphoneos .app";
        self.appPath.accessibilityLabel = @"Development application path";
        self.appPath.stringValue = [NSUserDefaults.standardUserDefaults stringForKey:@"DeviceConnectionAppPath"] ?: @"";
        self.chooseButton = [NSButton buttonWithTitle:@"Choose App…" target:self action:@selector(chooseApp)];
        self.mode = [NSPopUpButton new];
        [self.mode addItemsWithTitles:@[@"Launch app and connect", @"Attach to running app"]];
        self.mode.accessibilityLabel = @"Connection mode";
        NSTextField *help = [NSTextField wrappingLabelWithString:@"Install the app with Xcode first. Use the same signed .app from your build. Unlock the device and stop its Xcode debugger before connecting. Attach requires the app to be open on screen. After the app quits, connect again to load the server."];
        help.font = [NSFont systemFontOfSize:12];
        help.textColor = NSColor.secondaryLabelColor;
        self.status = [NSTextField wrappingLabelWithString:@""];
        self.status.accessibilityLabel = @"Device connection status";
        self.status.maximumNumberOfLines = 5;
        self.connectButton = [NSButton buttonWithTitle:@"Connect" target:self action:@selector(connect)];
        self.connectButton.bezelStyle = NSBezelStyleRounded;
        NSStackView *deviceRow = [NSStackView stackViewWithViews:@[self.devices, self.refreshButton]];
        NSStackView *appRow = [NSStackView stackViewWithViews:@[self.appPath, self.chooseButton]];
        NSStackView *stack = [NSStackView stackViewWithViews:@[intro, deviceRow, appRow, self.mode, help, self.status, self.connectButton]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 14;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [window.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-20],
            [stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:20],
            [stack.bottomAnchor constraintLessThanOrEqualToAnchor:window.contentView.bottomAnchor constant:-20],
            [deviceRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [appRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [intro.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [help.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [self.status.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
        ]];
        [self.appPath setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.devices setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}

- (void)setWorking:(BOOL)working {
    for (NSControl *control in @[self.devices, self.appPath, self.mode, self.refreshButton, self.chooseButton, self.connectButton]) control.enabled = !working;
}

- (void)refresh {
    [self setWorking:YES];
    if (LKDeviceConnection.sharedInstance.busy) {
        self.status.stringValue = @"A device operation is in progress…";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self.window.visible) [self refresh];
        });
        return;
    }
    self.status.stringValue = @"Looking for USB devices…";
    [LKDeviceConnection.sharedInstance listDevices:^(NSDictionary *result) {
        [self setWorking:NO];
        self.rows = result[@"devices"] ?: @[];
        [self.devices removeAllItems];
        for (NSDictionary *row in self.rows) [self.devices addItemWithTitle:[NSString stringWithFormat:@"%@ — %@ (iOS %@)%@", row[@"name"], row[@"model"], row[@"osVersion"], [row[@"supported"] boolValue] ? @"" : @" — unsupported"]];
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"DeviceConnectionDeviceID"];
        for (NSUInteger i = 0; i < self.rows.count; i++) if ([self.rows[i][@"id"] isEqual:saved]) [self.devices selectItemAtIndex:i];
        self.status.stringValue = result[@"error"] ?: (self.rows.count ? @"Choose a device and a development application." : @"No USB devices found. Unlock the device and trust this Mac.");
        self.connectButton.enabled = self.rows.count > 0;
    }];
}

- (void)chooseApp {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowedFileTypes = @[@"app"];
    panel.treatsFilePackagesAsDirectories = NO;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) self.appPath.stringValue = panel.URL.path;
    }];
}

- (void)connect {
    NSInteger index = self.devices.indexOfSelectedItem;
    if (index < 0 || index >= self.rows.count || !self.appPath.stringValue.length) {
        self.status.stringValue = @"Choose a USB device and a signed development .app."; return;
    }
    NSString *identifier = self.rows[index][@"id"];
    NSString *path = self.appPath.stringValue;
    [NSUserDefaults.standardUserDefaults setObject:identifier forKey:@"DeviceConnectionDeviceID"];
    [NSUserDefaults.standardUserDefaults setObject:path forKey:@"DeviceConnectionAppPath"];
    [self setWorking:YES];
    self.status.stringValue = @"Preparing and loading LookinServer… Keep the device unlocked. This can take a few minutes.";
    [LKDeviceConnection.sharedInstance connectDevice:identifier appPath:path mode:self.mode.indexOfSelectedItem ? @"attach" : @"launch" completion:^(NSDictionary *result) {
        [self setWorking:NO];
        self.status.stringValue = [result[@"success"] boolValue] ? @"Connected. The hierarchy is ready in Lookin." : result[@"error"] ?: @"Connection failed.";
        self.status.toolTip = result[@"log"] ?: self.status.stringValue;
    }];
}
@end
