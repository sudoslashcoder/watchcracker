// Tweak.xm (paste into your Theos project's Tweak.xm)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void dump_classes_and_methods(void) {
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);

    NSString *outPath = @"/var/mobile/Library/Logs/watch_class_dump.txt";
    NSMutableString *output = [NSMutableString stringWithFormat:@"Class dump for %@\n\n", [[NSBundle mainBundle] bundleIdentifier]];

    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name) continue;
        @try {
            [output appendFormat:@"== %s ==\n", name];
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(cls, &mcount);
            for (unsigned int m = 0; m < mcount; m++) {
                SEL sel = method_getName(methods[m]);
                const char *sname = sel_getName(sel);
                if (sname) [output appendFormat:@"  - %s\n", sname];
            }
            free(methods);
            [output appendString:@"\n"];
        } @catch (NSException *ex) { }
    }

    free(classes);
    [output writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[watchcracker] wrote class dump to %@", outPath);
}

static void sendMusicFileToWatch(NSString *filePath) {
    NSData *musicData = [NSData dataWithContentsOfFile:filePath];
    if (!musicData) {
        NSLog(@"[watchcracker] music not found: %@", filePath);
        return;
    }

    // Replace these names with the real ones you find in the class dump:
    Class mgrClass = objc_getClass("MusicSyncManager"); // <- edit after dump
    id mgr = nil;
    if (mgrClass) {
        SEL sharedSel = sel_registerName("sharedManager"); // common pattern
        if (sharedSel && class_respondsToSelector(mgrClass, sharedSel)) {
            id (*msg0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            mgr = msg0((id)mgrClass, sharedSel);
        }
    }
    if (!mgr) {
        NSLog(@"[watchcracker] manager not found; check class names.");
        return;
    }

    // Example method name - edit to the exact selector you find:
    SEL sendSel = sel_registerName("sendMusicData:toDevice:completion:");
    if (![mgr respondsToSelector:sendSel]) {
        NSLog(@"[watchcracker] manager doesn't respond to selector; adapt send selector");
        return;
    }

    // find device object (change selector name as needed)
    id device = nil;
    SEL connectedSel = sel_registerName("connectedDevice");
    if ([mgr respondsToSelector:connectedSel]) {
        device = ((id (*)(id, SEL))objc_msgSend)(mgr, connectedSel);
    }

    if (!device) {
        NSLog(@"[watchcracker] no device object; ensure the watch is connected");
        return;
    }

    // Build completion block
    void (^completion)(BOOL) = ^(BOOL ok) {
        NSLog(@"[watchcracker] transfer completion => %d", ok);
    };

    // Call selector dynamically: (mgr sendMusicData:musicData toDevice:device completion:completion);
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(mgr, sendSel, musicData, device, completion);
    NSLog(@"[watchcracker] invoked send selector (attempt)");
}

%ctor {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        dump_classes_and_methods();

        // auto-attempt: push any files in /var/mobile/Media/WatchMusic/
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = @"/var/mobile/Media/WatchMusic";
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            NSString *full = [dir stringByAppendingPathComponent:f];
            if ([[f pathExtension] caseInsensitiveCompare:@"mp3"] == NSOrderedSame ||
                [[f pathExtension] caseInsensitiveCompare:@"m4a"] == NSOrderedSame) {
                sendMusicFileToWatch(full);
                sleep(1);
            }
        }
    });
}