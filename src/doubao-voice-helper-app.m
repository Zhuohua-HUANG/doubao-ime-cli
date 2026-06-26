#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

#include <math.h>
#include <sys/socket.h>
#include <sys/un.h>

static NSString *const PerformNotificationName = @"dev.doubao-ime-cli.perform";
static NSString *const ConfigDirectoryName = @"DoubaoImeCli";
static NSString *const ConfigFileName = @"config.plist";
static NSString *const ConfigKeyHandsFree = @"handsFreeKeyName";
static NSString *const ConfigKeyHold = @"holdKeyName";
static NSString *const ConfigKeyLanguage = @"language";
static NSString *const ConfigKeyHasShownWelcome = @"hasShownWelcome";
static NSString *const ConfigKeyLastTrusted = @"lastAccessibilityTrusted";
static NSString *const ConfigKeyLastTrustedAt = @"lastAccessibilityTrustedAt";
static NSString *const ConfigKeySmartSilenceTimeoutMs = @"smartSilenceTimeoutMs";
static NSString *const ConfigKeySmartStartTimeoutInfinite = @"smartStartTimeoutInfinite";
static NSString *const ConfigKeySmartStartTimeoutMs = @"smartStartTimeoutMs";
static NSString *const FsmnSocketFileName = @"fsmn_vad.sock";
static const AVAudioFrameCount FsmnAudioTapBufferSize = 16384;
static const unsigned long FsmnModelEndSilenceMs = 800;
static const unsigned long SmartStopGraceMs = 3000;

static NSString *const DefaultHandsFreeKeyName = @"left-shift";
static NSString *const DefaultHoldKeyName = @"fn";

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
} ShortcutKey;

static const ShortcutKey KnownKeys[] = {
    {"fn", 63, kCGEventFlagMaskSecondaryFn, ModifierKindFn},
    {"left-control", 59, kCGEventFlagMaskControl, ModifierKindControl},
    {"right-control", 62, kCGEventFlagMaskControl, ModifierKindControl},
    {"left-option", 58, kCGEventFlagMaskAlternate, ModifierKindOption},
    {"right-option", 61, kCGEventFlagMaskAlternate, ModifierKindOption},
    {"left-command", 55, kCGEventFlagMaskCommand, ModifierKindCommand},
    {"right-command", 54, kCGEventFlagMaskCommand, ModifierKindCommand},
    {"left-shift", 56, kCGEventFlagMaskShift, ModifierKindShift},
    {"right-shift", 60, kCGEventFlagMaskShift, ModifierKindShift},
};

typedef struct {
    const ShortcutKey *keys[5];
    size_t count;
    CGEventFlags flags;
    char canonical[128];
} ShortcutCombo;

static size_t keyCount(void) {
    return sizeof(KnownKeys) / sizeof(KnownKeys[0]);
}

static const ShortcutKey *lookupKey(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) {
        return NULL;
    }

    const char *utf8 = [name UTF8String];
    for (size_t i = 0; i < keyCount(); i++) {
        if (strcmp(KnownKeys[i].name, utf8) == 0) {
            return &KnownKeys[i];
        }
    }
    return NULL;
}

static const ShortcutKey *lookupKeyCode(CGKeyCode keyCode) {
    for (size_t i = 0; i < keyCount(); i++) {
        if (KnownKeys[i].keyCode == keyCode) {
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
        return lookupKey(@"fn");
    }
    if ([normalized isEqualToString:@"command"] ||
        [normalized isEqualToString:@"cmd"] ||
        [normalized isEqualToString:@"⌘"] ||
        [normalized isEqualToString:@"左⌘"] ||
        [normalized isEqualToString:@"left-command"] ||
        [normalized isEqualToString:@"left-cmd"]) {
        return lookupKey(@"left-command");
    }
    if ([normalized isEqualToString:@"right-command"] ||
        [normalized isEqualToString:@"right-cmd"] ||
        [normalized isEqualToString:@"右command"] ||
        [normalized isEqualToString:@"右cmd"] ||
        [normalized isEqualToString:@"右⌘"]) {
        return lookupKey(@"right-command");
    }
    if ([normalized isEqualToString:@"option"] ||
        [normalized isEqualToString:@"alt"] ||
        [normalized isEqualToString:@"⌥"] ||
        [normalized isEqualToString:@"左⌥"] ||
        [normalized isEqualToString:@"left-option"] ||
        [normalized isEqualToString:@"left-alt"]) {
        return lookupKey(@"left-option");
    }
    if ([normalized isEqualToString:@"right-option"] ||
        [normalized isEqualToString:@"right-alt"] ||
        [normalized isEqualToString:@"右option"] ||
        [normalized isEqualToString:@"右alt"] ||
        [normalized isEqualToString:@"右⌥"]) {
        return lookupKey(@"right-option");
    }
    if ([normalized isEqualToString:@"control"] ||
        [normalized isEqualToString:@"ctrl"] ||
        [normalized isEqualToString:@"⌃"] ||
        [normalized isEqualToString:@"左⌃"] ||
        [normalized isEqualToString:@"left-control"] ||
        [normalized isEqualToString:@"left-ctrl"]) {
        return lookupKey(@"left-control");
    }
    if ([normalized isEqualToString:@"right-control"] ||
        [normalized isEqualToString:@"right-ctrl"] ||
        [normalized isEqualToString:@"右control"] ||
        [normalized isEqualToString:@"右ctrl"] ||
        [normalized isEqualToString:@"右⌃"]) {
        return lookupKey(@"right-control");
    }
    if ([normalized isEqualToString:@"shift"] ||
        [normalized isEqualToString:@"⇧"] ||
        [normalized isEqualToString:@"左⇧"] ||
        [normalized isEqualToString:@"left-shift"]) {
        return lookupKey(@"left-shift");
    }
    if ([normalized isEqualToString:@"right-shift"] ||
        [normalized isEqualToString:@"右shift"] ||
        [normalized isEqualToString:@"右⇧"]) {
        return lookupKey(@"right-shift");
    }

    return lookupKey(normalized);
}

static void appendCanonicalPart(ShortcutCombo *combo, const char *name) {
    if (combo->canonical[0] != '\0') {
        strlcat(combo->canonical, "+", sizeof(combo->canonical));
    }
    strlcat(combo->canonical, name, sizeof(combo->canonical));
}

static BOOL parseShortcutString(NSString *value, ShortcutCombo *combo) {
    if (![value isKindOfClass:[NSString class]] || combo == NULL) {
        return NO;
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
            return NO;
        }

        unsigned int kindMask = 1u << key->kind;
        if ((usedKinds & kindMask) != 0) {
            return NO;
        }
        usedKinds |= kindMask;

        combo->keys[combo->count++] = key;
        combo->flags |= key->flags;
        appendCanonicalPart(combo, key->name);
    }

    return combo->count > 0;
}

static NSString *configDirectoryPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"] stringByAppendingPathComponent:ConfigDirectoryName];
}

static NSString *configPath(void) {
    return [configDirectoryPath() stringByAppendingPathComponent:ConfigFileName];
}

static NSMutableDictionary *loadConfig(void) {
    NSDictionary *dictionary = [NSDictionary dictionaryWithContentsOfFile:configPath()];
    if ([dictionary isKindOfClass:[NSDictionary class]]) {
        return [dictionary mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}

static void saveConfig(NSDictionary *config) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager createDirectoryAtPath:configDirectoryPath() withIntermediateDirectories:YES attributes:nil error:nil];
    [config writeToFile:configPath() atomically:YES];
}

static NSString *bundleDefaultLanguage(void) {
    NSString *language = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"DoubaoVoiceDefaultLanguage"];
    if ([language isKindOfClass:[NSString class]] && ([language hasPrefix:@"en"] || [language hasPrefix:@"zh"])) {
        return [language hasPrefix:@"en"] ? @"en" : @"zh-Hans";
    }
    NSArray *preferred = [NSLocale preferredLanguages];
    if (preferred.count > 0) {
        NSString *first = preferred[0];
        if ([first hasPrefix:@"en"]) {
            return @"en";
        }
    }
    return @"zh-Hans";
}

static NSString *configuredLanguage(void) {
    NSString *language = [loadConfig() objectForKey:ConfigKeyLanguage];
    if ([language isKindOfClass:[NSString class]] && ([language hasPrefix:@"en"] || [language hasPrefix:@"zh"])) {
        return [language hasPrefix:@"en"] ? @"en" : @"zh-Hans";
    }
    return bundleDefaultLanguage();
}

static BOOL isEnglish(void) {
    return [configuredLanguage() isEqualToString:@"en"];
}

static NSString *L(NSString *zh, NSString *en) {
    return isEnglish() ? en : zh;
}

static NSString *canonicalShortcutName(NSString *value, NSString *fallback) {
    ShortcutCombo combo;
    if (parseShortcutString(value, &combo)) {
        return [NSString stringWithUTF8String:combo.canonical];
    }
    parseShortcutString(fallback, &combo);
    return [NSString stringWithUTF8String:combo.canonical];
}

static NSString *displayShortcutName(NSString *field, NSString *fallback) {
    NSDictionary *config = loadConfig();
    id value = [config objectForKey:field];
    if ([value isKindOfClass:[NSString class]] && [value length] == 0) {
        return @"";
    }
    return canonicalShortcutName([value isKindOfClass:[NSString class]] ? value : nil, fallback);
}

static BOOL accessibilityTrusted(BOOL prompt) {
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
    BOOL trusted = AXIsProcessTrustedWithOptions(options);
    CFRelease(options);
    return trusted;
}

static void rememberAccessibilityState(BOOL trusted) {
    NSMutableDictionary *config = loadConfig();
    [config setObject:@(trusted) forKey:ConfigKeyLastTrusted];
    [config setObject:[NSDate date] forKey:ConfigKeyLastTrustedAt];
    saveConfig(config);
}

static void openAccessibilitySettings(void) {
    NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

static void sleepMilliseconds(unsigned long milliseconds) {
    while (milliseconds > 0) {
        unsigned long chunk = milliseconds > 60000 ? 60000 : milliseconds;
        usleep((useconds_t)(chunk * 1000));
        milliseconds -= chunk;
    }
}

static void postModifierEvent(const ShortcutKey *key, BOOL isDown, CGEventFlags flags, CGEventSourceRef source) {
    CGEventRef event = CGEventCreateKeyboardEvent(source, key->keyCode, isDown);
    if (event == NULL) {
        return;
    }

    CGEventSetType(event, kCGEventFlagsChanged);
    CGEventSetFlags(event, flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void pressCombo(const ShortcutCombo *combo, CGEventSourceRef source) {
    CGEventFlags flags = 0;
    for (size_t i = 0; i < combo->count; i++) {
        flags |= combo->keys[i]->flags;
        postModifierEvent(combo->keys[i], YES, flags, source);
    }
}

static void releaseCombo(const ShortcutCombo *combo, CGEventSourceRef source) {
    CGEventFlags flags = combo->flags;
    for (size_t i = combo->count; i > 0; i--) {
        const ShortcutKey *key = combo->keys[i - 1];
        flags &= ~key->flags;
        postModifierEvent(key, NO, flags, source);
    }
}

static void tapCombo(const ShortcutCombo *combo, unsigned long downMs, CGEventSourceRef source) {
    pressCombo(combo, source);
    sleepMilliseconds(downMs);
    releaseCombo(combo, source);
}

static BOOL isHoldCommand(NSString *command) {
    return [command isEqualToString:@"hold"];
}

static BOOL isSmartCommand(NSString *command) {
    return [command isEqualToString:@"smart"] || [command isEqualToString:@"auto"];
}

static BOOL isHandsFreeCommand(NSString *command) {
    return [command isEqualToString:@"handsfree"];
}

static BOOL requestMicrophoneAccess(void) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL didGrant) {
        granted = didGrant;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    return granted;
}

typedef enum {
    SpeechEndpointReasonRecorderFailed = 0,
    SpeechEndpointReasonNoSpeech = 1,
    SpeechEndpointReasonSilenceAfterSpeech = 2,
    SpeechEndpointReasonMaxDuration = 3
} SpeechEndpointReason;

typedef struct {
    SpeechEndpointReason reason;
    unsigned long elapsedMs;
    BOOL sawSpeech;
} SpeechEndpointResult;

/* ── FSMN-VAD daemon management globals ────────────────────────────── */

static NSTask *gFsmnDaemonTask = nil;
static BOOL gFsmnDaemonReady = NO;
static NSLock *gFsmnDaemonLock = nil;

static NSString *fsmnSocketPath(void) {
    return [configDirectoryPath() stringByAppendingPathComponent:FsmnSocketFileName];
}

/* ── end daemon globals ────────────────────────────────────────────── */

static NSString *fsmnWorkerPath(void) {
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:@"fsmn_vad_worker" ofType:@"py"];
    if (bundlePath != nil) {
        return bundlePath;
    }

    NSString *installedPath = @"/usr/local/share/doubao-ime-cli/scripts/fsmn_vad_worker.py";
    if ([[NSFileManager defaultManager] fileExistsAtPath:installedPath]) {
        return installedPath;
    }

    NSString *developmentPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"scripts/fsmn_vad_worker.py"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:developmentPath]) {
        return developmentPath;
    }

    return nil;
}

