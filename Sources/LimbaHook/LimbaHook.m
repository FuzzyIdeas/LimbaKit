#import "LimbaHook.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

// A value no real translation contains, passed as the default so a missing key can be told apart.
static NSString *const kMissing = @"limba-missing";
static const NSUInteger kMaxRemembered = 50000;

static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static NSBundle *gOverlay;
static NSString *gLanguage;
static NSArray<NSString *> *gLanguages;
static BOOL gMarkers;
static NSMutableDictionary<NSString *, NSNumber *> *gMarkerIDs;
static NSMutableDictionary<NSNumber *, NSString *> *gMarkerTable;
static NSMutableDictionary<NSString *, NSString *> *gValueToKey;
static NSMutableSet<NSString *> *gSeen;
static NSMutableArray<NSString *> *gLog;

// Lookups nest: the public method calls private ones on the same bundle. Only the outermost call
// serves the overlay and adds a marker, the inner ones pass straight through.
static __thread int tDepth;

#pragma mark - Helpers

static NSString *LBTableKey(NSString *table, NSString *key) {
    NSString *t = table.length ? table : @"Localizable";
    return [NSString stringWithFormat:@"%@%C%@", t, (unichar)0x1F, key];
}

static void LBSnapshot(NSBundle **bundle, NSString **language, NSArray **languages) {
    os_unfair_lock_lock(&gLock);
    *bundle = gOverlay;
    if (language) *language = gLanguage;
    if (languages) *languages = gLanguages;
    os_unfair_lock_unlock(&gLock);
}

static NSString *LBMarkerFor(NSString *tableKey) {
    os_unfair_lock_lock(&gLock);
    NSNumber *n = gMarkerIDs[tableKey];
    if (!n) {
        n = @(gMarkerIDs.count + 1);
        gMarkerIDs[tableKey] = n;
        gMarkerTable[n] = tableKey;
    }
    os_unfair_lock_unlock(&gLock);

    unsigned long v = n.unsignedLongValue;
    uint32_t digits[8];
    int count = 0;
    do {
        digits[count++] = (uint32_t)(v % 240);
        v /= 240;
    } while (v > 0 && count < 8);

    NSMutableString *m = [NSMutableString stringWithCapacity:4 + count * 2];
    [m appendFormat:@"%C", (unichar)0x2060];
    for (int i = count - 1; i >= 0; i--) {
        uint32_t cp = 0xE0100 + digits[i] - 0x10000;
        [m appendFormat:@"%C%C", (unichar)(0xD800 + (cp >> 10)), (unichar)(0xDC00 + (cp & 0x3FF))];
    }
    [m appendFormat:@"%C", (unichar)0x2060];
    return m;
}

// `keepsConfig` is false for strings that may carry a plural configuration on the object itself:
// appending would build a new string and lose it, so those stay unmarked.
static id LBMark(id value, NSString *tableKey, BOOL keepsConfig) {
    if (!gMarkers || !tableKey) return value;
    if ([value isKindOfClass:NSAttributedString.class]) {
        NSAttributedString *a = value;
        NSMutableAttributedString *m = [a mutableCopy];
        NSDictionary *attrs = a.length ? [a attributesAtIndex:a.length - 1 effectiveRange:NULL] : @{};
        [m appendAttributedString:[[NSAttributedString alloc] initWithString:LBMarkerFor(tableKey) attributes:attrs]];
        return m;
    }
    if (![value isKindOfClass:NSString.class]) return value;
    // "%#@count@", or "%2$#@count@" when the counted number is not the first argument.
    if (!keepsConfig && [value rangeOfString:@"%([0-9]+\\$)?#@" options:NSRegularExpressionSearch].location != NSNotFound) return value;
    return [(NSString *)value stringByAppendingString:LBMarkerFor(tableKey)];
}

static void LBRemember(id value, NSString *tableKey) {
    if (!tableKey) return;
    NSString *s = [value isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)value string] : value;
    BOOL usable = [s isKindOfClass:NSString.class] && s.length > 0;
    os_unfair_lock_lock(&gLock);
    if (gSeen.count < kMaxRemembered) [gSeen addObject:tableKey];
    if (usable) {
        if (gValueToKey.count >= kMaxRemembered) [gValueToKey removeAllObjects];
        gValueToKey[s] = tableKey;
    }
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - Overlay lookups

typedef NSString *(*LBString4)(id, SEL, NSString *, NSString *, NSString *, id);
typedef id (*LBNoCache)(id, SEL, NSString *, NSString *, NSString *, NSArray *, NSString *__autoreleasing *, id __autoreleasing *);
typedef id (*LBFlagged)(id, SEL, NSString *, NSString *, NSString *, NSArray *, NSString *__autoreleasing *, BOOL);

