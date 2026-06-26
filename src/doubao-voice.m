#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 doubao-voice
 ------------

 This CLI intentionally stays on the "safe wrapper" side of reverse engineering.

 Doubao IME has internal Swift classes named like ASRShortcutMonitor and
 ASRPanelManager, but they are private implementation details. Linking or
 calling them would be brittle and could break on every app update.

 Instead, this tool does the same thing a user does from the keyboard:

   - hands-free voice input: tap the configured shortcut key once
   - hold-to-talk voice input: hold the configured shortcut key, then release it

 macOS requires Accessibility permission before a CLI can send global keyboard
 events. The "check --prompt" command exists only to make that permission step
 explicit and understandable.
 */

static NSString *const DoubaoBundlePath = @"/Library/Input Methods/DoubaoIme.app";
static NSString *const DoubaoBundleID = @"com.bytedance.inputmethod.doubaoime";
static NSString *const DoubaoSettingsBundleID = @"com.bytedance.inputmethod.doubaoime.settings";
static NSString *const DoubaoPinyinBundleID = @"com.bytedance.inputmethod.doubaoime.pinyin";
static NSString *const HelperBundlePath = @"/Applications/DoubaoVoiceCLI.app";
static NSString *const HelperBundleID = @"dev.doubao-ime-cli.helper";
static NSString *const HelperNotificationName = @"dev.doubao-ime-cli.perform";
static NSString *const ConfigDirectoryName = @"DoubaoImeCli";
static NSString *const ConfigFileName = @"config.plist";
static NSString *const ConfigKeyHandsFree = @"handsFreeKeyName";
static NSString *const ConfigKeyHold = @"holdKeyName";

static const char *DefaultHandsFreeKeyName = "right-option";
static const char *DefaultHoldKeyName = "fn";

typedef enum {
    ModifierKindFn = 1,
    ModifierKindControl = 2,
    ModifierKindOption = 3,
    ModifierKindCommand = 4,
    ModifierKindShift = 5
} ModifierKind;

typedef struct {
    const char *name;
    CGKeyCode keyCode;
    CGEventFlags flags;
    ModifierKind kind;
    const char *description;
} ShortcutKey;

typedef enum {
    LanguageZhHans,
    LanguageEn
} Language;

static Language CurrentLanguage = LanguageZhHans;

/*
 Key codes below are macOS virtual key codes. Modifier keys are delivered as
 kCGEventFlagsChanged events, so we keep both the physical key code and the flag
 that should be visible while the key is held.
 */
static const ShortcutKey KnownKeys[] = {
    {"fn", 63, kCGEventFlagMaskSecondaryFn, ModifierKindFn, "fn / Globe"},
    {"left-control", 59, kCGEventFlagMaskControl, ModifierKindControl, "left Control"},
    {"right-control", 62, kCGEventFlagMaskControl, ModifierKindControl, "right Control"},
    {"left-option", 58, kCGEventFlagMaskAlternate, ModifierKindOption, "left Option"},
    {"right-option", 61, kCGEventFlagMaskAlternate, ModifierKindOption, "right Option"},
    {"left-command", 55, kCGEventFlagMaskCommand, ModifierKindCommand, "left Command"},
    {"right-command", 54, kCGEventFlagMaskCommand, ModifierKindCommand, "right Command"},
    {"left-shift", 56, kCGEventFlagMaskShift, ModifierKindShift, "left Shift"},
    {"right-shift", 60, kCGEventFlagMaskShift, ModifierKindShift, "right Shift"},
};

typedef struct {
    const ShortcutKey *keys[5];
    size_t count;
    CGEventFlags flags;
    char canonical[128];
} ShortcutCombo;

typedef struct {
    ShortcutCombo combo;
    const char *source;
} KeyChoice;

typedef struct {
    const char *command;
    ShortcutCombo combo;
    bool keyWasSpecified;
    bool promptForAccessibility;
    bool verbose;
    unsigned long downMs;
    unsigned long gapMs;
    unsigned long durationMs;
} Options;

static bool isEnglish(void) {
    return CurrentLanguage == LanguageEn;
}

static void setLanguageFromValue(const char *value) {
    if (value == NULL) {
        return;
    }
    if (strcmp(value, "en") == 0 || strcmp(value, "en-US") == 0 || strcmp(value, "english") == 0) {
        CurrentLanguage = LanguageEn;
        return;
    }
    if (strcmp(value, "zh") == 0 || strcmp(value, "zh-Hans") == 0 || strcmp(value, "zh_CN") == 0 ||
        strcmp(value, "zh-CN") == 0 || strcmp(value, "chinese") == 0) {
        CurrentLanguage = LanguageZhHans;
        return;
    }
    fprintf(stderr, "Unsupported language: %s\n", value);
    exit(2);
}

static void configureLanguageFromEnvironment(void) {
    /*
     Default to Simplified Chinese because Doubao IME is primarily used by
     Chinese users. English is opt-in through DOUBAO_VOICE_LANG=en or --lang en.
     */
    const char *language = getenv("DOUBAO_VOICE_LANG");
    if (language != NULL && language[0] != '\0') {
        setLanguageFromValue(language);
    }
}

static void configureLanguageFromArguments(int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--lang") == 0 && i + 1 < argc) {
            setLanguageFromValue(argv[i + 1]);
            return;
        }
    }
}

