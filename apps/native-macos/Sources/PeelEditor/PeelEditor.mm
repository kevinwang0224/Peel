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
static NSColor *PeelOpaqueColor(NSColor *color, NSColor *background) {
    NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    NSColor *base = [background colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGFloat alpha = rgb.alphaComponent;
    return [NSColor colorWithSRGBRed:rgb.redComponent * alpha + base.redComponent * (1 - alpha)
                             green:rgb.greenComponent * alpha + base.greenComponent * (1 - alpha)
                              blue:rgb.blueComponent * alpha + base.blueComponent * (1 - alpha) alpha:1];
}

@interface PeelEditorView (Selection)
- (NSString *)selectedText;
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
    BOOL _configured;
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
        [_editor message:SCI_INDICSETFORE wParam:8 lParam:0x4444DD];
        [self configureLanguage:@"json" dark:NO fontSize:14 readOnly:NO];
    }
    return self;
}
- (void)dealloc {
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
- (void)notification:(SCNotification *)notification {
    if (notification->nmhdr.code == SCN_FOCUSIN && self.onFocus) self.onFocus();
    if (!_updating && notification->nmhdr.code == SCN_MODIFIED &&
        (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT)) && self.onChange) {
        self.onChange(self.text);
    }
}
- (void)configureLanguage:(NSString *)language dark:(BOOL)dark fontSize:(NSInteger)fontSize readOnly:(BOOL)readOnly {
    if (_editor.isEditable == readOnly) [_editor setEditable:!readOnly];
    if (_configured && [_language isEqualToString:language] && _fontSize == fontSize && _dark == dark) return;
    _configured = YES; _fontSize = fontSize; _dark = dark;
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
        NSColor *foreground = [NSColor textColor];
        [_editor setFontName:@"Menlo" size:(int)fontSize bold:NO italic:NO];
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
        [_editor setColorProperty:SCI_SETCARETFORE parameter:0 value:foreground];
        [_editor setColorProperty:SCI_SETSELBACK parameter:1 value:[NSColor selectedTextBackgroundColor]];
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
}
- (void)markErrorAtByte:(NSInteger)offset reveal:(BOOL)reveal {
    [_editor message:SCI_SETINDICATORCURRENT wParam:8];
    [_editor message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[_editor message:SCI_GETLENGTH]];
    if (offset < 0) return;
    auto length = [_editor message:SCI_GETLENGTH];
    auto position = std::min((sptr_t)offset, std::max((sptr_t)0, length - 1));
    [_editor message:SCI_INDICATORFILLRANGE wParam:position lParam:1];
    if (reveal) { [_editor message:SCI_GOTOPOS wParam:position]; [self focusEditor]; }
}
- (BOOL)findText:(NSString *)text backwards:(BOOL)backwards {
    return [_editor findAndHighlightText:text matchCase:NO wholeWord:NO scrollTo:YES wrap:YES backwards:backwards];
}
- (NSInteger)replaceText:(NSString *)text withText:(NSString *)replacement all:(BOOL)all {
    return [_editor findAndReplaceText:text byText:replacement matchCase:NO wholeWord:NO doAll:all];
}
- (void)insertTextAtEnd:(NSString *)text {
    [_editor message:SCI_GOTOPOS wParam:[_editor message:SCI_GETLENGTH]];
    [_editor insertText:text];
}
- (void)focusEditor { [self.window makeFirstResponder:_editor.content]; }
@end
