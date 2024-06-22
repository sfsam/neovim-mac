//
//  Neovim Mac
//  AppDelegate.mm
//
//  Copyright © 2020 Jay Sandhu. All rights reserved.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "AppDelegate.h"
#import "NVPrefsWindowController.h"
#import "NVRenderContext.h"
#import "NVWindowController.h"

#include "log.h"
#include "msgpack.hpp"
#include "neovim.hpp"

os_log_t rpc;

/// Returns true if one or more windows contain unsaved changes, otherwise false.
static bool hasUnsavedChanges(NSArray<NVWindowController*> *windows) {
    NSUInteger windowsCount = [windows count];

    if (!windowsCount) {
        return false;
    }

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    bool unsaved = false;

    for (NVWindowController *win in windows) {
        win.process->eval("len(filter(map(getbufinfo(), 'v:val.changed'), 'v:val'))", timeout,
                          [&](const msg::object &error, const msg::object &result, bool timed_out) {
            // If we time out, or get an unexpected result, assume we have unsaved changes.
            if (timed_out || !result.is<msg::integer>() || result.get<msg::integer>() != 0) {
                unsaved = true;
            }

            if (--windowsCount == 0) {
                dispatch_semaphore_signal(semaphore);
            }
        });
    }

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return unsaved;
}

/// Returns the best candidate window for opening a set of files.
/// The best candidate is the window with the most given files already open.
/// If none of the given files are open in any of the given windows, we fall
/// back to using the first responder.
/// @param windows  The windows to consider.
/// @param paths    Absolute paths of the files to consider.
static NVWindowController* openWith(NSArray<NVWindowController*> *windows,
                                    const std::vector<std::string_view> &paths) {
    NSUInteger windowsCount = [windows count];
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NVWindowController *controller = nil;
    uint64_t mostOpen = 0;

    for (NVWindowController *win in windows) {
        win.process->open_count(paths, timeout, [&, win](const msg::object &error,
                                                         const msg::object &result, bool timed_out) {
            if (!timed_out && result.is<msg::integer>() && result.get<msg::integer>() > mostOpen) {
                controller = win;
            }

            if (--windowsCount == 0) {
                dispatch_semaphore_signal(semaphore);
            }
        });
    }

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    if (controller) {
        return controller;
    }

    controller = [[NSApplication sharedApplication] targetForAction:@selector(saveDocument:)];

    if (controller && [controller isKindOfClass:[NVWindowController class]]) {
        return controller;
    } else {
        return windows[0];
    }
}

@interface AppDelegate() <NVMetalDeviceDelegate>
@end

@implementation AppDelegate {
    NVPrefsWindowController *prefsWindowController;
    NVRenderContextManager *contextManager;
    BOOL shouldTerminate;
}

- (void)metalUnavailable {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"This Mac does not support Metal";
    alert.informativeText = @"No Metal capable devices were found. "
                             "Neovim-Mac requires a Metal capable device.";
    [alert addButtonWithTitle:@"Quit"];
    [alert runModal];
    exit(0);
}

- (void)metalDeviceFailedToInitialize:(NSString *)deviceName {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Failed to initialize Metal device";
    alert.informativeText = [NSString stringWithFormat:
        @"Failed to initialize device: %@. "
        @"This may cause degraded performance in some circumstances.", deviceName];
    [alert runModal];
}

- (void)metalDevicesFailedToInitalize:(NSArray<NSString *> *)deviceNames
                      hasAlternatives:(BOOL)hasAlternatives {
    NSString *nameList = [deviceNames componentsJoinedByString:@", "];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Failed to initialize Metal device(s)";

    if (hasAlternatives) {
        alert.informativeText = [NSString stringWithFormat:
            @"Failed to initialize device(s): %@. "
            @"This may cause degraded performance in some circumstances.", nameList];
        [alert runModal];
    } else {
        alert.informativeText = [NSString stringWithFormat:
            @"Failed to initialize device(s): %@.\n"
            @"No Metal capable device is available.", nameList];
        [alert addButtonWithTitle:@"Quit"];
        [alert runModal];
        exit(0);
    }
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"NSDisabledDictationMenuItem"];
    [defaults setBool:YES forKey:@"NSDisabledCharacterPaletteMenuItem"];

    signal(SIGPIPE, SIG_IGN);
    rpc = os_log_create("io.github.jaysandhu.neovim-mac", "RPC");

    // Set handler for events sent by command-line tool nvmm.
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self andSelector:@selector(handleAppleEvent:withReplyEvent:) forEventClass:kCoreEventClass andEventID:'NVMM'];

    NVRenderContextOptions options;
    options.rasterizerWidth = 512;
    options.rasterizerHeight = 512;
    options.cachePageWidth = 1024;
    options.cachePageHeight = 1024;
    options.cacheGrowthFactor = 1.5;
    options.cacheInitialCapacity = 1;
    options.cacheEvictionThreshold = 8;
    options.cacheEvictionPreserve = 2;

    contextManager = [[NVRenderContextManager alloc] initWithOptions:options delegate:self];
}

