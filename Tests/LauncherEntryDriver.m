#import <Cocoa/Cocoa.h>

// Test-only injection into the owned candidate; the enrolled case uses the real helper's open acknowledgement.
static void save(NSDictionary *result) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:@(getenv("KHU_TEST_ENTRY_PROOF")) atomically:YES];
}
static NSArray<NSView *> *views(NSView *view) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:view];
    for (NSView *child in view.subviews) [all addObjectsFromArray:views(child)];
    return all;
}
__attribute__((constructor)) static void start(void) {
    if (!getenv("KHU_TEST_ENTRY_PROOF")) return;
    BOOL enrolled = [@(getenv("KHU_TEST_ENTRY_CASE")) hasPrefix:@"enrolled"];
    if (enrolled) {
        [[NSDistributedNotificationCenter defaultCenter] addObserverForName:@"com.khupdater.launcher.shown" object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSString *home=[NSFileManager defaultManager].homeDirectoryForCurrentUser.path;
            BOOL found=[[NSFileManager defaultManager] fileExistsAtPath:[home stringByAppendingPathComponent:@"Library/KHUpdater/base/config.json"]];
            save(@{@"passed":@YES,@"case":@(getenv("KHU_TEST_ENTRY_CASE")),@"mainWindowAcknowledged":@YES,@"home":home,@"configFound":@(found)});
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            save(@{@"passed":@NO,@"reason":@"existing helper did not open; pairing must not replace it"}); exit(6);
        });
        return;
    }
    if (!getenv("KHU_CONNECT_HOME")) { save(@{@"passed":@NO,@"reason":@"window case requires isolated home"}); exit(2); }
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        __block int ticks=0;
        NSTimer *timer=[NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            if (++ticks>100) { save(@{@"passed":@NO,@"reason":@"connection window missing"}); exit(3); }
            NSWindow *window=nil;
            for (NSWindow *w in NSApp.windows) if ([w.title isEqual:@"Connect to Update Studio"] && w.visible) window=w;
            if (!window) return;
            NSRect screen=window.screen.visibleFrame, frame=window.frame;
            BOOL centered=fabs(NSMidX(frame)-NSMidX(screen))<2 && fabs(NSMidY(frame)-NSMidY(screen))<NSHeight(screen)*0.12;
            BOOL normal=window.level==NSNormalWindowLevel && NSApp.modalWindow==nil;
            NSWindow *other=[[NSWindow alloc] initWithContentRect:NSMakeRect(80,80,220,120) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            other.title=@"Test another normal window"; [other makeKeyAndOrderFront:nil];
            BOOL usable=other.keyWindow;
            [other orderOut:nil];
            [window makeKeyAndOrderFront:nil];
            NSView *content=window.contentView;
            NSBitmapImageRep *rep=[content bitmapImageRepForCachingDisplayInRect:content.bounds];
            if (rep) {
                [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[@(getenv("KHU_TEST_ENTRY_PROOF")) stringByAppendingString:@".png"] atomically:YES];
            }
            save(@{@"passed":@(centered && normal && usable),@"case":@"connection-window",@"centered":@(centered),@"normalWindow":@(normal),@"otherWindowUsable":@(usable),@"frame":NSStringFromRect(frame),@"screen":NSStringFromRect(screen)});
            [timer invalidate];
            if (!(centered && normal && usable)) exit(4);
            for (NSView *v in views(content)) if ([v isKindOfClass:NSButton.class] && [((NSButton *)v).title isEqual:@"Cancel"]) { [(NSButton *)v performClick:nil]; return; }
            exit(5);
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSModalPanelRunLoopMode];
    }];
}