static void printUsage(void) {
    if (!isEnglish()) {
        puts("用法:");
        puts("  doubao-voice [smart] [--key left-shift] [--prompt]");
        puts("  doubao-voice handsfree [--key left-shift]");
        puts("  doubao-voice hold [--key fn] [--duration-ms 5000]");
        puts("  doubao-voice stop");
        puts("  doubao-voice logs");
        puts("  doubao-voice inspect");
        puts("  doubao-voice check [--prompt]");
        puts("  doubao-voice authorize");
        puts("");
        puts("命令:");
        puts("  smart         默认命令。前台启动免按模式，并在静音后自动结束。加 --verbose 打印实时监听日志。");
        puts("  handsfree     免按模式：按一次快捷键，豆包自行判断开始或结束。");
        puts("  hold          触发长按说话，持续指定时间后松开。");
        puts("  stop          终止当前运行中的语音输入和感应录音（支持别名 finish/terminate/kill/cancel）。");
        puts("  logs          查看最近 100 行智能判停 VAD 的后台诊断日志（支持别名 log）。");
        puts("  inspect       查看豆包安装、输入法、权限和快捷键推断。");
        puts("  check         检查 macOS 辅助功能权限。");
        puts("  authorize     打开辅助功能授权引导。");
        puts("");
        puts("选项:");
        puts("  --key NAME           覆盖本次使用的快捷键。");
        puts("  --duration-ms N      hold 的长按时长，默认 5000。");
        puts("  --down-ms N          每次点击的按下时长，默认 45。");
        puts("  --prompt             请求 macOS 显示辅助功能授权提示。");
        puts("  --verbose            前台模式运行时打印详细的 VAD 监听诊断日志。");
        puts("  --lang zh-Hans|en    输出语言，默认 zh-Hans。");
        puts("  -h, --help           显示帮助。");
        return;
    }

    puts("Usage:");
    puts("  doubao-voice [smart] [--key left-shift] [--prompt]");
    puts("  doubao-voice handsfree [--key left-shift]");
    puts("  doubao-voice hold [--key fn] [--duration-ms 5000]");
    puts("  doubao-voice stop");
    puts("  doubao-voice logs");
    puts("  doubao-voice inspect");
    puts("  doubao-voice check [--prompt]");
    puts("  doubao-voice authorize");
    puts("");
    puts("Commands:");
    puts("  smart         Default. Start hands-free mode and auto-finish after silence. Use --verbose for real-time logs.");
    puts("  handsfree     Hands-free mode: tap the shortcut once; Doubao decides start vs finish.");
    puts("  hold          Hold the hold-to-talk shortcut, then release it.");
    puts("  stop          Stop the active voice input recording session (aliases: finish/terminate/kill/cancel).");
    puts("  logs          Show the last 100 lines of VAD diagnostic logs (alias: log).");
    puts("  inspect       Show Doubao install/config/permission diagnostics.");
    puts("  check         Check Accessibility permission.");
    puts("  authorize     Open the Accessibility permission flow.");
    puts("");
    puts("Options:");
    puts("  --key NAME           Override the shortcut for this run.");
    puts("  --duration-ms N      Hold duration for `hold` (default: 5000).");
    puts("  --down-ms N          Key-down time for each tap (default: 45).");
    puts("  --prompt             Ask macOS to show the Accessibility prompt.");
    puts("  --verbose            Print extra event details before triggering.");
    puts("  --lang zh-Hans|en    Output language. Default: zh-Hans.");
    puts("  -h, --help           Show this help.");
    puts("");
    puts("Supported keys:");
    puts("  Single keys or combinations made from fn, shift, command, option, control.");
    puts("  Examples: fn, left-shift, left-command+left-shift, fn+control");
    puts("");
    puts("Note:");
    puts("  The DMG/pkg provides the /Applications/DoubaoVoiceCLI.app menu bar helper.");
    puts("  Grant Accessibility permission to \"Doubao Voice CLI\".");
    puts("  Smart endpointing uses FunASR FSMN-VAD. The app/pkg bundles its runtime and model.");
}

static void die(const char *message) {
    fprintf(stderr, "%s\n", message);
    exit(2);
}

static void dieWithValue(const char *prefix, const char *value) {
    fprintf(stderr, "%s: %s\n", prefix, value);
    exit(2);
}

static bool optionTakesValue(const char *arg) {
    return strcmp(arg, "--key") == 0 ||
           strcmp(arg, "--duration-ms") == 0 ||
           strcmp(arg, "--down-ms") == 0 ||
           strcmp(arg, "--gap-ms") == 0 ||
           strcmp(arg, "--lang") == 0;
}

static size_t keyCount(void) {
    return sizeof(KnownKeys) / sizeof(KnownKeys[0]);
}

static const ShortcutKey *lookupKey(const char *name) {
    for (size_t i = 0; i < keyCount(); i++) {
        if (strcmp(KnownKeys[i].name, name) == 0) {
            return &KnownKeys[i];
        }
    }
    return NULL;
}