static NSString *bundledFsmnRuntimePath(void) {
    BOOL isDirectory = NO;
    NSString *bundleRuntime = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"fsmn-runtime"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleRuntime isDirectory:&isDirectory] && isDirectory) {
        return bundleRuntime;
    }

    NSString *installedPath = @"/usr/local/share/doubao-ime-cli/fsmn-runtime";
    if ([[NSFileManager defaultManager] fileExistsAtPath:installedPath isDirectory:&isDirectory] && isDirectory) {
        return installedPath;
    }

    NSString *developmentRuntime = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"build/fsmn-runtime"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:developmentRuntime isDirectory:&isDirectory] && isDirectory) {
        return developmentRuntime;
    }

    return nil;
}

static NSString *fsmnPythonPath(void) {
    NSString *explicitPython = [[[NSProcessInfo processInfo] environment] objectForKey:@"DOUBAO_VOICE_PYTHON"];
    if ([explicitPython isKindOfClass:[NSString class]] && [explicitPython length] > 0) {
        return explicitPython;
    }

    NSString *runtimePath = bundledFsmnRuntimePath();
    if (runtimePath != nil) {
        NSString *runtimePython = [runtimePath stringByAppendingPathComponent:@"venv/bin/python3"];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:runtimePython]) {
            return runtimePython;
        }
    }

    return @"/usr/bin/python3";
}

static NSData *pcm16DataFromInputBuffer(AVAudioPCMBuffer *inputBuffer,
                                        AVAudioConverter *converter,
                                        AVAudioFormat *outputFormat) {
    AVAudioFrameCount frameCapacity = (AVAudioFrameCount)ceil((double)inputBuffer.frameLength * outputFormat.sampleRate / inputBuffer.format.sampleRate) + 512;
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:frameCapacity];
    if (outputBuffer == nil) {
        return nil;
    }

    __block BOOL consumed = NO;
    AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer * _Nullable(AVAudioPacketCount inNumberOfPackets,
                                                                       AVAudioConverterInputStatus *outStatus) {
        (void)inNumberOfPackets;
        if (consumed) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        consumed = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return inputBuffer;
    };

    NSError *error = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:outputBuffer error:&error withInputFromBlock:inputBlock];
    if (status == AVAudioConverterOutputStatus_Error || error != nil || outputBuffer.frameLength == 0) {
        if (error != nil) {
            NSLog(@"FSMN-VAD audio conversion failed: %@", error);
        }
        return nil;
    }

    AudioBuffer audioBuffer = outputBuffer.audioBufferList->mBuffers[0];
    if (audioBuffer.mData == NULL || audioBuffer.mDataByteSize == 0) {
        return nil;
    }
    return [NSData dataWithBytes:audioBuffer.mData length:audioBuffer.mDataByteSize];
}

static SpeechEndpointResult waitForSpeechEndpointViaSocket(unsigned long startTimeoutMs,
                                                           unsigned long stopGraceMs,
                                                           unsigned long maxDurationMs) {
    (void)startTimeoutMs;
    SpeechEndpointResult result = { SpeechEndpointReasonRecorderFailed, 0, NO };

    NSString *sockPath = fsmnSocketPath();
    if (sockPath == nil) {
        return result;
    }

    if (gFsmnDaemonLock != nil) {
        if (![gFsmnDaemonLock tryLock]) {
            return result;
        }
        BOOL ready = gFsmnDaemonReady;
        [gFsmnDaemonLock unlock];
        if (!ready) {
            return result;
        }
    } else {
        if (![[NSFileManager defaultManager] fileExistsAtPath:sockPath]) {
            return result;
        }
    }

    if (!requestMicrophoneAccess()) {
        NSLog(@"Microphone permission is not granted.");
        return result;
    }

    /* Connect to the daemon's Unix socket. */
    int sockFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockFd < 0) {
        NSLog(@"FSMN-VAD socket: failed to create socket fd.");
        return result;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, [sockPath fileSystemRepresentation], sizeof(addr.sun_path));

    if (connect(sockFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSLog(@"FSMN-VAD socket: connect failed (%s). Will fallback to pipe.", strerror(errno));
        close(sockFd);
        return result;
    }

    NSLog(@"FSMN-VAD socket: connected to daemon at %@", sockPath);

    /* Wrap the socket fd in NSFileHandle for async reading. */
    NSFileHandle *socketReadHandle = [[NSFileHandle alloc] initWithFileDescriptor:sockFd closeOnDealloc:NO];
    NSCondition *condition = [[NSCondition alloc] init];
    NSMutableArray *events = [NSMutableArray array];
    NSMutableString *readBuffer = [NSMutableString string];
    __block BOOL sessionStarted = NO;
    __block BOOL workerFailed = NO;

    socketReadHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if ([data length] == 0) {
            [condition lock];
            workerFailed = YES;
            [condition signal];
            [condition unlock];
            return;
        }

        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (chunk == nil) {
            return;
        }

        [condition lock];
        [readBuffer appendString:chunk];
        while (YES) {
            NSRange newline = [readBuffer rangeOfString:@"\n"];
            if (newline.location == NSNotFound) {
                break;
            }

            NSString *line = [[readBuffer substringToIndex:newline.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [readBuffer deleteCharactersInRange:NSMakeRange(0, newline.location + newline.length)];
            if ([line length] == 0) {
                continue;
            }

            NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *event = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
            if (![event isKindOfClass:[NSDictionary class]]) {
                NSLog(@"FSMN-VAD socket output: %@", line);
                continue;
            }

            NSString *eventName = [event objectForKey:@"event"];
            if ([eventName isEqualToString:@"session_start"]) {
                sessionStarted = YES;
            } else if ([eventName isEqualToString:@"error"]) {
                workerFailed = YES;
            }
            [events addObject:event];
            [condition signal];
        }
        [condition unlock];
    };

    /* Wait for session_start from the daemon. */
    NSDate *sessionDeadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    [condition lock];
    while (!sessionStarted && !workerFailed && [sessionDeadline timeIntervalSinceNow] > 0) {
        [condition waitUntilDate:sessionDeadline];
    }
    [events removeAllObjects];
    [condition unlock];

    if (!sessionStarted || workerFailed) {
        NSLog(@"FSMN-VAD socket: session_start not received. Will fallback to pipe.");
        socketReadHandle.readabilityHandler = nil;
        close(sockFd);
        return result;
    }

    NSLog(@"FSMN-VAD socket: session started.");

    /* Set up audio engine (same as pipe mode). */
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = [engine inputNode];
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:16000 channels:1 interleaved:YES];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    if (converter == nil || outputFormat == nil) {
        NSLog(@"Failed to create FSMN-VAD audio converter.");
        socketReadHandle.readabilityHandler = nil;
        close(sockFd);
        return result;
    }

    NSLock *writeLock = [[NSLock alloc] init];
    __block BOOL writeFailed = NO;
    [inputNode installTapOnBus:0 bufferSize:FsmnAudioTapBufferSize format:inputFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        if (writeFailed) {
            return;
        }
        NSData *pcmData = pcm16DataFromInputBuffer(buffer, converter, outputFormat);
        if ([pcmData length] == 0) {
            return;
        }
        [writeLock lock];
        @try {
            ssize_t written = send(sockFd, [pcmData bytes], [pcmData length], 0);
            if (written < 0) {
                writeFailed = YES;
            }
        } @catch (NSException *exception) {
            (void)exception;
            writeFailed = YES;
        }
        [writeLock unlock];
    }];

    NSError *engineError = nil;
    if (![engine startAndReturnError:&engineError]) {
        NSLog(@"Failed to start microphone capture for FSMN-VAD: %@", engineError);
        [inputNode removeTapOnBus:0];
        socketReadHandle.readabilityHandler = nil;
        close(sockFd);
        return result;
    }

    /* Main event loop (identical logic to pipe mode). */
    BOOL sawSpeech = NO;
    unsigned long nextProgressLogMs = 1000;
    unsigned long elapsedMs = 0;
    BOOL waitingForGrace = NO;
    NSDate *graceStartedAt = nil;
    NSDate *startedAt = [NSDate date];
    SpeechEndpointReason reason = SpeechEndpointReasonMaxDuration;

    while (YES) {
        NSDate *wakeAt = [NSDate dateWithTimeIntervalSinceNow:0.2];
        [condition lock];
        [condition waitUntilDate:wakeAt];
        NSArray *pendingEvents = [events copy];
        [events removeAllObjects];
        BOOL failed = workerFailed;
        [condition unlock];

        elapsedMs = (unsigned long)(-[startedAt timeIntervalSinceNow] * 1000.0);

        if (failed) {
            reason = SpeechEndpointReasonRecorderFailed;
            break;
        }

        for (NSDictionary *event in pendingEvents) {
            NSString *eventName = [event objectForKey:@"event"];
            if ([eventName isEqualToString:@"speech_start"]) {
                unsigned long atMs = [[event objectForKey:@"at_ms"] unsignedLongValue];
                if (!sawSpeech) {
                    NSLog(@"FSMN-VAD speech detected at modelTime=%lums elapsed=%lums.", atMs, elapsedMs);
                    startedAt = [NSDate date];
                } else if (waitingForGrace) {
                    NSLog(@"FSMN-VAD speech resumed during stop grace at modelTime=%lums elapsed=%lums.", atMs, elapsedMs);
                }
                sawSpeech = YES;
                waitingForGrace = NO;
                graceStartedAt = nil;
            } else if ([eventName isEqualToString:@"speech_end"]) {
                unsigned long atMs = [[event objectForKey:@"at_ms"] unsignedLongValue];
                if (sawSpeech && !waitingForGrace) {
                    waitingForGrace = YES;
                    graceStartedAt = [NSDate date];
                    NSLog(@"FSMN-VAD stop candidate at modelTime=%lums elapsed=%lums; waiting %lums grace.",
                          atMs,
                          elapsedMs,
                          stopGraceMs);
                }
            } else if ([eventName isEqualToString:@"error"]) {
                NSLog(@"FSMN-VAD worker error: %@ %@", [event objectForKey:@"code"], [event objectForKey:@"message"]);
                reason = SpeechEndpointReasonRecorderFailed;
                elapsedMs = (unsigned long)(-[startedAt timeIntervalSinceNow] * 1000.0);
                goto socket_cleanup;
            }
        }

        if (elapsedMs >= nextProgressLogMs) {
            NSLog(@"FSMN-VAD listening elapsed=%lums sawSpeech=%@ stopGrace=%@.",
                  elapsedMs,
                  sawSpeech ? @"YES" : @"NO",
                  waitingForGrace ? @"YES" : @"NO");
            nextProgressLogMs += 1000;
        }

        if (!sawSpeech && startTimeoutMs > 0 && elapsedMs >= startTimeoutMs) {
            reason = SpeechEndpointReasonNoSpeech;
            break;
        }

        if (sawSpeech && elapsedMs >= maxDurationMs) {
            reason = SpeechEndpointReasonMaxDuration;
            break;
        }

        if (waitingForGrace && graceStartedAt != nil &&
            (unsigned long)(-[graceStartedAt timeIntervalSinceNow] * 1000.0) >= stopGraceMs) {
            reason = SpeechEndpointReasonSilenceAfterSpeech;
            break;
        }
    }

