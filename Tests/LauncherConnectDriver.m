#import <Cocoa/Cocoa.h>

// Inject only into an owned test process: drive the unchanged shipped app without accessibility permission.
static NSArray<NSView *> *views(NSView *view) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:view];
    for (NSView *child in view.subviews) [all addObjectsFromArray:views(child)];
    return all;
}
static void save(NSDictionary *result) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@(getenv("KHU_TEST_PROOF")) atomically:YES];
}
static void capture(NSWindow *window, NSString *suffix) {
    NSString *base = @(getenv("KHU_TEST_PROOF"));
    NSView *view = window.contentView;
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    if (rep) {
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[base stringByAppendingFormat:@".%@.png",suffix] atomically:YES];
    }
}
__attribute__((constructor)) static void start(void) {
    if (!getenv("KHU_TEST_PROOF") || !getenv("KHU_CONNECT_HOME")) return;
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
        __block int ticks = 0;
        __block BOOL pressed = NO;
        NSTimer *driver = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            if (++ticks > 300) { save(@{@"passed":@NO,@"reason":@"native flow timed out"}); exit(2); }
            NSWindow *window = nil;
            for (NSWindow *w in NSApp.windows) if ([w.title isEqualToString:@"Connect to Update Studio"]) window=w;
            if (!window) return;
            NSArray *all = views(window.contentView);
            NSTextField *address=nil,*name=nil,*code=nil;
            NSButton *connect=nil,*cancel=nil;
            NSMutableArray *texts=[NSMutableArray array];
            for (NSView *view in all) {
                if ([view isKindOfClass:NSTextField.class]) {
                    NSTextField *f=(NSTextField *)view;
                    if ([f.accessibilityLabel isEqual:@"Update Studio address"]) address=f;
                    if ([f.accessibilityLabel isEqual:@"Name for this Mac"]) name=f;
                    if ([f.accessibilityLabel isEqual:@"Pairing code"]) code=f;
                    if (f.stringValue.length) [texts addObject:f.stringValue];
                }
                if ([view isKindOfClass:NSButton.class]) {
                    NSButton *b=(NSButton *)view;
                    if ([b.title isEqual:@"Connect"] || [b.title isEqual:@"Continue"]) connect=b;
                    if ([b.title isEqual:@"Cancel"]) cancel=b;
                }
            }
            NSString *mode=@(getenv("KHU_TEST_CASE"));
            if (!pressed && connect && code && name) {
                if (![mode isEqual:@"ats-control"] && (!address || !address.editable || !address.enabled)) {
                    save(@{@"passed":@NO,@"reason":@"address is not editable"}); exit(3);
                }
                if (address) address.stringValue=@(getenv("KHU_TEST_ADDRESS"));
                name.stringValue=@(getenv("KHU_TEST_MACHINE"));
                code.stringValue=@(getenv("KHU_TEST_CODE"));
                capture(window,@"before"); pressed=YES; [connect performClick:nil]; return;
            }
            NSString *text=[texts componentsJoinedByString:@"\n"];
            BOOL connected=[text containsString:@"Connected. Studio Launcher KH"];
            BOOL refused=[text containsString:@"Not connected:"] || [text containsString:@"outside the Tailscale range"];
            if (!pressed || (!connected && !refused)) return;
            BOOL expected=[mode isEqual:@"success"] ? connected :
                [mode isEqual:@"ats-control"] ? (connected || [text containsString:@"secure connection"]) :
                [mode isEqual:@"public-address"] ? [text containsString:@"outside the Tailscale range"] :
                [text containsString:@"pairing code is wrong"];
            NSString *file=[@(getenv("KHU_CONNECT_HOME")) stringByAppendingPathComponent:@"Library/KHUpdater/base/config.json"];
            BOOL installed=[[NSFileManager defaultManager] fileExistsAtPath:file];
            BOOL pass=expected && installed==([mode isEqual:@"success"] || ([mode isEqual:@"ats-control"] && connected));
            capture(window,@"after");
            save(@{@"passed":@(pass),@"case":mode,@"installed":@(installed),@"text":text,
                   @"editable":@(address && address.editable),@"addressEnabled":@(address && address.enabled)});
            [timer invalidate];
            if (!pass) exit(4);
            [(connected ? connect : cancel) performClick:nil];
        }];
        [[NSRunLoop mainRunLoop] addTimer:driver forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:driver forMode:NSModalPanelRunLoopMode];
    }];
}
