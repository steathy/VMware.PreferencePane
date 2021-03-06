//
//  MainPane.m
//  VMware Screen Resulution
//
//  Created by Martin Løbger on 11/02/2018.
//  Copyright © 2018 ML-Consulting. All rights reserved.
//

#import "MainPane.h"
#import <CoreFoundation/CoreFoundation.h>
#import <SecurityInterface/SFAuthorizationView.h>


const NSString* kPresetName     = @"name";
const NSString* kPresetWidth    = @"width";
const NSString* kPresetHeight   = @"height";

@interface MainPane()

@property (nonatomic, weak) IBOutlet NSTableView* presetsTableView;
@property (nonatomic, weak) IBOutlet NSTextField* textFieldResX;
@property (nonatomic, weak) IBOutlet NSStepper* stepperResX;
@property (nonatomic, weak) IBOutlet NSTextField* textFieldResY;
@property (nonatomic, weak) IBOutlet NSStepper* stepperResY;

@property (nonatomic, weak) IBOutlet SFAuthorizationView* authorizationView;
@property (nonatomic, weak) IBOutlet NSButton* buttonApply;

@property (strong) IBOutlet NSUserDefaultsController *userDefaultsController;
@property (strong) IBOutlet NSArrayController *presetsArrayController;

@end

@implementation MainPane
{
    NSString* _bundleIdentifier;
}

