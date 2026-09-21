// main.m — 7-Zip for macOS
//
// A native AppKit front end for the bundled 7-Zip console engine (7zz).
//
// Design notes
//   * No XIB/Storyboard: the whole UI is built in code, so the project builds
//     with the Command Line Tools alone (no full Xcode installation).
//   * The archive engine is the unmodified-signature 7zz binary shipped in
//     Contents/Resources.  All archive work is delegated to it via NSTask,
//     which keeps this front end small and avoids re-implementing formats.
//   * Drag and drop onto the window (and onto the Dock icon, through
//     application:openFiles:) handles both directions: dropping an archive
//     opens it, dropping any other files offers to compress them.
//
// Build: see dist/app/build_app.sh

#import <AppKit/AppKit.h>

#pragma mark - helpers

static NSString *HumanSize(long long n, BOOL folder)
{
    if (folder) return @"—";
    if (n < 0)  return @"—";
    if (n < 1024) return [NSString stringWithFormat:@"%lld B", n];
    double v = (double)n;
    NSArray *u = @[@"KB", @"MB", @"GB", @"TB"];
    NSUInteger i = 0;
    v /= 1024.0;
    while (v >= 1024.0 && i + 1 < u.count) { v /= 1024.0; i++; }
    return [NSString stringWithFormat:@"%.1f %@", v, u[i]];
}

static NSString *EnginePath(void)
{
    return [[NSBundle mainBundle] pathForResource:@"7zz" ofType:nil];
}

#pragma mark - task runner

@interface ZTask : NSObject
@property (nonatomic, copy) void (^onOutput)(NSString *chunk);
@property (nonatomic, copy) void (^onFinish)(int status, NSString *all);
@property (nonatomic, readonly) BOOL running;
- (void)run:(NSArray<NSString *> *)args;
- (void)cancel;
@end

@interface ZTask ()
@property (nonatomic, strong) NSTask *task;
@property (nonatomic, strong) NSMutableString *buffer;
@property (nonatomic, assign) BOOL runningFlag;
@end

@implementation ZTask

- (instancetype)init
{
    if ((self = [super init])) { _buffer = [NSMutableString string]; }
    return self;
}

- (BOOL)running { return _runningFlag; }

- (void)run:(NSArray<NSString *> *)args
{
    self.task = [[NSTask alloc] init];
    self.task.executableURL = [NSURL fileURLWithPath:EnginePath()];
    self.task.arguments = args;

    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"LC_ALL"] = @"en_US.UTF-8";      // keep 7zz output parseable
    self.task.environment = env;

    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    self.task.standardOutput = outPipe;
    self.task.standardError  = errPipe;

    __weak ZTask *weakSelf = self;

    void (^handle)(NSFileHandle *) = ^(NSFileHandle *fh) {
        NSData *d = [fh availableData];
        if (d.length == 0) { fh.readabilityHandler = nil; return; }
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!s) {
            s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
        }
        if (s.length) {
            ZTask *me = weakSelf;
            if (!me) return;
            @synchronized (me.buffer) { [me.buffer appendString:s]; }
            if (me.onOutput) { me.onOutput(s); }
        }
    };

    outPipe.fileHandleForReading.readabilityHandler = handle;
    errPipe.fileHandleForReading.readabilityHandler = handle;

    self.task.terminationHandler = ^(NSTask *t) {
        ZTask *me = weakSelf;
        if (!me) return;
        outPipe.fileHandleForReading.readabilityHandler = nil;
        errPipe.fileHandleForReading.readabilityHandler = nil;
        // drain anything still buffered
        NSData *rest = [outPipe.fileHandleForReading readDataToEndOfFile];
        NSData *restE = [errPipe.fileHandleForReading readDataToEndOfFile];
        NSString *tail = [[NSString alloc] initWithData:rest encoding:NSUTF8StringEncoding];
        NSString *tailE = [[NSString alloc] initWithData:restE encoding:NSUTF8StringEncoding];
        @synchronized (me.buffer) {
            if (tail)  [me.buffer appendString:tail];
            if (tailE) [me.buffer appendString:tailE];
        }
        me.runningFlag = NO;
        if (me.onFinish) { me.onFinish(t.terminationStatus, [me.buffer copy]); }
    };

    NSError *err = nil;
    if (![self.task launchAndReturnError:&err]) {
        self.runningFlag = NO;
        if (self.onFinish) { self.onFinish(-1, [NSString stringWithFormat:@"无法启动 7zz: %@", err.localizedDescription]); }
        return;
    }
    self.runningFlag = YES;
}

