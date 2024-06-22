//
//  nvmm
//  main.m
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import <Cocoa/Cocoa.h>

// Command-line tool for Neovim.
// Based on: https://stackoverflow.com/a/62134037/111418

static void
usage(void)
{
    printf("Usage:\n");
    printf("  %s [options] [file ...]\n", getprogname());
    printf("\n");
    printf("Options:\n");
    printf("  -d   Diff mode\n");
    printf("  -h   Print this help message\n");
    printf("  -N   Open new Neovim.app window\n");
    printf("  -o   Open windows, one per file\n");
    printf("  -O   Open vertical windows, one per file\n");
    printf("  -p   Open tab pages, one per file\n");
    printf("  -R   Read-only mode\n");
    printf("\n");
}

int
main(int argc, const char * argv[])
{
    @autoreleasepool {

        setprogname(argv[0]);

        // Get URL to Neovim.app from executable at Contents/Helpers/nvmm
        NSURL *neovimURL = [[[[[[NSBundle mainBundle] executableURL] URLByResolvingSymlinksInPath] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
        if (!neovimURL) {
            fprintf(stderr, "%s: Failed to locate Neovim.\n", getprogname());
            exit(EXIT_FAILURE);
        }

        int c;
        NSInteger index = 0;
        NSAppleEventDescriptor *optnList = [NSAppleEventDescriptor listDescriptor];

        while ((c = getopt(argc, (char * const *)argv, "dhNoOpR")) != -1) {
            if ('h' == c) {
                usage();
                exit(EXIT_FAILURE);
            } else if ('?' == c) {
                fprintf(stderr, "More info with \"%s -h\"\n", getprogname());
                exit(EXIT_FAILURE);
            } else if (strchr("dNoOpR", c)) {
                NSString *s = [NSString stringWithFormat:@"-%c", c];
                NSAppleEventDescriptor *optn = [NSAppleEventDescriptor descriptorWithString:s];
                [optnList insertDescriptor:optn atIndex:++index];
            } else {
                fprintf(stderr, "%s, Cannot parse option arguments.\n", getprogname());
                exit(EXIT_FAILURE);
            }
        }

        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.arguments = @[@"-nvmm"]; // so Neovim knows it was launched by nvmm
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:neovimURL configuration:config completionHandler:^(NSRunningApplication * _Nullable app, NSError * _Nullable error) {

            if (!app) {
                fprintf(stderr, "%s: %s\n", getprogname(), error.localizedDescription.UTF8String);
                exit(EXIT_FAILURE);
            }

            // Create an Apple event with our custom eventID 'NVMM'.
            // Neovim has a handler for 'NVMM' which opens a buffer for the path.

            NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:app.processIdentifier];

            NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass eventID:'NVMM' targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];

            NSAppleEventDescriptor *fileList = [NSAppleEventDescriptor listDescriptor];

            NSInteger index = 0;
            for (int i = 1; i < argc; i++) {
                if ('-' == argv[i][0]) continue; // skip option arguments
                NSString *path = [NSString stringWithCString:argv[i] encoding:NSUTF8StringEncoding];
                NSAppleEventDescriptor *file = [NSAppleEventDescriptor descriptorWithFileURL:[NSURL fileURLWithPath:path]];
                [fileList insertDescriptor:file atIndex:++index];
            }

            [event setParamDescriptor:optnList forKeyword:'OPTN'];
            [event setParamDescriptor:fileList forKeyword:'FILE'];

            NSError *aeError = nil;
            NSAppleEventDescriptor *desc = [event sendEventWithOptions:kAENoReply timeout:kAEDefaultTimeout error:&aeError];

            if (!desc) {
                fprintf(stderr, "%s: %s\n", getprogname(), aeError.localizedDescription.UTF8String);
                exit(1);
            }
            exit(EXIT_SUCCESS);
        }];
        dispatch_main(); // never returns; allows async operation to complete
    }
}
