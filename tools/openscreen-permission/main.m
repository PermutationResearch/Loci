#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

@interface PermissionDelegate : NSObject <NSApplicationDelegate>
@end

@implementation PermissionDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    CGRequestScreenCaptureAccess();

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Openscreen requested Screen Recording access"];
    [alert setInformativeText:@"If macOS asks, enable Openscreen in System Settings > Privacy & Security > Screen & System Audio Recording."];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];

    [NSApp terminate:nil];
}
@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        PermissionDelegate *delegate = [[PermissionDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }

    return 0;
}