static NSString *normalizedToken(NSString *token) {
    NSString *trimmed = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [[trimmed lowercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

static const ShortcutKey *lookupKeyToken(NSString *token) {
    NSString *normalized = normalizedToken(token);
    if ([normalized length] == 0) {
        return NULL;
    }

    if ([normalized isEqualToString:@"fn"] ||
        [normalized isEqualToString:@"globe"] ||
        [normalized isEqualToString:@"地球键"] ||
        [normalized isEqualToString:@"地球"]) {
        return lookupKey("fn");
    }
    if ([normalized isEqualToString:@"command"] ||
        [normalized isEqualToString:@"cmd"] ||
        [normalized isEqualToString:@"⌘"] ||
        [normalized isEqualToString:@"左⌘"] ||
        [normalized isEqualToString:@"left-command"] ||
        [normalized isEqualToString:@"left-cmd"]) {
        return lookupKey("left-command");
    }
    if ([normalized isEqualToString:@"right-command"] ||
        [normalized isEqualToString:@"right-cmd"] ||
        [normalized isEqualToString:@"右command"] ||
        [normalized isEqualToString:@"右cmd"] ||
        [normalized isEqualToString:@"右⌘"]) {
        return lookupKey("right-command");
    }
    if ([normalized isEqualToString:@"option"] ||
        [normalized isEqualToString:@"alt"] ||
        [normalized isEqualToString:@"⌥"] ||
        [normalized isEqualToString:@"左⌥"] ||
        [normalized isEqualToString:@"left-option"] ||
        [normalized isEqualToString:@"left-alt"]) {
        return lookupKey("left-option");
    }
    if ([normalized isEqualToString:@"right-option"] ||
        [normalized isEqualToString:@"right-alt"] ||
        [normalized isEqualToString:@"右option"] ||
        [normalized isEqualToString:@"右alt"] ||
        [normalized isEqualToString:@"右⌥"]) {
        return lookupKey("right-option");
    }
    if ([normalized isEqualToString:@"control"] ||
        [normalized isEqualToString:@"ctrl"] ||
        [normalized isEqualToString:@"⌃"] ||
        [normalized isEqualToString:@"左⌃"] ||
        [normalized isEqualToString:@"left-control"] ||
        [normalized isEqualToString:@"left-ctrl"]) {
        return lookupKey("left-control");
    }
    if ([normalized isEqualToString:@"right-control"] ||
        [normalized isEqualToString:@"right-ctrl"] ||
        [normalized isEqualToString:@"右control"] ||
        [normalized isEqualToString:@"右ctrl"] ||
        [normalized isEqualToString:@"右⌃"]) {
        return lookupKey("right-control");
    }
    if ([normalized isEqualToString:@"shift"] ||
        [normalized isEqualToString:@"⇧"] ||
        [normalized isEqualToString:@"左⇧"] ||
        [normalized isEqualToString:@"left-shift"]) {
        return lookupKey("left-shift");
    }
    if ([normalized isEqualToString:@"right-shift"] ||
        [normalized isEqualToString:@"右shift"] ||
        [normalized isEqualToString:@"右⇧"]) {
        return lookupKey("right-shift");
    }

    return lookupKey([normalized UTF8String]);
}

static void appendCanonicalPart(ShortcutCombo *combo, const char *name) {
    if (combo->canonical[0] != '\0') {
        strlcat(combo->canonical, "+", sizeof(combo->canonical));
    }
    strlcat(combo->canonical, name, sizeof(combo->canonical));
}

static bool parseShortcutString(NSString *value, ShortcutCombo *combo) {
    if (![value isKindOfClass:[NSString class]] || combo == NULL) {
        return false;
    }

    memset(combo, 0, sizeof(*combo));
    NSString *prepared = [[[[value stringByReplacingOccurrencesOfString:@"＋" withString:@"+"]
                             stringByReplacingOccurrencesOfString:@"、" withString:@"+"]
                             stringByReplacingOccurrencesOfString:@"，" withString:@"+"]
                             stringByReplacingOccurrencesOfString:@"," withString:@"+"];
    NSArray *parts = [prepared componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"+ \t\r\n"]];
    unsigned int usedKinds = 0;

    for (NSString *part in parts) {
        NSString *token = normalizedToken(part);
        if ([token length] == 0) {
            continue;
        }

        const ShortcutKey *key = lookupKeyToken(token);
        if (key == NULL || combo->count >= 5) {
            return false;
        }

        unsigned int kindMask = 1u << key->kind;
        if ((usedKinds & kindMask) != 0) {
            return false;
        }
        usedKinds |= kindMask;

        combo->keys[combo->count++] = key;
        combo->flags |= key->flags;
        appendCanonicalPart(combo, key->name);
    }

    return combo->count > 0;
}

static bool parseShortcutCString(const char *value, ShortcutCombo *combo) {
    if (value == NULL) {
        return false;
    }
    return parseShortcutString([NSString stringWithUTF8String:value], combo);
}

static ShortcutCombo parseShortcutOrDie(const char *name) {
    ShortcutCombo combo;
    if (!parseShortcutCString(name, &combo)) {
        dieWithValue(isEnglish() ? "Unsupported shortcut" : "不支持的快捷键", name);
    }
    return combo;
}

static const ShortcutKey *lookupKeyCode(long keyCode) {
    for (size_t i = 0; i < keyCount(); i++) {
        if ((long)KnownKeys[i].keyCode == keyCode) {
            return &KnownKeys[i];
        }
    }
    return NULL;
}

static unsigned long parseUnsignedLong(const char *flag, const char *value) {
    if (value == NULL || value[0] == '\0') {
        dieWithValue(isEnglish() ? "Missing value for" : "缺少参数值", flag);
    }

    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') {
        dieWithValue(isEnglish() ? "Invalid integer for" : "不是合法整数", flag);
    }
    return parsed;
}

static bool isHelpFlag(const char *arg) {
    return strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0;
}

static bool isHandsFreeCommand(const char *command) {
    return strcmp(command, "handsfree") == 0;
}

static bool isSmartCommand(const char *command) {
    return strcmp(command, "smart") == 0 || strcmp(command, "auto") == 0;
}

static bool isInspectCommand(const char *command) {
    return strcmp(command, "inspect") == 0 || strcmp(command, "status") == 0;
}

static bool isStopCommand(const char *command) {
    return strcmp(command, "stop") == 0 ||
           strcmp(command, "finish") == 0 ||
           strcmp(command, "terminate") == 0 ||
           strcmp(command, "kill") == 0 ||
           strcmp(command, "cancel") == 0;
}

static bool isLogsCommand(const char *command) {
    return strcmp(command, "logs") == 0 || strcmp(command, "log") == 0;
}

static bool isKnownCommand(const char *command) {
    return isSmartCommand(command) ||
           isHandsFreeCommand(command) ||
           strcmp(command, "hold") == 0 ||
           strcmp(command, "check") == 0 ||
           strcmp(command, "authorize") == 0 ||
           isInspectCommand(command) ||
           isStopCommand(command) ||
           isLogsCommand(command);
}

static int findCommandIndex(int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (isHelpFlag(arg) || strcmp(arg, "--prompt") == 0 || strcmp(arg, "--verbose") == 0) {
            continue;
        }
        if (optionTakesValue(arg)) {
            i++;
            continue;
        }
        if (arg[0] != '-') {
            return i;
        }
    }
    return -1;
}

static bool isTruthy(id value) {
    if (value == nil) {
        return false;
    }
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    return false;
}

static bool accessibilityTrusted(bool prompt) {
    /*
     AXIsProcessTrustedWithOptions is the official macOS way to check whether
     this process may control other apps. Passing prompt=true asks System
     Settings to show the permission UI; it does not silently grant anything.
     */
    const void *keys[] = { kAXTrustedCheckOptionPrompt };
    const void *values[] = { prompt ? kCFBooleanTrue : kCFBooleanFalse };
    CFDictionaryRef options = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    bool trusted = AXIsProcessTrustedWithOptions(options);
    CFRelease(options);
    return trusted;
}

static void sleepMilliseconds(unsigned long milliseconds) {
    /*
     usleep takes microseconds as a useconds_t. Sleeping in chunks avoids
     overflow if a user gives a large --duration-ms value.
     */
    while (milliseconds > 0) {
        unsigned long chunk = milliseconds > 60000 ? 60000 : milliseconds;
        usleep((useconds_t)(chunk * 1000));
        milliseconds -= chunk;
    }
}

