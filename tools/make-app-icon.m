#import <Cocoa/Cocoa.h>

/*
 Build-time icon generator using native macOS iconutil.
 */

typedef struct {
    NSUInteger size;
    const char *filename;
} IconSizeSpec;

static const IconSizeSpec SizeSpecs[] = {
    {16, "icon_16x16.png"},
    {32, "icon_16x16@2x.png"},
    {32, "icon_32x32.png"},
    {64, "icon_32x32@2x.png"},
    {128, "icon_128x128.png"},
    {256, "icon_128x128@2x.png"},
    {256, "icon_256x256.png"},
    {512, "icon_256x256@2x.png"},
    {512, "icon_512x512.png"},
    {1024, "icon_512x512@2x.png"}
};

static BOOL writeBitmap(NSBitmapImageRep *bitmap, NSBitmapImageFileType type, NSString *path) {
    NSData *data = [bitmap representationUsingType:type properties:@{}];
    if (data == nil) {
        return NO;
    }
    return [data writeToFile:path atomically:YES];
}

static void drawIcon(NSUInteger pixels, NSString *path, NSBitmapImageFileType type) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)pixels
                      pixelsHigh:(NSInteger)pixels
                    bitsPerSample:8
                  samplesPerPixel:4
                         hasAlpha:YES
                         isPlanar:NO
                   colorSpaceName:NSCalibratedRGBColorSpace
                      bytesPerRow:0
                     bitsPerPixel:0];

    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];

    NSRect canvas = NSMakeRect(0, 0, pixels, pixels);
    [[NSColor clearColor] setFill];
    NSRectFill(canvas);

    // 1. Draw blue squircle background
    CGFloat radius = pixels * 0.22;
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:canvas xRadius:radius yRadius:radius];
    [[NSColor colorWithCalibratedRed:0.12 green:0.43 blue:0.98 alpha:1.0] setFill];
    [background fill];

    // 2. Draw white circle inside
    [[NSColor whiteColor] setFill];
    CGFloat circleRadius = pixels * 0.32;
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pixels * 0.5 - circleRadius, pixels * 0.5 - circleRadius, circleRadius * 2, circleRadius * 2)];
    [circle fill];

    // 3. Draw blue prompt '>' and sound wave bars inside circle
    [[NSColor colorWithCalibratedRed:0.12 green:0.43 blue:0.98 alpha:1.0] setStroke];
    CGFloat strokeWidth = pixels * 0.045;

    // Chevron '>'
    NSBezierPath *chevron = [NSBezierPath bezierPath];
    [chevron moveToPoint:NSMakePoint(pixels * 0.28, pixels * 0.60)];
    [chevron lineToPoint:NSMakePoint(pixels * 0.40, pixels * 0.50)];
    [chevron lineToPoint:NSMakePoint(pixels * 0.28, pixels * 0.40)];
    [chevron setLineWidth:strokeWidth];
    [chevron setLineCapStyle:NSLineCapStyleRound];
    [chevron setLineJoinStyle:NSLineJoinStyleRound];
    [chevron stroke];

    // Bar 1 (Short)
    NSBezierPath *bar1 = [NSBezierPath bezierPath];
    [bar1 moveToPoint:NSMakePoint(pixels * 0.52, pixels * 0.42)];
    [bar1 lineToPoint:NSMakePoint(pixels * 0.52, pixels * 0.58)];
    [bar1 setLineWidth:strokeWidth];
    [bar1 setLineCapStyle:NSLineCapStyleRound];
    [bar1 stroke];

    // Bar 2 (Tall)
    NSBezierPath *bar2 = [NSBezierPath bezierPath];
    [bar2 moveToPoint:NSMakePoint(pixels * 0.62, pixels * 0.35)];
    [bar2 lineToPoint:NSMakePoint(pixels * 0.62, pixels * 0.65)];
    [bar2 setLineWidth:strokeWidth];
    [bar2 setLineCapStyle:NSLineCapStyleRound];
    [bar2 stroke];

    // Bar 3 (Medium)
    NSBezierPath *bar3 = [NSBezierPath bezierPath];
    [bar3 moveToPoint:NSMakePoint(pixels * 0.72, pixels * 0.40)];
    [bar3 lineToPoint:NSMakePoint(pixels * 0.72, pixels * 0.60)];
    [bar3 setLineWidth:strokeWidth];
    [bar3 setLineCapStyle:NSLineCapStyleRound];
    [bar3 stroke];

    [NSGraphicsContext restoreGraphicsState];

    if (!writeBitmap(bitmap, type, path)) {
        fprintf(stderr, "Failed to write icon bitmap: %s\n", [path UTF8String]);
        exit(1);
    }
}

static void runIconutil(NSString *iconsetPath, NSString *outputPath) {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/iconutil"];
    [task setArguments:@[@"-c", @"icns", iconsetPath, @"-o", outputPath]];
    [task launch];
    [task waitUntilExit];

    if ([task terminationStatus] != 0) {
        fprintf(stderr, "iconutil failed with status %d\n", [task terminationStatus]);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: make-app-icon OUTPUT.icns\n");
            return 2;
        }

        NSString *outputPath = [NSString stringWithUTF8String:argv[1]];
        NSString *buildDir = [outputPath stringByDeletingLastPathComponent];
        NSString *iconsetPath = [buildDir stringByAppendingPathComponent:@"AppIcon.iconset"];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager createDirectoryAtPath:buildDir withIntermediateDirectories:YES attributes:nil error:nil]) {
            fprintf(stderr, "Failed to create build directory: %s\n", [buildDir UTF8String]);
            return 1;
        }

        [fileManager removeItemAtPath:iconsetPath error:nil];
        [fileManager removeItemAtPath:outputPath error:nil];

        if (![fileManager createDirectoryAtPath:iconsetPath withIntermediateDirectories:YES attributes:nil error:nil]) {
            fprintf(stderr, "Failed to create iconset directory: %s\n", [iconsetPath UTF8String]);
            return 1;
        }

        for (size_t i = 0; i < sizeof(SizeSpecs)/sizeof(SizeSpecs[0]); i++) {
            NSString *pngPath = [iconsetPath stringByAppendingPathComponent:[NSString stringWithUTF8String:SizeSpecs[i].filename]];
            drawIcon(SizeSpecs[i].size, pngPath, NSBitmapImageFileTypePNG);
        }

        runIconutil(iconsetPath, outputPath);
        [fileManager removeItemAtPath:iconsetPath error:nil];

        return 0;
    }
}
