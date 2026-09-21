// make_icon.m — renders the 7-Zip macOS app icon as a 1024x1024 PNG.
//
// Written in Objective-C rather than Swift because this machine only has the
// Command Line Tools installed, and swiftc currently fails there with a
// SwiftBridging module-map conflict.  clang + AppKit works fine.
//
// Build:  clang -fobjc-arc -framework AppKit -framework CoreGraphics -o make_icon make_icon.m

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {

        const CGFloat size = 1024.0;
        const CGFloat inset = 100.0;
        const CGFloat side = size - inset * 2.0;
        const CGFloat radius = side * 0.2237;   // Apple squircle ratio

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:(NSInteger)size
                          pixelsHigh:(NSInteger)size
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSCalibratedRGBColorSpace
                         bytesPerRow:0
                        bitsPerPixel:0];

        if (!rep) {
            fprintf(stderr, "cannot allocate bitmap\n");
            return 1;
        }

        NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        CGContextRef ctx = [gc CGContext];
        CGContextSetShouldAntialias(ctx, true);

        NSRect rect = NSMakeRect(inset, inset, side, side);
        NSBezierPath *squircle =
            [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];

        // ---- background: flat two-tone, no gradients ----------------------
        [squircle addClip];
        [[NSColor colorWithCalibratedRed:0.086 green:0.180 blue:0.365 alpha:1.0] setFill];
        NSRectFill(rect);
        [[NSColor colorWithCalibratedRed:0.145 green:0.286 blue:0.541 alpha:1.0] setFill];
        NSRectFill(NSMakeRect(inset, inset + side * 0.42, side, side * 0.58));

        // ---- inner highlight border ---------------------------------------
        [squircle setLineWidth:6.0];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:0.16] setStroke];
        [squircle stroke];

        // ---- word mark ----------------------------------------------------
        NSFont *font = [NSFont systemFontOfSize:side * 0.46 weight:NSFontWeightBold];
        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        NSString *word = @"7z";
        NSSize textSize = [word sizeWithAttributes:attrs];
        NSPoint origin = NSMakePoint(
            inset + (side - textSize.width) / 2.0,
            inset + (side - textSize.height) / 2.0 + side * 0.02);
        [word drawAtPoint:origin withAttributes:attrs];

        [NSGraphicsContext restoreGraphicsState];

        // ---- write PNG ----------------------------------------------------
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (!png) {
            fprintf(stderr, "png encoding failed\n");
            return 1;
        }

        NSString *out = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : @"icon_1024.png";
        if (![png writeToFile:out atomically:YES]) {
            fprintf(stderr, "cannot write %s\n", [out UTF8String]);
            return 1;
        }
        fprintf(stdout, "wrote %s (%lu bytes)\n", [out UTF8String], (unsigned long)[png length]);
    }
    return 0;
}