static void postModifierEvent(const ShortcutKey *key, bool isDown, CGEventFlags flags, CGEventSourceRef source) {
    CGEventRef event = CGEventCreateKeyboardEvent(source, key->keyCode, isDown);
    if (event == NULL) {
        die("Failed to create keyboard event");
    }

    /*
     Modifier keys are represented as flagsChanged events. For combinations we
     keep the full visible modifier flag state on every key transition.
     */
    CGEventSetType(event, kCGEventFlagsChanged);
    CGEventSetFlags(event, flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void pressCombo(const ShortcutCombo *combo, CGEventSourceRef source) {
    CGEventFlags flags = 0;
    for (size_t i = 0; i < combo->count; i++) {
        flags |= combo->keys[i]->flags;
        postModifierEvent(combo->keys[i], true, flags, source);
    }
}

static void releaseCombo(const ShortcutCombo *combo, CGEventSourceRef source) {
    CGEventFlags flags = combo->flags;
    for (size_t i = combo->count; i > 0; i--) {
        const ShortcutKey *key = combo->keys[i - 1];
        flags &= ~key->flags;
        postModifierEvent(key, false, flags, source);
    }
}

static void tapCombo(const ShortcutCombo *combo, unsigned long downMs, CGEventSourceRef source) {
    pressCombo(combo, source);
    sleepMilliseconds(downMs);
    releaseCombo(combo, source);
}

static NSDictionary *readDictionaryAtPath(NSString *path) {
    NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return dictionary;
}

static NSString *configDirectoryPath(void) {
    NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    return [support stringByAppendingPathComponent:ConfigDirectoryName];
}

static NSString *configPath(void) {
    return [configDirectoryPath() stringByAppendingPathComponent:ConfigFileName];
}

static NSDictionary *readCliConfig(void) {
    return readDictionaryAtPath(configPath());
}

static bool comboFromConfigValue(id value, ShortcutCombo *combo) {
    if (![value isKindOfClass:[NSString class]]) {
        return false;
    }
    return parseShortcutString((NSString *)value, combo);
}

static bool helperAppInstalled(void) {
    BOOL isDirectory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:HelperBundlePath isDirectory:&isDirectory] && isDirectory;
}

static NSString *helperExecutablePath(void) {
    return [HelperBundlePath stringByAppendingPathComponent:@"Contents/MacOS/DoubaoVoiceCLI"];
}

static NSString *homeRelativePath(NSString *path) {
    NSString *home = NSHomeDirectory();
    if ([path hasPrefix:home]) {
        return [@"~" stringByAppendingString:[path substringFromIndex:[home length]]];
    }
    return path;
}

static NSArray *preferenceDomains(void) {
    return @[DoubaoBundleID, DoubaoSettingsBundleID, DoubaoPinyinBundleID];
}

static NSArray *shortcutPreferenceKeys(void) {
    return @[
        @"asrShortcutKeyCode",
        @"asrShortcutModifierFlags",
        @"asrShortcutKeyDisplay",
        @"asrLongPressShortcutKeyCode",
        @"asrLongPressShortcutModifierFlags",
        @"asrLongPressShortcutKeyDisplay",
        @"pressRespondMode"
    ];
}

static NSMutableDictionary *collectPublicShortcutDefaults(void) {
    /*
     Doubao appears to keep much of its settings state in MMKV/internal storage.
     Still, checking public macOS preferences is useful because future versions
     may mirror these fields there, and this is a stable, non-invasive read.
     */
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    for (NSString *domain in preferenceDomains()) {
        for (NSString *key in shortcutPreferenceKeys()) {
            CFStringRef cfDomain = (__bridge CFStringRef)domain;
            CFStringRef cfKey = (__bridge CFStringRef)key;
            CFTypeRef copied = CFPreferencesCopyAppValue(cfKey, cfDomain);
            if (copied == NULL) {
                continue;
            }

            id object = (__bridge id)copied;
            NSString *compoundKey = [NSString stringWithFormat:@"%@:%@", domain, key];
            [found setObject:object forKey:compoundKey];
            CFRelease(copied);
        }
    }
    return found;
}

static id firstDefaultValue(NSDictionary *defaults, NSArray *keys) {
    for (NSString *domain in preferenceDomains()) {
        for (NSString *key in keys) {
            NSString *compoundKey = [NSString stringWithFormat:@"%@:%@", domain, key];
            id value = [defaults objectForKey:compoundKey];
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

static bool comboFromDisplayValue(id value, ShortcutCombo *combo) {
    if (![value isKindOfClass:[NSString class]]) {
        return false;
    }
    return parseShortcutString((NSString *)value, combo);
}

static bool comboFromNumericValue(id value, ShortcutCombo *combo) {
    if (![value respondsToSelector:@selector(longValue)]) {
        return false;
    }
    const ShortcutKey *key = lookupKeyCode([value longValue]);
    if (key == NULL) {
        return false;
    }
    memset(combo, 0, sizeof(*combo));
    combo->keys[0] = key;
    combo->count = 1;
    combo->flags = key->flags;
    strlcpy(combo->canonical, key->name, sizeof(combo->canonical));
    return true;
}

static KeyChoice inferHandsFreeKey(NSDictionary *defaults) {
    NSDictionary *config = readCliConfig();
    ShortcutCombo combo;
    if (comboFromConfigValue([config objectForKey:ConfigKeyHandsFree], &combo)) {
        return (KeyChoice){combo, "Doubao Voice CLI helper settings"};
    }

    NSArray *displayKeys = @[@"asrShortcutKeyDisplay"];
    NSArray *codeKeys = @[@"asrShortcutKeyCode"];

    if (comboFromDisplayValue(firstDefaultValue(defaults, displayKeys), &combo)) {
        return (KeyChoice){combo, "public Doubao preference display"};
    }

    if (comboFromNumericValue(firstDefaultValue(defaults, codeKeys), &combo)) {
        return (KeyChoice){combo, "public Doubao preference key code"};
    }

    parseShortcutCString(DefaultHandsFreeKeyName, &combo);
    return (KeyChoice){combo, "fallback from observed Doubao settings UI"};
}

static KeyChoice inferHoldKey(NSDictionary *defaults) {
    NSDictionary *config = readCliConfig();
    ShortcutCombo combo;
    if (comboFromConfigValue([config objectForKey:ConfigKeyHold], &combo)) {
        return (KeyChoice){combo, "Doubao Voice CLI helper settings"};
    }

    NSArray *displayKeys = @[@"asrLongPressShortcutKeyDisplay"];
    NSArray *codeKeys = @[@"asrLongPressShortcutKeyCode"];

    if (comboFromDisplayValue(firstDefaultValue(defaults, displayKeys), &combo)) {
        return (KeyChoice){combo, "public Doubao preference display"};
    }

    if (comboFromNumericValue(firstDefaultValue(defaults, codeKeys), &combo)) {
        return (KeyChoice){combo, "public Doubao preference key code"};
    }

    parseShortcutCString(DefaultHoldKeyName, &combo);
    return (KeyChoice){combo, "fallback from observed Doubao settings UI"};
}

static const char *localizedKeyChoiceSource(const char *source) {
    if (isEnglish()) {
        return source;
    }
    if (strcmp(source, "public Doubao preference display") == 0) {
        return "来自豆包公开偏好设置的显示值";
    }
    if (strcmp(source, "public Doubao preference key code") == 0) {
        return "来自豆包公开偏好设置的按键码";
    }
    if (strcmp(source, "fallback from observed Doubao settings UI") == 0) {
        return "根据豆包设置界面观察到的默认值回退";
    }
    if (strcmp(source, "Doubao Voice CLI helper settings") == 0) {
        return "来自菜单栏助手的手动配置";
    }
    return source;
}

static bool fileDataContainsString(NSData *data, NSString *needle) {
    NSData *needleData = [needle dataUsingEncoding:NSUTF8StringEncoding];
    if (needleData == nil || [needleData length] == 0 || data == nil) {
        return false;
    }
    NSRange fullRange = NSMakeRange(0, [data length]);
    return [data rangeOfData:needleData options:0 range:fullRange].location != NSNotFound;
}

static NSArray *scanApplicationSupportForShortcutHints(void) {
    /*
     This is intentionally tiny and read-only. It helps users understand whether
     their Doubao build stores shortcut field names in plaintext somewhere under
     Application Support. The CLI does not parse MMKV or modify any file.
     */
    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DoubaoIme"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:root]) {
        return @[];
    }

    NSMutableArray *matches = [NSMutableArray array];
    NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
    NSArray *resourceKeys = @[NSURLIsRegularFileKey, NSURLFileSizeKey];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:rootURL
                                          includingPropertiesForKeys:resourceKeys
                                                             options:NSDirectoryEnumerationSkipsPackageDescendants | NSDirectoryEnumerationSkipsHiddenFiles
                                                        errorHandler:^BOOL(NSURL *url, NSError *error) {
        (void)url;
        (void)error;
        return YES;
    }];

    NSUInteger scanned = 0;
    for (NSURL *url in enumerator) {
        if (scanned >= 250 || [matches count] >= 10) {
            break;
        }

        NSNumber *isRegular = nil;
        if (![url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:nil] || !isTruthy(isRegular)) {
            continue;
        }

        NSNumber *fileSize = nil;
        if (![url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil]) {
            continue;
        }
        if ([fileSize unsignedLongLongValue] > 256 * 1024) {
            continue;
        }

        NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        scanned++;
        if (data == nil) {
            continue;
        }

        if (fileDataContainsString(data, @"asrShortcutKeyDisplay") ||
            fileDataContainsString(data, @"asrLongPressShortcutKeyDisplay") ||
            fileDataContainsString(data, @"asrShortcutKeyCode") ||
            fileDataContainsString(data, @"asrLongPressShortcutKeyCode")) {
            [matches addObject:homeRelativePath([url path])];
        }
    }

    return matches;
}

static NSDictionary *doubaoInfoPlist(void) {
    NSString *infoPath = [DoubaoBundlePath stringByAppendingPathComponent:@"Contents/Info.plist"];
    return readDictionaryAtPath(infoPath);
}

static bool doubaoIsSelectedInputSource(void) {
    /*
     HIToolbox records the selected input sources in a plist. This is only a
     diagnostic hint; Doubao may still receive global shortcuts even if another
     input source is currently active, depending on how its monitor is running.
     */
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.apple.HIToolbox.plist"];
    NSDictionary *hitoolbox = readDictionaryAtPath(path);
    NSArray *sources = [hitoolbox objectForKey:@"AppleSelectedInputSources"];
    if (![sources isKindOfClass:[NSArray class]]) {
        return false;
    }

    for (id source in sources) {
        if (![source isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *bundleID = [(NSDictionary *)source objectForKey:@"Bundle ID"];
        NSString *inputMode = [(NSDictionary *)source objectForKey:@"Input Mode"];
        if ([bundleID isEqualToString:DoubaoBundleID] ||
            [inputMode containsString:DoubaoBundleID] ||
            [inputMode containsString:@"bytedance.inputmethod.doubaoime"]) {
            return true;
        }
    }
    return false;
}

static void printDefaults(NSDictionary *defaults) {
    if ([defaults count] == 0) {
        puts(isEnglish() ? "Public shortcut defaults: not found" : "公开快捷键偏好设置：未找到");
        return;
    }

    puts(isEnglish() ? "Public shortcut defaults:" : "公开快捷键偏好设置:");
    NSArray *keys = [[defaults allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in keys) {
        id value = [defaults objectForKey:key];
        printf("  %s = %s\n", [key UTF8String], [[value description] UTF8String]);
    }
}

static void printHelperState(void) {
    NSDictionary *config = readCliConfig();
    bool installed = helperAppInstalled();
    printf(isEnglish() ? "Menu bar helper app: %s\n" : "菜单栏助手 App: %s\n",
           installed ? (isEnglish() ? "installed" : "已安装") : (isEnglish() ? "not installed" : "未安装"));
    printf(isEnglish() ? "  path: %s\n" : "  路径: %s\n", [HelperBundlePath UTF8String]);

    ShortcutCombo handsFree;
    ShortcutCombo hold;
    bool hasHandsFree = comboFromConfigValue([config objectForKey:ConfigKeyHandsFree], &handsFree);
    bool hasHold = comboFromConfigValue([config objectForKey:ConfigKeyHold], &hold);
    if (hasHandsFree || hasHold) {
        printf(isEnglish() ? "  saved hands-free shortcut: %s\n" : "  已保存免按模式快捷键: %s\n",
               hasHandsFree ? handsFree.canonical : "(not set)");
        printf(isEnglish() ? "  saved hold-to-talk shortcut: %s\n" : "  已保存长按模式快捷键: %s\n",
               hasHold ? hold.canonical : "(not set)");
    } else {
        puts(isEnglish() ? "  saved shortcuts: not configured yet" : "  已保存快捷键：尚未配置");
    }

    puts(isEnglish() ? "  Accessibility target: Doubao Voice CLI" : "  辅助功能授权对象: 豆包 Voice CLI");
}

static void inspectEnvironment(void) {
    NSDictionary *info = doubaoInfoPlist();
    NSMutableDictionary *defaults = collectPublicShortcutDefaults();
    KeyChoice handsFree = inferHandsFreeKey(defaults);
    KeyChoice hold = inferHoldKey(defaults);
    NSArray *hintFiles = scanApplicationSupportForShortcutHints();

    if (info == nil) {
        printf(isEnglish() ? "Doubao IME bundle: not found at %s\n" : "豆包输入法安装包：未找到，路径 %s\n", [DoubaoBundlePath UTF8String]);
    } else {
        NSString *name = [info objectForKey:@"CFBundleName"];
        NSString *version = [info objectForKey:@"CFBundleShortVersionString"];
        NSString *bundleID = [info objectForKey:@"CFBundleIdentifier"];
        if (name == nil) {
            name = @"DoubaoIme";
        }
        if (version == nil) {
            version = [info objectForKey:@"CFBundleVersion"];
        }
        if (version == nil) {
            version = @"unknown";
        }
        if (bundleID == nil) {
            bundleID = @"unknown";
        }
        puts(isEnglish() ? "Doubao IME bundle: found" : "豆包输入法安装包：已找到");
        printf(isEnglish() ? "  path: %s\n" : "  路径: %s\n", [DoubaoBundlePath UTF8String]);
        printf(isEnglish() ? "  name: %s\n" : "  名称: %s\n", [name UTF8String]);
        printf(isEnglish() ? "  bundle id: %s\n" : "  Bundle ID: %s\n", [bundleID UTF8String]);
        printf(isEnglish() ? "  version: %s\n" : "  版本: %s\n", [version UTF8String]);
    }

    bool trusted = accessibilityTrusted(false);
    bool selected = doubaoIsSelectedInputSource();
    printf(isEnglish() ? "Accessibility permission: %s\n" : "辅助功能权限: %s\n",
           trusted ? (isEnglish() ? "granted" : "已授权") : (isEnglish() ? "not granted" : "未授权"));
    printf(isEnglish() ? "Selected input source looks like Doubao: %s\n" : "当前输入法看起来是豆包: %s\n",
           selected ? (isEnglish() ? "yes" : "是") : (isEnglish() ? "no" : "否"));
    printHelperState();
    printf(isEnglish() ? "Hands-free shortcut: %s (%s)\n" : "免按模式快捷键: %s (%s)\n",
           handsFree.combo.canonical, localizedKeyChoiceSource(handsFree.source));
    printf(isEnglish() ? "Hold-to-talk shortcut: %s (%s)\n" : "长按模式快捷键: %s (%s)\n",
           hold.combo.canonical, localizedKeyChoiceSource(hold.source));
    printDefaults(defaults);

    if ([hintFiles count] == 0) {
        puts(isEnglish() ? "Plaintext Application Support shortcut hints: none found" : "Application Support 明文快捷键线索：未找到");
    } else {
        puts(isEnglish() ? "Plaintext Application Support shortcut hints:" : "Application Support 明文快捷键线索:");
        for (NSString *path in hintFiles) {
            printf("  %s\n", [path UTF8String]);
        }
    }
}

static int levenshteinDistance(const char *s1, const char *s2) {
    int len1 = (int)strlen(s1);
    int len2 = (int)strlen(s2);
    int *matrix = malloc((len1 + 1) * (len2 + 1) * sizeof(int));
    if (!matrix) return 100;
    for (int i = 0; i <= len1; i++) {
        matrix[i * (len2 + 1) + 0] = i;
    }
    for (int j = 0; j <= len2; j++) {
        matrix[0 * (len2 + 1) + j] = j;
    }
    for (int i = 1; i <= len1; i++) {
        for (int j = 1; j <= len2; j++) {
            int cost = (s1[i - 1] == s2[j - 1]) ? 0 : 1;
            int a = matrix[(i - 1) * (len2 + 1) + j] + 1;
            int b = matrix[i * (len2 + 1) + (j - 1)] + 1;
            int c = matrix[(i - 1) * (len2 + 1) + (j - 1)] + cost;
            int min = a < b ? a : b;
            if (c < min) min = c;
            matrix[i * (len2 + 1) + j] = min;
        }
    }
    int result = matrix[len1 * (len2 + 1) + len2];
    free(matrix);
    return result;
}

static const char *recommendCommand(const char *input) {
    const char *commands[] = {
        "smart", "handsfree", "hold", "check", "authorize", "inspect", "stop", "finish"
    };
    int count = sizeof(commands) / sizeof(commands[0]);
    
    for (int i = 0; i < count; i++) {
        if (strstr(input, commands[i]) != NULL || strstr(commands[i], input) != NULL) {
            return commands[i];
        }
    }
    
    const char *bestMatch = NULL;
    int minDistance = 999;
    for (int i = 0; i < count; i++) {
        int dist = levenshteinDistance(input, commands[i]);
        if (dist < minDistance) {
            minDistance = dist;
            bestMatch = commands[i];
        }
    }
    if (minDistance < 4) {
        return bestMatch;
    }
    return NULL;
}

static Options parseOptions(int argc, const char *argv[], KeyChoice handsFree, KeyChoice hold) {
    Options options;
    options.command = "smart";
    options.combo = handsFree.combo;
    options.keyWasSpecified = false;
    options.promptForAccessibility = false;
    options.verbose = false;
    options.downMs = 45;
    options.gapMs = 120;
    options.durationMs = 5000;

    int commandIndex = findCommandIndex(argc, argv);
    if (commandIndex >= 0) {
        options.command = argv[commandIndex];
    }

    if (isHelpFlag(options.command)) {
        printUsage();
        exit(0);
    }
    if (!isKnownCommand(options.command)) {
        const char *rec = recommendCommand(options.command);
        if (rec != NULL) {
            if (isEnglish()) {
                fprintf(stderr, "Unknown command: '%s'. Did you mean '%s'?\n", options.command, rec);
                fprintf(stderr, "Run 'doubao-voice --help' for a list of available commands.\n");
            } else {
                fprintf(stderr, "未知命令: '%s'。您是指 '%s' 吗？\n", options.command, rec);
                fprintf(stderr, "运行 'doubao-voice --help' 可以查看可用命令列表。\n");
            }
        } else {
            if (isEnglish()) {
                fprintf(stderr, "Unknown command: '%s'. Run 'doubao-voice --help' for a list of available commands.\n", options.command);
            } else {
                fprintf(stderr, "未知命令: '%s'。运行 'doubao-voice --help' 可以查看可用命令列表。\n", options.command);
            }
        }
        exit(2);
    }

    if (strcmp(options.command, "hold") == 0) {
        options.combo = hold.combo;
    }

    for (int i = 1; i < argc; i++) {
        if (i == commandIndex) {
            continue;
        }
        const char *arg = argv[i];
        if (isHelpFlag(arg)) {
            printUsage();
            exit(0);
        } else if (strcmp(arg, "--key") == 0) {
            if (++i >= argc) {
                die(isEnglish() ? "--key requires a value" : "--key 需要一个参数值");
            }
            options.combo = parseShortcutOrDie(argv[i]);
            options.keyWasSpecified = true;
        } else if (strcmp(arg, "--duration-ms") == 0) {
            if (++i >= argc) {
                die(isEnglish() ? "--duration-ms requires a value" : "--duration-ms 需要一个参数值");
            }
            options.durationMs = parseUnsignedLong("--duration-ms", argv[i]);
        } else if (strcmp(arg, "--down-ms") == 0) {
            if (++i >= argc) {
                die(isEnglish() ? "--down-ms requires a value" : "--down-ms 需要一个参数值");
            }
            options.downMs = parseUnsignedLong("--down-ms", argv[i]);
        } else if (strcmp(arg, "--gap-ms") == 0) {
            if (++i >= argc) {
                die(isEnglish() ? "--gap-ms requires a value" : "--gap-ms 需要一个参数值");
            }
            options.gapMs = parseUnsignedLong("--gap-ms", argv[i]);
        } else if (strcmp(arg, "--lang") == 0) {
            if (++i >= argc) {
                die(isEnglish() ? "--lang requires a value" : "--lang 需要一个参数值");
            }
            setLanguageFromValue(argv[i]);
        } else if (strcmp(arg, "--prompt") == 0) {
            options.promptForAccessibility = true;
        } else if (strcmp(arg, "--verbose") == 0) {
            options.verbose = true;
        } else {
            dieWithValue(isEnglish() ? "Unknown option" : "未知选项", arg);
        }
    }

    return options;
}

static CGEventSourceRef createEventSource(void) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == NULL) {
        die("Failed to create HID event source");
    }
    CGEventSourceSetLocalEventsSuppressionInterval(source, 0);
    return source;
}

static bool envVarTruthy(const char *name) {
    const char *value = getenv(name);
    if (value == NULL || value[0] == '\0') {
        return false;
    }
    return strcmp(value, "0") != 0 &&
           strcmp(value, "false") != 0 &&
           strcmp(value, "FALSE") != 0 &&
           strcmp(value, "no") != 0 &&
           strcmp(value, "NO") != 0;
}

static bool runOpenCommand(NSArray *arguments) {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/open"];
    [task setArguments:arguments];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        (void)exception;
        return false;
    }

    return [task terminationStatus] == 0;
}

static bool launchHelperApp(void) {
    if (!helperAppInstalled()) {
        return false;
    }

    @autoreleasepool {
        NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:HelperBundleID];
        if ([apps count] > 0) {
            return true;
        }
    }

    if (!runOpenCommand(@[@"-g", @"-b", HelperBundleID])) {
        if (!runOpenCommand(@[@"-g", HelperBundlePath])) {
            return false;
        }
    }

    /*
     The app registers its distributed-notification observer during launch.
     A short wait makes the first CLI command after install reliable without
     needing a heavier IPC service.
     */
    sleepMilliseconds(550);
    return true;
}

static void postHelperNotification(NSDictionary *userInfo) {
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:HelperNotificationName
                                                                   object:@"doubao-voice"
                                                                 userInfo:userInfo
                                                       deliverImmediately:YES];
}

