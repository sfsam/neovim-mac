//
//  Created by Sanjay Madan on 6-Aug-2022.
//  This file is distributed under the MIT License.
//  See LICENSE.txt for details.
//

#import "NVPrefsWindowController.h"

@implementation NVPrefsWindowController

- (instancetype)init {
    // Create checkboxes and bind to NSUserDefaults.
    NSButton *(^chkbx)(NSString *, NSString *) = ^NSButton*(NSString *title, NSString *key) {
        NSButton *b = [NSButton checkboxWithTitle:title target:self action:nil];
        [b bind:@"value" toObject:[NSUserDefaultsController sharedUserDefaultsController] withKeyPath:[@"values." stringByAppendingString:key] options:@{NSContinuouslyUpdatesValueBindingOption: @(YES)}];
        return b;
    };
    NSButton *buffersChkbx = chkbx(NSLocalizedString(@"Open files in buffers instead of tabs", @""), @"NVPreferencesOpenFilesInBuffersInsteadOfTabs");
    NSButton *terminateChkBx = chkbx(NSLocalizedString(@"Terminate after last window closed", @""), @"NVPreferencesTerminateAfterLastWindowClosed");
    NSButton *titlebarChkBx = chkbx(NSLocalizedString(@"Titlebar appears transparent", @""), @"NVPreferencesTitlebarAppearsTransparent");

    // Set up grid of checkboxes and labels.
    NSTextField *buffersNote = [NSTextField labelWithString:NSLocalizedString(@"This applies to files opened from the Finder or from another application.", @"")];
    buffersNote.textColor = [NSColor disabledControlTextColor];
    buffersNote.lineBreakMode = NSLineBreakByWordWrapping;
    buffersNote.font = [NSFont systemFontOfSize:12];
    [buffersNote setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSGridView *grid = [NSGridView gridViewWithViews:@[@[buffersChkbx], @[buffersNote], @[terminateChkBx], @[titlebarChkBx]]];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [[grid rowAtIndex:2] setBottomPadding:12];
    [[grid cellForView:buffersNote] setXPlacement:NSGridCellPlacementNone];
    [[grid cellForView:buffersNote] setCustomPlacementConstraints:@[[buffersNote.leadingAnchor constraintEqualToAnchor:grid.leadingAnchor constant:20]]];
    
    // Grid is centered in contentView with standard margins.
    NSView *contentView = [NSView new];
    [contentView addSubview:grid];
    [contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-[grid]-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(grid)]];
    [contentView addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-[grid]-|" options:0 metrics:nil views:NSDictionaryOfVariableBindings(grid)]];

    // Set up prefs panel with contentView.
    NSPanel *prefsPanel = [[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    prefsPanel.title = NSLocalizedString(@"Preferences", @"");
    prefsPanel.contentView = contentView;

    self = [super initWithWindow:prefsPanel];
    return self;
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self.window center];
}

@end
