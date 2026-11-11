#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Hooks the string lookups of a bundle so that they check a translation overlay first.
///
/// Foundation, SwiftUI and AppKit resolve localized strings through several NSBundle methods, some of
/// them private. The hook subclasses the bundle's class at runtime (the way KVO does) and overrides
/// each of those methods, but only when its type encoding matches the one it was written against, so
/// an OS that changes a private signature loses that one path instead of crashing.
///
/// Written in Objective-C on purpose: a string that comes out of a `.stringsdict` carries its plural
/// configuration on the NSString object, and a round trip through Swift's String could drop it.
@interface LBHook : NSObject

/// Installs the hook on `bundle`. Safe to call more than once. Returns the hooked selector names.
+ (NSArray<NSString *> *)installOnBundle:(NSBundle *)bundle;

/// The active translation: a bundle made from a folder that holds one `<language>.lproj`, and its language.
+ (void)setOverlayBundle:(nullable NSBundle *)bundle language:(nullable NSString *)language;
@property (class, readonly, nullable) NSBundle *overlayBundle;
@property (class, readonly, nullable) NSString *overlayLanguage;

/// Makes `bundle` read and parse each of `tables` for `language`, with the same lookup that the hook
/// makes. The first lookup in a table loads the whole file and the next ones are served from memory,
/// so calling this off the main thread keeps that first load away from the app's first draw.
+ (void)warmBundle:(NSBundle *)bundle language:(NSString *)language tables:(NSArray<NSString *> *)tables;

/// While true, every resolved string ends with an invisible marker that names its table and key.
@property (class) BOOL markersEnabled;
/// Marker number to "table" + U+001F + "key".
+ (NSDictionary<NSNumber *, NSString *> *)markerTable;

/// The "table" + U+001F + "key" that last produced `value`, for mapping AppKit text back to its key.
+ (nullable NSString *)tableKeyForValue:(NSString *)value;
/// Remembered values that contain a format placeholder (`%@`, `%lld`), for matching formatted AppKit text.
+ (NSDictionary<NSString *, NSString *> *)formatValues;
/// How many values are in `formatValues`, without copying them.
@property (class, readonly) NSUInteger formatValuesCount;
/// Every "table" + U+001F + "key" looked up since launch.
+ (NSSet<NSString *> *)seenTableKeys;

/// Hooked and skipped selectors, for diagnostics.
@property (class, readonly) NSArray<NSString *> *log;

/// Removes every marker from `string`.
+ (NSString *)stringByRemovingMarkers:(NSString *)string;

@end

NS_ASSUME_NONNULL_END
