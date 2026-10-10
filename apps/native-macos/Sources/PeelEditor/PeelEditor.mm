#import "PeelEditor.h"
#include <string>
#include <string_view>
#include <vector>
#include <libproc.h>
#include <sys/resource.h>
#include <unistd.h>
#include <malloc/malloc.h>
void PeelReleaseUnusedMemory(void) {
    // Return unused allocator pages after idle/close; live editor buffers remain owned normally.
    malloc_zone_pressure_relief(nullptr, 0);
}
uint64_t PeelPhysicalFootprint(void) {
    struct rusage_info_v2 usage = {};
    return proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0 ? usage.ri_phys_footprint : 0;
}
#include "ILexer.h"
#include "LexerModule.h"
#include "SciLexer.h"
#import "ScintillaView.h"
extern const Lexilla::LexerModule lmJSON;
extern const Lexilla::LexerModule lmCPP;

// Scintilla stores opaque RGB: resolve AppKit's alpha-based label colors against the editor surface.
static NSColor *PeelBlend(NSColor *color, NSColor *background, CGFloat alpha) {
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *base = [background colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    return [NSColor colorWithSRGBRed:rgb.redComponent * alpha + base.redComponent * (1 - alpha)
                             green:rgb.greenComponent * alpha + base.greenComponent * (1 - alpha)
                              blue:rgb.blueComponent * alpha + base.blueComponent * (1 - alpha) alpha:1];
}
static NSColor *PeelOpaqueColor(NSColor *color, NSColor *background) {
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    return PeelBlend(rgb, background, rgb.alphaComponent);
}
// SCI_SETELEMENTCOLOUR expects 0xAABBGGRR.
static sptr_t PeelPackedRGBA(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    return (sptr_t)(0xFFu << 24 | (unsigned)lround(rgb.blueComponent * 255) << 16 |
                    (unsigned)lround(rgb.greenComponent * 255) << 8 | (unsigned)lround(rgb.redComponent * 255));
}
// System monospaced (SF Mono) when Scintilla's font lookup can resolve it; Menlo otherwise.
static NSString *PeelEditorFontName(void) {
    static NSString *name;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFont *mono = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];
        name = [NSFont fontWithName:mono.fontName size:13] ? mono.fontName : @"Menlo";
    });
    return name;
}
// Chevron fold markers: Scintilla's built-in arrows look like triangles from another UI era.
// Render straight-alpha RGBA at 2x so the glyph matches the line-number color and stays crisp.
static const int PeelFoldGlyphPixels = 24;
static NSData *PeelChevronPixels(BOOL expanded, NSColor *color) {
    const int n = PeelFoldGlyphPixels;
    NSMutableData *coverage = [NSMutableData dataWithLength:n * n];
    CGContextRef gc = CGBitmapContextCreate(coverage.mutableBytes, n, n, 8, n, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    CGContextSetLineWidth(gc, 2.6);
    CGContextSetLineCap(gc, kCGLineCapRound);
    CGContextSetLineJoin(gc, kCGLineJoinRound);
    CGContextSetGrayStrokeColor(gc, 0, 1);
    if (expanded) { // y is up: the apex sits below the arms
        CGContextMoveToPoint(gc, 6, 15); CGContextAddLineToPoint(gc, 12, 9); CGContextAddLineToPoint(gc, 18, 15);
    } else {
        CGContextMoveToPoint(gc, 9, 18); CGContextAddLineToPoint(gc, 15, 12); CGContextAddLineToPoint(gc, 9, 6);
    }
    CGContextStrokePath(gc);
    CGContextRelease(gc);
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    unsigned char r = lround(rgb.redComponent * 255), g = lround(rgb.greenComponent * 255), b = lround(rgb.blueComponent * 255);
    NSMutableData *pixels = [NSMutableData dataWithLength:n * n * 4];
    unsigned char *out = (unsigned char *)pixels.mutableBytes;
    const unsigned char *in = (const unsigned char *)coverage.bytes;
    for (int i = 0; i < n * n; i++) { out[i * 4] = r; out[i * 4 + 1] = g; out[i * 4 + 2] = b; out[i * 4 + 3] = in[i]; }
    return pixels;
}
static const int PeelErrorAnnotationStyle = 60;
static const NSInteger PeelMatchLimit = 10000;

@interface PeelEditorView (Selection)
- (void)replaceSelectionWithText:(NSString *)text;
@end
@interface PeelContentView : SCIContentView
@property(assign) PeelEditorView *peelOwner;
@end
@implementation PeelContentView
- (NSRect)accessibilityFrame {
    if (!self.window) return NSZeroRect;
    return [self.window convertRectToScreen:[self convertRect:self.visibleRect toView:nil]];
}
- (void)paste:(id)sender {
    NSString *text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (!text) return;
    if (self.peelOwner.transformPaste) text = self.peelOwner.transformPaste(text);
    [self.peelOwner replaceSelectionWithText:text];
}
- (void)copy:(id)sender {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSString *selected = [self.peelOwner selectedText];
    [pasteboard clearContents];
    [pasteboard setString:selected.length ? selected : self.peelOwner.text forType:NSPasteboardTypeString];
}
- (void)keyDown:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagCommand) && event.keyCode == 36 && self.peelOwner.onRun) {
        self.peelOwner.onRun(); return;
    }
    [super keyDown:event];
}
@end
@interface PeelScintillaView : ScintillaView
@end
@implementation PeelScintillaView
+ (Class)contentViewClass { return [PeelContentView class]; }
@end

