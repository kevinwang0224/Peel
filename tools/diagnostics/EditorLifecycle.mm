// Native rendering diagnostic: no user documents, event injection, or production hooks.
#import <AppKit/AppKit.h>
#import "PeelEditor.h"

static NSScrollView *FindScrollView(NSView *view) {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:[NSScrollView class]]) return (NSScrollView *)subview;
        if (NSScrollView *found = FindScrollView(subview)) return found;
    }
    return nil;
}

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
        // Rubber-banding past the top: the clip view sits above the document. A top content inset
        // reproduces that position without event injection; ASan flags any negative-line layout.
        @autoreleasepool {
            NSMutableString *document = [NSMutableString stringWithString:@"{\n"];
            for (int line = 0; line < 300; line++) [document appendFormat:@"  \"key%d\": %d,\n", line, line];
            [document appendString:@"  \"end\": true\n}\n"];
            PeelEditorView *editor = [[PeelEditorView alloc] initWithFrame:NSMakeRect(0, 0, 900, 600)];
            window.contentView = editor;
            [editor loadDocument:document];
            [editor layoutSubtreeIfNeeded];
            NSClipView *clip = FindScrollView(editor).contentView;
            if (!clip) { fprintf(stderr, "Missing editor scroll view\n"); return 1; }
            const CGFloat overscrolls[] = {10, 80, 400};
            for (CGFloat overscroll : overscrolls) {
                clip.contentInsets = NSEdgeInsetsMake(overscroll, 0, 0, 0);
                NSRect above = NSMakeRect(0, -overscroll, clip.bounds.size.width, clip.bounds.size.height);
                [clip scrollToPoint:[clip constrainBoundsRect:above].origin];
                if (clip.bounds.origin.y != -overscroll) { fprintf(stderr, "Could not overscroll the editor\n"); return 1; }
                NSBitmapImageRep *rep = [editor bitmapImageRepForCachingDisplayInRect:editor.bounds];
                [editor cacheDisplayInRect:editor.bounds toBitmapImageRep:rep];
            }
            window.contentView = nil;
        }
        [window close];
    }
    fprintf(stdout, "EDITOR_OVERSCROLL_PASS=3\n");
    fprintf(stdout, "EDITOR_LIFECYCLE_PASS=500\n");
    return 0;
}
