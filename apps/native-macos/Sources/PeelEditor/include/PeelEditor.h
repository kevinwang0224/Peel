#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT uint64_t PeelPhysicalFootprint(void);
@interface PeelEditorView : NSView
@property(copy) NSString *text;
@property(copy, nullable) void (^onChange)(NSString *);
@property(copy, nullable) void (^onRun)(void);
@property(copy, nullable) void (^onFocus)(void);
@property(copy, nullable) NSString * (^transformPaste)(NSString *);
- (void)configureLanguage:(NSString *)language dark:(BOOL)dark fontSize:(NSInteger)fontSize readOnly:(BOOL)readOnly;
- (void)loadDocument:(NSString *)text;
- (void)markErrorAtByte:(NSInteger)offset reveal:(BOOL)reveal;
- (BOOL)findText:(NSString *)text backwards:(BOOL)backwards;
- (NSInteger)replaceText:(NSString *)text withText:(NSString *)replacement all:(BOOL)all;
- (void)focusEditor;
- (void)insertTextAtEnd:(NSString *)text;
@end
NS_ASSUME_NONNULL_END