- (void)cancel { if (self.runningFlag) { [self.task terminate]; } }

@end

#pragma mark - archive model

@interface ArcItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL isFolder;
@property (nonatomic, assign) long long size;
@property (nonatomic, assign) long long packed;
@property (nonatomic, copy) NSString *modified;
@property (nonatomic, copy) NSString *method;
@end

@implementation ArcItem
@end

static NSArray<ArcItem *> *ParseListing(NSString *out)
{
    NSMutableArray<ArcItem *> *items = [NSMutableArray array];
    NSArray *blocks = [out componentsSeparatedByString:@"\n\n"];
    for (NSString *block in blocks) {
        NSMutableDictionary *kv = [NSMutableDictionary dictionary];
        for (NSString *line in [block componentsSeparatedByString:@"\n"]) {
            NSRange eq = [line rangeOfString:@" = "];
            if (eq.location == NSNotFound) continue;
            NSString *k = [line substringToIndex:eq.location];
            NSString *v = [line substringFromIndex:eq.location + 3];
            kv[k] = v;
        }
        NSString *p = kv[@"Path"];
        if (!p.length) continue;
        if (kv[@"Type"]) continue;                       // archive's own header block
        ArcItem *it = [[ArcItem alloc] init];
        it.path     = p;
        it.isFolder = [kv[@"Folder"] isEqualToString:@"+"];
        it.size     = [kv[@"Size"] longLongValue];
        it.packed   = [kv[@"Packed Size"] longLongValue];
        NSString *mod = kv[@"Modified"] ?: @"";
        // 7-Zip prints 2026-09-21 22:41:13.1204491; trim to seconds
        if (mod.length > 19) mod = [mod substringToIndex:19];
        it.modified = mod;
        it.method   = kv[@"Method"] ?: (it.isFolder ? @"" : @"");
        [items addObject:it];
    }
    return items;
}

#pragma mark - drop view

@protocol DropViewDelegate <NSObject>
- (void)dropView:(id)view didReceiveURLs:(NSArray<NSURL *> *)urls;
@end

@interface DropView : NSView
@property (nonatomic, weak) id<DropViewDelegate> dropDelegate;
@property (nonatomic, assign) BOOL highlighted;
@end

@implementation DropView

- (instancetype)initWithFrame:(NSRect)f
{
    if ((self = [super initWithFrame:f])) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    self.highlighted = YES;
    self.needsDisplay = YES;
    return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender
{
    self.highlighted = NO;
    self.needsDisplay = YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    self.highlighted = NO;
    self.needsDisplay = YES;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSPasteboardItem *it in [sender.draggingPasteboard pasteboardItems]) {
        NSString *s = [it stringForType:NSPasteboardTypeFileURL];
        if (s) { NSURL *u = [NSURL URLWithString:s]; if (u) [urls addObject:u]; }
    }
    if (urls.count && [self.dropDelegate respondsToSelector:@selector(dropView:didReceiveURLs:)]) {
        [self.dropDelegate dropView:self didReceiveURLs:urls];
        return YES;
    }
    return NO;
}

- (void)drawRect:(NSRect)dirty
{
    [super drawRect:dirty];
    if (self.highlighted) {
        [[NSColor colorWithCalibratedRed:0.145 green:0.286 blue:0.541 alpha:0.12] setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 8, 8)
                                                          xRadius:12 yRadius:12];
        [p setLineWidth:3];
        [[NSColor colorWithCalibratedRed:0.145 green:0.286 blue:0.541 alpha:0.8] setStroke];
        [p stroke];
    }
}
@end

#pragma mark - main view controller

@interface MainViewController : NSViewController
    <NSTableViewDataSource, NSTableViewDelegate, DropViewDelegate, NSTextFieldDelegate>
@end