static NSString *LBOverlayString(NSString *key, NSString *table) {
    NSBundle *ov; NSString *lang; NSArray *langs;
    LBSnapshot(&ov, &lang, &langs);
    if (!ov || !key) return nil;
    NSString *r;
    SEL single = NSSelectorFromString(@"localizedStringForKey:value:table:localization:");
    if (@available(macOS 15.4, *)) {
        r = [ov localizedStringForKey:key value:kMissing table:table localizations:langs];
    } else if (lang && [ov respondsToSelector:single]) {
        r = ((LBString4)objc_msgSend)(ov, single, key, kMissing, table, lang);
    } else {
        r = [ov localizedStringForKey:key value:kMissing table:table];
    }
    if (!r || [r isEqualToString:kMissing]) return nil;
    return r;
}

static NSAttributedString *LBOverlayAttributed(NSString *key, NSString *table) {
    NSBundle *ov; NSString *lang;
    LBSnapshot(&ov, &lang, NULL);
    if (!ov || !key) return nil;
    SEL single = NSSelectorFromString(@"localizedAttributedStringForKey:value:table:localization:");
    NSAttributedString *r;
    if (lang && [ov respondsToSelector:single]) {
        r = ((NSAttributedString * (*)(id, SEL, NSString *, NSString *, NSString *, NSString *)) objc_msgSend)(ov, single, key, kMissing, table, lang);
    } else {
        r = [ov localizedAttributedStringForKey:key value:kMissing table:table];
    }
    if (!r || [r.string isEqualToString:kMissing]) return nil;
    return r;
}

static id LBOverlayNoCache(SEL sel, NSString *key, NSString *table, NSArray *bundleLocalizations, NSString *__autoreleasing *locOut, id __autoreleasing *configOut) {
    NSBundle *ov; NSArray *langs;
    LBSnapshot(&ov, NULL, &langs);
    if (!ov || !key || ![ov respondsToSelector:sel]) return nil;
    NSString *loc = nil;
    id config = nil;
    id r = ((LBNoCache)objc_msgSend)(ov, sel, key, kMissing, table, langs ?: bundleLocalizations, &loc, &config);
    if (!r || [r isEqual:kMissing]) return nil;
    if (locOut) *locOut = loc;
    if (configOut) *configOut = config;
    return r;
}

static id LBOverlayFlagged(SEL sel, NSString *key, NSString *table, NSArray *bundleLocalizations, NSString *__autoreleasing *locOut, BOOL preventMarkdown) {
    NSBundle *ov; NSArray *langs;
    LBSnapshot(&ov, NULL, &langs);
    if (!ov || !key || ![ov respondsToSelector:sel]) return nil;
    NSString *loc = nil;
    id r = ((LBFlagged)objc_msgSend)(ov, sel, key, kMissing, table, langs ?: bundleLocalizations, &loc, preventMarkdown);
    NSString *plain = [r isKindOfClass:NSAttributedString.class] ? [(NSAttributedString *)r string] : r;
    if (!r || [plain isEqual:kMissing]) return nil;
    if (locOut) *locOut = loc;
    return r;
}

#pragma mark - Installation

static NSString *LBTypesOnly(const char *encoding) {
    NSMutableString *s = [NSMutableString string];
    for (const char *p = encoding; p && *p; p++) {
        if (*p < '0' || *p > '9') [s appendFormat:@"%c", *p];
    }
    return s;
}

static BOOL LBAdd(Class sub, Class sup, NSString *name, NSString *expectedTypes, id block, NSMutableArray *installed) {
    SEL sel = NSSelectorFromString(name);
    Method m = class_getInstanceMethod(sup, sel);
    if (!m) {
        [gLog addObject:[@"absent " stringByAppendingString:name]];
        return NO;
    }
    NSString *types = LBTypesOnly(method_getTypeEncoding(m));
    if (![types isEqualToString:expectedTypes]) {
        [gLog addObject:[NSString stringWithFormat:@"skipped %@ (types %@, expected %@)", name, types, expectedTypes]];
        return NO;
    }
    if (!class_addMethod(sub, sel, imp_implementationWithBlock(block), method_getTypeEncoding(m))) {
        [gLog addObject:[@"failed " stringByAppendingString:name]];
        return NO;
    }
    [installed addObject:name];
    return YES;
}

@implementation LBHook

+ (void)initialize {
    if (self != LBHook.class) return;
    gMarkerIDs = [NSMutableDictionary new];
    gMarkerTable = [NSMutableDictionary new];
    gValueToKey = [NSMutableDictionary new];
    gSeen = [NSMutableSet new];
    gLog = [NSMutableArray new];
}