static NSString *unsignedLongString(unsigned long value) {
    return [NSString stringWithFormat:@"%lu", value];
}

static int runSmartForegroundThroughHelperIfAvailable(Options options) {
    if (envVarTruthy("DOUBAO_VOICE_DIRECT")) {
        return -1;
    }

    NSString *executable = helperExecutablePath();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:executable]) {
        return -1;
    }

    /* Ensure the persistent menu-bar helper app is running in the background (which starts the socket daemon). */
    launchHelperApp();

    NSMutableArray *arguments = [NSMutableArray arrayWithObject:@"smart"];
    [arguments addObjectsFromArray:@[@"--down-ms", unsignedLongString(options.downMs)]];
    [arguments addObjectsFromArray:@[@"--gap-ms", unsignedLongString(options.gapMs)]];
    if (options.keyWasSpecified) {
        [arguments addObjectsFromArray:@[@"--key", [NSString stringWithUTF8String:options.combo.canonical]]];
    }

    if (options.verbose) {
        [arguments addObject:@"--verbose"];
    }

    if (isEnglish()) {
        fprintf(stderr, "Running smart endpointing in foreground. Keep this terminal open until it finishes.\n");
    } else {
        fprintf(stderr, "正在以前台模式运行智能判停。请保持这个终端打开，直到它完成。\n");
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:executable];
    [task setArguments:arguments];
    [task setStandardInput:[NSFileHandle fileHandleWithStandardInput]];
    [task setStandardOutput:[NSFileHandle fileHandleWithStandardOutput]];

    if (options.verbose) {
        [task setStandardError:[NSFileHandle fileHandleWithStandardError]];
    } else {
        NSString *logPath = [configDirectoryPath() stringByAppendingPathComponent:@"doubao-voice.log"];
        [[NSFileManager defaultManager] createDirectoryAtPath:configDirectoryPath() withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
            [[NSFileManager defaultManager] createFileAtPath:logPath contents:[NSData data] attributes:nil];
        }
        NSFileHandle *logFileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (logFileHandle != nil) {
            [logFileHandle seekToEndOfFile];
            NSString *header = [NSString stringWithFormat:@"\n=== Session started at %@ ===\n", [NSDate date]];
            [logFileHandle writeData:[header dataUsingEncoding:NSUTF8StringEncoding]];
            [task setStandardError:logFileHandle];
        } else {
            [task setStandardError:[NSFileHandle fileHandleWithStandardError]];
        }
    }

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        (void)exception;
        return -1;
    }

    return [task terminationStatus];
}

