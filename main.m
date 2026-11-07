#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <signal.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/wait.h>

static NSString *const StateDir = @"/var/run/io.github.azoghby.stimulate";
static volatile sig_atomic_t interrupted = 0;
static void onSignal(int value) { interrupted = value; }

static NSString *run(NSString *path, NSArray<NSString *> *arguments, int *status) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path]; task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe]; task.standardOutput = pipe; task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { if (status) *status = -1; return error.localizedDescription; }
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit]; if (status) *status = task.terminationStatus;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}
static BOOL disabled(void) {
    NSString *output = run(@"/usr/bin/pmset", @[@"-g"], NULL);
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*SleepDisabled\\s+1\\s*$" options:0 error:NULL];
    return [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)] != nil;
}
static BOOL setDisabled(BOOL value) {
    int status = -1;
    run(@"/usr/bin/pmset", @[@"-a", @"disablesleep", value ? @"1" : @"0"], &status);
    return status == 0 && disabled() == value;
}
static BOOL lowBattery(void) {
    NSString *output = run(@"/usr/bin/pmset", @[@"-g", @"batt"], NULL);
    if (![output containsString:@"'Battery Power'"]) return NO;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)%" options:0 error:NULL];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];
    return match && [[output substringWithRange:[match rangeAtIndex:1]] integerValue] <= 20;
}
static BOOL heartbeatFresh(NSString *path) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    NSDate *date = attributes[NSFileModificationDate];
    return date && -date.timeIntervalSinceNow < 20;
}
static void writeState(NSString *token, NSString *status, NSString *reason, NSTimeInterval deadline) {
    NSDictionary *state = @{@"token":token, @"status":status, @"reason":reason,
       @"deadline":@(deadline), @"pid":@(getpid())};
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
    [data writeToFile:[StateDir stringByAppendingPathComponent:@"status.json"] options:NSDataWritingAtomic error:NULL];
}
static int watchdog(NSArray<NSString *> *args) {
    if (geteuid() != 0 || args.count != 6) return 2;
    pid_t owner = (pid_t)[args[2] intValue]; NSString *token = args[3], *heartbeat = args[4];
    NSInteger seconds = [args[5] integerValue];
    if (owner <= 1 || token.length != 36 || seconds < 60 || seconds > 7200 || ![[NSFileManager defaultManager] fileExistsAtPath:heartbeat]) return 2;
    struct stat info;
    if (mkdir(StateDir.fileSystemRepresentation, 0755) != 0 && errno != EEXIST) return 3;
    if (lstat(StateDir.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0022)) return 3;
    NSString *lock = [StateDir stringByAppendingPathComponent:@"active.lock"];
    if (mkdir(lock.fileSystemRepresentation, 0700) != 0) return 4;
    NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + seconds;
    if (disabled()) { writeState(token,@"error",@"System sleep is already disabled by another tool. Restore it there first.",deadline); rmdir(lock.fileSystemRepresentation); return 5; }
    signal(SIGTERM, onSignal); signal(SIGINT, onSignal); signal(SIGHUP, onSignal);
    writeState(token,@"starting",@"Requesting closed-lid mode",deadline);
    if (!setDisabled(YES)) {
        BOOL restored = setDisabled(NO);
        writeState(token,@"error",restored ? @"macOS did not enable closed-lid mode." : @"Could not restore sleep. Run sudo pmset -a disablesleep 0 in Terminal.",deadline);
        rmdir(lock.fileSystemRepresentation); return 6;
    }
    writeState(token,@"active",@"Closed-lid mode is enabled",deadline);
    NSString *reason = @"Timer finished";
    // Administrator authentication blocks the UI; allow its heartbeat to resume.
    sleep(3);
    while (!interrupted && NSDate.date.timeIntervalSince1970 < deadline) {
        if (kill(owner,0) != 0 && errno == ESRCH) { reason=@"App closed"; break; }
        if (!heartbeatFresh(heartbeat)) { reason=@"Session stopped or app stopped responding"; break; }
        if (lowBattery()) { reason=@"Battery reached 20%; normal sleep restored"; break; }
        // Power-source changes can reset this setting on Apple Silicon.
        if (!disabled() && !setDisabled(YES)) { reason=@"macOS stopped allowing closed-lid mode"; break; }
        sleep(3);
    }
    if (interrupted) reason=@"Background helper stopped";
    BOOL restored=NO;
    for (int attempt=0; attempt<3 && !restored; attempt++) { restored=setDisabled(NO); if (!restored) sleep(1); }
    writeState(token,restored ? @"stopped" : @"error",restored ? reason : @"Sleep could not be restored. Run sudo pmset -a disablesleep 0 in Terminal.",deadline);
    rmdir(lock.fileSystemRepresentation);
    return restored ? 0 : 7;
}
static NSString *shellQuote(NSString *value) { return [NSString stringWithFormat:@"'%@'",[value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]]; }

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property NSStatusItem *item;
@property NSMenu *menu;
@property NSMenuItem *headline;
@property NSMenuItem *detail;
@property NSMenuItem *stopItem;
@property NSMutableArray<NSMenuItem *> *startItems;
@property NSTimer *timer;
@property NSString *token;
@property NSString *heartbeat;
@property NSString *lastReason;
@property BOOL active;
@property BOOL authorizing;
@property BOOL stopping;
@property BOOL quitAfterStop;
@property IOPMAssertionID assertion;
@property NSWindow *window;
@property NSTextField *windowStatus;
@property NSTextField *windowDetail;
@property NSMutableArray<NSButton *> *startButtons;
@property NSButton *windowStop;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.assertion=kIOPMNullAssertionID;
    self.item=[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.button.image=[NSImage imageWithSystemSymbolName:@"laptopcomputer" accessibilityDescription:@"Stimulate"];
    self.item.button.image.template=YES;
    self.menu=[NSMenu new]; self.menu.autoenablesItems=NO; self.menu.delegate=self;
    self.headline=[[NSMenuItem alloc] initWithTitle:@"Normal sleep enabled" action:NULL keyEquivalent:@""];
    self.headline.enabled=NO; [self.menu addItem:self.headline];
    self.detail=[[NSMenuItem alloc] initWithTitle:@"Choose a timed closed-lid session" action:NULL keyEquivalent:@""];
    self.detail.enabled=NO; [self.menu addItem:self.detail];
    [self.menu addItem:NSMenuItem.separatorItem]; self.startItems=[NSMutableArray new];
    for (NSNumber *minutes in @[@15,@30,@60,@120]) {
        NSMenuItem *entry=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Stay awake with lid closed — %@ minutes",minutes] action:@selector(start:) keyEquivalent:@""];
        entry.target=self; entry.tag=minutes.integerValue; [self.menu addItem:entry]; [self.startItems addObject:entry];
    }
    self.stopItem=[[NSMenuItem alloc] initWithTitle:@"Stop and restore normal sleep" action:@selector(stop:) keyEquivalent:@""];
    self.stopItem.target=self; self.stopItem.enabled=NO; [self.menu addItem:self.stopItem];
    [self.menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *about=[[NSMenuItem alloc] initWithTitle:@"About / how it works…" action:@selector(about:) keyEquivalent:@""]; about.target=self; [self.menu addItem:about];
    NSMenuItem *quit=[[NSMenuItem alloc] initWithTitle:@"Quit Stimulate" action:@selector(quit:) keyEquivalent:@"q"]; quit.target=self; [self.menu addItem:quit];
    self.item.menu=self.menu;
    NSMenuItem *controls=[[NSMenuItem alloc] initWithTitle:@"Show controls…" action:@selector(showControls:) keyEquivalent:@""];
    controls.target=self; [self.menu insertItem:controls atIndex:self.menu.numberOfItems-2];
    self.timer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self tick:nil];
    [self showControls:nil];
}
- (void)showControls:(id)sender {
    if (!self.window) {
        self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,520,340) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
        self.window.title=@"Stimulate"; self.window.releasedWhenClosed=NO;
        NSView *view=self.window.contentView;
        self.windowStatus=[NSTextField labelWithString:@"Normal sleep enabled"];
        self.windowStatus.font=[NSFont systemFontOfSize:23 weight:NSFontWeightSemibold];
        self.windowStatus.frame=NSMakeRect(28,280,470,32); [view addSubview:self.windowStatus];
        self.windowDetail=[NSTextField labelWithString:@"Choose a timed closed-lid session"];
        self.windowDetail.frame=NSMakeRect(28,245,465,28); self.windowDetail.textColor=NSColor.secondaryLabelColor; [view addSubview:self.windowDetail];
        NSTextField *description=[NSTextField wrappingLabelWithString:@"Keep working with your laptop closed. Starting a session requires administrator permission. Normal sleep is restored when you stop, the timer ends, or the battery reaches 20%."];
        description.frame=NSMakeRect(28,172,462,65); description.font=[NSFont systemFontOfSize:13]; [view addSubview:description];
        self.startButtons=[NSMutableArray new]; NSInteger index=0;
        for (NSNumber *minutes in @[@15,@30,@60,@120]) {
            NSButton *button=[NSButton buttonWithTitle:[NSString stringWithFormat:@"%@ min",minutes] target:self action:@selector(start:)];
            button.tag=minutes.integerValue; button.frame=NSMakeRect(24+index*120,125,114,34); [view addSubview:button]; [self.startButtons addObject:button]; index++;
        }
        self.windowStop=[NSButton buttonWithTitle:@"Stop and restore normal sleep" target:self action:@selector(stop:)];
        self.windowStop.frame=NSMakeRect(24,80,300,34); self.windowStop.enabled=NO; [view addSubview:self.windowStop];
        NSButton *help=[NSButton buttonWithTitle:@"Details…" target:self action:@selector(about:)]; help.frame=NSMakeRect(380,80,110,34); [view addSubview:help];
        NSTextField *note=[NSTextField wrappingLabelWithString:@"Keep your Mac ventilated. Do not run it inside a closed bag. Test a brief lid close before relying on this for travel."];
        note.frame=NSMakeRect(28,20,462,45); note.font=[NSFont systemFontOfSize:12]; note.textColor=NSColor.secondaryLabelColor; [view addSubview:note];
        [self.window center];
    }
    [NSApp activateIgnoringOtherApps:YES]; [self.window makeKeyAndOrderFront:nil]; [self tick:nil];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)flag { [self showControls:nil]; return YES; }
