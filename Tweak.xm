// Tweak.xm - dynamic discovery + auto-invoke transfer attempts
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kLogPath = @"/var/mobile/Library/Logs/watchcracker.log";
static void wc_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // append to file
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!h) {
        [@"" writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    }
    [h seekToEndOfFile];
    [h writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
    [h writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
    NSLog(@"[watchcracker] %@", s);
}

// helper: get candidate manager singleton
static id find_manager(void) {
    const char *candidateNames[] = {
        "MusicSyncManager", "WatchTransferManager", "TransferManager", "SyncManager",
        "MusicManager", "MediaSyncManager", "DeviceTransferManager", NULL
    };
    const char *singletonSelectors[] = {"sharedManager","sharedInstance","defaultManager","getInstance","instance","manager","shared","getSharedInstance", NULL};

    for (int i=0; candidateNames[i]; ++i) {
        Class cls = objc_getClass(candidateNames[i]);
        if (!cls) continue;
        for (int s=0; singletonSelectors[s]; ++s) {
            SEL sel = sel_registerName(singletonSelectors[s]);
            if (sel && class_respondsToSelector(cls, sel)) {
                id (*getter)(id, SEL) = (id(*)(id,SEL))objc_msgSend;
                id mgr = getter((id)cls, sel);
                if (mgr) {
                    wc_log(@"[find_manager] found manager class %s via selector %s", candidateNames[i], singletonSelectors[s]);
                    return mgr;
                }
            }
        }
    }
    // fallback: search for classes that contain 'Music' and have a shared instance
    int num = objc_getClassList(NULL,0);
    Class *classes = (Class*)malloc(sizeof(Class)*num);
    num = objc_getClassList(classes, num);
    for (int i=0;i<num;i++){
        const char *name = class_getName(classes[i]);
        if (strcasestr(name,"Music") || strcasestr(name,"Transfer") || strcasestr(name,"Sync")) {
            Class cls = classes[i];
            for (int s=0; singletonSelectors[s]; ++s) {
                SEL sel = sel_registerName(singletonSelectors[s]);
                if (sel && class_respondsToSelector(cls, sel)) {
                    id (*getter)(id, SEL) = (id(*)(id,SEL))objc_msgSend;
                    id mgr = getter((id)cls, sel);
                    if (mgr) {
                        wc_log(@"[find_manager] heuristic found manager class %s via selector %s", name, singletonSelectors[s]);
                        free(classes);
                        return mgr;
                    }
                }
            }
        }
    }
    free(classes);
    wc_log(@"[find_manager] no manager found by heuristics");
    return nil;
}

// helper: try to obtain a connected device object from mgr (common selectors)
static id find_device_for_manager(id mgr) {
    const char *deviceSelectors[] = {"connectedDevice","getConnectedDevice","currentDevice","device","connectedPeripheral","peripheral","activeDevice", NULL};
    for (int i=0; deviceSelectors[i]; ++i) {
        SEL sel = sel_registerName(deviceSelectors[i]);
        if (sel && [mgr respondsToSelector:sel]) {
            id (*getter)(id, SEL) = (id(*)(id,SEL))objc_msgSend;
            id dev = getter(mgr, sel);
            if (dev) {
                wc_log(@"[find_device] got device via %s", deviceSelectors[i]);
                return dev;
            }
        }
    }
    return nil;
}

// attempt to call an IMP with safe permutations
static BOOL tryInvokeMethodWithSafePermutations(id mgr, SEL sel, NSString *path) {
    Method m = class_getInstanceMethod(object_getClass(mgr), sel);
    if (!m) return NO;
    IMP imp = method_getImplementation(m);
    unsigned int nargs = method_getNumberOfArguments(m); // includes self, _cmd
    wc_log(@"[tryInvoke] trying selector %s with nargs=%u", sel_getName(sel), nargs);

    NSData *data = [NSData dataWithContentsOfFile:path];
    id device = find_device_for_manager(mgr);

    @try {
        if (nargs == 2) { // just call method without args
            void (*f)(id, SEL) = (void(*)(id, SEL))imp;
            f(mgr, sel);
            return YES;
        } else if (nargs == 3) { // one param - try NSString then NSData
            void (*f1)(id, SEL, id) = (void(*)(id, SEL, id))imp;
            @try { f1(mgr, sel, path); wc_log(@"[tryInvoke] called %s with NSString", sel_getName(sel)); return YES; } @catch(...) {}
            if (data) { @try { f1(mgr, sel, data); wc_log(@"[tryInvoke] called %s with NSData", sel_getName(sel)); return YES; } @catch(...) {} }
        } else if (nargs == 4) { // two params - try (NSString, device), (NSData, device), (NSString, nil)
            void (*f2)(id, SEL, id, id) = (void(*)(id, SEL, id, id))imp;
            @try { f2(mgr, sel, path, device); wc_log(@"[tryInvoke] called %s with (NSString,device)", sel_getName(sel)); return YES; } @catch(...) {}
            if (data) { @try { f2(mgr, sel, data, device); wc_log(@"[tryInvoke] called %s with (NSData,device)", sel_getName(sel)); return YES; } @catch(...) {} }
            @try { f2(mgr, sel, path, nil); wc_log(@"[tryInvoke] called %s with (NSString,nil)", sel_getName(sel)); return YES; } @catch(...) {}
        } else if (nargs >= 5) { // three+ params - common pattern: (NSData, device, completion) or (NSString, device, completion)
            void (*f3)(id, SEL, id, id, id) = (void(*)(id, SEL, id, id, id))imp;
            id completion = ^(BOOL ok){ wc_log(@"[tryInvoke] completion called: %d", ok); };
            @try { f3(mgr, sel, data ? data : path, device, completion); wc_log(@"[tryInvoke] called %s with (data/path,device,completion)", sel_getName(sel)); return YES; } @catch(...) {}
            @try { f3(mgr, sel, path, device, completion); wc_log(@"[tryInvoke] called %s with (path,device,completion)", sel_getName(sel)); return YES; } @catch(...) {}
        }
    } @catch (NSException *e) {
        wc_log(@"[tryInvoke] exception calling %s: %@", sel_getName(sel), e);
    }
    return NO;
}

// find candidate selectors on manager class (by substring)
static NSArray<NSString*>* find_candidate_selectors_for_manager(id mgr) {
    NSMutableArray *cands = [NSMutableArray array];
    unsigned int mcount = 0;
    Method *methods = class_copyMethodList(object_getClass(mgr), &mcount);
    for (unsigned int i=0;i<mcount;i++) {
        SEL sel = method_getName(methods[i]);
        const char *s = sel_getName(sel);
        if (!s) continue;
        if (strcasestr(s,"send") || strcasestr(s,"upload") || strcasestr(s,"transfer") || strcasestr(s,"push") || strcasestr(s,"sync") || strcasestr(s,"music") || strcasestr(s,"track") || strcasestr(s,"song")) {
            [cands addObject:[NSString stringWithUTF8String:s]];
        }
    }
    free(methods);
    return cands;
}

// force-allow validator methods found across all classes with common names
static void auto_hook_validators(void) {
    int numClasses = objc_getClassList(NULL,0);
    Class *classes = (Class*)malloc(sizeof(Class)*numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    for (int i=0;i<numClasses;i++) {
        Class cls = classes[i];
        unsigned int mc=0;
        Method *m = class_copyMethodList(cls, &mc);
        for (unsigned int j=0;j<mc;j++) {
            SEL sel = method_getName(m[j]);
            const char *sn = sel_getName(sel);
            if (!sn) continue;
            // names that probably validate a file/format
            if (strcasestr(sn,"isSupported") || strcasestr(sn,"isValid") || strcasestr(sn,"validate") || strcasestr(sn,"canUpload") || strcasestr(sn,"fileIs") || strcasestr(sn,"isAuthorized")) {
                // replace implementation for 1-arg BOOL methods and 0-arg BOOL methods
                unsigned int nargs = method_getNumberOfArguments(m[j]);
                const char *types = method_getTypeEncoding(m[j]);
                // will only replace if return type likely integer/BOOL (type encoding starts with 'c'/'B'/'i')
                if (types && (types[0]=='c' || types[0]=='B' || types[0]=='i')) {
                    if (nargs == 2) { // -(BOOL)foo
                        BOOL (^blk0)(id, SEL) = ^BOOL(id self, SEL _cmd){ wc_log(@"[validator-hook] %@ -> YES (no-arg)", NSStringFromSelector(_cmd)); return YES; };
                        IMP imp = imp_implementationWithBlock((id)blk0);
                        class_replaceMethod(cls, sel, imp, types);
                        wc_log(@"[validator-hook] replaced %s on class %s (no-arg)", sel_getName(sel), class_getName(cls));
                    } else if (nargs == 3) { // -(BOOL)foo:(id)arg
                        BOOL (^blk1)(id, SEL, id) = ^BOOL(id self, SEL _cmd, id a){ wc_log(@"[validator-hook] %@(%@) -> YES", NSStringFromSelector(_cmd), a); return YES; };
                        IMP imp = imp_implementationWithBlock((id)blk1);
                        class_replaceMethod(cls, sel, imp, types);
                        wc_log(@"[validator-hook] replaced %s on class %s (one-arg)", sel_getName(sel), class_getName(cls));
                    }
                }
            }
        }
        free(m);
    }
    free(classes);
}

// attempt to find and invoke upload selectors for manager
static void attempt_auto_upload_dir(void) {
    id mgr = find_manager();
    if (!mgr) { wc_log(@"[auto_upload] manager not found, aborting"); return; }
    NSArray<NSString*> *cands = find_candidate_selectors_for_manager(mgr);
    wc_log(@"[auto_upload] candidate selectors: %@", cands);
    if (!cands.count) { wc_log(@"[auto_upload] no candidate selectors on manager - dumping methods for manual inspection"); return; }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = @"/var/mobile/Media/WatchMusic";
    NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray *mp3s = [NSMutableArray array];
    for (NSString *f in files) {
        NSString *e = [f pathExtension];
        if (!e) continue;
        if ([[e lowercaseString] isEqualToString:@"mp3"] || [[e lowercaseString] isEqualToString:@"m4a"] || [[e lowercaseString] isEqualToString:@"wav"]) {
            [mp3s addObject:[dir stringByAppendingPathComponent:f]];
        }
    }
    if (mp3s.count==0) { wc_log(@"[auto_upload] no files in %@", dir); return; }

    for (NSString *path in mp3s) {
        wc_log(@"[auto_upload] trying file %@", path);
        for (NSString *selName in cands) {
            SEL sel = sel_registerName(selName.UTF8String);
            BOOL ok = tryInvokeMethodWithSafePermutations(mgr, sel, path);
            if (ok) {
                wc_log(@"[auto_upload] invocation succeeded for selector %@ on file %@", selName, path);
                // don't break: maybe other selectors too
            } else {
                wc_log(@"[auto_upload] invocation FAILED for selector %@ on file %@", selName, path);
            }
        }
    }
}

// ctor - run discovery, hook validators, attempt upload
%ctor {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        @autoreleasepool {
            wc_log(@"[watchcracker] ctor starting");
            // dump classes (optional; you probably already have this)
            // call validator auto-hook
            auto_hook_validators();
            wc_log(@"[watchcracker] validator hooking complete");
            sleep(1);
            // attempt auto upload directory
            attempt_auto_upload_dir();
            wc_log(@"[watchcracker] auto-upload run complete");
        }
    });
}