static int requestHelperAuthorization(void) {
    if (!launchHelperApp()) {
        return -1;
    }

    postHelperNotification(@{@"command": @"authorize"});
    if (isEnglish()) {
        puts("Opened the menu bar helper app.");
        puts("Allow \"Doubao Voice CLI\" in System Settings > Privacy & Security > Accessibility.");
    } else {
        puts("已打开菜单栏助手 App。");
        puts("请在 系统设置 > 隐私与安全性 > 辅助功能 中允许“豆包 Voice CLI”。");
    }
    return 0;
}

static int runTriggerThroughHelperIfAvailable(Options options) {
    if (envVarTruthy("DOUBAO_VOICE_DIRECT")) {
        return -1;
    }
    if (!launchHelperApp()) {
        return -1;
    }

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:[NSString stringWithUTF8String:options.command] forKey:@"command"];
    [userInfo setObject:@(options.downMs) forKey:@"downMs"];
    [userInfo setObject:@(options.gapMs) forKey:@"gapMs"];
    [userInfo setObject:@(options.durationMs) forKey:@"durationMs"];
    if (options.keyWasSpecified) {
        [userInfo setObject:[NSString stringWithUTF8String:options.combo.canonical] forKey:@"keyName"];
    }

    postHelperNotification(userInfo);
    if (options.verbose) {
        puts(isEnglish() ? "Command sent to menu bar helper app." : "命令已发送给菜单栏助手 App。");
    }
    return 0;
}

