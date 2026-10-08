#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT uint64_t PeelPhysicalFootprint(void);
FOUNDATION_EXPORT void PeelReleaseUnusedMemory(void);
typedef NS_OPTIONS(NSUInteger, PeelFindOptions) {
    PeelFindOptionMatchCase = 1 << 0,
    PeelFindOptionWholeWord = 1 << 1,
    PeelFindOptionRegex = 1 << 2,
};
@interface PeelEditorView : NSView
@property(copy) NSString *text;
@property(copy, nullable) void (^onChange)(NSString *);
@property(copy, nullable) void (^onRun)(void);
@property(copy, nullable) void (^onFocus)(void);
@property(copy, nullable) NSString * (^transformPaste)(NSString *);
@property(copy, nullable) void (^onCursor)(NSInteger line, NSInteger column);
@property(copy, nullable) void (^onDropFile)(NSString *path);
/// Slightly recessed surface for read-only output.
@property(nonatomic) BOOL recessed;
- (void)configureLanguage:(NSString *)language dark:(BOOL)dark fontSize:(NSInteger)fontSize readOnly:(BOOL)readOnly;
- (void)loadDocument:(NSString *)text;
- (void)markErrorAtByte:(NSInteger)offset message:(nullable NSString *)message reveal:(BOOL)reveal;
- (NSString *)selectedText;
/// Selects the next/previous match, wrapping around. `inclusive` keeps a match that starts at the selection.
- (BOOL)findText:(NSString *)text backwards:(BOOL)backwards options:(PeelFindOptions)options inclusive:(BOOL)inclusive;
/// Replaces the selection when it is a match, then selects the next match.
- (BOOL)replaceText:(NSString *)text withText:(NSString *)replacement options:(PeelFindOptions)options;
- (NSInteger)replaceAllText:(NSString *)text withText:(NSString *)replacement options:(PeelFindOptions)options;
/// Number of matches (capped at 10 000) and, in `current`, the 1-based index of the selected match (0 if none).
- (NSInteger)countMatchesForText:(NSString *)text options:(PeelFindOptions)options current:(nullable NSInteger *)current;
- (void)goToLine:(NSInteger)line;
- (NSInteger)lineCount;
- (void)foldAll:(BOOL)contract;
- (void)focusEditor;
- (void)insertTextAtEnd:(NSString *)text;
@end
NS_ASSUME_NONNULL_END
