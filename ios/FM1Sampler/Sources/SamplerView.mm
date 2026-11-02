#import "SamplerView.h"
#import "Backend.h"
#import "Diag.h"
#import <CoreText/CoreText.h>
#include "Core.h"
#include <string>
#include <unordered_map>
#include <vector>

namespace {
constexpr float kMinW = 860, kMinH = 400;   // the units the deck is laid out in (SamplerUI::deck)

void setFill(CGContextRef c, uint32_t argb) {
    CGContextSetRGBFillColor(c, ((argb >> 16) & 255) / 255.0, ((argb >> 8) & 255) / 255.0, (argb & 255) / 255.0, ((argb >> 24) & 255) / 255.0);
}
void setStroke(CGContextRef c, uint32_t argb) {
    CGContextSetRGBStrokeColor(c, ((argb >> 16) & 255) / 255.0, ((argb >> 8) & 255) / 255.0, (argb & 255) / 255.0, ((argb >> 24) & 255) / 255.0);
}
CGPathRef roundRect(CGRect r, CGFloat rad) {
    r = CGRectStandardize(r);
    rad = std::max<CGFloat>(0, std::min({rad, r.size.width / 2, r.size.height / 2}));
    return CGPathCreateWithRoundedRect(r, rad, rad, nullptr);
}
}  // namespace

@implementation SamplerView {
    CADisplayLink* _link;
    std::vector<UiOp> _ops;
    // layout: the UI's units -> points
    CGFloat _scale, _ox;
    // CTLines of the texts, rebuilt when the text set changes (most frames draw the same strings)
    std::unordered_map<std::string, CTLineRef> _lines, _prevLines;
    NSMutableDictionary<NSString*, id>* _fonts;
    UITouch* _touch;
    // FM1_SNAP=<ms>: the screen as Documents/diag/snap_NN.png every <ms> (diagnostics: real-device screenshots over a wireless link)
    double _snapEvery, _snapLast;
    int _snapN;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = YES;
        self.multipleTouchEnabled = NO;
        self.backgroundColor = UIColor.blackColor;
        self.contentMode = UIViewContentModeRedraw;
        self.layer.drawsAsynchronously = YES;
        _fonts = [NSMutableDictionary dictionary];
        _scale = 1;
        _snapEvery = [diagValue(@"FM1_SNAP") doubleValue] / 1000.0;
        if (diagValue(@"FM1_SCRIPT")) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(snapNamed:) name:@"FM1Snap" object:nil];
    }
    return self;
}
- (void)dealloc {
    for (auto& kv : _lines) CFRelease(kv.second);
    for (auto& kv : _prevLines) CFRelease(kv.second);
}

- (void)startAnimating {
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)step:(CADisplayLink*)l {
    [self setNeedsDisplay];
    if (_snapEvery > 0 && l.timestamp - _snapLast >= _snapEvery) { _snapLast = l.timestamp; [self snapshot]; }
}
- (void)snapNamed:(NSNotification*)n { [self snapshotTo:[NSString stringWithFormat:@"%@.png", n.object]]; }
- (void)snapshot { [self snapshotTo:[NSString stringWithFormat:@"snap_%02d.png", _snapN++ % 100]]; }
- (void)snapshotTo:(NSString*)file {
    UIGraphicsImageRendererFormat* fmt = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer* r = [[UIGraphicsImageRenderer alloc] initWithBounds:self.bounds format:fmt];
    NSData* png = [r PNGDataWithActions:^(UIGraphicsImageRendererContext* ctx) { [self drawFrameIn:ctx.CGContext]; }];
    NSString* dir = [Backend.shared.dataDir stringByAppendingPathComponent:@"diag"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [png writeToFile:[dir stringByAppendingPathComponent:file] atomically:YES];
}

// The UI gets the safe area (the Dynamic Island and the rounded corners sit at the sides in landscape) and the full height.
- (void)layoutUnits:(float*)w height:(float*)h {
    const UIEdgeInsets in = self.safeAreaInsets;
    const CGFloat aw = std::max<CGFloat>(1, self.bounds.size.width - in.left - in.right), ah = std::max<CGFloat>(1, self.bounds.size.height);
    _scale = std::min(ah / kMinH, aw / kMinW);
    _ox = in.left;
    *w = (float)(aw / _scale); *h = (float)(ah / _scale);
    static float lw = 0, lh = 0;
    if (*w != lw || *h != lh) { lw = *w; lh = *h; fm1log("layout: %.0f x %.0f pt, safe left %.0f right %.0f -> %.1f x %.1f units, scale %.3f", self.bounds.size.width, ah, in.left, in.right, *w, *h, _scale); }
}

- (id)fontOfSize:(CGFloat)size bold:(BOOL)bold {
    NSString* key = [NSString stringWithFormat:@"%.2f%d", size, bold];
    id f = _fonts[key];
    if (!f) {
        // Menlo: a monospace like Android's, ~0.6 em per character, which SamplerUI::fit assumes
        CTFontRef ct = CTFontCreateWithName(bold ? CFSTR("Menlo-Bold") : CFSTR("Menlo-Regular"), size, nullptr);
        f = (__bridge_transfer id)ct;
        _fonts[key] = f;
    }
    return f;
}

- (CTLineRef)lineFor:(const std::string&)text size:(float)size bold:(bool)bold {
    std::string key = text; key += '\x01'; key += std::to_string((int)(size * 100)); key += bold ? 'b' : 'r';
    auto it = _lines.find(key);
    if (it != _lines.end()) return it->second;
    CTLineRef line = nullptr;
    auto pit = _prevLines.find(key);
    if (pit != _prevLines.end()) { line = pit->second; _prevLines.erase(pit); }
    else {
        NSString* s = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @"";
        NSDictionary* attrs = @{(__bridge NSString*)kCTFontAttributeName: [self fontOfSize:size bold:bold],
                                (__bridge NSString*)kCTForegroundColorFromContextAttributeName: @YES};
        line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:s attributes:attrs]);
    }
    _lines[key] = line;
    return line;
}