+ (NSArray<NSString *> *)installOnBundle:(NSBundle *)bundle {
    @synchronized(self) {
        Class sup = object_getClass(bundle);
        if ([NSStringFromClass(sup) hasPrefix:@"LBHooked_"]) return @[];

        NSString *name = [@"LBHooked_" stringByAppendingString:NSStringFromClass(sup)];
        Class sub = NSClassFromString(name);
        NSMutableArray *installed = [NSMutableArray array];

        if (!sub) {
            sub = objc_allocateClassPair(sup, name.UTF8String, 0);
            if (!sub) {
                [gLog addObject:[@"could not subclass " stringByAppendingString:NSStringFromClass(sup)]];
                return @[];
            }

            // Public: NSLocalizedString, String(localized:) on older systems, AppKit.
            NSString *n1 = @"localizedStringForKey:value:table:";
            SEL s1 = NSSelectorFromString(n1);
            NSString *(*o1)(id, SEL, NSString *, NSString *, NSString *) = (void *)class_getMethodImplementation(sup, s1);
            LBAdd(sub, sup, n1, @"@@:@@@", ^NSString *(id me, NSString *key, NSString *value, NSString *table) {
                tDepth++;
                BOOL outer = tDepth == 1 && key;
                NSString *tk = outer ? LBTableKey(table, key) : nil;
                NSString *r = outer ? LBOverlayString(key, table) : nil;
                if (!r) r = o1(me, s1, key, value, table);
                if (outer) { r = LBMark(r, tk, NO); LBRemember(r, tk); }
                tDepth--;
                return r;
            }, installed);

            // localization: (private) and localizations: (public since macOS 15.4) share one shape.
            for (NSString *n in @[ @"localizedStringForKey:value:table:localization:", @"localizedStringForKey:value:table:localizations:", @"_localizedStringForKey:value:table:localizations:" ]) {
                SEL s = NSSelectorFromString(n);
                LBString4 o = (LBString4)class_getMethodImplementation(sup, s);
                LBAdd(sub, sup, n, @"@@:@@@@", ^NSString *(id me, NSString *key, NSString *value, NSString *table, id loc) {
                    tDepth++;
                    BOOL outer = tDepth == 1 && key;
                    NSString *tk = outer ? LBTableKey(table, key) : nil;
                    NSString *r = outer ? LBOverlayString(key, table) : nil;
                    if (!r) r = o(me, s, key, value, table, loc);
                    if (outer) { r = LBMark(r, tk, NO); LBRemember(r, tk); }
                    tDepth--;
                    return r;
                }, installed);
            }

            // Foundation's Swift String(localized:) and SwiftUI's LocalizedStringResource. The plural
            // configuration comes back through `configOut`, so marking the string is safe here.
            NSString *n6 = @"_localizedStringNoCacheNoMarkdownParsingForKey:value:table:bundleLocalizations:localization:formatSpecifierConfiguration:";
            SEL s6 = NSSelectorFromString(n6);
            LBNoCache o6 = (LBNoCache)class_getMethodImplementation(sup, s6);
            LBAdd(sub, sup, n6, @"@@:@@@@^@^@", ^id(id me, NSString *key, NSString *value, NSString *table, NSArray *bl, NSString *__autoreleasing *locOut, id __autoreleasing *configOut) {
                tDepth++;
                BOOL outer = tDepth == 1 && key;
                NSString *tk = outer ? LBTableKey(table, key) : nil;
                id r = outer ? LBOverlayNoCache(s6, key, table, bl, locOut, configOut) : nil;
                if (!r) r = o6(me, s6, key, value, table, bl, locOut, configOut);
                if (outer) { r = LBMark(r, tk, YES); LBRemember(r, tk); }
                tDepth--;
                return r;
            }, installed);

            NSString *n5 = @"_localizedStringForKey:value:table:bundleLocalizations:localization:preventMarkdownParsing:";
            SEL s5 = NSSelectorFromString(n5);
            LBFlagged o5 = (LBFlagged)class_getMethodImplementation(sup, s5);
            LBAdd(sub, sup, n5, @"@@:@@@@^@B", ^id(id me, NSString *key, NSString *value, NSString *table, NSArray *bl, NSString *__autoreleasing *locOut, BOOL preventMarkdown) {
                tDepth++;
                BOOL outer = tDepth == 1 && key;
                NSString *tk = outer ? LBTableKey(table, key) : nil;
                id r = outer ? LBOverlayFlagged(s5, key, table, bl, locOut, preventMarkdown) : nil;
                if (!r) r = o5(me, s5, key, value, table, bl, locOut, preventMarkdown);
                if (outer) { r = LBMark(r, tk, NO); LBRemember(r, tk); }
                tDepth--;
                return r;
            }, installed);

            // SwiftUI Text, Button, Toggle, Label, Section, Picker, menus from Commands.
            NSString *n7 = @"localizedAttributedStringForKey:value:table:";
            SEL s7 = NSSelectorFromString(n7);
            NSAttributedString *(*o7)(id, SEL, NSString *, NSString *, NSString *) = (void *)class_getMethodImplementation(sup, s7);
            LBAdd(sub, sup, n7, @"@@:@@@", ^NSAttributedString *(id me, NSString *key, NSString *value, NSString *table) {
                tDepth++;
                BOOL outer = tDepth == 1 && key;
                NSString *tk = outer ? LBTableKey(table, key) : nil;
                NSAttributedString *r = outer ? LBOverlayAttributed(key, table) : nil;
                if (!r) r = o7(me, s7, key, value, table);
                if (outer) { r = LBMark(r, tk, YES); LBRemember(r, tk); }
                tDepth--;
                return r;
            }, installed);

            NSString *n8 = @"localizedAttributedStringForKey:value:table:localization:";
            SEL s8 = NSSelectorFromString(n8);
            NSAttributedString *(*o8)(id, SEL, NSString *, NSString *, NSString *, NSString *) = (void *)class_getMethodImplementation(sup, s8);
            LBAdd(sub, sup, n8, @"@@:@@@@", ^NSAttributedString *(id me, NSString *key, NSString *value, NSString *table, NSString *loc) {
                tDepth++;
                BOOL outer = tDepth == 1 && key;
                NSString *tk = outer ? LBTableKey(table, key) : nil;
                NSAttributedString *r = outer ? LBOverlayAttributed(key, table) : nil;
                if (!r) r = o8(me, s8, key, value, table, loc);
                if (outer) { r = LBMark(r, tk, YES); LBRemember(r, tk); }
                tDepth--;
                return r;
            }, installed);

            objc_registerClassPair(sub);
            [gLog addObject:[NSString stringWithFormat:@"created %@: %@", name, [installed componentsJoinedByString:@", "]]];
        }

        object_setClass(bundle, sub);
        [gLog addObject:[NSString stringWithFormat:@"installed on %@", bundle.bundleIdentifier ?: bundle.bundlePath]];
        return installed;
    }
}