socket_cleanup:
    [engine stop];
    [inputNode removeTapOnBus:0];
    socketReadHandle.readabilityHandler = nil;
    /* Shut down writing side so the daemon sees EOF and ends the session. */
    shutdown(sockFd, SHUT_WR);
    /* Brief drain to let session_end arrive before closing. */
    usleep(50000);
    close(sockFd);
    result.reason = reason;
    result.elapsedMs = elapsedMs;
    result.sawSpeech = sawSpeech;
    return result;
}

static SpeechEndpointResult waitForSpeechEndpointViaPipe(unsigned long startTimeoutMs,
                                                         unsigned long stopGraceMs,
                                                         unsigned long maxDurationMs) {
    (void)startTimeoutMs;
    SpeechEndpointResult result = { SpeechEndpointReasonRecorderFailed, 0, NO };

    if (!requestMicrophoneAccess()) {
        NSLog(@"Microphone permission is not granted.");
        return result;
    }

    NSString *workerPath = fsmnWorkerPath();
    if (workerPath == nil) {
        NSLog(@"FSMN-VAD worker not found. Reinstall Doubao Voice CLI.");
        return result;
    }

    NSString *pythonPath = fsmnPythonPath();

    NSTask *task = [[NSTask alloc] init];
    NSPipe *stdinPipe = [NSPipe pipe];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    NSFileHandle *stdinWriter = [stdinPipe fileHandleForWriting];
    NSFileHandle *stdoutReader = [stdoutPipe fileHandleForReading];
    NSFileHandle *stderrReader = [stderrPipe fileHandleForReading];
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [environment setObject:[NSString stringWithFormat:@"%lu", FsmnModelEndSilenceMs] forKey:@"DOUBAO_VOICE_FSMN_END_SILENCE_MS"];
    NSString *runtimePath = bundledFsmnRuntimePath();
    if (runtimePath != nil) {
        [environment setObject:[runtimePath stringByAppendingPathComponent:@"modelscope-cache"] forKey:@"MODELSCOPE_CACHE"];
    }
    NSLog(@"FSMN-VAD runtime python (pipe fallback): %@", pythonPath);

    [task setLaunchPath:pythonPath];
    [task setArguments:@[workerPath]];
    [task setEnvironment:environment];
    [task setStandardInput:stdinPipe];
    [task setStandardOutput:stdoutPipe];
    [task setStandardError:stderrPipe];

    NSCondition *condition = [[NSCondition alloc] init];
    NSMutableArray *events = [NSMutableArray array];
    NSMutableString *stdoutBuffer = [NSMutableString string];
    __block BOOL workerReady = NO;
    __block BOOL workerFailed = NO;

    stdoutReader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if ([data length] == 0) {
            return;
        }

        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (chunk == nil) {
            return;
        }

        [condition lock];
        [stdoutBuffer appendString:chunk];
        while (YES) {
            NSRange newline = [stdoutBuffer rangeOfString:@"\n"];
            if (newline.location == NSNotFound) {
                break;
            }

            NSString *line = [[stdoutBuffer substringToIndex:newline.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [stdoutBuffer deleteCharactersInRange:NSMakeRange(0, newline.location + newline.length)];
            if ([line length] == 0) {
                continue;
            }

            NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *event = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
            if (![event isKindOfClass:[NSDictionary class]]) {
                NSLog(@"FSMN-VAD worker output: %@", line);
                continue;
            }

            NSString *eventName = [event objectForKey:@"event"];
            if ([eventName isEqualToString:@"ready"]) {
                workerReady = YES;
            } else if ([eventName isEqualToString:@"error"]) {
                workerFailed = YES;
            }
            [events addObject:event];
            [condition signal];
        }
        [condition unlock];
    };

    stderrReader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if ([data length] == 0) {
            return;
        }
        NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if ([line length] > 0) {
            NSLog(@"FSMN-VAD worker stderr: %@", [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        }
    };

    @try {
        [task launch];
    } @catch (NSException *exception) {
        NSLog(@"Failed to launch FSMN-VAD worker: %@", exception);
        return result;
    }

    NSDate *readyDeadline = [NSDate dateWithTimeIntervalSinceNow:60.0];
    [condition lock];
    while (!workerReady && !workerFailed && [readyDeadline timeIntervalSinceNow] > 0) {
        [condition waitUntilDate:readyDeadline];
    }
    NSArray *startupEvents = [events copy];
    [events removeAllObjects];
    [condition unlock];

    for (NSDictionary *event in startupEvents) {
        NSString *eventName = [event objectForKey:@"event"];
        if ([eventName isEqualToString:@"ready"]) {
            NSLog(@"FSMN-VAD ready: model=%@ chunk=%@ms endSilence=%@ms",
                  [event objectForKey:@"model"],
                  [event objectForKey:@"chunk_ms"],
                  [event objectForKey:@"max_end_silence_ms"]);
        } else if ([eventName isEqualToString:@"error"]) {
            NSLog(@"FSMN-VAD startup error: %@ %@", [event objectForKey:@"code"], [event objectForKey:@"message"]);
        }
    }

    if (!workerReady || workerFailed) {
        NSLog(@"FSMN-VAD is not available. Reinstall the pkg or run doubao-voice-install-fsmn-vad to verify/repair the bundled runtime.");
        stdoutReader.readabilityHandler = nil;
        stderrReader.readabilityHandler = nil;
        if ([task isRunning]) {
            [task terminate];
        }
        return result;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *inputNode = [engine inputNode];
    AVAudioFormat *inputFormat = [inputNode outputFormatForBus:0];
    AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:16000 channels:1 interleaved:YES];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
    if (converter == nil || outputFormat == nil) {
        NSLog(@"Failed to create FSMN-VAD audio converter.");
        stdoutReader.readabilityHandler = nil;
        stderrReader.readabilityHandler = nil;
        if ([task isRunning]) {
            [task terminate];
        }
        return result;
    }

    NSLock *writeLock = [[NSLock alloc] init];
    __block BOOL writeFailed = NO;
    [inputNode installTapOnBus:0 bufferSize:FsmnAudioTapBufferSize format:inputFormat block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        if (writeFailed) {
            return;
        }
        NSData *pcmData = pcm16DataFromInputBuffer(buffer, converter, outputFormat);
        if ([pcmData length] == 0) {
            return;
        }
        [writeLock lock];
        @try {
            [stdinWriter writeData:pcmData];
        } @catch (NSException *exception) {
            (void)exception;
            writeFailed = YES;
        }
        [writeLock unlock];
    }];

    NSError *engineError = nil;
    if (![engine startAndReturnError:&engineError]) {
        NSLog(@"Failed to start microphone capture for FSMN-VAD: %@", engineError);
        [inputNode removeTapOnBus:0];
        stdoutReader.readabilityHandler = nil;
        stderrReader.readabilityHandler = nil;
        if ([task isRunning]) {
            [task terminate];
        }
        return result;
    }

    BOOL sawSpeech = NO;
    unsigned long nextProgressLogMs = 1000;
    unsigned long elapsedMs = 0;
    BOOL waitingForGrace = NO;
    NSDate *graceStartedAt = nil;
    NSDate *startedAt = [NSDate date];
    SpeechEndpointReason reason = SpeechEndpointReasonMaxDuration;

    while (YES) {
        NSDate *wakeAt = [NSDate dateWithTimeIntervalSinceNow:0.2];
        [condition lock];
        [condition waitUntilDate:wakeAt];
        NSArray *pendingEvents = [events copy];
        [events removeAllObjects];
        BOOL failed = workerFailed;
        [condition unlock];

        elapsedMs = (unsigned long)(-[startedAt timeIntervalSinceNow] * 1000.0);

        if (failed) {
            reason = SpeechEndpointReasonRecorderFailed;
            break;
        }

        for (NSDictionary *event in pendingEvents) {
            NSString *eventName = [event objectForKey:@"event"];
            if ([eventName isEqualToString:@"speech_start"]) {
                unsigned long atMs = [[event objectForKey:@"at_ms"] unsignedLongValue];
                if (!sawSpeech) {
                    NSLog(@"FSMN-VAD speech detected at modelTime=%lums elapsed=%lums.", atMs, elapsedMs);
                    startedAt = [NSDate date];
                } else if (waitingForGrace) {
                    NSLog(@"FSMN-VAD speech resumed during stop grace at modelTime=%lums elapsed=%lums.", atMs, elapsedMs);
                }
                sawSpeech = YES;
                waitingForGrace = NO;
                graceStartedAt = nil;
            } else if ([eventName isEqualToString:@"speech_end"]) {
                unsigned long atMs = [[event objectForKey:@"at_ms"] unsignedLongValue];
                if (sawSpeech && !waitingForGrace) {
                    waitingForGrace = YES;
                    graceStartedAt = [NSDate date];
                    NSLog(@"FSMN-VAD stop candidate at modelTime=%lums elapsed=%lums; waiting %lums grace.",
                          atMs,
                          elapsedMs,
                          stopGraceMs);
                }
            } else if ([eventName isEqualToString:@"error"]) {
                NSLog(@"FSMN-VAD worker error: %@ %@", [event objectForKey:@"code"], [event objectForKey:@"message"]);
                reason = SpeechEndpointReasonRecorderFailed;
                elapsedMs = (unsigned long)(-[startedAt timeIntervalSinceNow] * 1000.0);
                goto fsmn_cleanup;
            }
        }

        if (elapsedMs >= nextProgressLogMs) {
            NSLog(@"FSMN-VAD listening elapsed=%lums sawSpeech=%@ stopGrace=%@.",
                  elapsedMs,
                  sawSpeech ? @"YES" : @"NO",
                  waitingForGrace ? @"YES" : @"NO");
            nextProgressLogMs += 1000;
        }

        if (!sawSpeech && startTimeoutMs > 0 && elapsedMs >= startTimeoutMs) {
            reason = SpeechEndpointReasonNoSpeech;
            break;
        }

        if (sawSpeech && elapsedMs >= maxDurationMs) {
            reason = SpeechEndpointReasonMaxDuration;
            break;
        }

        if (waitingForGrace && graceStartedAt != nil &&
            (unsigned long)(-[graceStartedAt timeIntervalSinceNow] * 1000.0) >= stopGraceMs) {
            reason = SpeechEndpointReasonSilenceAfterSpeech;
            break;
        }
    }

fsmn_cleanup:
    [engine stop];
    [inputNode removeTapOnBus:0];
    stdoutReader.readabilityHandler = nil;
    stderrReader.readabilityHandler = nil;
    @try {
        [stdinWriter closeFile];
    } @catch (NSException *exception) {
        (void)exception;
    }
    if ([task isRunning]) {
        [task terminate];
        [task waitUntilExit];
    }
    result.reason = reason;
    result.elapsedMs = elapsedMs;
    result.sawSpeech = sawSpeech;
    return result;
}

static SpeechEndpointResult waitForSpeechEndpoint(unsigned long startTimeoutMs,
                                                  unsigned long stopGraceMs,
                                                  unsigned long maxDurationMs) {
    /* Try the persistent socket daemon first (zero model-load latency). */
    SpeechEndpointResult result = waitForSpeechEndpointViaSocket(startTimeoutMs, stopGraceMs, maxDurationMs);
    if (result.reason != SpeechEndpointReasonRecorderFailed || result.sawSpeech || result.elapsedMs > 0) {
        return result;
    }

    /* Socket not available — fall back to launching a one-shot pipe worker. */
    NSLog(@"FSMN-VAD socket daemon not available; falling back to pipe mode.");
    return waitForSpeechEndpointViaPipe(startTimeoutMs, stopGraceMs, maxDurationMs);
}

static NSString *speechEndpointReasonName(SpeechEndpointReason reason) {
    switch (reason) {
        case SpeechEndpointReasonNoSpeech:
            return @"no-speech";
        case SpeechEndpointReasonSilenceAfterSpeech:
            return @"silence-after-speech";
        case SpeechEndpointReasonMaxDuration:
            return @"max-duration";
        case SpeechEndpointReasonRecorderFailed:
        default:
            return @"recorder-failed";
    }
}

static int runSmartEndpointCommand(const ShortcutCombo *combo,
                                   unsigned long downMs,
                                   unsigned long gapMs,
                                   CGEventSourceRef source) {
    (void)gapMs;
    const unsigned long minimumBeforeFinishMs = 1600;
    NSDate *startedAt = [NSDate date];

    NSLog(@"Doubao Voice smart: sending start shortcut tap (%s).", combo->canonical);
    tapCombo(combo, downMs, source);

    NSDictionary *config = loadConfig();
    unsigned long silenceTimeoutMs = SmartStopGraceMs;
    id silenceVal = [config objectForKey:ConfigKeySmartSilenceTimeoutMs];
    if (silenceVal != nil) {
        silenceTimeoutMs = [silenceVal unsignedLongValue];
    }

    BOOL startInfinite = YES;
    id startInfVal = [config objectForKey:ConfigKeySmartStartTimeoutInfinite];
    if (startInfVal != nil) {
        startInfinite = [startInfVal boolValue];
    }

    unsigned long startTimeoutMs = 5000;
    id startVal = [config objectForKey:ConfigKeySmartStartTimeoutMs];
    if (startVal != nil) {
        startTimeoutMs = [startVal unsignedLongValue];
    }
    if (startInfinite) {
        startTimeoutMs = 0;
    }

    SpeechEndpointResult endpoint = waitForSpeechEndpoint(startTimeoutMs, silenceTimeoutMs, 60000);
    unsigned long elapsedSinceStartMs = (unsigned long)(-[startedAt timeIntervalSinceNow] * 1000.0);
    if (elapsedSinceStartMs < minimumBeforeFinishMs) {
        sleepMilliseconds(minimumBeforeFinishMs - elapsedSinceStartMs);
    }

    NSLog(@"Doubao Voice smart: endpoint reason=%@ elapsed=%lums sawSpeech=%@; sending finish shortcut tap.",
          speechEndpointReasonName(endpoint.reason),
          endpoint.elapsedMs,
          endpoint.sawSpeech ? @"YES" : @"NO");
    tapCombo(combo, downMs, source);

    BOOL success = (endpoint.reason != SpeechEndpointReasonRecorderFailed);
    if (success) {
        printf("{\"status\":\"success\",\"command\":\"smart\",\"saw_speech\":%s,\"reason\":\"%s\",\"elapsed_ms\":%lu}\n",
               endpoint.sawSpeech ? "true" : "false",
               [speechEndpointReasonName(endpoint.reason) UTF8String],
               endpoint.elapsedMs);
        fflush(stdout);
        return 0;
    } else {
        printf("{\"status\":\"error\",\"command\":\"smart\",\"error_type\":\"recorder-failed\",\"message\":\"FSMN-VAD worker failed or microphone permission is denied. Check logs via 'doubao-voice logs'.\"}\n");
        fflush(stdout);
        return 1;
    }
}

@interface AppCommandOptions : NSObject
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSString *keyName;
@property(nonatomic) unsigned long downMs;
@property(nonatomic) unsigned long gapMs;
@property(nonatomic) unsigned long durationMs;
@end

@implementation AppCommandOptions
@end

static unsigned long unsignedLongOption(NSString *value, unsigned long fallback) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) {
        return fallback;
    }
    NSScanner *scanner = [NSScanner scannerWithString:value];
    unsigned long long parsed = 0;
    if (![scanner scanUnsignedLongLong:&parsed] || ![scanner isAtEnd]) {
        return fallback;
    }
    return (unsigned long)parsed;
}

