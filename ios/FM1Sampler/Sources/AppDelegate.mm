#import "AppDelegate.h"
#import "ViewController.h"
#import "FakeUnitViewController.h"
#import "Diag.h"

@implementation AppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts {
    app.idleTimerDisabled = YES;   // the screen stays on while the app is in front (Android: FLAG_KEEP_SCREEN_ON)
    return YES;
}
- (UISceneConfiguration*)application:(UIApplication*)app configurationForConnectingSceneSession:(UISceneSession*)s options:(UISceneConnectionOptions*)o {
    UISceneConfiguration* c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = SceneDelegate.class;
    return c;
}
@end

@implementation SceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)opts {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    self.window.rootViewController = [[ViewController alloc] init];
#if FM1_TEST_TOOLS
    // FM1_FAKE_UNIT=1 (diagnostics, Debug only): this phone plays an FM-1 running RemoteFM1 over Bluetooth instead of being the sampler
    if (diagValue(@"FM1_FAKE_UNIT")) self.window.rootViewController = [[FakeUnitViewController alloc] init];
#endif
    [self.window makeKeyAndVisible];
}
@end