- (void)handleAppleEvent:(NSAppleEventDescriptor *)event withReplyEvent: (NSAppleEventDescriptor *)replyEvent {
    BOOL openNewWindow = NO;
    NSArray<NSString *> *options = @[];
    NSAppleEventDescriptor *optnList = [event paramDescriptorForKeyword:'OPTN'];
    for (NSInteger i = 1; i <= [optnList numberOfItems]; i++) {
        openNewWindow = YES;
        NSString *option = [[optnList descriptorAtIndex:i] stringValue];
        if ([option isEqualToString:@"-N"]) continue;
        options = [options arrayByAddingObject:option];
    }

    NSArray<NSString *> *filenames = @[];
    NSAppleEventDescriptor *fileList = [event paramDescriptorForKeyword:'FILE'];
    for (NSInteger i = 1; i <= [fileList numberOfItems]; i++) {
        NSURL *fileURL = [[fileList descriptorAtIndex:i] fileURLValue];
        filenames = [filenames arrayByAddingObject:[fileURL path]];
    }

    NSArray<NVWindowController*> *windows = [NVWindowController windows];

    if (![windows count]) {
        [[[NVWindowController alloc] initWithContextManager:contextManager] spawnWithOptions:options files:filenames];
        return;
    } else if (openNewWindow) {
        // Cascade the new window relative to the last one.
        NSWindow *lastWindow = windows.lastObject.window;
        NSRect frame = lastWindow.frame;
        NSPoint topLeft = CGPointMake(NSMinX(frame), NSMaxY(frame));
        NSPoint cascadedTopLeft = [lastWindow cascadeTopLeftFromPoint:topLeft];
        NVWindowController *controller = [[NVWindowController alloc] initWithContextManager:contextManager];
        [controller.window setFrameTopLeftPoint:cascadedTopLeft];
        [controller spawnWithOptions:options files:filenames];
        return;
    }

    std::vector<std::string_view> paths;
    paths.reserve([filenames count]);
    for (NSString *path in filenames) {
        paths.push_back([path UTF8String]);
    }

    NVWindowController *controller = openWith(windows, paths);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"NVPreferencesOpenFilesInBuffersInsteadOfTabs"]) {
        controller.process->open_buffers(paths);
    }
    else {
        controller.process->open_tabs(paths);
    }
    [controller.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender {
    // Do not open an Untitled window if invoked from nvmm, the
    // command-line tool. The Apple event handler for nvmm will
    // open a new window if one isn't already open.
    for (NSString *arg in NSProcessInfo.processInfo.arguments) {
        if ([arg isEqualToString:@"-nvmm"]) return NO;
    }
    return YES;
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    NVWindowController *controller = [[NVWindowController alloc] initWithContextManager:contextManager];
    return [controller spawn] == 0;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    NSArray<NVWindowController*> *windows = [NVWindowController windows];

    if (![windows count]) {
        [[[NVWindowController alloc] initWithContextManager:contextManager] spawnOpenFile:filename];
    } else {
        std::vector<std::string_view> paths{filename.UTF8String};
        NVWindowController *controller = openWith(windows, paths);
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([defaults boolForKey:@"NVPreferencesOpenFilesInBuffersInsteadOfTabs"]) {
            controller.process->open_buffers(paths);
        }
        else {
            controller.process->open_tabs(paths);
        }
        [controller.window makeKeyAndOrderFront:nil];
    }

    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    NSArray<NVWindowController*> *windows = [NVWindowController windows];

    if (![windows count]) {
        [[[NVWindowController alloc] initWithContextManager:contextManager] spawnOpenFiles:filenames];
        return;
    }

    std::vector<std::string_view> paths;
    paths.reserve([filenames count]);

    for (NSString *path in filenames) {
        paths.push_back([path UTF8String]);
    }

    NVWindowController *controller = openWith(windows, paths);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"NVPreferencesOpenFilesInBuffersInsteadOfTabs"]) {
        controller.process->open_buffers(paths);
    }
    else {
        controller.process->open_tabs(paths);
    }
    [controller.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    if (!shouldTerminate) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        shouldTerminate = [defaults boolForKey:@"NVPreferencesTerminateAfterLastWindowClosed"];
    }
    return shouldTerminate;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (shouldTerminate) {
        return NSTerminateNow;
    }

    NSArray<NVWindowController*> *windows = [NVWindowController windows];

    if (!hasUnsavedChanges(windows)) {
        return NSTerminateNow;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Quit without saving?";
    alert.informativeText = @"There are modified buffers. If you quit now all changes will be lost.";
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Cancel"];
    
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        // Terminate once all the windows have been closed.
        shouldTerminate = YES;

        for (NVWindowController *controller in windows) {
            [controller forceQuit];
        }

        // Give it a second, if we're still around, force an abrupt exit.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    }

    return NSTerminateCancel;
}

- (IBAction)closeAllWindows:(id)sender {
    BOOL shouldCloseAllWindows = YES;

    NSArray<NVWindowController*> *windows = [NVWindowController windows];

    if (hasUnsavedChanges(windows)) {
        shouldCloseAllWindows = NO;
        NSAlert *alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = @"Close all windows without saving?";
        alert.informativeText = @"There are modified buffers. If you close all windows now all changes will be lost.";
        [alert addButtonWithTitle:@"Close All Windows"];
        [alert addButtonWithTitle:@"Cancel"];

        if ([alert runModal] == NSAlertFirstButtonReturn) {
            shouldCloseAllWindows = YES;
        }
    }

    if (shouldCloseAllWindows) {
        for (NSWindow *window in [[NSApplication sharedApplication] windows]) {
            [[window windowController] close];
        }
    }
}

- (IBAction)newDocument:(id)sender {
    [[[NVWindowController alloc] initWithContextManager:contextManager] spawn];
}

- (IBAction)newTab:(id)sender {
    [[[NVWindowController alloc] initWithContextManager:contextManager] spawn];
}

- (IBAction)openDocument:(id)sender {
    NSOpenPanel *panel = [[NSOpenPanel alloc] init];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;

    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

    NVWindowController *controller = [[NVWindowController alloc] initWithContextManager:contextManager];
    [controller spawnOpenURLs:[panel URLs]];
}

- (IBAction)displayPreferenes:(id)sender {
    if (!prefsWindowController) {
        prefsWindowController = [[NVPrefsWindowController alloc] init];
    }
    [prefsWindowController showWindow:nil];
}

@end