// Syntax palettes. Roles map onto the JSON lexer styles; the JavaScript lexer reuses key, string,
// number and keyword. Only token colors are themed; backgrounds stay system-driven.
struct PeelPalette { uint32_t key, string, number, keyword, punctuation, escape, error; };
struct PeelSyntaxTheme { const char *name; PeelPalette light, dark; };
static const PeelSyntaxTheme PeelSyntaxThemes[] = {
    {"vscode",
        {0x0451a5, 0xa31515, 0x098658, 0x0000ff, 0x000000, 0xee0000, 0xe51400},
        {0x9cdcfe, 0xce9178, 0xb5cea8, 0x569cd6, 0xd4d4d4, 0xd7ba7d, 0xf44747}},
    {"github",
        {0x0550ae, 0x0a3069, 0x953800, 0xcf222e, 0x57606a, 0x116329, 0x82071e},
        {0x79c0ff, 0xa5d6ff, 0xffa657, 0xff7b72, 0x8b949e, 0x7ee787, 0xffa198}},
    {"solarized",
        {0x268bd2, 0x2aa198, 0xd33682, 0x859900, 0x657b83, 0xcb4b16, 0xdc322f},
        {0x268bd2, 0x2aa198, 0xd33682, 0x859900, 0x839496, 0xcb4b16, 0xdc322f}},
    {"one",
        {0xe45649, 0x50a14f, 0x986801, 0xa626a4, 0x696c77, 0x0184bc, 0xca1243},
        {0xe06c75, 0x98c379, 0xd19a66, 0xc678dd, 0xabb2bf, 0x56b6c2, 0xf44747}},
    {"nord",
        {0x5e81ac, 0x587a3c, 0xa0648f, 0x3d7e8a, 0x6b7689, 0xa17a1f, 0xbf616a},
        {0x88c0d0, 0xa3be8c, 0xb48ead, 0x81a1c1, 0x8f9bb3, 0xebcb8b, 0xbf616a}},
    {"dracula",
        {0x036a96, 0x846e15, 0x644ac9, 0xa3144d, 0x6b6f85, 0xa34d14, 0xcb3a2a},
        {0x8be9fd, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0xa4a9c4, 0xffb86c, 0xff5555}},
    {"catppuccin",
        {0x1e66f5, 0x40a02b, 0xfe640b, 0x8839ef, 0x7c7f93, 0x179299, 0xd20f39},
        {0x89b4fa, 0xa6e3a1, 0xfab387, 0xcba6f7, 0x9399b2, 0x94e2d5, 0xf38ba8}},
};
static NSString *PeelResolvedThemeName(NSString *name) {
    for (const auto &theme : PeelSyntaxThemes) if ([name isEqualToString:@(theme.name)]) return name;
    return @(PeelSyntaxThemes[0].name);
}
static const PeelPalette &PeelPaletteFor(NSString *name, BOOL dark) {
    for (const auto &theme : PeelSyntaxThemes)
        if ([name isEqualToString:@(theme.name)]) return dark ? theme.dark : theme.light;
    return dark ? PeelSyntaxThemes[0].dark : PeelSyntaxThemes[0].light;
}
static NSColor *PeelHex(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0
                                blue:(rgb & 0xff) / 255.0 alpha:1];
}