@interface MainViewController ()
@property (nonatomic, strong) DropView *drop;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSScrollView *tableScroll;
@property (nonatomic, strong) NSTextView *log;
@property (nonatomic, strong) NSScrollView *logScroll;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *archiveLabel;
@property (nonatomic, strong) NSPopUpButton *formatPop;
@property (nonatomic, strong) NSSlider *levelSlider;
@property (nonatomic, strong) NSTextField *levelLabel;
@property (nonatomic, strong) NSSecureTextField *password;
@property (nonatomic, strong) NSButton *extractBtn;
@property (nonatomic, strong) NSButton *testBtn;
@property (nonatomic, strong) NSButton *addBtn;
@property (nonatomic, strong) NSButton *compressBtn;
@property (nonatomic, strong) NSButton *cancelBtn;

@property (nonatomic, copy) NSString *archivePath;
@property (nonatomic, strong) NSArray<ArcItem *> *items;
@property (nonatomic, strong) ZTask *current;
@end

@implementation MainViewController

- (void)loadView
{
    self.drop = [[DropView alloc] initWithFrame:NSMakeRect(0, 0, 940, 640)];
    self.drop.dropDelegate = self;
    self.view = self.drop;
    [self buildUI];
    [self setControlsEnabled:NO];
    self.statusLabel.stringValue = @"将归档或文件夹拖到这里";
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-method-access"

- (NSTextField *)label:(NSString *)s
{
    NSTextField *t = [[NSTextField alloc] initWithFrame:NSZeroRect];
    t.stringValue = s;
    t.editable = NO;
    t.bordered = NO;
    t.drawsBackground = NO;
    t.translatesAutoresizingMaskIntoConstraints = NO;
    return t;
}

- (NSButton *)button:(NSString *)title action:(SEL)sel
{
    NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (void)buildUI
{
    // ---------- header row ----------
    NSTextField *title = [self label:@"7-Zip"];
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];

    self.archiveLabel = [self label:@"未打开归档"];
    self.archiveLabel.textColor = [NSColor secondaryLabelColor];
    self.archiveLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

    self.formatPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.formatPop.translatesAutoresizingMaskIntoConstraints = NO;
    [self.formatPop addItemsWithTitles:@[@"7z", @"zip", @"tar", @"xz", @"gz", @"bz2"]];
    [self.formatPop selectItemAtIndex:0];

    self.levelSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.levelSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.levelSlider.minValue = 0; self.levelSlider.maxValue = 9;
    self.levelSlider.integerValue = 5;
    self.levelSlider.target = self;
    self.levelSlider.action = @selector(levelChanged:);

    self.levelLabel = [self label:@"级别 5"];

    self.password = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.password.translatesAutoresizingMaskIntoConstraints = NO;
    self.password.placeholderString = @"密码（可选）";

    self.compressBtn = [self button:@"压缩…" action:@selector(doCompressPick:)];

    // ---------- content row ----------
    self.table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.allowsMultipleSelection = YES;
    self.table.rowHeight = 20;

    NSArray *cols = @[@[@"名称", @380], @[@"大小", @90], @[@"压缩后", @90], @[@"修改时间", @150], @[@"方法", @110]];
    for (NSArray *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[0];
        col.width = [c[1] doubleValue];
        [self.table addTableColumn:col];
    }

    self.tableScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.tableScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableScroll.documentView = self.table;
    self.tableScroll.hasVerticalScroller = YES;
    self.tableScroll.drawsBackground = YES;
    self.tableScroll.backgroundColor = [NSColor textBackgroundColor];

    // ---------- log ----------
    self.log = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.log.editable = NO;
    self.log.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.log.string = @"";
    self.logScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.logScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.logScroll.documentView = self.log;
    self.logScroll.hasVerticalScroller = YES;
    self.logScroll.drawsBackground = YES;
    self.logScroll.backgroundColor = [NSColor textBackgroundColor];

    // ---------- bottom row ----------
    self.extractBtn = [self button:@"解压到…" action:@selector(doExtract:)];
    self.testBtn    = [self button:@"测试" action:@selector(doTest:)];
    self.addBtn     = [self button:@"添加文件…" action:@selector(doAdd:)];
    self.cancelBtn  = [self button:@"停止" action:@selector(doCancel:)];
    self.cancelBtn.enabled = NO;

    self.progress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progress.translatesAutoresizingMaskIntoConstraints = NO;
    self.progress.style = NSProgressIndicatorStyleBar;
    self.progress.indeterminate = NO;
    self.progress.minValue = 0; self.progress.maxValue = 100;

    self.statusLabel = [self label:@"就绪"];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];

    for (NSView *v in @[title, self.archiveLabel, self.formatPop, self.levelSlider, self.levelLabel,
                        self.password, self.compressBtn, self.tableScroll, self.logScroll,
                        self.extractBtn, self.testBtn, self.addBtn, self.cancelBtn,
                        self.progress, self.statusLabel]) {
        [self.drop addSubview:v];
    }

    NSMutableArray *cons = [NSMutableArray array];

    // header
    [cons addObject:[NSLayoutConstraint constraintWithItem:title attribute:NSLayoutAttributeTop
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeTop multiplier:1 constant:16]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:title attribute:NSLayoutAttributeLeading
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeLeading multiplier:1 constant:20]];

    [cons addObject:[NSLayoutConstraint constraintWithItem:self.archiveLabel attribute:NSLayoutAttributeLeading
        relatedBy:NSLayoutRelationEqual toItem:title attribute:NSLayoutAttributeTrailing multiplier:1 constant:12]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.archiveLabel attribute:NSLayoutAttributeCenterY
        relatedBy:NSLayoutRelationEqual toItem:title attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.archiveLabel attribute:NSLayoutAttributeTrailing
        relatedBy:NSLayoutRelationLessThanOrEqual toItem:self.drop attribute:NSLayoutAttributeTrailing multiplier:1 constant:-20]];

    // compression controls row: format / level / password / compress
    NSArray *row = @[self.formatPop, self.levelSlider, self.levelLabel, self.password, self.compressBtn];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.formatPop attribute:NSLayoutAttributeTop
        relatedBy:NSLayoutRelationEqual toItem:title attribute:NSLayoutAttributeBottom multiplier:1 constant:14]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.formatPop attribute:NSLayoutAttributeLeading
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeLeading multiplier:1 constant:20]];

    NSView *prev = self.formatPop;
    for (NSUInteger i = 1; i < row.count; i++) {
        NSView *v = row[i];
        [cons addObject:[NSLayoutConstraint constraintWithItem:v attribute:NSLayoutAttributeLeading
            relatedBy:NSLayoutRelationEqual toItem:prev attribute:NSLayoutAttributeTrailing multiplier:1 constant:10]];
        [cons addObject:[NSLayoutConstraint constraintWithItem:v attribute:NSLayoutAttributeCenterY
            relatedBy:NSLayoutRelationEqual toItem:self.formatPop attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
        prev = v;
    }
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.levelSlider attribute:NSLayoutAttributeWidth
        relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:120]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.password attribute:NSLayoutAttributeWidth
        relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:160]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.compressBtn attribute:NSLayoutAttributeTrailing
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeTrailing multiplier:1 constant:-20]];

    // table
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.tableScroll attribute:NSLayoutAttributeTop
        relatedBy:NSLayoutRelationEqual toItem:self.formatPop attribute:NSLayoutAttributeBottom multiplier:1 constant:14]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.tableScroll attribute:NSLayoutAttributeLeading
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeLeading multiplier:1 constant:20]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.tableScroll attribute:NSLayoutAttributeTrailing
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeTrailing multiplier:1 constant:-20]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.tableScroll attribute:NSLayoutAttributeHeight
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeHeight multiplier:0.42 constant:0]];

    // log
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.logScroll attribute:NSLayoutAttributeTop
        relatedBy:NSLayoutRelationEqual toItem:self.tableScroll attribute:NSLayoutAttributeBottom multiplier:1 constant:10]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.logScroll attribute:NSLayoutAttributeLeading
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeLeading multiplier:1 constant:20]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.logScroll attribute:NSLayoutAttributeTrailing
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeTrailing multiplier:1 constant:-20]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.logScroll attribute:NSLayoutAttributeHeight
        relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:110]];

    // action buttons
    NSArray *acts = @[self.extractBtn, self.testBtn, self.addBtn, self.cancelBtn];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.extractBtn attribute:NSLayoutAttributeTop
        relatedBy:NSLayoutRelationEqual toItem:self.logScroll attribute:NSLayoutAttributeBottom multiplier:1 constant:12]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.extractBtn attribute:NSLayoutAttributeLeading
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeLeading multiplier:1 constant:20]];
    prev = self.extractBtn;
    for (NSUInteger i = 1; i < acts.count; i++) {
        NSView *v = acts[i];
        [cons addObject:[NSLayoutConstraint constraintWithItem:v attribute:NSLayoutAttributeLeading
            relatedBy:NSLayoutRelationEqual toItem:prev attribute:NSLayoutAttributeTrailing multiplier:1 constant:8]];
        [cons addObject:[NSLayoutConstraint constraintWithItem:v attribute:NSLayoutAttributeCenterY
            relatedBy:NSLayoutRelationEqual toItem:self.extractBtn attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
        prev = v;
    }

    // progress + status
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.progress attribute:NSLayoutAttributeLeading
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeLeading multiplier:1 constant:20]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.progress attribute:NSLayoutAttributeTrailing
        relatedBy:NSLayoutRelationEqual toItem:self.statusLabel attribute:NSLayoutAttributeLeading multiplier:1 constant:-10]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.progress attribute:NSLayoutAttributeCenterY
        relatedBy:NSLayoutRelationEqual toItem:self.statusLabel attribute:NSLayoutAttributeCenterY multiplier:1 constant:0]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.progress attribute:NSLayoutAttributeWidth
        relatedBy:NSLayoutRelationGreaterThanOrEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:260]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.statusLabel attribute:NSLayoutAttributeTrailing
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeTrailing multiplier:1 constant:-20]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.statusLabel attribute:NSLayoutAttributeBottom
        relatedBy:NSLayoutRelationEqual toItem:self.drop attribute:NSLayoutAttributeBottom multiplier:1 constant:-14]];
    [cons addObject:[NSLayoutConstraint constraintWithItem:self.statusLabel attribute:NSLayoutAttributeWidth
        relatedBy:NSLayoutRelationGreaterThanOrEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:160]];

    [NSLayoutConstraint activateConstraints:cons];
}