- (void)mainViewDidLoad
{
    // Fix for size according to :
    // https://blog.timschroeder.net/2016/07/16/the-strange-case-of-the-os-x-system-preferences-window-width
    NSSize size = self.mainView.frame.size;
    size.width = [self preferenceWindowWidth];
    [[self mainView] setFrameSize:size];
    
    NSBundle* prefPaneBundle = [NSBundle bundleForClass:self.class];
    _bundleIdentifier = [prefPaneBundle objectForInfoDictionaryKey:(NSString*)kCFBundleIdentifierKey];

    NSString * versionString = [prefPaneBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    self.version = [NSString stringWithFormat:@"Version: %@", versionString];
    
    [self applicationDidChangeScreenParametersNotification:nil];
    
    [self loadDefaultPresets:NO];

    _stepperResX.integerValue = _currentWidth.integerValue;
    _stepperResY.integerValue = _currentHeight.integerValue;
    
    for (NSDictionary* preset in _presetsArrayController.arrangedObjects) {
        if ([preset[kPresetWidth] isEqualToValue:_currentWidth] &&
            [preset[kPresetHeight] isEqualToValue:_currentHeight]) {
            [_presetsArrayController setSelectedObjects:@[preset]];
            [_presetsTableView scrollRowToVisible:_presetsArrayController.selectionIndex];
            break;
        }
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidChangeScreenParametersNotification:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];

    if ([_authorizationView.subviews count] == 0) {
        // On earlier versions (seen on Yosemite) the SFAuthorizationView does
        // not deserialieze from xib correctly, leaving it "empty".
        // If it is empty we know it failed and we can mauallyt create
        // one to work around it - thank you Apple.
        SFAuthorizationView* authView = [[SFAuthorizationView alloc] initWithFrame:_authorizationView.frame];
        [_authorizationView.superview addSubview:authView];
        [_authorizationView removeFromSuperview];
        _authorizationView = authView;
    }

    // Setup security.
    AuthorizationItem items = {kAuthorizationRightExecute, 0, NULL, 0};
    AuthorizationRights rights = {1, &items};
    _authorizationView.delegate = self;
    [_authorizationView setAuthorizationRights:&rights];
    [_authorizationView updateStatus:nil];
}


- (float)preferenceWindowWidth
{
    float result = 668.0; // default in case something goes wrong
    NSMutableArray *windows = (NSMutableArray *)CFBridgingRelease(CGWindowListCopyWindowInfo
                                                                  (kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    int myProcessIdentifier = [[NSProcessInfo processInfo] processIdentifier];
    BOOL foundWidth = NO;
    for (NSDictionary *window in windows) {
        int windowProcessIdentifier = [[window objectForKey:@"kCGWindowOwnerPID"] intValue];
        if ((myProcessIdentifier == windowProcessIdentifier) && (!foundWidth)) {
            foundWidth = YES;
            NSDictionary *bounds = [window objectForKey:@"kCGWindowBounds"];
            result = [[bounds valueForKey:@"Width"] floatValue];
        }
    }
    return result;
}


- (void)loadDefaultPresets:(bool)reset
{
    NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
    NSString* presetsKey = [_bundleIdentifier stringByAppendingString:@"@presets"];
    if (reset) {
        [_presetsArrayController removeObjects:_presetsArrayController.arrangedObjects];
        [userDefaults removeObjectForKey:presetsKey];
    }
    if ( [userDefaults arrayForKey:presetsKey].count == 0) {
        NSBundle* prefPaneBundle = [NSBundle bundleForClass:self.class];
        NSURL* presetsUrl = [prefPaneBundle URLForResource:@"Presets" withExtension:@"plist"];
        NSArray* presets = [NSArray arrayWithContentsOfURL:presetsUrl];
        [_presetsArrayController addObjects:presets];
        [_presetsArrayController setSelectionIndexes:[NSIndexSet new]];
    }
}


- (void)setScreenSize:(NSSize)size authorization:(SFAuthorization*)authorization
{
    NSPipe *pipeError = [NSPipe pipe];
    NSPipe *pipeOutput = [NSPipe pipe];
    
    NSTask *task = [[NSTask alloc] init];
    task.currentDirectoryPath = @"/Library/Application Support/VMware Tools/";
    task.launchPath = [task.currentDirectoryPath stringByAppendingPathComponent:@"vmware-resolutionSet"];
    task.arguments = @[@(size.width).stringValue, @(size.height).stringValue];
    task.standardError = pipeError;
    task.standardOutput = pipeOutput;
    
    NSError* error = nil;
    
    if (@available(macOS 10.13, *)) {
        if (![task launchAndReturnError:(&error)]) {
            NSLog (@"ERROR:\n%@", error);
            NSAlert* alert = [NSAlert alertWithError:error];
            [alert beginSheetModalForWindow:self.mainView.window completionHandler:nil];
            return;
        }
    }
    else {
        [task launch];
    }
    
    [task waitUntilExit];
    
    if (task.terminationStatus != 0) {
        
        // ERROR
        NSFileHandle *file = pipeError.fileHandleForReading;
        NSData *data = [file readDataToEndOfFile];
        [file closeFile];
        NSString *errorText = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
        NSLog (@"ERROR (%i):\n%@", task.terminationStatus, errorText);
        
        error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                    code:task.terminationStatus
                                userInfo:@{ NSLocalizedDescriptionKey: errorText }];
        
        NSAlert* alert = [NSAlert alertWithError:error];
        [alert beginSheetModalForWindow:self.mainView.window completionHandler:nil];
        return;
    }
    
    // SUCCESS
    NSFileHandle* file = pipeOutput.fileHandleForReading;
    NSData* data = [file readDataToEndOfFile];
    [file closeFile];
    if (data.length == 0) {
        // vmware-resolutionSet writes its log to stderr
        NSFileHandle *file = pipeError.fileHandleForReading;
        data = [file readDataToEndOfFile];
        [file closeFile];
    }
    NSString *outputText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog (@"SUCCESS:\n%@", outputText);
    
    if (authorization != nil) {
        // Make mutable copy - needed to test different extra parameters during development
        NSMutableArray* args = task.arguments.mutableCopy;
        
        // Convert array into void* array.
        const char **argv = (const char **)malloc(sizeof(char *) * [args count] + 1);
        int argvIndex = 0;
        for (NSString *string in task.arguments) {
            argv[argvIndex] = [string UTF8String];
            argvIndex++;
        }
        argv[argvIndex] = nil;
        
        // This is depricated - but if it works, it works - and if it works, don't fix it
        // Anyway, someday I might look a bit more int SMJobBless
        OSErr processError = AuthorizationExecuteWithPrivileges([authorization authorizationRef],
                                                                [task.launchPath UTF8String],
                                                                kAuthorizationFlagDefaults,
                                                                (char *const *)argv,
                                                                NULL);
        free(argv);
        
        if (processError != errAuthorizationSuccess) {
            NSLog(@"Error: %d", processError);
            return;
        }
    }
}


#pragma mark - Notification Handlers

- (void)applicationDidChangeScreenParametersNotification:(NSNotification*) notification
{
    NSScreen* screen = NSScreen.mainScreen;
    NSRect screenSize = screen.frame;
    self.currentWidth = [NSNumber numberWithInteger:screenSize.size.width];
    self.currentHeight = [NSNumber numberWithInteger:screenSize.size.height];
}


#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSDictionary* selectedPreset = [_presetsArrayController.selectedObjects firstObject];
    _stepperResX.integerValue = [selectedPreset[kPresetWidth] integerValue];
    _stepperResY.integerValue = [selectedPreset[kPresetHeight] integerValue];
}


#pragma mark - Interface Builder Action

- (IBAction)apply:(id)sender
{
    NSSize size = NSMakeSize(_textFieldResX.integerValue, _textFieldResY.integerValue);
    NSUserDefaults* userDefaults = [NSUserDefaults standardUserDefaults];
    NSString* skipPrivilegedWarningKey = [_bundleIdentifier stringByAppendingString:@"@skipPrivilegedWarning"];

    if (_authorizationView.authorizationState == SFAuthorizationViewUnlockedState) {
        [self setScreenSize:size authorization:[_authorizationView authorization]];
    }
    else if ([userDefaults boolForKey:skipPrivilegedWarningKey]) {
        [self setScreenSize:size authorization:nil];
    }
    else {
        NSAlert* alert = [[NSAlert alloc] init];
        alert.alertStyle = NSAlertStyleWarning;
        alert.showsSuppressionButton = YES; // Uses default checkbox title
        alert.messageText = NSLocalizedString(@"This is not permanent!", -);
        alert.informativeText = NSLocalizedString(@"To make the screen size change accross reboots, you must unlock the padlock before pressing \"Apply\"!", -);
        [alert addButtonWithTitle:NSLocalizedString(@"Continue", -)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", -)].tag = NSModalResponseCancel;

        [alert beginSheetModalForWindow:self.mainView.window completionHandler:^(NSModalResponse returnCode) {
            if (returnCode == NSModalResponseCancel) {
                return;
            }
            
            if (alert.suppressionButton.state == NSOnState) {
                // Suppress this alert from now on
                [userDefaults setBool:YES forKey:skipPrivilegedWarningKey];
            }
            
            [self setScreenSize:size authorization:nil];
        }];
    }
    
}


- (IBAction)presetNameAction:(id)sender
{
    // The ugliest hack ever:
    // In order to trigger NSArrayController to write
    // back changes, we will add/remove an object :(
    // Please, anyone! Tell me how to go bout this....
    id selectedObjects = _presetsArrayController.selectedObjects;

    NSDictionary* newPreset = @{
                                kPresetName : @"dummy",
                                kPresetWidth : @0,
                                kPresetHeight : @0
                                };
    [_presetsArrayController addObject:newPreset];
    [_presetsArrayController removeObject:newPreset];

    _presetsArrayController.selectedObjects = selectedObjects;
}


- (IBAction)presetsAdd:(id)sender
{
    NSDictionary* newPreset = @{
                                kPresetName : @"New Screen Size",
                                kPresetWidth : @(_textFieldResX.integerValue),
                                kPresetHeight : @(_textFieldResY.integerValue)
                                };
    [_presetsArrayController addObject:newPreset];
}


- (IBAction)presetRename:(id)sender
{
    NSInteger selectedRow = _presetsTableView.selectedRow;
    if (selectedRow >= 0) {
        [_presetsTableView editColumn:0
                                  row:selectedRow
                            withEvent:nil
                               select:YES];
    }
}


- (IBAction)presetReset:(id)sender
{
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = NSLocalizedString(@"Reset all presets?", -);
    alert.informativeText = NSLocalizedString(@"This will remove all presets and restore the defaults!", -);
    [alert addButtonWithTitle:NSLocalizedString(@"Reset", -)];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", -)].tag = NSModalResponseCancel;

    [alert beginSheetModalForWindow:self.mainView.window completionHandler:^(NSModalResponse returnCode) {
        if (returnCode == NSModalResponseCancel) {
            return;
        }
        [self loadDefaultPresets:YES];
    }];
}

@end
