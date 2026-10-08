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

@interface PeelEditorView () <ScintillaNotificationProtocol> {
    PeelScintillaView *_editor;
    BOOL _updating;
    NSString *_language;
    NSInteger _fontSize;
    BOOL _dark;
    BOOL _readOnly;
    BOOL _appliedRecessed;
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
    const sptr_t length = [_editor message:SCI_GETSELTEXT];
    if (length <= 1) return @"";
    std::string buffer(length, '\0');
    [_editor message:SCI_GETSELTEXT wParam:0 lParam:(sptr_t)buffer.data()];
    return [[NSString alloc] initWithBytes:buffer.data() length:length - 1 encoding:NSUTF8StringEncoding] ?: @"";
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
    if (_configured && [_language isEqualToString:language] && _fontSize == fontSize && _dark == dark &&
        _appliedRecessed == _recessed) return;
    _configured = YES; _fontSize = fontSize; _dark = dark; _appliedRecessed = _recessed;
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
        [_editor setColorProperty:SCI_SETCARETFORE parameter:0 value:[NSColor textInsertionPointColor]];
        [_editor setColorProperty:SCI_SETSELBACK parameter:1 value:[NSColor selectedTextBackgroundColor]];
        // Selection in a window or pane without focus is gray, as in AppKit text views.
        [_editor message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_SELECTION_INACTIVE_BACK
                  lParam:PeelPackedRGBA(PeelOpaqueColor([NSColor unemphasizedSelectedTextBackgroundColor], background))];
        [_editor setColorProperty:SCI_INDICSETFORE parameter:8 value:[NSColor systemRedColor]];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:PeelErrorAnnotationStyle value:[NSColor systemRedColor]];
        [_editor setColorProperty:SCI_STYLESETBACK parameter:PeelErrorAnnotationStyle
                            value:PeelBlend([NSColor systemRedColor], background, 0.10)];
        [_editor message:SCI_SETCARETLINEVISIBLE wParam:1];
        [_editor setColorProperty:SCI_SETCARETLINEBACK parameter:0 value:[NSColor quaternaryLabelColor]];
        [_editor message:SCI_SETCARETLINEBACKALPHA wParam:18];
        BOOL json = [language isEqualToString:@"json"];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:json ? SCE_JSON_STRING : SCE_C_STRING value:dark ? [NSColor colorWithSRGBRed:0.55 green:0.77 blue:0.65 alpha:1] : [NSColor colorWithSRGBRed:0.20 green:0.43 blue:0.34 alpha:1]];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:json ? SCE_JSON_PROPERTYNAME : SCE_C_CHARACTER value:dark ? [NSColor colorWithSRGBRed:0.55 green:0.70 blue:0.91 alpha:1] : [NSColor colorWithSRGBRed:0.22 green:0.37 blue:0.57 alpha:1]];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:json ? SCE_JSON_NUMBER : SCE_C_NUMBER value:dark ? [NSColor colorWithSRGBRed:0.87 green:0.69 blue:0.46 alpha:1] : [NSColor colorWithSRGBRed:0.58 green:0.37 blue:0.18 alpha:1]];
        [_editor setColorProperty:SCI_STYLESETFORE parameter:json ? SCE_JSON_KEYWORD : SCE_C_WORD value:dark ? [NSColor colorWithSRGBRed:0.76 green:0.61 blue:0.86 alpha:1] : [NSColor colorWithSRGBRed:0.48 green:0.31 blue:0.59 alpha:1]];
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