@interface PeelEditorView () <ScintillaNotificationProtocol> {
    PeelScintillaView *_editor;
    BOOL _updating;
    NSString *_language;
    NSInteger _fontSize;
    BOOL _dark;
    BOOL _readOnly;
    BOOL _appliedRecessed;
    NSString *_syntaxTheme;
    NSString *_appliedTheme;
    BOOL _configured;
    BOOL _cursorReportPending;
    NSInteger _marginDigits;
    NSInteger _errorOffset;
    NSString *_errorMessage;
}
@end
@implementation PeelEditorView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _editor = [[PeelScintillaView alloc] initWithFrame:self.bounds];
        _editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _editor.delegate = self;
        ((PeelContentView *)_editor.content).peelOwner = self;
        [self addSubview:_editor];
        [_editor message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
        [_editor message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
        [_editor message:SCI_SETMARGINWIDTHN wParam:0 lParam:42];
        [_editor message:SCI_SETMARGINTYPEN wParam:1 lParam:SC_MARGIN_SYMBOL];
        [_editor message:SCI_SETMARGINMASKN wParam:1 lParam:SC_MASK_FOLDERS];
        [_editor message:SCI_SETMARGINWIDTHN wParam:1 lParam:16];
        [_editor message:SCI_SETMARGINSENSITIVEN wParam:1 lParam:1];
        // Scintilla shows a mirrored arrow over margins; keep the standard arrow like the rest of the app.
        [_editor message:SCI_SETMARGINCURSORN wParam:0 lParam:SC_CURSORARROW];
        [_editor message:SCI_SETMARGINCURSORN wParam:1 lParam:SC_CURSORARROW];
        [_editor message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEREND lParam:SC_MARK_ARROW];
        [_editor message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPENMID lParam:SC_MARK_ARROWDOWN];
        [_editor message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERMIDTAIL lParam:SC_MARK_EMPTY];
        [_editor message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERTAIL lParam:SC_MARK_EMPTY];
        [_editor message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDERSUB lParam:SC_MARK_EMPTY];
        [_editor message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDER lParam:SC_MARK_ARROW];
        [_editor message:SCI_MARKERDEFINE wParam:SC_MARKNUM_FOLDEROPEN lParam:SC_MARK_ARROWDOWN];
        [_editor message:SCI_SETAUTOMATICFOLD wParam:SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];
        [_editor message:SCI_SETMARGINLEFT wParam:0 lParam:8];
        [_editor message:SCI_SETMARGINRIGHT wParam:0 lParam:12];
        [_editor message:SCI_SETEXTRAASCENT wParam:2];
        [_editor message:SCI_SETEXTRADESCENT wParam:2];
        [_editor message:SCI_SETINDENT wParam:2];
        [_editor message:SCI_SETTABWIDTH wParam:2];
        [_editor message:SCI_SETUSETABS wParam:0];
        [_editor message:SCI_SETWRAPMODE wParam:SC_WRAP_NONE];
        [_editor message:SCI_SETLAYOUTCACHE wParam:SC_CACHE_PAGE];
        [_editor message:SCI_INDICSETSTYLE wParam:8 lParam:INDIC_SQUIGGLE];
        _errorOffset = -1;
        [self configureLanguage:@"json" dark:NO fontSize:14 readOnly:NO];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(systemColorsChanged:)
                                                     name:NSSystemColorsDidChangeNotification object:nil];
    }
    return self;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    // Scintilla copies colors once, so repaint them whenever the view's real appearance flips.
    _configured = NO;
    [self configureLanguage:_language dark:_dark fontSize:_fontSize readOnly:_readOnly];
}
- (void)systemColorsChanged:(NSNotification *)notification {
    // Accent and selection colors are copied into Scintilla; refresh them when the user changes them.
    _configured = NO;
    [self configureLanguage:_language dark:_dark fontSize:_fontSize readOnly:_readOnly];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _editor.delegate = nil;
    ((PeelContentView *)_editor.content).peelOwner = nil;
}
- (NSString *)selectedText {
    // Unlike the documentation, this Scintilla build returns the byte count without the terminator.
    const sptr_t length = [_editor message:SCI_GETSELTEXT];
    if (length <= 0) return @"";
    std::string buffer((size_t)length + 1, '\0');
    [_editor message:SCI_GETSELTEXT wParam:0 lParam:(sptr_t)buffer.data()];
    return [[NSString alloc] initWithBytes:buffer.data() length:(NSUInteger)length encoding:NSUTF8StringEncoding] ?: @"";
}
- (NSString *)text {
    const sptr_t length = [_editor message:SCI_GETLENGTH];
    if (length == 0) return @"";
    std::string buffer(length + 1, '\0');
    [_editor message:SCI_GETTEXT wParam:length + 1 lParam:(sptr_t)buffer.data()];
    return [[NSString alloc] initWithBytes:buffer.data() length:length encoding:NSUTF8StringEncoding] ?: @"";
}
- (void)setText:(NSString *)text {
    if ([self.text isEqualToString:text]) return;
    _updating = YES;
    BOOL readOnly = ![_editor isEditable];
    [_editor setEditable:YES];
    [_editor message:SCI_BEGINUNDOACTION];
    [_editor message:SCI_SETTARGETSTART wParam:0];
    [_editor message:SCI_SETTARGETEND wParam:[_editor message:SCI_GETLENGTH]];
    const char *utf8 = text.UTF8String;
    [_editor message:SCI_REPLACETARGET wParam:[text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] lParam:(sptr_t)utf8];
    [_editor message:SCI_ENDUNDOACTION];
    [_editor setEditable:!readOnly];
    _updating = NO;
    _errorOffset = -2;  // the replacement removed indicators and annotations
    [self updateLineNumberMargin:NO];
}
- (void)replaceSelectionWithText:(NSString *)text {
    if (![_editor isEditable]) return;
    [_editor message:SCI_BEGINUNDOACTION];
    [_editor message:SCI_TARGETFROMSELECTION];
    const sptr_t start = [_editor message:SCI_GETTARGETSTART];
    const NSUInteger length = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [_editor message:SCI_REPLACETARGET wParam:length lParam:(sptr_t)text.UTF8String];
    [_editor message:SCI_GOTOPOS wParam:start + length];
    [_editor message:SCI_ENDUNDOACTION];
}
- (void)setWrapsLines:(BOOL)wraps {
    if (_wrapsLines == wraps) return;
    _wrapsLines = wraps;
    // Keep the same document line at the top across the layout change.
    const sptr_t top = [_editor message:SCI_DOCLINEFROMVISIBLE wParam:[_editor message:SCI_GETFIRSTVISIBLELINE]];
    [_editor message:SCI_SETWRAPMODE wParam:wraps ? SC_WRAP_WORD : SC_WRAP_NONE];
    [_editor message:SCI_SETWRAPINDENTMODE wParam:SC_WRAPINDENT_SAME];
    [_editor message:SCI_SETXOFFSET wParam:0];
    [_editor message:SCI_SETFIRSTVISIBLELINE wParam:[_editor message:SCI_VISIBLEFROMDOCLINE wParam:top]];
}
- (void)loadDocument:(NSString *)text {
    self.text = text;
    [_editor message:SCI_EMPTYUNDOBUFFER];
    [_editor message:SCI_GOTOPOS wParam:0];
}
- (void)updateLineNumberMargin:(BOOL)force {
    sptr_t lines = [_editor message:SCI_GETLINECOUNT];
    NSInteger digits = 3;
    for (sptr_t limit = 1000; lines >= limit; limit *= 10) digits++;
    if (!force && digits == _marginDigits) return;
    _marginDigits = digits;
    std::string widest((size_t)digits, '9');
    sptr_t width = [_editor message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:(sptr_t)widest.c_str()];
    [_editor message:SCI_SETMARGINWIDTHN wParam:0 lParam:width + 10];
}
- (void)reportCursor {
    if (!self.onCursor || _cursorReportPending) return;
    _cursorReportPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_cursorReportPending = NO;
        if (!self.onCursor) return;
        const sptr_t position = [self->_editor message:SCI_GETCURRENTPOS];
        const sptr_t line = [self->_editor message:SCI_LINEFROMPOSITION wParam:position];
        const sptr_t column = [self->_editor message:SCI_GETCOLUMN wParam:position];
        self.onCursor(line + 1, column + 1);
    });
}
- (void)notification:(SCNotification *)notification {
    if (notification->nmhdr.code == SCN_FOCUSIN && self.onFocus) self.onFocus();
    if (notification->nmhdr.code == SCN_URIDROPPED && self.onDropFile && notification->text) {
        self.onDropFile([NSString stringWithUTF8String:notification->text]);
    }
    if (notification->nmhdr.code == SCN_UPDATEUI && !_updating &&
        (notification->updated & (SC_UPDATE_SELECTION | SC_UPDATE_CONTENT))) {
        [self reportCursor];
    }
    if (notification->nmhdr.code == SCN_MODIFIED &&
        (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) && notification->linesAdded != 0) {
        [self updateLineNumberMargin:NO];
    }
    if (!_updating && notification->nmhdr.code == SCN_MODIFIED &&
        (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) && self.onChange) {
        self.onChange(self.text);
    }
}
- (void)configureLanguage:(NSString *)language dark:(BOOL)dark fontSize:(NSInteger)fontSize readOnly:(BOOL)readOnly {
    if (_editor.isEditable == readOnly) [_editor setEditable:!readOnly];
    _readOnly = readOnly;
    // The view's effective appearance is the source of truth; SwiftUI's colorScheme can lag behind it.
    dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
    if (_configured && [_language isEqualToString:language] && _fontSize == fontSize && _dark == dark &&
        _appliedRecessed == _recessed && [_appliedTheme isEqualToString:PeelResolvedThemeName(_syntaxTheme)]) return;
    _configured = YES; _fontSize = fontSize; _dark = dark; _appliedRecessed = _recessed;
    _appliedTheme = PeelResolvedThemeName(_syntaxTheme);
    if (![_language isEqualToString:language]) {
        _language = [language copy];
        auto lexer = [language isEqualToString:@"json"] ? lmJSON.Create() :
            [language isEqualToString:@"javascript"] ? lmCPP.Create() : nullptr;
        [_editor message:SCI_SETILEXER wParam:0 lParam:(sptr_t)lexer];
        [_editor setLexerProperty:@"fold" value:@"1"];
        [_editor setLexerProperty:@"lexer.json.allow.comments" value:@"0"];
        [_editor message:SCI_SETKEYWORDS wParam:0 lParam:(sptr_t)"true false null undefined const let var return async await function new data"];
    }
    NSAppearance *appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    [appearance performAsCurrentDrawingAppearance:^{
        NSColor *background = [NSColor textBackgroundColor];
        if (_recessed) background = PeelBlend([NSColor windowBackgroundColor], background, 0.5);
        NSColor *foreground = [NSColor textColor];
        [_editor setFontName:PeelEditorFontName() size:(int)fontSize bold:NO italic:NO];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:STYLE_DEFAULT value:foreground];
        [_editor setColorProperty:SCI_STYLESETBACK parameter:STYLE_DEFAULT value:background];
        [_editor message:SCI_STYLECLEARALL];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:STYLE_LINENUMBER value:PeelOpaqueColor([NSColor secondaryLabelColor], background)];
        [_editor setColorProperty:SCI_STYLESETBACK parameter:STYLE_LINENUMBER value:background];
        [_editor setColorProperty:SCI_SETFOLDMARGINCOLOUR parameter:1 value:background];
        [_editor setColorProperty:SCI_SETFOLDMARGINHICOLOUR parameter:1 value:background];
        for (int marker = SC_MARKNUM_FOLDEREND; marker <= SC_MARKNUM_FOLDEROPEN; marker++) {
            [_editor setColorProperty:SCI_MARKERSETFORE parameter:marker value:PeelOpaqueColor([NSColor tertiaryLabelColor], background)];
            [_editor setColorProperty:SCI_MARKERSETBACK parameter:marker value:background];
        }
        NSColor *chevron = PeelOpaqueColor([NSColor tertiaryLabelColor], background);
        NSData *collapsed = PeelChevronPixels(NO, chevron), *expanded = PeelChevronPixels(YES, chevron);
        [_editor message:SCI_RGBAIMAGESETWIDTH wParam:PeelFoldGlyphPixels];
        [_editor message:SCI_RGBAIMAGESETHEIGHT wParam:PeelFoldGlyphPixels];
        [_editor message:SCI_RGBAIMAGESETSCALE wParam:200];
        for (int marker : {SC_MARKNUM_FOLDEREND, SC_MARKNUM_FOLDER})
            [_editor message:SCI_MARKERDEFINERGBAIMAGE wParam:marker lParam:(sptr_t)collapsed.bytes];
        for (int marker : {SC_MARKNUM_FOLDEROPENMID, SC_MARKNUM_FOLDEROPEN})
            [_editor message:SCI_MARKERDEFINERGBAIMAGE wParam:marker lParam:(sptr_t)expanded.bytes];
        // Same wParam limitation as the caret line: SCI_SETCARETFORE always produced black.
        NSColor *caret = dark ? [NSColor colorWithSRGBRed:0.78 green:0.79 blue:0.79 alpha:1]
                              : [NSColor colorWithSRGBRed:0.16 green:0.17 blue:0.18 alpha:1];
        [_editor message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_CARET lParam:PeelPackedRGBA(caret)];
        [_editor message:SCI_SETCARETWIDTH wParam:2];
        [_editor setColorProperty:SCI_SETSELBACK parameter:1 value:[NSColor selectedTextBackgroundColor]];
        // Selection in a window or pane without focus is gray, as in AppKit text views.
        [_editor message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_SELECTION_INACTIVE_BACK
                  lParam:PeelPackedRGBA(PeelOpaqueColor([NSColor unemphasizedSelectedTextBackgroundColor], background))];
        [_editor setColorProperty:SCI_INDICSETFORE parameter:8 value:[NSColor systemRedColor]];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:PeelErrorAnnotationStyle value:[NSColor systemRedColor]];
        [_editor setColorProperty:SCI_STYLESETBACK parameter:PeelErrorAnnotationStyle
                            value:PeelBlend([NSColor systemRedColor], background, 0.10)];
        [_editor message:SCI_SETCARETLINEVISIBLE wParam:1];
        // A wrapped long line (minified JSON) otherwise tints every screen row it spans, so scrolling
        // shows a lighter slab next to the untinted gutter; highlight only the row holding the caret.
        [_editor message:SCI_SETCARETLINEHIGHLIGHTSUBLINE wParam:1];
        // SCI_SETCARETLINEBACK takes the colour in wParam, which setColorProperty cannot express
        // (it was always black). Set the element colour directly with an opaque blend of the
        // text colour over the background, a soft gray in dark mode.
        [_editor message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_CARET_LINE_BACK
                  lParam:PeelPackedRGBA(PeelBlend(foreground, background, dark ? 0.095 : 0.05))];
        BOOL json = [language isEqualToString:@"json"];
        const PeelPalette &palette = PeelPaletteFor(_appliedTheme, dark);
        [_editor setColorProperty:SCI_STYLESETFORE parameter:json ? SCE_JSON_STRING : SCE_C_STRING value:PeelHex(palette.string)];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:json ? SCE_JSON_PROPERTYNAME : SCE_C_CHARACTER value:PeelHex(palette.key)];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:json ? SCE_JSON_NUMBER : SCE_C_NUMBER value:PeelHex(palette.number)];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:json ? SCE_JSON_KEYWORD : SCE_C_WORD value:PeelHex(palette.keyword)];
        if (json) {
            [_editor setColorProperty:SCI_STYLESETFORE parameter:SCE_JSON_OPERATOR value:PeelHex(palette.punctuation)];
            [_editor setColorProperty:SCI_STYLESETFORE parameter:SCE_JSON_ESCAPESEQUENCE value:PeelHex(palette.escape)];
            [_editor setColorProperty:SCI_STYLESETFORE parameter:SCE_JSON_URI value:PeelHex(palette.string)];
            [_editor setColorProperty:SCI_STYLESETFORE parameter:SCE_JSON_COMPACTIRI value:PeelHex(palette.string)];
            [_editor setColorProperty:SCI_STYLESETFORE parameter:SCE_JSON_LDKEYWORD value:PeelHex(palette.keyword)];
            [_editor setColorProperty:SCI_STYLESETFORE parameter:SCE_JSON_ERROR value:PeelHex(palette.error)];
        }
    }];
    [_editor setEditable:!readOnly];
    [_editor message:SCI_ANNOTATIONSETVISIBLE wParam:ANNOTATION_STANDARD];
    _errorOffset = -2;  // style reset: repaint the diagnostic on the next mark
    [self updateLineNumberMargin:YES];
}
- (void)markErrorAtByte:(NSInteger)offset message:(NSString *)message reveal:(BOOL)reveal {
    NSString *text = message ?: @"";
    // Synchronization runs on every SwiftUI update; only touch Scintilla when the diagnostic changes.
    if (offset != _errorOffset || ![text isEqualToString:_errorMessage ?: @""]) {
        [_editor message:SCI_SETINDICATORCURRENT wParam:8];
        [_editor message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[_editor message:SCI_GETLENGTH]];
        [_editor message:SCI_ANNOTATIONCLEARALL];
        if (offset >= 0) {
            auto length = [_editor message:SCI_GETLENGTH];
            auto position = std::min((sptr_t)offset, std::max((sptr_t)0, length - 1));
            [_editor message:SCI_INDICATORFILLRANGE wParam:position lParam:1];
            if (text.length) {
                const sptr_t line = [_editor message:SCI_LINEFROMPOSITION wParam:position];
                [_editor message:SCI_ANNOTATIONSETTEXT wParam:line lParam:(sptr_t)text.UTF8String];
                [_editor message:SCI_ANNOTATIONSETSTYLE wParam:line lParam:PeelErrorAnnotationStyle];
            }
        }
        _errorOffset = offset;
        _errorMessage = [text copy];
    }
    if (offset >= 0 && reveal) {
        auto length = [_editor message:SCI_GETLENGTH];
        [_editor message:SCI_GOTOPOS wParam:std::min((sptr_t)offset, std::max((sptr_t)0, length - 1))];
        [self focusEditor];
    }
}