static NSString *normalizedAppArgument(NSString *argument) {
    NSString *normalized = [[argument stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    while ([normalized hasPrefix:@"--"]) {
        normalized = [normalized substringFromIndex:2];
    }
    while ([normalized hasPrefix:@"-"] || [normalized hasPrefix:@"/"]) {
        normalized = [normalized substringFromIndex:1];
    }
    return normalized;
}

static AppCommandOptions *appCommandOptionsFromArguments(int argc, const char *argv[]) {
    AppCommandOptions *options = [[AppCommandOptions alloc] init];
    options.command = @"handsfree";
    options.downMs = 45;
    options.gapMs = 120;
    options.durationMs = 5000;

    int index = 1;
    if (argc > 1) {
        NSString *first = [NSString stringWithUTF8String:argv[1]];
        NSString *normalizedFirst = normalizedAppArgument(first);
        if (isHandsFreeCommand(normalizedFirst) || isHoldCommand(normalizedFirst) || isSmartCommand(normalizedFirst) || [normalizedFirst isEqualToString:@"authorize"]) {
            options.command = normalizedFirst;
            index = 2;
        }
    }

    for (int i = index; i < argc; i++) {
        NSString *argument = [NSString stringWithUTF8String:argv[i]];
        NSString *normalized = normalizedAppArgument(argument);
        if ([normalized isEqualToString:@"key"] && i + 1 < argc) {
            options.keyName = [NSString stringWithUTF8String:argv[++i]];
        } else if ([normalized isEqualToString:@"duration-ms"] && i + 1 < argc) {
            options.durationMs = unsignedLongOption([NSString stringWithUTF8String:argv[++i]], options.durationMs);
        } else if ([normalized isEqualToString:@"down-ms"] && i + 1 < argc) {
            options.downMs = unsignedLongOption([NSString stringWithUTF8String:argv[++i]], options.downMs);
        } else if ([normalized isEqualToString:@"gap-ms"] && i + 1 < argc) {
            options.gapMs = unsignedLongOption([NSString stringWithUTF8String:argv[++i]], options.gapMs);
        }
    }

    return options;
}

static int runOneShotCommandFromArguments(int argc, const char *argv[]) {
    AppCommandOptions *options = appCommandOptionsFromArguments(argc, argv);

    if ([options.command isEqualToString:@"authorize"]) {
        openAccessibilitySettings();
        accessibilityTrusted(YES);
        return 0;
    }
    if (!isHandsFreeCommand(options.command) && !isHoldCommand(options.command) && !isSmartCommand(options.command)) {
        printf("{\"status\":\"error\",\"command\":\"%s\",\"error_type\":\"unsupported_command\",\"message\":\"Unsupported command.\"}\n", [options.command UTF8String]);
        fflush(stdout);
        NSLog(@"Unsupported Doubao Voice CLI app argument: %@", options.command);
        return 2;
    }

    ShortcutCombo combo;
    if (!parseShortcutString(options.keyName, &combo)) {
        NSString *configured = displayShortcutName(isHoldCommand(options.command) ? ConfigKeyHold : ConfigKeyHandsFree,
                                                   isHoldCommand(options.command) ? DefaultHoldKeyName : DefaultHandsFreeKeyName);
        if (!parseShortcutString(configured, &combo)) {
            printf("{\"status\":\"error\",\"command\":\"%s\",\"error_type\":\"shortcut_not_configured\",\"message\":\"Shortcut is not configured.\"}\n", [options.command UTF8String]);
            fflush(stdout);
            NSLog(@"Shortcut is not configured for command: %@", options.command);
            return 2;
        }
    }

    BOOL trusted = accessibilityTrusted(YES);
    rememberAccessibilityState(trusted);
    if (!trusted) {
        printf("{\"status\":\"error\",\"command\":\"%s\",\"error_type\":\"accessibility_denied\",\"message\":\"Accessibility permission is not granted. Open System Settings > Privacy & Security > Accessibility, then allow 'Doubao Voice CLI'.\"}\n", [options.command UTF8String]);
        fflush(stdout);
        openAccessibilitySettings();
        return 1;
    }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == NULL) {
        return 1;
    }
    CGEventSourceSetLocalEventsSuppressionInterval(source, 0);

    int status = 0;
    if (isSmartCommand(options.command)) {
        status = runSmartEndpointCommand(&combo, options.downMs, options.gapMs, source);
    } else if (isHoldCommand(options.command)) {
        pressCombo(&combo, source);
        sleepMilliseconds(options.durationMs);
        releaseCombo(&combo, source);
        printf("{\"status\":\"success\",\"command\":\"hold\",\"duration_ms\":%lu}\n", options.durationMs);
        fflush(stdout);
    } else {
        tapCombo(&combo, options.downMs, source);
        printf("{\"status\":\"success\",\"command\":\"handsfree\"}\n");
        fflush(stdout);
    }

    CFRelease(source);
    return status;
}

static NSString *agentUsageText(void) {
    if (isEnglish()) {
        return @"You can call the local CLI `doubao-voice` to control Doubao IME voice input.\n\n"
               @"Rules:\n"
               @"1. Start smart hands-free voice input: run `doubao-voice`\n"
               @"2. The CLI will auto-finish after it detects speech followed by silence.\n"
               @"3. Manual hands-free mode: run `doubao-voice handsfree`\n"
               @"4. Hold-to-talk for N seconds: run `doubao-voice hold --duration-ms N000`\n"
               @"   Example for 5 seconds: `doubao-voice hold --duration-ms 5000`\n"
               @"5. Check environment and permission: run `doubao-voice inspect --lang en`\n\n"
               @"Shortcut rules:\n"
               @"- The menu bar helper stores the hands-free and hold-to-talk shortcuts.\n"
               @"- Shortcuts must use single keys or combinations made from fn, shift, command, option, control.\n"
               @"- Examples: fn, left-shift, left-command+left-shift, fn+control.\n"
               @"- Do not pass `--key` unless the user asks for a temporary override.\n\n"
               @"Output format:\n"
               @"- On completion, the CLI outputs a single JSON line on standard output. Examples:\n"
               @"  - Success with speech detected and stopped on silence:\n"
               @"    `{\"status\":\"success\",\"command\":\"smart\",\"saw_speech\":true,\"reason\":\"silence-after-speech\",\"elapsed_ms\":4500}`\n"
               @"  - Success with no speech detected:\n"
               @"    `{\"status\":\"success\",\"command\":\"smart\",\"saw_speech\":false,\"reason\":\"no-speech\",\"elapsed_ms\":3000}`\n"
               @"  - Failure due to missing Accessibility permissions:\n"
               @"    `{\"status\":\"error\",\"command\":\"smart\",\"error_type\":\"accessibility_denied\",\"message\":\"...\"}`\n"
               @"  - Failure due to background VAD or microphone issues:\n"
               @"    `{\"status\":\"error\",\"command\":\"smart\",\"error_type\":\"recorder-failed\",\"message\":\"...\"}`\n\n"
               @"Troubleshooting for Agent:\n"
               @"- If the status is \"error\":\n"
               @"  1. If `accessibility_denied`, explain to the user that they must authorize \"Doubao Voice CLI\" in System Settings.\n"
               @"  2. For other failures, run `doubao-voice logs` (or `doubao-voice log`) to print the last 100 lines of background VAD diagnostics logs, or run `doubao-voice inspect` to diagnose settings and shortcut key mismatches.\n\n"
               @"This CLI does not transcribe audio. It only triggers Doubao IME voice input.";
    }

    return @"你可以调用本机 CLI `doubao-voice` 来控制豆包输入法的语音输入。\n\n"
           @"基础规则：\n"
           @"1. 开始智能免按语音输入：运行 `doubao-voice`\n"
           @"2. CLI 会在检测到说话后，再检测到静音时自动结束/提交。\n"
           @"3. 手动触发免按模式：运行 `doubao-voice handsfree`\n"
           @"4. 长按说话 N 秒：运行 `doubao-voice hold --duration-ms N000`\n"
           @"   例如长按 5 秒：`doubao-voice hold --duration-ms 5000`\n"
           @"5. 检查环境和权限：运行 `doubao-voice inspect`\n\n"
           @"快捷键规则：\n"
           @"- 免按模式和长按模式快捷键由菜单栏助手保存。\n"
           @"- 快捷键只能使用 fn、shift、command、option、control 中的单键或组合键。\n"
           @"- 示例：fn、left-shift、left-command+left-shift、fn+control。\n"
           @"- 除非用户明确要求临时覆盖，否则不要主动添加 `--key`。\n\n"
           @"输出格式：\n"
           @"- 执行结束时，CLI 会在标准输出（stdout）打印一行 JSON，说明执行结果。示例：\n"
           @"  - 成功检测到说话并在静音后自动结束：\n"
           @"    `{\"status\":\"success\",\"command\":\"smart\",\"saw_speech\":true,\"reason\":\"silence-after-speech\",\"elapsed_ms\":4500}`\n"
           @"  - 成功运行但未检测到说话：\n"
           @"    `{\"status\":\"success\",\"command\":\"smart\",\"saw_speech\":false,\"reason\":\"no-speech\",\"elapsed_ms\":3000}`\n"
           @"  - 因缺少辅助功能权限失败：\n"
           @"    `{\"status\":\"error\",\"command\":\"smart\",\"error_type\":\"accessibility_denied\",\"message\":\"...\"}`\n"
           @"  - 因 VAD 进程或麦克风故障失败：\n"
           @"    `{\"status\":\"error\",\"command\":\"smart\",\"error_type\":\"recorder-failed\",\"message\":\"...\"}`\n\n"
           @"排查指南（供 Agent 使用）：\n"
           @"- 如果返回的 JSON 中 status 为 \"error\"：\n"
           @"  1. 若 error_type 为 `accessibility_denied`，请提示用户需要在“系统设置 > 隐私与安全性 > 辅助功能”中允许“豆包 Voice CLI”。\n"
           @"  2. 若为其他类型失败，可运行 `doubao-voice logs`（或 `doubao-voice log`）获取最近 100 行后台诊断日志以分析具体错误原因（如 Python 虚拟环境、VAD 模型加载或音频格式转换问题），或运行 `doubao-voice inspect` 检查系统依赖、快捷键推断与授权状态。\n\n"
           @"这个 CLI 不负责语音识别内容，它只负责触发豆包输入法的语音输入，并在本机做静音判停。";
}

static NSTextField *label(NSString *text, NSRect frame, CGFloat fontSize, BOOL bold) {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    [field setStringValue:text];
    [field setEditable:NO];
    [field setSelectable:NO];
    [field setBezeled:NO];
    [field setDrawsBackground:NO];
    [field setFont:bold ? [NSFont boldSystemFontOfSize:fontSize] : [NSFont systemFontOfSize:fontSize]];
    [field setLineBreakMode:NSLineBreakByWordWrapping];
    return field;
}

static NSTextField *textInput(NSRect frame) {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    [field setEditable:YES];
    [field setSelectable:YES];
    [field setBezeled:YES];
    [field setBezelStyle:NSTextFieldRoundedBezel];
    [field setDrawsBackground:YES];
    [field setFont:[NSFont systemFontOfSize:13]];
    return field;
}

@interface SettingsWindow : NSWindow
@end

@implementation SettingsWindow
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (([event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars isEqualToString:@"c"]) {
            if ([NSApp sendAction:@selector(copy:) to:nil from:self]) {
                return YES;
            }
        } else if ([chars isEqualToString:@"v"]) {
            if ([NSApp sendAction:@selector(paste:) to:nil from:self]) {
                return YES;
            }
        } else if ([chars isEqualToString:@"x"]) {
            if ([NSApp sendAction:@selector(cut:) to:nil from:self]) {
                return YES;
            }
        } else if ([chars isEqualToString:@"a"]) {
            if ([NSApp sendAction:@selector(selectAll:) to:nil from:self]) {
                return YES;
            }
        }
    }
    return [super performKeyEquivalent:event];
}
@end