#pragma clang diagnostic pop

- (void)levelChanged:(id)s
{
    self.levelLabel.stringValue = [NSString stringWithFormat:@"级别 %ld", (long)self.levelSlider.integerValue];
}

- (void)setControlsEnabled:(BOOL)on
{
    self.extractBtn.enabled = on;
    self.testBtn.enabled = on;
    self.addBtn.enabled = on;
}

- (void)appendLog:(NSString *)s
{
    if (!s.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTextStorage *st = self.log.textStorage;
        [st appendAttributedString:[[NSAttributedString alloc] initWithString:s
            attributes:@{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
                         NSForegroundColorAttributeName: [NSColor labelColor]}]];
        [self.log scrollRangeToVisible:NSMakeRange(st.length, 0)];
    });
}

- (void)showStatus:(NSString *)s
{
    dispatch_async(dispatch_get_main_queue(), ^{ self.statusLabel.stringValue = s; });
}

// parse "NN%" out of a progress chunk written by 7zz -bsp1
- (void)handleProgress:(NSString *)chunk
{
    NSArray *parts = [chunk componentsSeparatedByString:@"\r"];
    for (NSString *p in parts) {
        NSRange r = [p rangeOfString:@"%"];
        if (r.location == NSNotFound) continue;
        // walk back to the digits
        NSInteger i = (NSInteger)r.location - 1;
        NSMutableString *digits = [NSMutableString string];
        while (i >= 0) {
            unichar c = [p characterAtIndex:(NSUInteger)i];
            if (c >= '0' && c <= '9') { [digits insertString:[NSString stringWithFormat:@"%C", c] atIndex:0]; i--; }
            else break;
        }
        if (digits.length) {
            double v = digits.doubleValue;
            dispatch_async(dispatch_get_main_queue(), ^{ self.progress.doubleValue = v; });
        }
    }
}

