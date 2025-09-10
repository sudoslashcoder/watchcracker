#import <UIKit/UIKit.h>

%hook UIApplication

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    %orig;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Injected!"
                                                                   message:@"Xiaomi Watch dylib is running."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication].keyWindow.rootViewController
            presentViewController:alert animated:YES completion:nil];
    });
}

%end