- (void)drawRect:(CGRect)rect { [self drawFrameIn:UIGraphicsGetCurrentContext()]; }

- (void)drawFrameIn:(CGContextRef)c {
    Backend* b = Backend.shared;
    float uw, uh;
    [self layoutUnits:&uw height:&uh];
    b.core->uiFrame(uw, uh, b.nowMs, _ops);
    // the bands outside the safe area take the colour of the UI's background (its first op fills the whole screen)
    if (!_ops.empty() && _ops[0].type == UiOp::RRECT) setFill(c, _ops[0].color); else CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillRect(c, self.bounds);
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, _ox, 0);
    CGContextScaleCTM(c, _scale, _scale);
    CGContextSetTextMatrix(c, CGAffineTransformMakeScale(1, -1));   // the context is flipped (y down): glyphs upright again
    CGContextSetLineCap(c, kCGLineCapRound);
    // the lines of the last frame that this one does not use are freed at the end
    for (auto& kv : _prevLines) CFRelease(kv.second);
    _prevLines.clear();
    _prevLines.swap(_lines);
    int saves = 0;
    for (const UiOp& o : _ops) {
        const float* f = o.f;
        switch (o.type) {
        case UiOp::RRECT: {
            setFill(c, o.color);
            if (f[4] > 0) { CGPathRef p = roundRect(CGRectMake(f[0], f[1], f[2], f[3]), f[4]); CGContextAddPath(c, p); CGContextFillPath(c); CGPathRelease(p); }
            else CGContextFillRect(c, CGRectMake(f[0], f[1], f[2], f[3]));
            break;
        }
        case UiOp::STROKE: {
            setStroke(c, o.color); CGContextSetLineWidth(c, f[5]);
            CGPathRef p = roundRect(CGRectMake(f[0], f[1], f[2], f[3]), f[4]); CGContextAddPath(c, p); CGContextStrokePath(c); CGPathRelease(p);
            break;
        }
        case UiOp::TEXT: {   // x baseline size align bold
            if (o.text.empty() || f[2] <= 0) break;
            CTLineRef line = [self lineFor:o.text size:f[2] bold:f[4] != 0];
            CGFloat x = f[0];
            const int al = (int)f[3];
            if (al) { const double w = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr); x -= al == 1 ? w / 2 : w; }
            setFill(c, o.color);
            CGContextSetTextPosition(c, x, f[1]);
            CTLineDraw(line, c);
            break;
        }
        case UiOp::LINE:
            setStroke(c, o.color); CGContextSetLineWidth(c, f[4]);
            CGContextMoveToPoint(c, f[0], f[1]); CGContextAddLineToPoint(c, f[2], f[3]); CGContextStrokePath(c);
            break;
        case UiOp::CIRCLE:
            setFill(c, o.color); CGContextFillEllipseInRect(c, CGRectMake(f[0] - f[2], f[1] - f[2], 2 * f[2], 2 * f[2]));
            break;
        case UiOp::TRI:
            setFill(c, o.color);
            CGContextMoveToPoint(c, f[0], f[1]); CGContextAddLineToPoint(c, f[2], f[3]); CGContextAddLineToPoint(c, f[4], f[5]); CGContextClosePath(c); CGContextFillPath(c);
            break;
        case UiOp::CLIP:
            CGContextSaveGState(c); saves++; CGContextClipToRect(c, CGRectMake(f[0], f[1], f[2], f[3]));
            break;
        case UiOp::ENDCLIP:
            if (saves > 0) { CGContextRestoreGState(c); saves--; }
            break;
        }
    }
    while (saves-- > 0) CGContextRestoreGState(c);
    CGContextRestoreGState(c);
}

// ---- touch: one finger, like the Android view (its pointer 0) ----
- (void)sendTouch:(UITouch*)t action:(int)a {
    const CGPoint p = [t locationInView:self];
    Backend* b = Backend.shared;
    b.core->uiTouch(a, (float)((p.x - _ox) / _scale), (float)(p.y / _scale), b.nowMs);
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e {
    if (_touch) return;
    _touch = touches.anyObject;
    [self sendTouch:_touch action:0];
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e {
    if (_touch && [touches containsObject:_touch]) [self sendTouch:_touch action:1];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e {
    if (_touch && [touches containsObject:_touch]) { [self sendTouch:_touch action:2]; _touch = nil; }
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)e { [self touchesEnded:touches withEvent:e]; }
@end