#pragma mark operations

- (void)runEngine:(NSArray<NSString *> *)args
          status:(NSString *)what
        onFinish:(void (^)(int status))done
{
    if (self.current.running) {
        NSBeep();
        [self showStatus:@"已有任务在执行"];
        return;
    }

    [self appendLog:[NSString stringWithFormat:@"\n$ 7zz %@\n", [args componentsJoinedByString:@" "]]];

    ZTask *t = [[ZTask alloc] init];
    self.current = t;
    self.cancelBtn.enabled = YES;
    self.progress.doubleValue = 0;
    [self showStatus:what];

    __weak MainViewController *weakSelf = self;
    t.onOutput = ^(NSString *chunk) {
        MainViewController *me = weakSelf;
        if (!me) return;
        [me handleProgress:chunk];
    };
    t.onFinish = ^(int st, NSString *all) {
        MainViewController *me = weakSelf;
        dispatch_async(dispatch_get_main_queue(), ^{
            me.cancelBtn.enabled = NO;
            me.progress.doubleValue = st == 0 ? 100 : 0;
            // strip carriage-return progress noise before logging
            NSMutableArray *lines = [NSMutableArray array];
            for (NSString *l in [all componentsSeparatedByString:@"\n"]) {
                NSString *c = [l stringByReplacingOccurrencesOfString:@"\r" withString:@""];
                if (c.length) [lines addObject:c];
            }
            NSString *clean = [lines componentsJoinedByString:@"\n"];
            if (clean.length) [me appendLog:[clean stringByAppendingString:@"\n"]];
            if (done) done(st);
        });
    };
    [t run:args];
}