static int runLogsCommand(void) {
    NSString *logPath = [configDirectoryPath() stringByAppendingPathComponent:@"doubao-voice.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        if (isEnglish()) {
            puts("No log file found. Run 'doubao-voice' first to generate logs.");
        } else {
            puts("未找到日志文件。请先运行 'doubao-voice' 以生成日志。");
        }
        return 0;
    }
    
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:&error];
    if (error != nil || content == nil) {
        fprintf(stderr, "Failed to read log file: %s\n", [[error localizedDescription] UTF8String]);
        return 1;
    }
    
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    NSUInteger count = [lines count];
    NSUInteger start = (count > 100) ? (count - 100) : 0;
    
    for (NSUInteger i = start; i < count; i++) {
        puts([[lines objectAtIndex:i] UTF8String]);
    }
    return 0;
}

static int runStopCommand(Options options) {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/pkill"];
    [task setArguments:@[@"-f", @"DoubaoVoiceCLI smart"]];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        (void)exception;
    }
    
    int status = [task terminationStatus];
    if (status == 0) {
        /* A VAD process was running and was terminated. Send the toggle-off shortcut. */
        CGEventSourceRef source = createEventSource();
        tapCombo(&options.combo, options.downMs, source);
        CFRelease(source);
        
        printf("{\"status\":\"success\",\"command\":\"stop\",\"stopped\":true}\n");
        fflush(stdout);
        if (isEnglish()) {
            puts("Voice input session stopped.");
        } else {
            puts("语音输入会话已终止。");
        }
    } else {
        printf("{\"status\":\"success\",\"command\":\"stop\",\"stopped\":false}\n");
        fflush(stdout);
        if (isEnglish()) {
            puts("No active voice input session found.");
        } else {
            puts("没有发现运行中的语音输入会话。");
        }
    }
    return 0;
}

