// The one screen: full screen landscape SamplerView, the system file picker when the UI asks for a file (the counterpart of SamplerActivity).
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "ViewController.h"
#import "SamplerView.h"
#import "Backend.h"
#import "AudioImport.h"
#import "Diag.h"
#include "Core.h"

@interface ViewController () <UIDocumentPickerDelegate>
@end

@implementation ViewController {
    SamplerView* _view;
}

- (void)loadView {
    _view = [[SamplerView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view = _view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    Backend* b = Backend.shared;
    __weak ViewController* weak = self;
    b.onFileRequest = ^{ [weak pickFile]; };
    [b start];
    [_view startAnimating];
    // diagnostics: FM1_IMPORT=<a.m4a,b.aif,...> imports Documents/import/<file> one after the other, as if picked (tests the decoder on the phone)
    if (NSString* list = diagValue(@"FM1_IMPORT")) {
        NSArray* files = [list componentsSeparatedByString:@","];
        for (NSUInteger i = 0; i < files.count; i++) {
            NSURL* u = [NSURL fileURLWithPath:[[b.dataDir stringByAppendingPathComponent:@"import"] stringByAppendingPathComponent:files[i]]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((4 + 3 * i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self importURL:u removeAfter:NO]; });
        }
    }
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // the timeline sits at the bottom edge: drags there scrub the tape
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)pickFile {
    if (self.presentedViewController) return;
    NSMutableArray<UTType*>* types = [NSMutableArray arrayWithObject:UTTypeAudio];
    UTType* ogg = [UTType typeWithFilenameExtension:@"ogg"]; if (ogg) [types addObject:ogg];
    UIDocumentPickerViewController* p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    p.delegate = self;
    p.allowsMultipleSelection = NO;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (urls.firstObject) [self importURL:urls.firstObject removeAfter:YES];
}

- (void)importURL:(NSURL*)url removeAfter:(BOOL)remove {
    Backend* b = Backend.shared;
    b.core->say("READING THE FILE...");
    NSString* dir = b.dataDir;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // decoding can take a moment: off the main thread
        NSError* e = nil;
        const CFTimeInterval t0 = CACurrentMediaTime();
        NSString* out = [AudioImport importURL:url toDir:dir error:&e];
        if (remove) [NSFileManager.defaultManager removeItemAtURL:url error:nil];   // the picker's copy in our tmp/
        fm1log("import %s: %s (%.0f ms)", url.lastPathComponent.UTF8String, out ? out.lastPathComponent.UTF8String : e.localizedDescription.UTF8String, (CACurrentMediaTime() - t0) * 1000);
        if (out) b.core->importFile(out.UTF8String);
        else b.core->say("CANNOT READ THIS FILE");
    });
}
@end
