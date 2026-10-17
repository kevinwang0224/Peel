// Native rendering diagnostic: no user documents, event injection, or production hooks.
#import <AppKit/AppKit.h>
#import "PeelEditor.h"

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 600)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        NSArray<NSString *> *documents = @[@"", @"\n", @"{}\n", @"\n\n",
            @"{\n  \"name\": \"Peel\",\n  \"items\": [1, 2, 3]\n}\n"];
        NSString *cursorPath = [[NSBundle mainBundle] pathForResource:@"mac_cursor_flipped" ofType:@"tiff"];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:cursorPath];
        if (!image) { fprintf(stderr, "Missing diagnostic cursor image\n"); return 1; }
        NSCursor *cursor = [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(15, 2)];
        for (int iteration = 0; iteration < 100; iteration++) {
            for (NSString *document in documents) {
                @autoreleasepool {
                    PeelEditorView *editor = [[PeelEditorView alloc] initWithFrame:NSMakeRect(0, 0, 900, 600)];
                    window.contentView = editor;
                    [editor loadDocument:document];
                    [editor layoutSubtreeIfNeeded];
                    NSBitmapImageRep *rep = [editor bitmapImageRepForCachingDisplayInRect:editor.bounds];
                    if (!rep) { fprintf(stderr, "Could not create render target\n"); return 1; }
                    [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:rep];
                    if (![editor.text isEqualToString:document]) {
                        fprintf(stderr, "Rendering changed the document\n"); return 1;
                    }
                    [cursor set];
                    [[NSCursor IBeamCursor] set];
                    [[NSCursor resizeLeftRightCursor] set];
                    [[NSCursor arrowCursor] set];
                    window.contentView = nil;
                }
            }
        }
        [window close];
    }
    fprintf(stdout, "EDITOR_LIFECYCLE_PASS=500\n");
    return 0;
}