@interface SettingsContentView : NSView
@end

@implementation SettingsContentView
- (void)mouseDown:(NSEvent *)event {
    [[self window] makeFirstResponder:nil];
    [super mouseDown:event];
}
@end

@interface CardView : NSView
@end

@implementation CardView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = NSInsetRect([self bounds], 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:10 yRadius:10];
    [[NSColor controlBackgroundColor] setFill];
    [path fill];
    
    [[NSColor separatorColor] setStroke];
    [path setLineWidth:1.0];
    [path stroke];
}
@end

@interface DividerView : NSView
@end

@implementation DividerView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = [self bounds];
    [[NSColor separatorColor] setFill];
    NSRectFill(bounds);
}
@end

static NSImage *statusBarImage(void) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [image lockFocus];

    [[NSColor blackColor] setStroke];
    CGFloat strokeWidth = 1.8;

    NSBezierPath *chevron = [NSBezierPath bezierPath];
    [chevron moveToPoint:NSMakePoint(2.5, 13)];
    [chevron lineToPoint:NSMakePoint(6.5, 9)];
    [chevron lineToPoint:NSMakePoint(2.5, 5)];
    [chevron setLineWidth:strokeWidth];
    [chevron setLineCapStyle:NSLineCapStyleRound];
    [chevron setLineJoinStyle:NSLineJoinStyleRound];
    [chevron stroke];

    NSBezierPath *bar1 = [NSBezierPath bezierPath];
    [bar1 moveToPoint:NSMakePoint(9.5, 6.5)];
    [bar1 lineToPoint:NSMakePoint(9.5, 11.5)];
    [bar1 setLineWidth:strokeWidth];
    [bar1 setLineCapStyle:NSLineCapStyleRound];
    [bar1 stroke];

    NSBezierPath *bar2 = [NSBezierPath bezierPath];
    [bar2 moveToPoint:NSMakePoint(12.5, 4.5)];
    [bar2 lineToPoint:NSMakePoint(12.5, 13.5)];
    [bar2 setLineWidth:strokeWidth];
    [bar2 setLineCapStyle:NSLineCapStyleRound];
    [bar2 stroke];

    NSBezierPath *bar3 = [NSBezierPath bezierPath];
    [bar3 moveToPoint:NSMakePoint(15.5, 6.0)];
    [bar3 lineToPoint:NSMakePoint(15.5, 12.0)];
    [bar3 setLineWidth:strokeWidth];
    [bar3 setLineCapStyle:NSLineCapStyleRound];
    [bar3 stroke];

    [image unlockFocus];
    [image setTemplate:YES];
    return image;
}

static NSString *displayNameForShortcutToken(NSString *token, BOOL english) {
    if ([token isEqualToString:@"fn"]) {
        return @"fn";
    }
    if ([token isEqualToString:@"left-command"]) {
        return english ? @"Left Command" : @"左⌘";
    }
    if ([token isEqualToString:@"right-command"]) {
        return english ? @"Right Command" : @"右⌘";
    }
    if ([token isEqualToString:@"left-option"]) {
        return english ? @"Left Option" : @"左⌥";
    }
    if ([token isEqualToString:@"right-option"]) {
        return english ? @"Right Option" : @"右⌥";
    }
    if ([token isEqualToString:@"left-control"]) {
        return english ? @"Left Control" : @"左⌃";
    }
    if ([token isEqualToString:@"right-control"]) {
        return english ? @"Right Control" : @"右⌃";
    }
    if ([token isEqualToString:@"left-shift"]) {
        return english ? @"Left Shift" : @"左⇧";
    }
    if ([token isEqualToString:@"right-shift"]) {
        return english ? @"Right Shift" : @"右⇧";
    }
    return token;
}

static NSString *displayNameForShortcut(NSString *shortcutName, BOOL english) {
    ShortcutCombo combo;
    if (!parseShortcutString(shortcutName, &combo)) {
        return shortcutName != nil ? shortcutName : @"";
    }

    NSMutableArray *parts = [NSMutableArray array];
    NSArray *tokens = [[NSString stringWithUTF8String:combo.canonical] componentsSeparatedByString:@"+"];
    for (NSString *token in tokens) {
        [parts addObject:displayNameForShortcutToken(token, english)];
    }
    return [parts componentsJoinedByString:@"+"];
}

@interface ShortcutRecorderControl : NSControl
@property(nonatomic, copy) NSString *shortcutName;
@property(nonatomic, copy) NSString *placeholderText;
@property(nonatomic, copy) NSString *recordingText;
@property(nonatomic) BOOL displayEnglish;
@property(nonatomic) BOOL invalidCapture;
@property(nonatomic) BOOL clearedShortcut;
@end

@implementation ShortcutRecorderControl {
    NSMutableSet<NSString *> *_downKeyNames;
    NSMutableSet<NSString *> *_capturedKeyNames;
    BOOL _recording;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _downKeyNames = [NSMutableSet set];
        _capturedKeyNames = [NSMutableSet set];
        _shortcutName = @"";
        _placeholderText = @"";
        _recordingText = @"";
        [self setFocusRingType:NSFocusRingTypeExterior];
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    _recording = YES;
    [_downKeyNames removeAllObjects];
    [_capturedKeyNames removeAllObjects];
    self.invalidCapture = NO;
    self.clearedShortcut = NO;
    [self setNeedsDisplay:YES];
    return YES;
}

- (BOOL)resignFirstResponder {
    _recording = NO;
    [_downKeyNames removeAllObjects];
    [_capturedKeyNames removeAllObjects];
    [self setNeedsDisplay:YES];
    return YES;
}

- (NSRect)clearButtonRectForPillRect:(NSRect)pillRect {
    CGFloat size = 14.0;
    return NSMakeRect(NSMaxX(pillRect) - size - 6,
                      NSMidY(pillRect) - size / 2.0,
                      size,
                      size);
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    NSString *text = @"";
    if ([self.shortcutName length] > 0) {
        text = displayNameForShortcut(self.shortcutName, self.displayEnglish);
    }
    
    if ([text length] > 0) {
        CGFloat pillWidth = self.bounds.size.width;
        NSRect pillRect = NSMakeRect(0, (self.bounds.size.height - 24)/2.0, pillWidth, 24);
        
        if (NSPointInRect(point, [self clearButtonRectForPillRect:pillRect])) {
            self.clearedShortcut = YES;
            self.invalidCapture = NO;
            self.shortcutName = @"";
            [_downKeyNames removeAllObjects];
            [_capturedKeyNames removeAllObjects];
            [[self window] makeFirstResponder:nil];
            [self sendAction:[self action] to:[self target]];
            return;
        }
    }

    [[self window] makeFirstResponder:self];
}