- (void)doCancel:(id)s
{
    [self.current cancel];
    [self showStatus:@"已请求停止"];
}

- (void)openArchive:(NSString *)path
{
    self.archivePath = path;
    self.archiveLabel.stringValue = path;
    self.items = @[];
    [self.table reloadData];
    [self showStatus:@"正在读取归档…"];
    [self reloadListing];
}

- (void)reloadListing
{
    if (!self.archivePath) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *t = [[NSTask alloc] init];
        t.executableURL = [NSURL fileURLWithPath:EnginePath()];
        t.arguments = @[@"l", @"-slt", self.archivePath];
        NSPipe *p = [NSPipe pipe];
        t.standardOutput = p;
        t.standardError = [NSPipe pipe];
        NSError *e = nil;
        if (![t launchAndReturnError:&e]) return;
        NSData *d = [p.fileHandleForReading readDataToEndOfFile];
        [t waitUntilExit];
        NSString *out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        NSArray<ArcItem *> *items = ParseListing(out);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.items = items;
            [self.table reloadData];
            self.archiveLabel.stringValue = [NSString stringWithFormat:@"%@  ·  %lu 项",
                                             self.archivePath ?: @"", (unsigned long)items.count];
            [self setControlsEnabled:YES];
            [self showStatus:[NSString stringWithFormat:@"已载入 %lu 项", (unsigned long)items.count]];
        });
    });
}

- (void)doOpen:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    p.message = @"选择要打开的归档";
    if ([p runModal] == NSModalResponseOK) {
        [self openArchive:p.URL.path];
    }
}

- (void)doExtract:(id)s
{
    if (!self.archivePath) return;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO;
    p.canChooseDirectories = YES;
    p.canCreateDirectories = YES;
    p.allowsMultipleSelection = NO;
    p.message = @"选择解压目标文件夹";
    p.directoryURL = [NSURL fileURLWithPath:[self.archivePath stringByDeletingLastPathComponent]];
    if ([p runModal] != NSModalResponseOK) return;

    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"x", self.archivePath,
                             [NSString stringWithFormat:@"-o%@", p.URL.path], @"-y", nil];
    if (self.password.stringValue.length) [args addObject:[NSString stringWithFormat:@"-p%@", self.password.stringValue]];

    __weak MainViewController *weakSelf = self;
    [self runEngine:args status:@"正在解压…" onFinish:^(int st) {
        [weakSelf showStatus:(st == 0 ? @"解压完成" : [NSString stringWithFormat:@"解压失败（状态 %d）", st])];
    }];
}

