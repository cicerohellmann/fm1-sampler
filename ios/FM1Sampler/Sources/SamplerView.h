// Replays the draw ops built by the C++ phone UI (engine/ui/SamplerUI.cpp) with Core Graphics and forwards touches to it; the counterpart of
// SamplerView.java. All layout lives in C++: the UI is laid out in units, at least 400 high and 860 wide, scaled to the safe area.
#import <UIKit/UIKit.h>

@interface SamplerView : UIView
- (void)startAnimating;
@end