- (void)setShortcutName:(NSString *)shortcutName {
    _shortcutName = shortcutName != nil ? [shortcutName copy] : @"";
    [self setNeedsDisplay:YES];
}

- (void)setPlaceholderText:(NSString *)placeholderText {
    _placeholderText = placeholderText != nil ? [placeholderText copy] : @"";
    [self setNeedsDisplay:YES];
}

- (void)setRecordingText:(NSString *)recordingText {
    _recordingText = recordingText != nil ? [recordingText copy] : @"";
    [self setNeedsDisplay:YES];
}

- (void)setDisplayEnglish:(BOOL)displayEnglish {
    _displayEnglish = displayEnglish;
    [self setNeedsDisplay:YES];
}

- (ShortcutCombo)comboFromKeyNames:(NSSet<NSString *> *)keyNames {
    ShortcutCombo combo;
    memset(&combo, 0, sizeof(combo));
    unsigned int usedKinds = 0;

    for (size_t i = 0; i < keyCount(); i++) {
        NSString *name = [NSString stringWithUTF8String:KnownKeys[i].name];
        if (![keyNames containsObject:name]) {
            continue;
        }

        unsigned int kindMask = 1u << KnownKeys[i].kind;
        if ((usedKinds & kindMask) != 0 || combo.count >= 5) {
            memset(&combo, 0, sizeof(combo));
            return combo;
        }

        usedKinds |= kindMask;
        combo.keys[combo.count++] = &KnownKeys[i];
        combo.flags |= KnownKeys[i].flags;
        appendCanonicalPart(&combo, KnownKeys[i].name);
    }

    return combo;
}

- (void)flagsChanged:(NSEvent *)event {
    const ShortcutKey *key = lookupKeyCode((CGKeyCode)[event keyCode]);
    if (key == NULL) {
        self.invalidCapture = YES;
        NSBeep();
        [self sendAction:[self action] to:[self target]];
        return;
    }

    NSString *name = [NSString stringWithUTF8String:key->name];
    BOOL isDown = (((CGEventFlags)[event modifierFlags]) & key->flags) != 0;
    if (isDown) {
        if ([_downKeyNames count] == 0 && [_capturedKeyNames count] > 0) {
            [_capturedKeyNames removeAllObjects];
        }
        [_downKeyNames addObject:name];
        [_capturedKeyNames addObject:name];
    } else {
        [_downKeyNames removeObject:name];
    }

    ShortcutCombo combo = [self comboFromKeyNames:_capturedKeyNames];
    if (isDown && combo.count > 0) {
        self.invalidCapture = NO;
        self.shortcutName = [NSString stringWithUTF8String:combo.canonical];
        [self sendAction:[self action] to:[self target]];
    } else if (isDown) {
        self.invalidCapture = YES;
        NSBeep();
        [self sendAction:[self action] to:[self target]];
    }
    [self setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent *)event {
    (void)event;
    self.invalidCapture = YES;
    NSBeep();
    [self sendAction:[self action] to:[self target]];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = [self bounds];
    NSString *text = @"";
    NSColor *textColor = [NSColor labelColor];
    BOOL hasShortcut = NO;
    
    if (_recording && [_downKeyNames count] == 0 && [_capturedKeyNames count] == 0) {
        text = self.recordingText;
        textColor = [NSColor secondaryLabelColor];
    } else if ([self.shortcutName length] > 0) {
        text = displayNameForShortcut(self.shortcutName, self.displayEnglish);
        hasShortcut = YES;
    } else {
        text = self.placeholderText;
        textColor = [NSColor secondaryLabelColor];
    }
    
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: textColor
    };
    NSSize textSize = [text sizeWithAttributes:attributes];
    CGFloat pillWidth = bounds.size.width;
    
    NSRect pillRect = NSMakeRect(0, (bounds.size.height - 24)/2.0, pillWidth, 24);
    NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:6 yRadius:6];
    
    if (_recording) {
        [[NSColor colorWithCalibratedRed:59/255.0 green:130/255.0 blue:246/255.0 alpha:0.1] setFill];
        [pillPath fill];
        [[NSColor controlAccentColor] setStroke];
        [pillPath setLineWidth:1.5];
        [pillPath stroke];
    } else {
        [[NSColor colorWithCalibratedWhite:0.5 alpha:0.15] setFill];
        [pillPath fill];
    }
    
    CGFloat textRegionWidth = hasShortcut ? (pillWidth - 30.0) : pillWidth;
    CGFloat textX = NSMinX(pillRect) + (textRegionWidth - textSize.width) / 2.0;
    if (textX < NSMinX(pillRect) + 8) {
        textX = NSMinX(pillRect) + 8;
    }
    NSRect textRect = NSMakeRect(textX,
                                 NSMidY(pillRect) - textSize.height / 2.0 - 0.5,
                                 textSize.width,
                                 textSize.height);
    [text drawInRect:textRect withAttributes:attributes];
    
    if (hasShortcut && !_recording) {
        NSRect clearRect = [self clearButtonRectForPillRect:pillRect];
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:clearRect];
        [[NSColor colorWithCalibratedWhite:0.6 alpha:1.0] setFill];
        [circle fill];
        
        [[NSColor whiteColor] setStroke];
        NSBezierPath *cross = [NSBezierPath bezierPath];
        [cross setLineWidth:1.2];
        CGFloat pad = 3.5;
        [cross moveToPoint:NSMakePoint(NSMinX(clearRect) + pad, NSMinY(clearRect) + pad)];
        [cross lineToPoint:NSMakePoint(NSMaxX(clearRect) - pad, NSMaxY(clearRect) - pad)];
        [cross moveToPoint:NSMakePoint(NSMinX(clearRect) + pad, NSMaxY(clearRect) - pad)];
        [cross lineToPoint:NSMakePoint(NSMaxX(clearRect) - pad, NSMinY(clearRect) + pad)];
        [cross stroke];
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSSegmentedControl *languageControl;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *subtitleLabel;
@property(nonatomic, strong) NSTextField *handsFreeTitleLabel;
@property(nonatomic, strong) ShortcutRecorderControl *handsFreeField;
@property(nonatomic, strong) NSTextField *holdTitleLabel;
@property(nonatomic, strong) ShortcutRecorderControl *holdField;
@property(nonatomic, strong) NSTextField *shortcutHelpLabel;
@property(nonatomic, strong) NSTextField *shortcutErrorLabel;
@property(nonatomic, strong) NSTextField *permissionTitleLabel;
@property(nonatomic, strong) NSButton *permissionButton;
@property(nonatomic, strong) NSTextField *usageTitleLabel;
@property(nonatomic, strong) NSButton *instructionsCopyButton;
@property(nonatomic, strong) NSTextView *usageTextView;
@property(nonatomic, strong) NSButton *quitButton;

@property(nonatomic, strong) CardView *shortcutCard;
@property(nonatomic, strong) CardView *permissionCard;
@property(nonatomic, strong) CardView *usageCard;
@property(nonatomic, strong) CardView *smartVadCard;
@property(nonatomic, strong) NSTextField *smartVadTitleLabel;
@property(nonatomic, strong) NSTextField *silenceTimeoutLabel;
@property(nonatomic, strong) NSTextField *silenceTimeoutField;
@property(nonatomic, strong) NSButton *startInfiniteCheckbox;
@property(nonatomic, strong) NSTextField *startTimeoutLabel;
@property(nonatomic, strong) NSTextField *startTimeoutField;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self ensureDefaultConfig];
    [self createStatusItem];

    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                        selector:@selector(handlePerformNotification:)
                                                            name:PerformNotificationName
                                                          object:nil
                                              suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

    NSMutableDictionary *config = loadConfig();
    if (![[config objectForKey:ConfigKeyHasShownWelcome] boolValue]) {
        [config setObject:@YES forKey:ConfigKeyHasShownWelcome];
        saveConfig(config);
        [self showSettings:nil];
    }

    /* Initialize daemon lock and start the persistent FSMN-VAD worker. */
    if (gFsmnDaemonLock == nil) {
        gFsmnDaemonLock = [[NSLock alloc] init];
    }
    [self startFsmnDaemon];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self stopFsmnDaemon];
}

- (void)startFsmnDaemon {
    NSString *workerPath = fsmnWorkerPath();
    if (workerPath == nil) {
        NSLog(@"FSMN-VAD daemon: worker script not found. Socket mode disabled.");
        return;
    }

    NSString *pythonPath = fsmnPythonPath();
    NSString *sockPath = fsmnSocketPath();

    /* Remove stale socket file. */
    [[NSFileManager defaultManager] removeItemAtPath:sockPath error:nil];

    NSTask *task = [[NSTask alloc] init];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    NSFileHandle *stdoutReader = [stdoutPipe fileHandleForReading];
    NSFileHandle *stderrReader = [stderrPipe fileHandleForReading];
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    NSString *runtimePath = bundledFsmnRuntimePath();
    if (runtimePath != nil) {
        [environment setObject:[runtimePath stringByAppendingPathComponent:@"modelscope-cache"] forKey:@"MODELSCOPE_CACHE"];
    }
    [environment setObject:[NSString stringWithFormat:@"%lu", FsmnModelEndSilenceMs] forKey:@"DOUBAO_VOICE_FSMN_END_SILENCE_MS"];

    [task setLaunchPath:pythonPath];
    [task setArguments:@[workerPath, @"--serve", sockPath]];
    [task setEnvironment:environment];
    [task setStandardInput:[NSPipe pipe]];
    [task setStandardOutput:stdoutPipe];
    [task setStandardError:stderrPipe];

    NSLog(@"FSMN-VAD daemon: starting with python=%@ socket=%@", pythonPath, sockPath);

    /* Read stdout for the "ready" event. */
    NSMutableString *__block stdoutBuffer = [NSMutableString string];
    stdoutReader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if ([data length] == 0) {
            return;
        }
        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (chunk == nil) {
            return;
        }
        [stdoutBuffer appendString:chunk];
        while (YES) {
            NSRange newline = [stdoutBuffer rangeOfString:@"\n"];
            if (newline.location == NSNotFound) {
                break;
            }
            NSString *line = [[stdoutBuffer substringToIndex:newline.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [stdoutBuffer deleteCharactersInRange:NSMakeRange(0, newline.location + newline.length)];
            if ([line length] == 0) {
                continue;
            }
            NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *event = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
            if (![event isKindOfClass:[NSDictionary class]]) {
                NSLog(@"FSMN-VAD daemon stdout: %@", line);
                continue;
            }
            NSString *eventName = [event objectForKey:@"event"];
            if ([eventName isEqualToString:@"ready"]) {
                [gFsmnDaemonLock lock];
                gFsmnDaemonReady = YES;
                [gFsmnDaemonLock unlock];
                NSLog(@"FSMN-VAD daemon: model loaded and socket ready. model=%@ chunk=%@ms endSilence=%@ms",
                      [event objectForKey:@"model"],
                      [event objectForKey:@"chunk_ms"],
                      [event objectForKey:@"max_end_silence_ms"]);
            } else if ([eventName isEqualToString:@"error"]) {
                NSLog(@"FSMN-VAD daemon error: %@ %@", [event objectForKey:@"code"], [event objectForKey:@"message"]);
            }
        }
    };

    stderrReader.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if ([data length] == 0) {
            return;
        }
        NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if ([line length] > 0) {
            NSLog(@"FSMN-VAD daemon stderr: %@", [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
        }
    };

    /* Auto-restart on unexpected termination. */
    __weak AppDelegate *weakSelf = self;
    task.terminationHandler = ^(NSTask *terminatedTask) {
        (void)terminatedTask;
        [gFsmnDaemonLock lock];
        gFsmnDaemonReady = NO;
        gFsmnDaemonTask = nil;
        [gFsmnDaemonLock unlock];
        NSLog(@"FSMN-VAD daemon: process terminated (exit=%d). Will auto-restart in 2s.", [terminatedTask terminationStatus]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (strongSelf != nil) {
                [strongSelf startFsmnDaemon];
            }
        });
    };

    @try {
        [task launch];
    } @catch (NSException *exception) {
        NSLog(@"FSMN-VAD daemon: failed to launch: %@", exception);
        return;
    }

    [gFsmnDaemonLock lock];
    gFsmnDaemonTask = task;
    [gFsmnDaemonLock unlock];
}

- (void)stopFsmnDaemon {
    [gFsmnDaemonLock lock];
    NSTask *task = gFsmnDaemonTask;
    gFsmnDaemonTask = nil;
    gFsmnDaemonReady = NO;
    [gFsmnDaemonLock unlock];

    if (task != nil) {
        /* Clear termination handler to prevent auto-restart during shutdown. */
        task.terminationHandler = nil;
        if ([task isRunning]) {
            [task terminate];
            [task waitUntilExit];
        }
    }

    /* Clean up socket file. */
    NSString *sockPath = fsmnSocketPath();
    [[NSFileManager defaultManager] removeItemAtPath:sockPath error:nil];
    NSLog(@"FSMN-VAD daemon: stopped and socket cleaned up.");
}

- (void)ensureDefaultConfig {
    NSMutableDictionary *config = loadConfig();
    BOOL changed = NO;

    if (![config objectForKey:ConfigKeyLanguage]) {
        [config setObject:bundleDefaultLanguage() forKey:ConfigKeyLanguage];
        changed = YES;
    }
    if (![config objectForKey:ConfigKeyHandsFree]) {
        [config setObject:DefaultHandsFreeKeyName forKey:ConfigKeyHandsFree];
        changed = YES;
    }
    if (![config objectForKey:ConfigKeyHold]) {
        [config setObject:DefaultHoldKeyName forKey:ConfigKeyHold];
        changed = YES;
    }
    if (![config objectForKey:ConfigKeySmartSilenceTimeoutMs]) {
        [config setObject:@(SmartStopGraceMs) forKey:ConfigKeySmartSilenceTimeoutMs];
        changed = YES;
    }
    if (![config objectForKey:ConfigKeySmartStartTimeoutInfinite]) {
        [config setObject:@YES forKey:ConfigKeySmartStartTimeoutInfinite];
        changed = YES;
    }
    if (![config objectForKey:ConfigKeySmartStartTimeoutMs]) {
        [config setObject:@5000 forKey:ConfigKeySmartStartTimeoutMs];
        changed = YES;
    }

    if (changed) {
        saveConfig(config);
    }
}

- (BOOL)shortcutValueIsValid:(id)value {
    ShortcutCombo combo;
    return [value isKindOfClass:[NSString class]] && parseShortcutString(value, &combo);
}

- (void)createStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = statusBarImage();
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(showSettings:);
    [self applyLanguage];
}