- (void)doTest:(id)s
{
    if (!self.archivePath) return;
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"t", self.archivePath, nil];
    if (self.password.stringValue.length) [args addObject:[NSString stringWithFormat:@"-p%@", self.password.stringValue]];
    __weak MainViewController *weakSelf = self;
    [self runEngine:args status:@"正在校验完整性…" onFinish:^(int st) {
        [weakSelf showStatus:(st == 0 ? @"完整性校验通过" : [NSString stringWithFormat:@"校验失败（状态 %d）", st])];
    }];
}

- (void)doAdd:(id)s
{
    if (!self.archivePath) return;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = YES;
    p.allowsMultipleSelection = YES;
    p.message = @"选择要加入归档的文件或文件夹";
    if ([p runModal] != NSModalResponseOK) return;
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"a", self.archivePath, nil];
    for (NSURL *u in p.URLs) [args addObject:u.path];
    __weak MainViewController *weakSelf = self;
    [self runEngine:args status:@"正在添加…" onFinish:^(int st) {
        MainViewController *me = weakSelf;
        [me showStatus:(st == 0 ? @"已添加" : [NSString stringWithFormat:@"添加失败（状态 %d）", st])];
        [me reloadListing];
    }];
}

- (void)doCompressPick:(id)s
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES;
    p.canChooseDirectories = YES;
    p.allowsMultipleSelection = YES;
    p.message = @"选择要压缩的文件或文件夹";
    if ([p runModal] != NSModalResponseOK) return;
    [self compressURLs:p.URLs];
}

- (void)compressURLs:(NSArray<NSURL *> *)urls
{
    if (!urls.count) return;
    NSString *fmt = self.formatPop.titleOfSelectedItem;
    NSString *base = urls.count == 1 ? urls[0].lastPathComponent : @"归档";
    NSString *dir  = urls[0].URLByDeletingLastPathComponent.path ?: NSHomeDirectory();

    NSSavePanel *sp = [NSSavePanel savePanel];
    sp.message = @"保存归档";
    sp.nameFieldStringValue = [NSString stringWithFormat:@"%@.%@", base, fmt];
    sp.directoryURL = [NSURL fileURLWithPath:dir];
    if ([sp runModal] != NSModalResponseOK) return;

    NSMutableArray *args = [NSMutableArray array];
    [args addObject:@"a"];
    [args addObject:[NSString stringWithFormat:@"-t%@", fmt]];
    [args addObject:[NSString stringWithFormat:@"-mx=%ld", (long)self.levelSlider.integerValue]];
    [args addObject:@"-bsp1"];
    if (self.password.stringValue.length) {
        [args addObject:[NSString stringWithFormat:@"-p%@", self.password.stringValue]];
        [args addObject:@"-mhe=on"];          // encrypt headers for 7z
    }
    [args addObject:sp.URL.path];
    for (NSURL *u in urls) [args addObject:u.path];

    __weak MainViewController *weakSelf = self;
    [self runEngine:args status:@"正在压缩…" onFinish:^(int st) {
        MainViewController *me = weakSelf;
        [me showStatus:(st == 0 ? @"压缩完成" : [NSString stringWithFormat:@"压缩失败（状态 %d）", st])];
        if (st == 0) [me openArchive:sp.URL.path];
    }];
}

#pragma mark drag & drop

- (void)dropView:(id)view didReceiveURLs:(NSArray<NSURL *> *)urls
{
    if (urls.count == 1) {
        NSNumber *isDir = nil;
        [urls[0] getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL];
        if (!isDir.boolValue) {
            // treat a single non-directory as an archive to open
            [self openArchive:urls[0].path];
            return;
        }
    }
    [self compressURLs:urls];
}