static int PeelSearchFlags(PeelFindOptions options) {
    int flags = 0;
    if (options & PeelFindOptionMatchCase) flags |= SCFIND_MATCHCASE;
    if (options & PeelFindOptionWholeWord) flags |= SCFIND_WHOLEWORD;
    if (options & PeelFindOptionRegex) flags |= SCFIND_REGEXP | SCFIND_CXX11REGEX;
    return flags;
}
// Searches [start, end) (backwards when start > end); the match becomes the target range.
- (sptr_t)searchFrom:(sptr_t)start to:(sptr_t)end needle:(const std::string &)needle options:(PeelFindOptions)options {
    [_editor message:SCI_SETSEARCHFLAGS wParam:PeelSearchFlags(options)];
    [_editor message:SCI_SETTARGETSTART wParam:start];
    [_editor message:SCI_SETTARGETEND wParam:end];
    return [_editor message:SCI_SEARCHINTARGET wParam:needle.size() lParam:(sptr_t)needle.data()];
}
- (BOOL)findText:(NSString *)text backwards:(BOOL)backwards options:(PeelFindOptions)options inclusive:(BOOL)inclusive {
    if (text.length == 0) return NO;
    const std::string needle = text.UTF8String;
    const sptr_t length = [_editor message:SCI_GETLENGTH];
    const sptr_t selStart = [_editor message:SCI_GETSELECTIONSTART];
    const sptr_t selEnd = [_editor message:SCI_GETSELECTIONEND];
    sptr_t found;
    if (backwards) {
        found = [self searchFrom:selStart to:0 needle:needle options:options];
        if (found < 0) found = [self searchFrom:length to:0 needle:needle options:options];
    } else {
        found = [self searchFrom:inclusive ? selStart : selEnd to:length needle:needle options:options];
        if (found < 0) found = [self searchFrom:0 to:length needle:needle options:options];
    }
    if (found < 0) return NO;
    const sptr_t start = [_editor message:SCI_GETTARGETSTART];
    const sptr_t end = [_editor message:SCI_GETTARGETEND];
    if (end <= start) return NO;  // empty regular-expression matches cannot advance
    [_editor message:SCI_ENSUREVISIBLEENFORCEPOLICY wParam:[_editor message:SCI_LINEFROMPOSITION wParam:start]];
    [_editor message:SCI_SETSEL wParam:start lParam:end];
    [_editor message:SCI_SCROLLCARET];
    return YES;
}
- (BOOL)replaceText:(NSString *)text withText:(NSString *)replacement options:(PeelFindOptions)options {
    if (text.length == 0 || ![_editor isEditable]) return NO;
    const std::string needle = text.UTF8String;
    const sptr_t selStart = [_editor message:SCI_GETSELECTIONSTART];
    const sptr_t selEnd = [_editor message:SCI_GETSELECTIONEND];
    if (selEnd > selStart && [self searchFrom:selStart to:selEnd needle:needle options:options] == selStart &&
        [_editor message:SCI_GETTARGETEND] == selEnd) {
        const std::string value = replacement.UTF8String ?: "";
        [_editor message:SCI_BEGINUNDOACTION];
        [_editor message:(options & PeelFindOptionRegex) ? SCI_REPLACETARGETRE : SCI_REPLACETARGET
                  wParam:value.size() lParam:(sptr_t)value.data()];
        const sptr_t end = [_editor message:SCI_GETTARGETEND];
        [_editor message:SCI_ENDUNDOACTION];
        [_editor message:SCI_SETSEL wParam:end lParam:end];
    }
    return [self findText:text backwards:NO options:options inclusive:NO];
}
- (NSInteger)replaceAllText:(NSString *)text withText:(NSString *)replacement options:(PeelFindOptions)options {
    if (text.length == 0 || ![_editor isEditable]) return 0;
    const std::string needle = text.UTF8String;
    const std::string value = replacement.UTF8String ?: "";
    NSInteger count = 0;
    sptr_t position = 0;
    _updating = YES;  // one change notification for the whole operation
    [_editor message:SCI_BEGINUNDOACTION];
    while (count < 1000000 && [self searchFrom:position to:[_editor message:SCI_GETLENGTH] needle:needle options:options] >= 0) {
        const sptr_t start = [_editor message:SCI_GETTARGETSTART];
        if ([_editor message:SCI_GETTARGETEND] <= start) break;
        [_editor message:(options & PeelFindOptionRegex) ? SCI_REPLACETARGETRE : SCI_REPLACETARGET
                  wParam:value.size() lParam:(sptr_t)value.data()];
        position = [_editor message:SCI_GETTARGETEND];
        count++;
    }
    [_editor message:SCI_ENDUNDOACTION];
    _updating = NO;
    if (count > 0 && self.onChange) self.onChange(self.text);
    return count;
}
- (NSInteger)countMatchesForText:(NSString *)text options:(PeelFindOptions)options current:(NSInteger *)current {
    if (current) *current = 0;
    if (text.length == 0) return 0;
    const std::string needle = text.UTF8String;
    const sptr_t length = [_editor message:SCI_GETLENGTH];
    const sptr_t selStart = [_editor message:SCI_GETSELECTIONSTART];
    const sptr_t selEnd = [_editor message:SCI_GETSELECTIONEND];
    NSInteger total = 0;
    sptr_t position = 0;
    while (total < PeelMatchLimit && position <= length && [self searchFrom:position to:length needle:needle options:options] >= 0) {
        const sptr_t start = [_editor message:SCI_GETTARGETSTART];
        const sptr_t end = [_editor message:SCI_GETTARGETEND];
        if (end <= start) break;
        total++;
        if (current && start == selStart && end == selEnd) *current = total;
        position = end;
    }
    return total;
}
- (void)goToLine:(NSInteger)line {
    const sptr_t count = [_editor message:SCI_GETLINECOUNT];
    const sptr_t target = std::max((sptr_t)0, std::min((sptr_t)line - 1, count - 1));
    [_editor message:SCI_ENSUREVISIBLEENFORCEPOLICY wParam:target];
    [_editor message:SCI_GOTOLINE wParam:target];
    [self focusEditor];
}
- (NSInteger)lineCount { return [_editor message:SCI_GETLINECOUNT]; }
- (void)foldAll:(BOOL)contract {
    [_editor message:SCI_FOLDALL wParam:contract ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND];
}
- (void)insertTextAtEnd:(NSString *)text {
    [_editor message:SCI_GOTOPOS wParam:[_editor message:SCI_GETLENGTH]];
    [_editor insertText:text];
}
- (void)focusEditor { [self.window makeFirstResponder:_editor.content]; }
@end