- (void)showSettings:(id)sender {
    (void)sender;
    if (self.window == nil) {
        [self buildSettingsWindow];
    }
    [self reloadSettingsControls];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)buildSettingsWindow {
    // 580x840 window
    self.window = [[SettingsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 580, 840)
                                             styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView)
                                                backing:NSBackingStoreBuffered
                                                   defer:NO];
    [self.window setReleasedWhenClosed:NO];
    self.window.titlebarAppearsTransparent = YES;
    self.window.titleVisibility = NSWindowTitleHidden;

    NSView *content = [[SettingsContentView alloc] initWithFrame:NSMakeRect(0, 0, 580, 840)];
    [self.window setContentView:content];

    // Background color
    content.wantsLayer = YES;
    content.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;

    // Title label
    self.titleLabel = label(@"", NSMakeRect(30, 758, 360, 32), 22, YES);
    [content addSubview:self.titleLabel];

    // Language Segmented Control
    self.languageControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(400, 762, 150, 24)];
    [self.languageControl setSegmentCount:2];
    [self.languageControl setTarget:self];
    [self.languageControl setAction:@selector(languageChanged:)];
    [self.languageControl setLabel:@"中文" forSegment:0];
    [self.languageControl setLabel:@"English" forSegment:1];
    [content addSubview:self.languageControl];

    // Subtitle label
    self.subtitleLabel = label(@"", NSMakeRect(30, 732, 520, 18), 12, NO);
    [self.subtitleLabel setTextColor:[NSColor secondaryLabelColor]];
    [content addSubview:self.subtitleLabel];

    // Card 1: 快捷键 (height = 160)
    self.shortcutCard = [[CardView alloc] initWithFrame:NSMakeRect(30, 552, 520, 160)];
    [content addSubview:self.shortcutCard];
    
    NSTextField *card1Title = label(L(@"快捷键", @"Shortcuts"), NSMakeRect(20, 124, 480, 20), 14, YES);
    [self.shortcutCard addSubview:card1Title];

    // Row 1: 长按模式
    self.holdTitleLabel = label(@"", NSMakeRect(20, 96, 300, 18), 13, YES);
    [self.shortcutCard addSubview:self.holdTitleLabel];
    NSTextField *holdSubtitle = label(L(@"按住说话，松手结束", @"Hold to speak, release to finish"), NSMakeRect(20, 82, 300, 14), 11, NO);
    [holdSubtitle setTextColor:[NSColor secondaryLabelColor]];
    [self.shortcutCard addSubview:holdSubtitle];

    self.holdField = [[ShortcutRecorderControl alloc] initWithFrame:NSMakeRect(340, 84, 160, 28)];
    [self.holdField setTarget:self];
    [self.holdField setAction:@selector(shortcutRecorded:)];
    [self.holdField setTag:2];
    [self.shortcutCard addSubview:self.holdField];

    // Divider
    DividerView *div1 = [[DividerView alloc] initWithFrame:NSMakeRect(20, 70, 480, 0.5)];
    [self.shortcutCard addSubview:div1];

    // Row 2: 免按模式
    self.handsFreeTitleLabel = label(@"", NSMakeRect(20, 42, 300, 18), 13, YES);
    [self.shortcutCard addSubview:self.handsFreeTitleLabel];
    NSTextField *handsFreeSubtitle = label(L(@"按一次即可开始说话，再按任意键可结束", @"Press once to speak; press any key to finish"), NSMakeRect(20, 28, 300, 14), 11, NO);
    [handsFreeSubtitle setTextColor:[NSColor secondaryLabelColor]];
    [self.shortcutCard addSubview:handsFreeSubtitle];

    self.handsFreeField = [[ShortcutRecorderControl alloc] initWithFrame:NSMakeRect(340, 30, 160, 28)];
    [self.handsFreeField setTarget:self];
    [self.handsFreeField setAction:@selector(shortcutRecorded:)];
    [self.handsFreeField setTag:1];
    [self.shortcutCard addSubview:self.handsFreeField];

    // Card 4: 智能判停设置 (height = 130)
    self.smartVadCard = [[CardView alloc] initWithFrame:NSMakeRect(30, 407, 520, 130)];
    [content addSubview:self.smartVadCard];

    self.smartVadTitleLabel = label(@"", NSMakeRect(20, 94, 480, 20), 14, YES);
    [self.smartVadCard addSubview:self.smartVadTitleLabel];

    // Row 1: 尾部静音检测时间
    self.silenceTimeoutLabel = label(@"", NSMakeRect(20, 64, 300, 18), 13, NO);
    [self.smartVadCard addSubview:self.silenceTimeoutLabel];

    self.silenceTimeoutField = textInput(NSMakeRect(380, 60, 120, 24));
    [self.silenceTimeoutField setDelegate:self];
    [self.silenceTimeoutField setTarget:self];
    [self.silenceTimeoutField setAction:@selector(silenceTimeoutChanged:)];
    [self.smartVadCard addSubview:self.silenceTimeoutField];

    // Row 2: 初始等待与超时
    self.startInfiniteCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(20, 26, 180, 24)];
    [self.startInfiniteCheckbox setButtonType:NSButtonTypeSwitch];
    [self.startInfiniteCheckbox setTarget:self];
    [self.startInfiniteCheckbox setAction:@selector(startInfiniteChanged:)];
    [self.smartVadCard addSubview:self.startInfiniteCheckbox];

    self.startTimeoutLabel = label(@"", NSMakeRect(210, 30, 160, 18), 13, NO);
    [self.smartVadCard addSubview:self.startTimeoutLabel];

    self.startTimeoutField = textInput(NSMakeRect(380, 26, 120, 24));
    [self.startTimeoutField setDelegate:self];
    [self.startTimeoutField setTarget:self];
    [self.startTimeoutField setAction:@selector(startTimeoutChanged:)];
    [self.smartVadCard addSubview:self.startTimeoutField];

    // Error Label / Help Label (Normally hidden under Card 4)
    self.shortcutHelpLabel = label(@"", NSMakeRect(30, 392, 520, 16), 11, NO);
    [self.shortcutHelpLabel setTextColor:[NSColor systemRedColor]];
    [content addSubview:self.shortcutHelpLabel];

    self.shortcutErrorLabel = label(@"", NSMakeRect(30, 392, 520, 16), 11, NO);
    [self.shortcutErrorLabel setTextColor:[NSColor systemRedColor]];
    [content addSubview:self.shortcutErrorLabel];

    // Card 2: 辅助功能权限 (height = 90)
    self.permissionCard = [[CardView alloc] initWithFrame:NSMakeRect(30, 302, 520, 90)];
    [content addSubview:self.permissionCard];
    
    self.permissionTitleLabel = label(@"", NSMakeRect(20, 52, 280, 20), 13, YES);
    [self.permissionCard addSubview:self.permissionTitleLabel];
    
    NSTextField *permissionSubtitle = label(L(@"模拟快捷键以触发语音输入，请确保此项已允许。", 
                                              @"Accessibility permission is required for simulating shortcuts. Please check this option."),
                                             NSMakeRect(20, 16, 280, 32), 11, NO);
    [permissionSubtitle setTextColor:[NSColor secondaryLabelColor]];
    [self.permissionCard addSubview:permissionSubtitle];
    
    self.permissionButton = [[NSButton alloc] initWithFrame:NSMakeRect(320, 31, 180, 28)];
    [self.permissionButton setBezelStyle:NSBezelStyleRounded];
    [self.permissionButton setTarget:self];
    [self.permissionButton setAction:@selector(openPermission:)];
    [self.permissionCard addSubview:self.permissionButton];

    // Card 3: 使用说明 (height = 210)
    self.usageCard = [[CardView alloc] initWithFrame:NSMakeRect(30, 77, 520, 210)];
    [content addSubview:self.usageCard];
    
    self.usageTitleLabel = label(@"", NSMakeRect(20, 174, 360, 20), 13, YES);
    [self.usageCard addSubview:self.usageTitleLabel];
    
    self.instructionsCopyButton = [[NSButton alloc] initWithFrame:NSMakeRect(390, 170, 110, 28)];
    [self.instructionsCopyButton setBezelStyle:NSBezelStyleRounded];
    [self.instructionsCopyButton setTarget:self];
    [self.instructionsCopyButton setAction:@selector(copyUsage:)];
    [self.usageCard addSubview:self.instructionsCopyButton];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 20, 480, 132)];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setHasVerticalScroller:YES];
    self.usageTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 132)];
    [self.usageTextView setEditable:NO];
    [self.usageTextView setSelectable:YES];
    [self.usageTextView setFont:[NSFont userFixedPitchFontOfSize:11]];
    [scrollView setDocumentView:self.usageTextView];
    [self.usageCard addSubview:scrollView];

    // Below Cards: Exit Button & Version
    NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    if (!version) {
        version = @"0.1.0";
    }
    NSString *versionFormat = L(@"助手应用版本 v%@ (%@)", @"Helper App Version v%@ (%@)");
    NSString *versionString = [NSString stringWithFormat:versionFormat, version, version];
    NSTextField *quitDesc = label(versionString, NSMakeRect(30, 22, 300, 20), 12, NO);
    [quitDesc setTextColor:[NSColor secondaryLabelColor]];
    [content addSubview:quitDesc];
    
    self.quitButton = [[NSButton alloc] initWithFrame:NSMakeRect(440, 18, 110, 28)];
    [self.quitButton setBezelStyle:NSBezelStyleRounded];
    [self.quitButton setTarget:NSApp];
    [self.quitButton setAction:@selector(terminate:)];
    [content addSubview:self.quitButton];

}