#pragma mark table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.items.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)self.items.count) return nil;
    ArcItem *it = self.items[(NSUInteger)row];
    NSTextField *tf = [tv makeViewWithIdentifier:col.identifier owner:self];
    if (!tf) {
        tf = [[NSTextField alloc] initWithFrame:NSZeroRect];
        tf.editable = NO; tf.bordered = NO; tf.drawsBackground = NO;
        tf.textColor = [NSColor labelColor];
        tf.identifier = col.identifier;
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    NSString *ident = col.identifier;
    if ([ident isEqualToString:@"名称"])      tf.stringValue = it.path;
    else if ([ident isEqualToString:@"大小"])
        tf.stringValue = (it.isFolder && it.size == 0) ? @"—" : HumanSize(it.size, NO);
    else if ([ident isEqualToString:@"压缩后"])
        tf.stringValue = (it.isFolder || it.packed <= 0) ? @"—" : HumanSize(it.packed, NO);
    else if ([ident isEqualToString:@"修改时间"]) tf.stringValue = it.modified;
    else if ([ident isEqualToString:@"方法"])   tf.stringValue = it.method;
    return tf;
}

@end

#pragma mark - app delegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) MainViewController *vc;
@end

@implementation AppDelegate

- (void)buildMenu
{
    NSMenu *bar = [[NSMenu alloc] init];

    // application menu
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"关于 7-Zip" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"服务" action:nil keyEquivalent:@""];
    NSMenu *services = [[NSMenu alloc] init];
    [NSApp setServicesMenu:services];
    appMenu.itemArray.lastObject.submenu = services;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"隐藏 7-Zip" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"退出 7-Zip" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    // file
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [bar addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    [fileMenu addItemWithTitle:@"打开归档…" action:@selector(doOpen:) keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"压缩…" action:@selector(doCompressPick:) keyEquivalent:@"n"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"解压到…" action:@selector(doExtract:) keyEquivalent:@"e"];
    [fileMenu addItemWithTitle:@"测试归档" action:@selector(doTest:) keyEquivalent:@"t"];
    fileItem.submenu = fileMenu;

    // edit (so the password field gets standard shortcuts)
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;

    // archive
    NSMenuItem *arcItem = [[NSMenuItem alloc] init];
    [bar addItem:arcItem];
    NSMenu *arcMenu = [[NSMenu alloc] initWithTitle:@"操作"];
    [arcMenu addItemWithTitle:@"停止当前任务" action:@selector(doCancel:) keyEquivalent:@"."];
    arcItem.submenu = arcMenu;

    // window
    NSMenuItem *winItem = [[NSMenuItem alloc] init];
    [bar addItem:winItem];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
    [winMenu addItemWithTitle:@"最小化" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winMenu addItemWithTitle:@"缩放" action:@selector(performZoom:) keyEquivalent:@""];
    winItem.submenu = winMenu;

    NSApp.mainMenu = bar;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    [self buildMenu];

    self.vc = [[MainViewController alloc] init];
    NSRect frame = NSMakeRect(0, 0, 940, 640);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"7-Zip";
    self.window.contentViewController = self.vc;
    self.window.minSize = NSMakeSize(820, 560);
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];

    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (void)openPathOnLaunch:(NSString *)path
{
    [self.vc openArchive:path];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)application:(NSApplication *)app openFiles:(NSArray<NSString *> *)filenames
{
    for (NSString *f in filenames) {
        [self.vc openArchive:f];
        break;      // open the first one
    }
    [app replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

#pragma mark services

- (void)compressWithSevenZip:(NSPasteboard *)pboard
                    userData:(NSString *)userData
                       error:(NSString **)error
{
    NSArray *urls = [pboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) { if (error) *error = @"没有收到文件"; return; }
    [self.vc compressURLs:urls];
}

- (void)extractWithSevenZip:(NSPasteboard *)pboard
                   userData:(NSString *)userData
                      error:(NSString **)error
{
    NSArray *urls = [pboard readObjectsForClasses:@[NSURL.class]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls.count) { if (error) *error = @"没有收到归档"; return; }
    [self.vc openArchive:[urls[0] path]];
    [self.vc performSelector:@selector(doExtract:) withObject:nil afterDelay:0.4];
}

@end

#pragma mark - main

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Allow an archive to be handed over on the command line:
        //   7-Zip.app/Contents/MacOS/7-Zip <archive>
        // This also makes the front end scriptable from a shell.
        for (int i = 1; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if (a.length && ![a hasPrefix:@"-"]) {
                [delegate performSelector:@selector(openPathOnLaunch:)
                               withObject:a
                               afterDelay:0.4];
                break;
            }
        }

        [app run];
    }
    return 0;
}