static int runTriggerCommand(Options options) {
    if (isSmartCommand(options.command)) {
        int foregroundResult = runSmartForegroundThroughHelperIfAvailable(options);
        if (foregroundResult >= 0) {
            return foregroundResult;
        }
    }

    int helperResult = runTriggerThroughHelperIfAvailable(options);
    if (helperResult >= 0) {
        return helperResult;
    }

    if (!accessibilityTrusted(options.promptForAccessibility)) {
        printf("{\"status\":\"error\",\"command\":\"%s\",\"error_type\":\"accessibility_denied\",\"message\":\"Accessibility permission is not granted. Run: doubao-voice check --prompt\"}\n", options.command);
        fflush(stdout);
        if (isEnglish()) {
            fprintf(stderr, "Accessibility permission is not granted.\n");
            fprintf(stderr, "Run: doubao-voice check --prompt\n");
            fprintf(stderr, "Then allow this binary, or the terminal app running it, in System Settings > Privacy & Security > Accessibility.\n");
        } else {
            fprintf(stderr, "辅助功能权限未授权。\n");
            fprintf(stderr, "请运行: doubao-voice check --prompt\n");
            fprintf(stderr, "然后在 系统设置 > 隐私与安全性 > 辅助功能 中允许运行本 CLI 的应用。\n");
        }
        return 1;
    }

    if (options.verbose) {
        printf(isEnglish() ? "Command: %s\n" : "命令: %s\n", options.command);
        printf(isEnglish() ? "Shortcut: %s%s\n" : "快捷键: %s%s\n",
               options.combo.canonical,
               options.keyWasSpecified ? (isEnglish() ? " from --key" : "，来自 --key") : "");
    }

    if (isSmartCommand(options.command)) {
        printf("{\"status\":\"error\",\"command\":\"smart\",\"error_type\":\"helper_not_installed\",\"message\":\"Smart endpointing requires /Applications/DoubaoVoiceCLI.app\"}\n");
        fflush(stdout);
        if (isEnglish()) {
            fprintf(stderr, "Smart endpointing requires /Applications/DoubaoVoiceCLI.app because microphone metering runs inside the menu bar helper.\n");
            fprintf(stderr, "Use `doubao-voice handsfree` for manual hands-free mode, or drag DoubaoVoiceCLI.app to Applications and run `doubao-voice` again.\n");
        } else {
            fprintf(stderr, "智能判停需要 /Applications/DoubaoVoiceCLI.app，因为麦克风判停运行在菜单栏助手里。\n");
            fprintf(stderr, "你可以先用 `doubao-voice handsfree` 手动使用免按模式，或把 DoubaoVoiceCLI.app 拖到 Applications 后再运行 `doubao-voice`。\n");
        }
        return 2;
    }

    CGEventSourceRef source = createEventSource();
    if (isHandsFreeCommand(options.command)) {
        if (options.verbose) {
            printf(isEnglish() ? "Sending hands-free tap: down=%lums\n" : "发送免按模式单击: 按下=%lums\n", options.downMs);
        }
        tapCombo(&options.combo, options.downMs, source);
        printf("{\"status\":\"success\",\"command\":\"handsfree\"}\n");
        fflush(stdout);
    } else if (strcmp(options.command, "hold") == 0) {
        if (options.verbose) {
            printf(isEnglish() ? "Holding key for %lums\n" : "长按按键 %lums\n", options.durationMs);
        }
        pressCombo(&options.combo, source);
        sleepMilliseconds(options.durationMs);
        releaseCombo(&options.combo, source);
        printf("{\"status\":\"success\",\"command\":\"hold\",\"duration_ms\":%lu}\n", options.durationMs);
        fflush(stdout);
    }
    CFRelease(source);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        configureLanguageFromEnvironment();
        configureLanguageFromArguments(argc, argv);
        NSMutableDictionary *defaults = collectPublicShortcutDefaults();
        KeyChoice handsFree = inferHandsFreeKey(defaults);
        KeyChoice hold = inferHoldKey(defaults);
        Options options = parseOptions(argc, argv, handsFree, hold);

        if (strcmp(options.command, "check") == 0) {
            if (helperAppInstalled() && !envVarTruthy("DOUBAO_VOICE_DIRECT")) {
                if (options.promptForAccessibility) {
                    return requestHelperAuthorization();
                }

                printf(isEnglish() ? "Menu bar helper app: installed\n" : "菜单栏助手 App: 已安装\n");
                printf(isEnglish() ? "Accessibility target: Doubao Voice CLI\n" : "辅助功能授权对象: 豆包 Voice CLI\n");
                puts(isEnglish() ? "Run `doubao-voice authorize` to open the permission panel." :
                                   "请运行 `doubao-voice authorize` 打开授权面板。");
                return 1;
            }

            bool trusted = accessibilityTrusted(options.promptForAccessibility);
            printf(isEnglish() ? "Accessibility permission: %s\n" : "辅助功能权限: %s\n",
                   trusted ? (isEnglish() ? "granted" : "已授权") : (isEnglish() ? "not granted" : "未授权"));
            return trusted ? 0 : 1;
        }

        if (strcmp(options.command, "authorize") == 0) {
            if (helperAppInstalled() && !envVarTruthy("DOUBAO_VOICE_DIRECT")) {
                int helperResult = requestHelperAuthorization();
                if (helperResult >= 0) {
                    return helperResult;
                }
            }

            bool trusted = accessibilityTrusted(true);
            printf(isEnglish() ? "Accessibility permission: %s\n" : "辅助功能权限: %s\n",
                   trusted ? (isEnglish() ? "granted" : "已授权") : (isEnglish() ? "not granted" : "未授权"));
            if (!trusted) {
                if (isEnglish()) {
                    puts("Open System Settings > Privacy & Security > Accessibility, then allow the app that runs this CLI.");
                    puts("If a voice assistant launches the CLI, that assistant may need Accessibility permission too.");
                } else {
                    puts("请打开 系统设置 > 隐私与安全性 > 辅助功能，然后允许运行本 CLI 的应用。");
                    puts("如果由语音助手调用本 CLI，语音助手应用本身可能也需要辅助功能权限。");
                }
            }
            return trusted ? 0 : 1;
        }

        if (isInspectCommand(options.command)) {
            inspectEnvironment();
            return 0;
        }

        if (isStopCommand(options.command)) {
            return runStopCommand(options);
        }

        if (isLogsCommand(options.command)) {
            return runLogsCommand();
        }

        return runTriggerCommand(options);
    }
}