- (void)reloadSettingsControls {
    [self.handsFreeField setShortcutName:displayShortcutName(ConfigKeyHandsFree, DefaultHandsFreeKeyName)];
    [self.holdField setShortcutName:displayShortcutName(ConfigKeyHold, DefaultHoldKeyName)];
    [self.shortcutHelpLabel setStringValue:@""];
    [self.shortcutErrorLabel setStringValue:@""];

    NSDictionary *config = loadConfig();
    
    // Silence Timeout
    unsigned long silenceVal = [[config objectForKey:ConfigKeySmartSilenceTimeoutMs] unsignedLongValue];
    if (silenceVal == 0) {
        silenceVal = SmartStopGraceMs;
    }
    [self.silenceTimeoutField setDoubleValue:(double)silenceVal / 1000.0];
    
    // Start Wait infinite checkbox
    BOOL startInfinite = YES;
    id startInfVal = [config objectForKey:ConfigKeySmartStartTimeoutInfinite];
    if (startInfVal != nil) {
        startInfinite = [startInfVal boolValue];
    }
    [self.startInfiniteCheckbox setState:startInfinite ? NSControlStateValueOn : NSControlStateValueOff];
    
    // Start Wait timeout
    unsigned long startVal = [[config objectForKey:ConfigKeySmartStartTimeoutMs] unsignedLongValue];
    if (startVal == 0) {
        startVal = 5000;
    }
    [self.startTimeoutField setDoubleValue:(double)startVal / 1000.0];
    [self.startTimeoutField setEnabled:!startInfinite];
    if (startInfinite) {
        [self.startTimeoutField setTextColor:[NSColor disabledControlTextColor]];
    } else {
        [self.startTimeoutField setTextColor:[NSColor controlTextColor]];
    }

    [self applyLanguage];
}

- (void)applyLanguage {
    BOOL english = isEnglish();
    NSString *appName = english ? @"Doubao Voice CLI" : @"豆包 Voice CLI";
    self.statusItem.button.toolTip = appName;
    [self.window setTitle:english ? @"Doubao Voice CLI Settings" : @"豆包 Voice CLI 设置"];

    [self.languageControl setLabel:@"中文" forSegment:0];
    [self.languageControl setLabel:@"English" forSegment:1];
    [self.languageControl setSelectedSegment:english ? 1 : 0];

    [self.titleLabel setStringValue:appName];
    [self.subtitleLabel setStringValue:L(@"把这里的两个快捷键设置成和豆包输入法设置页一致，CLI 就会按这套配置触发。",
                                         @"Keep these two shortcuts aligned with Doubao IME. The CLI will use this saved configuration.")];
    [self.handsFreeTitleLabel setStringValue:L(@"免按模式", @"Hands-Free Mode")];
    [self.holdTitleLabel setStringValue:L(@"长按模式", @"Hold-to-Talk Mode")];
    
    [self.handsFreeField setDisplayEnglish:english];
    [self.holdField setDisplayEnglish:english];
    [self.handsFreeField setPlaceholderText:L(@"点击设置", @"Set Shortcut")];
    [self.holdField setPlaceholderText:L(@"点击设置", @"Set Shortcut")];
    [self.handsFreeField setRecordingText:L(@"请直接按键...", @"Press key...")];
    [self.holdField setRecordingText:L(@"请直接按键...", @"Press key...")];

    // Smart VAD Card Localizations
    [self.smartVadTitleLabel setStringValue:L(@"智能判停设置", @"Smart VAD Settings")];
    [self.silenceTimeoutLabel setStringValue:L(@"尾部静音检测时间 (秒):", @"Speech End Silence (sec):")];
    [self.startInfiniteCheckbox setTitle:L(@"初始等待不限时", @"Unlimited wait for speech start")];
    [self.startTimeoutLabel setStringValue:L(@"初始静音限制 (秒):", @"Initial Silence Limit (sec):")];

    [self.permissionTitleLabel setStringValue:L(@"辅助功能权限", @"Accessibility Permission")];
    [self.permissionButton setTitle:L(@"打开辅助功能授权", @"Open Accessibility")];
    [self.usageTitleLabel setStringValue:L(@"CLI 使用说明（可复制给 Agent）", @"CLI Instructions (copy for Agent)")];
    [self.instructionsCopyButton setTitle:L(@"复制说明", @"Copy")];
    [self.quitButton setTitle:L(@"退出助手", @"Quit Helper")];
    [self.usageTextView setString:agentUsageText()];
}

- (void)languageChanged:(id)sender {
    (void)sender;
    NSMutableDictionary *config = loadConfig();
    [config setObject:([self.languageControl selectedSegment] == 1 ? @"en" : @"zh-Hans") forKey:ConfigKeyLanguage];
    saveConfig(config);
    [self applyLanguage];
}

- (void)shortcutRecorded:(ShortcutRecorderControl *)field {
    if ([field clearedShortcut]) {
        NSMutableDictionary *config = loadConfig();
        [config setObject:@"" forKey:([field tag] == 1 ? ConfigKeyHandsFree : ConfigKeyHold)];
        saveConfig(config);
        [field setClearedShortcut:NO];
        [self.shortcutHelpLabel setStringValue:@""];
        [self.shortcutErrorLabel setStringValue:@""];
        return;
    }

    if ([field invalidCapture]) {
        [self.shortcutHelpLabel setStringValue:L(@"不支持这个按键。只能使用 fn、shift、command、option、control 的单键或组合键。",
                                                 @"Unsupported key. Use only single keys or combinations made from fn, shift, command, option, control.")];
        [self.shortcutErrorLabel setStringValue:@""];
        [field setInvalidCapture:NO];
        return;
    }

    ShortcutCombo combo;
    if (!parseShortcutString([field shortcutName], &combo)) {
        [self.shortcutHelpLabel setStringValue:L(@"不支持这个按键。只能使用 fn、shift、command、option、control 的单键或组合键。",
                                                 @"Unsupported key. Use only single keys or combinations made from fn, shift, command, option, control.")];
        [self.shortcutErrorLabel setStringValue:@""];
        return;
    }

    NSString *canonical = [NSString stringWithUTF8String:combo.canonical];
    [field setShortcutName:canonical];
    NSMutableDictionary *config = loadConfig();
    [config setObject:canonical forKey:([field tag] == 1 ? ConfigKeyHandsFree : ConfigKeyHold)];
    saveConfig(config);
    [self.shortcutHelpLabel setStringValue:@""];
    [self.shortcutErrorLabel setStringValue:@""];
}

- (void)silenceTimeoutChanged:(id)sender {
    NSTextField *field = (NSTextField *)sender;
    double val = [field doubleValue];
    if (val < 0.5) {
        val = 0.5;
    }
    if (val > 30.0) {
        val = 30.0;
    }
    [field setDoubleValue:val];
    
    NSMutableDictionary *config = loadConfig();
    [config setObject:@((unsigned long)(val * 1000.0)) forKey:ConfigKeySmartSilenceTimeoutMs];
    saveConfig(config);
}

- (void)startTimeoutChanged:(id)sender {
    NSTextField *field = (NSTextField *)sender;
    double val = [field doubleValue];
    if (val < 1.0) {
        val = 1.0;
    }
    if (val > 120.0) {
        val = 120.0;
    }
    [field setDoubleValue:val];
    
    NSMutableDictionary *config = loadConfig();
    [config setObject:@((unsigned long)(val * 1000.0)) forKey:ConfigKeySmartStartTimeoutMs];
    saveConfig(config);
}

- (void)startInfiniteChanged:(id)sender {
    NSButton *btn = (NSButton *)sender;
    BOOL checked = ([btn state] == NSControlStateValueOn);
    
    NSMutableDictionary *config = loadConfig();
    [config setObject:@(checked) forKey:ConfigKeySmartStartTimeoutInfinite];
    saveConfig(config);
    
    [self.startTimeoutField setEnabled:!checked];
    if (checked) {
        [self.startTimeoutField setTextColor:[NSColor disabledControlTextColor]];
    } else {
        [self.startTimeoutField setTextColor:[NSColor controlTextColor]];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSTextField *textField = [notification object];
    if (textField == self.silenceTimeoutField) {
        [self silenceTimeoutChanged:textField];
    } else if (textField == self.startTimeoutField) {
        [self startTimeoutChanged:textField];
    }
}

- (void)openPermission:(id)sender {
    (void)sender;
    openAccessibilitySettings();
    accessibilityTrusted(YES);
}

- (void)copyUsage:(id)sender {
    (void)sender;
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:agentUsageText() forType:NSPasteboardTypeString];
}

- (void)handlePerformNotification:(NSNotification *)notification {
    NSDictionary *userInfo = [notification userInfo];
    NSString *command = [userInfo objectForKey:@"command"];
    if (![command isKindOfClass:[NSString class]] || [command length] == 0) {
        command = @"smart";
    }

    if ([command isEqualToString:@"authorize"] || [command isEqualToString:@"show-settings"]) {
        [self showSettings:nil];
        openAccessibilitySettings();
        accessibilityTrusted(YES);
        return;
    }

    NSString *keyName = [userInfo objectForKey:@"keyName"];
    ShortcutCombo combo;
    if (!parseShortcutString(keyName, &combo)) {
        NSString *configured = displayShortcutName(isHoldCommand(command) ? ConfigKeyHold : ConfigKeyHandsFree,
                                                   isHoldCommand(command) ? DefaultHoldKeyName : DefaultHandsFreeKeyName);
        if (!parseShortcutString(configured, &combo)) {
            [self showSettings:nil];
            return;
        }
    }

    BOOL trusted = accessibilityTrusted(YES);
    rememberAccessibilityState(trusted);
    if (!trusted) {
        [self showSettings:nil];
        openAccessibilitySettings();
        return;
    }

    unsigned long downMs = [[userInfo objectForKey:@"downMs"] unsignedLongValue];
    unsigned long gapMs = [[userInfo objectForKey:@"gapMs"] unsignedLongValue];
    unsigned long durationMs = [[userInfo objectForKey:@"durationMs"] unsignedLongValue];
    if (downMs == 0) {
        downMs = 45;
    }
    if (gapMs == 0) {
        gapMs = 120;
    }
    if (durationMs == 0) {
        durationMs = 5000;
    }

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source == NULL) {
        return;
    }
    CGEventSourceSetLocalEventsSuppressionInterval(source, 0);

    if (isSmartCommand(command)) {
        runSmartEndpointCommand(&combo, downMs, gapMs, source);
    } else if (isHoldCommand(command)) {
        pressCombo(&combo, source);
        sleepMilliseconds(durationMs);
        releaseCombo(&combo, source);
    } else {
        tapCombo(&combo, downMs, source);
    }

    CFRelease(source);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1) {
            return runOneShotCommandFromArguments(argc, argv);
        }

        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [application setDelegate:delegate];
        [application run];
    }
    return 0;
}