+ (void)setOverlayBundle:(NSBundle *)bundle language:(NSString *)language {
    os_unfair_lock_lock(&gLock);
    gOverlay = bundle;
    gLanguage = [language copy];
    gLanguages = language ? @[ language ] : nil;
    os_unfair_lock_unlock(&gLock);
}

+ (NSBundle *)overlayBundle {
    NSBundle *b;
    LBSnapshot(&b, NULL, NULL);
    return b;
}

+ (NSString *)overlayLanguage {
    NSBundle *b; NSString *l;
    LBSnapshot(&b, &l, NULL);
    return l;
}

+ (BOOL)markersEnabled { return gMarkers; }
+ (void)setMarkersEnabled:(BOOL)enabled { gMarkers = enabled; }

+ (NSDictionary<NSNumber *, NSString *> *)markerTable {
    os_unfair_lock_lock(&gLock);
    NSDictionary *d = [gMarkerTable copy];
    os_unfair_lock_unlock(&gLock);
    return d;
}

+ (NSString *)tableKeyForValue:(NSString *)value {
    if (!value) return nil;
    os_unfair_lock_lock(&gLock);
    NSString *tk = gValueToKey[value];
    os_unfair_lock_unlock(&gLock);
    return tk;
}

+ (NSDictionary<NSString *, NSString *> *)formatValues {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    os_unfair_lock_lock(&gLock);
    [gValueToKey enumerateKeysAndObjectsUsingBlock:^(NSString *value, NSString *tk, BOOL *stop) {
        if ([value rangeOfString:@"%"].location != NSNotFound) out[value] = tk;
    }];
    os_unfair_lock_unlock(&gLock);
    return out;
}

+ (NSSet<NSString *> *)seenTableKeys {
    os_unfair_lock_lock(&gLock);
    NSSet *s = [gSeen copy];
    os_unfair_lock_unlock(&gLock);
    return s;
}

+ (NSArray<NSString *> *)log {
    @synchronized(self) { return [gLog copy]; }
}

+ (NSString *)stringByRemovingMarkers:(NSString *)string {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\\x{2060}[\\x{E0100}-\\x{E01EF}]+\\x{2060}" options:0 error:nil];
    });
    if (!string.length || [string rangeOfString:@"⁠"].location == NSNotFound) return string;
    return [re stringByReplacingMatchesInString:string options:0 range:NSMakeRange(0, string.length) withTemplate:@""];
}

@end