- (void)about:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert=[NSAlert new]; alert.messageText=@"Stimulate";
    alert.informativeText=@"Use the laptop icon in your menu bar to start a 15–120 minute closed-lid session. macOS will ask for administrator permission.\n\nA separate background helper restores normal sleep at the deadline, when you stop or quit, if this app stops responding, or at 20% battery. Keep the Mac ventilated; do not run it inside a closed bag. Internet-dependent work still needs a connection.\n\nThis changes a system-wide power setting and can prevent manual sleep during the session. Compatibility must be tested on this Mac by closing and reopening the lid.\n\nRecovery command if needed:\nsudo pmset -a disablesleep 0\n\nNo login item, passwordless administrator rule, network service, or permanent helper is installed.";
    [alert addButtonWithTitle:@"Got it"]; [alert runModal];
}
- (void)start:(NSMenuItem *)sender {
    if (self.active || self.authorizing || self.stopping) return;
    if (lowBattery()) { [self showError:@"Charge above 20% before starting a closed-lid session."]; return; }
    if (NSProcessInfo.processInfo.thermalState>=NSProcessInfoThermalStateSerious) { [self showError:@"Let your Mac cool down before starting."]; return; }
    if (disabled()) { [self showError:@"System sleep is already disabled by another tool. Restore it there first."]; return; }
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:@"Stimulate"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL];
    self.token=NSUUID.UUID.UUIDString;
    self.heartbeat=[directory stringByAppendingPathComponent:self.token];
    if (![@"alive" writeToFile:self.heartbeat atomically:YES encoding:NSUTF8StringEncoding error:NULL]) { [self showError:@"Could not create the session heartbeat."]; return; }
    self.authorizing=YES; self.lastReason=@"Waiting for administrator permission"; [self tick:nil];
    NSString *command=[NSString stringWithFormat:@"%@ --launch-watch %d %@ %@ %ld", shellQuote(NSBundle.mainBundle.executablePath),getpid(),shellQuote(self.token),shellQuote(self.heartbeat),(long)sender.tag*60];
    NSString *escaped=[[command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *source=[NSString stringWithFormat:@"do shell script \"%@\" with administrator privileges",escaped];
    NSDictionary *error=nil;
    [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&error];
    self.authorizing=NO;
    if (error) { [self clearHeartbeat]; self.token=nil; self.lastReason=@"Session was not started"; [self showError:error[NSAppleScriptErrorMessage] ?: @"Administrator permission was not granted."]; }
    else {
        self.lastReason=@"Starting background helper…";
        NSString *token=[self.token copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            if ([self.token isEqualToString:token] && !self.active && !self.stopping) {
                [self clearHeartbeat]; self.token=nil; self.lastReason=@"Helper did not start";
                [self showError:@"The helper did not start. Another session may be running. No active session has been confirmed."];
            }
        });
    }
    [self tick:nil];
}
- (void)showError:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES]; NSAlert *alert=[NSAlert new]; alert.messageText=@"Stimulate"; alert.informativeText=message; alert.alertStyle=NSAlertStyleWarning; [alert runModal];
}
- (void)clearHeartbeat { if (self.heartbeat) [[NSFileManager defaultManager] removeItemAtPath:self.heartbeat error:NULL]; self.heartbeat=nil; }
- (void)stop:(id)sender {
    [self clearHeartbeat]; self.stopping=YES; self.lastReason=@"Restoring normal sleep…";
    if (self.assertion!=kIOPMNullAssertionID) { IOPMAssertionRelease(self.assertion); self.assertion=kIOPMNullAssertionID; }
    [self tick:nil];
}
- (void)quit:(id)sender {
    if (self.token) { self.quitAfterStop=YES; [self stop:nil]; }
    else [NSApp terminate:nil];
}
- (void)tick:(id)sender {
    if (self.heartbeat && !self.stopping) [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate:NSDate.date} ofItemAtPath:self.heartbeat error:NULL];
    NSData *data=[NSData dataWithContentsOfFile:[StateDir stringByAppendingPathComponent:@"status.json"]];
    NSDictionary *state=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (self.token && [state[@"token"] isEqualToString:self.token]) {
        NSString *status=state[@"status"];
        self.active=[status isEqualToString:@"active"];
        if (self.active && !self.stopping) {
            if (self.assertion==kIOPMNullAssertionID) IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,kIOPMAssertionLevelOn,CFSTR("Stimulate timed session"),&_assertion);
            if (NSProcessInfo.processInfo.thermalState>=NSProcessInfoThermalStateSerious) { [self stop:nil]; return; }
            NSInteger remaining=MAX(0,(NSInteger)[state[@"deadline"] doubleValue]-(NSInteger)NSDate.date.timeIntervalSince1970);
            self.lastReason=[NSString stringWithFormat:@"%ld:%02ld remaining · stops at 20%% battery",(long)remaining/60,(long)remaining%60];
        }
        if ([status isEqualToString:@"stopped"] || [status isEqualToString:@"error"]) {
            [self clearHeartbeat]; self.token=nil; self.active=NO; self.stopping=NO; self.lastReason=state[@"reason"];
            if (self.assertion!=kIOPMNullAssertionID) { IOPMAssertionRelease(self.assertion); self.assertion=kIOPMNullAssertionID; }
            if ([status isEqualToString:@"error"]) [self showError:self.lastReason];
            if (self.quitAfterStop) { [NSApp terminate:nil]; return; }
        }
    }
    self.headline.title=self.stopping ? @"Stopping…" : self.active ? @"Closed-lid session active" : self.authorizing ? @"Authorizing…" : disabled() ? @"System sleep disabled" : @"Normal sleep enabled";
    self.detail.title=self.lastReason ?: @"Choose a timed closed-lid session";
    self.item.button.title=self.active ? @" ON" : @"";
    self.item.button.toolTip=[NSString stringWithFormat:@"Stimulate: %@",self.headline.title];
    BOOL busy=self.token!=nil || self.authorizing || self.stopping;
    for (NSMenuItem *entry in self.startItems) entry.enabled=!busy;
    self.stopItem.enabled=self.token!=nil && !self.authorizing && !self.stopping;
    self.windowStatus.stringValue=self.headline.title;
    self.windowDetail.stringValue=self.detail.title;
    for (NSButton *button in self.startButtons) button.enabled=!busy;
    self.windowStop.enabled=self.stopItem.enabled;
}
- (void)menuWillOpen:(NSMenu *)menu { [self tick:nil]; }
- (void)applicationWillTerminate:(NSNotification *)notification { [self clearHeartbeat]; if(self.assertion!=kIOPMNullAssertionID) IOPMAssertionRelease(self.assertion); }
@end

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *args=NSProcessInfo.processInfo.arguments;
        if (argc==6 && [args[1] isEqualToString:@"--launch-watch"]) {
            if (geteuid()!=0) { fprintf(stderr,"Administrator permission is required.\n"); return 2; }
            pid_t child=fork();
            if (child<0) return 3;
            if (child==0) {
                setsid();
                int nullfd=open("/dev/null",O_RDWR);
                if(nullfd>=0) { dup2(nullfd,STDIN_FILENO); dup2(nullfd,STDOUT_FILENO); dup2(nullfd,STDERR_FILENO); if(nullfd>2) close(nullfd); }
                execl(argv[0],argv[0],"--watch",argv[2],argv[3],argv[4],argv[5],NULL);
                _exit(127);
            }
            for (int attempt=0; attempt<30; attempt++) {
                int result=0;
                if(waitpid(child,&result,WNOHANG)==child) {
                    fprintf(stderr,"Background helper could not start (exit %d).\n", WIFEXITED(result)?WEXITSTATUS(result):-1); return 4;
                }
                NSData *data=[NSData dataWithContentsOfFile:[StateDir stringByAppendingPathComponent:@"status.json"]];
                NSDictionary *state=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]:nil;
                if([state[@"token"] isEqualToString:args[3]] && [state[@"status"] isEqualToString:@"active"]) { printf("Closed-lid mode enabled.\n"); return 0; }
                usleep(100000);
            }
            fprintf(stderr,"Helper startup was not confirmed.\n"); return 5;
        }
        if (argc>1 && [args[1] isEqualToString:@"--watch"]) return watchdog(args);
        if (argc>1 && [args[1] isEqualToString:@"--self-test"]) {
            NSString *sample=@"a'b c";
            if (![shellQuote(sample) isEqualToString:@"'a'\\''b c'"]) return 1;
            if (heartbeatFresh(@"/nonexistent/stimulate-test")) return 1;
            printf("PASS: shell quoting, missing heartbeat, read-only system state. SleepDisabled=%d\n",disabled());
            return 0;
        }
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *delegate=[AppDelegate new]; app.delegate=delegate; [app run];
    }
    return 0;
}
