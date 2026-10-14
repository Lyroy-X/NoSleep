// Local bootstrap console for ONE owned lab guest. Not shipped with NoSleep.
// No host screen, USB, clipboard, audio, host network or VPN API is used.
// Apple's private VNC interface matches the pinned official Tart implementation;
// a process-local bind interposer forces every INET listener to loopback BEFORE
// it becomes reachable. A guard library is loaded only into this helper,
// never into Tart, Cisco or any system process.
#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#import <Security/Security.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static NSString * const guestName = @"nosleep-vpn-lab-20261012";
static unsigned (*bindCount)(void);
static NSMutableArray *signalSources;

// Same transport as pinned official Tart ControlSocket.swift: private Unix
// socket -> VZVirtioSocket port8080. Only bytes move; no Ethernet/IP/route API.
// Keep memory, concurrent connections and lifetime bounded.
static void pumpSockets(int first, int second) {
    int sockets[2] = {first, second};
    unsigned char buffers[2][65536]; size_t used[2] = {0, 0}; BOOL eof[2] = {NO, NO};
    for (int i = 0; i < 2; i++) fcntl(sockets[i], F_SETFL, fcntl(sockets[i], F_GETFL) | O_NONBLOCK);
    time_t deadline = time(NULL) + 600;
    while (time(NULL) < deadline && !(eof[0] && eof[1] && !used[0] && !used[1])) {
        struct pollfd events[2];
        for (int i = 0; i < 2; i++) events[i] = (struct pollfd){sockets[i],
            (short)((!eof[i] && used[i] < sizeof(buffers[i]) ? POLLIN : 0) | (used[1-i] ? POLLOUT : 0)), 0};
        if (poll(events, 2, 1000) < 0) { if (errno == EINTR) continue; break; }
        BOOL failed = NO;
        for (int i = 0; i < 2; i++) {
            if (events[i].revents & POLLOUT) {
                ssize_t count = send(sockets[i], buffers[1-i], used[1-i], 0);
                if (count > 0) { used[1-i] -= count; memmove(buffers[1-i], buffers[1-i] + count, used[1-i]); }
                else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) failed = YES;
            }
            if (events[i].revents & (POLLIN | POLLHUP)) {
                ssize_t count = recv(sockets[i], buffers[i] + used[i], sizeof(buffers[i]) - used[i], 0);
                if (count > 0) used[i] += count;
                else if (!count) eof[i] = YES;
                else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) failed = YES;
            }
            if (events[i].revents & (POLLERR | POLLNVAL)) failed = YES;
            if (eof[1-i] && !used[1-i]) shutdown(sockets[i], SHUT_WR);
        }
        if (failed) break;
    }
    close(first); close(second);
}

static void writeJSON(NSDictionary *value, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if (path) {
        if (![data writeToFile:path atomically:YES]) exit(74);
        chmod(path.fileSystemRepresentation, 0600);
    } else {
        fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
    }
}
static int selfTest(void) {
    for (int family = AF_INET; family <= AF_INET6; family += AF_INET6 - AF_INET) {
        // Calls from this executable deliberately bypass dyld interposition.
        // CoreFoundation is an independent framework caller, like Apple VNC.
        CFSocketRef socket = CFSocketCreate(kCFAllocatorDefault, family, SOCK_STREAM, 0, 0, NULL, NULL);
        int fd = socket ? CFSocketGetNative(socket) : -1;
        struct sockaddr_storage address = {0}; socklen_t size;
        if (family == AF_INET) {
            struct sockaddr_in *v4 = (void *)&address;
            v4->sin_len = sizeof(*v4); v4->sin_family = AF_INET; size = sizeof(*v4);
        } else {
            struct sockaddr_in6 *v6 = (void *)&address;
            v6->sin6_len = sizeof(*v6); v6->sin6_family = AF_INET6; size = sizeof(*v6);
        }
        CFDataRef bytes = CFDataCreate(kCFAllocatorDefault, (void *)&address, size);
        if (fd < 0 || CFSocketSetAddress(socket, bytes) != kCFSocketSuccess || getsockname(fd, (void *)&address, &size)) return 70;
        CFRelease(bytes);
        BOOL local = family == AF_INET ? ((struct sockaddr_in *)&address)->sin_addr.s_addr == htonl(INADDR_LOOPBACK)
            : IN6_IS_ADDR_LOOPBACK(&((struct sockaddr_in6 *)&address)->sin6_addr);
        CFSocketInvalidate(socket); CFRelease(socket); if (!local) {
            writeJSON(@{@"processLocalBindGuard": @NO, @"family": @(family), @"calls": @(bindCount())}, nil); return 71;
        }
    }
    writeJSON(@{@"processLocalBindGuard": @YES, @"IPv4AndIPv6Loopback": @YES, @"VMStarted": @NO}, nil);
    return 0;
}
static void callVoid0(id receiver, NSString *name) {
    ((void (*)(id, SEL))objc_msgSend)(receiver, NSSelectorFromString(name));
}

@interface LabDelegate : NSObject <VZVirtualMachineDelegate>
@end
@implementation LabDelegate
- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)machine { exit(0); }
- (void)virtualMachine:(VZVirtualMachine *)machine didStopWithError:(NSError *)error {
    writeJSON(@{@"guestStoppedWithError": @YES, @"domain": error.domain, @"code": @(error.code)}, nil); exit(1);
}
@end

int main(int argc, const char *argv[]) { @autoreleasepool {
    bindCount = dlsym(RTLD_DEFAULT, "nosleep_loopback_bind_count");
    if (!bindCount) return 76; // Never start the guest without the bind guard.
    unsetenv("DYLD_INSERT_LIBRARIES"); // Child ps/shell must not inherit it.
    if (argc == 2 && !strcmp(argv[1], "--self-test-bind")) return selfTest();
    if (argc == 2 && !strcmp(argv[1], "--list-private-vnc")) {
        for (NSString *name in @[@"_VZVNCServer", @"_VZVNCAuthenticationSecurityConfiguration"]) {
            unsigned count = 0; Method *methods = class_copyMethodList(NSClassFromString(name), &count);
            NSMutableArray *names = [NSMutableArray array];
            for (unsigned i = 0; i < count; i++) [names addObject:NSStringFromSelector(method_getName(methods[i]))];
            free(methods); writeJSON(@{@"class": name, @"selectors": names}, nil);
        }
        return 0;
    }
    if (argc != 3 || strcmp(argv[2], guestName.UTF8String)) return 64;
    NSString *root = [NSString stringWithUTF8String:argv[1]];
    NSString *expected = @"/Users/robertoguzov/Dev/Work/NoSleep/build/vpn-lab";
    if (![root.stringByResolvingSymlinksInPath isEqual:expected]) return 65;
    NSString *guest = [root stringByAppendingFormat:@"/vms/vms/%@", guestName];
    NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"guest-created.json"]] options:0 error:nil];
    if (![meta[@"name"] isEqual:guestName] || ![meta[@"home"] isEqual:[root stringByAppendingPathComponent:@"vms"]]) return 66;
    NSDictionary *stored = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[guest stringByAppendingPathComponent:@"config.json"]] options:0 error:nil];
    if (![stored[@"arch"] isEqual:@"arm64"] || ![stored[@"os"] isEqual:@"darwin"]
        || [stored[@"cpuCount"] integerValue] > 4 || [stored[@"memorySize"] unsignedLongLongValue] > 8ULL * 1024 * 1024 * 1024) return 67;
    // Refuse concurrent Tart use before opening this disk for writes.
    NSTask *processes = [NSTask new]; processes.launchPath = @"/bin/ps"; processes.arguments = @[@"-axo", @"command="];
    NSPipe *pipe = [NSPipe pipe]; processes.standardOutput = pipe; [processes launch];
    NSString *commands = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    [processes waitUntilExit];
    for (NSString *line in [commands componentsSeparatedByString:@"\n"])
        if ([line containsString:@"/tart run "] && [line containsString:guestName]) return 68;
    // Official Tart's running() checks the PID of a config.json fcntl lock.
    // Hold that same legitimate VM-disk ownership lock for this real VM;
    // this both prevents concurrent Tart boot and enables its supported exec
    // client against our equivalent port8080 control socket.
    int configLock = open([guest stringByAppendingPathComponent:@"config.json"].fileSystemRepresentation, O_RDWR | O_CLOEXEC);
    struct flock exclusive = {0}; exclusive.l_type = F_WRLCK; exclusive.l_whence = SEEK_SET;
    if (configLock < 0 || fcntl(configLock, F_SETLK, &exclusive)) return 81;
    Class securityClass = NSClassFromString(@"_VZVNCAuthenticationSecurityConfiguration");
    Class serverClass = NSClassFromString(@"_VZVNCServer");
    if (!securityClass || !serverClass || ![securityClass instancesRespondToSelector:NSSelectorFromString(@"initWithPassword:")]
        || ![serverClass instancesRespondToSelector:NSSelectorFromString(@"initWithPort:queue:securityConfiguration:")]) return 69;

    VZVirtualMachineConfiguration *config = [VZVirtualMachineConfiguration new];
    config.CPUCount = 4; config.memorySize = 6ULL * 1024 * 1024 * 1024;
    config.bootLoader = [[VZMacOSBootLoader alloc] init];
    VZMacPlatformConfiguration *platform = [[VZMacPlatformConfiguration alloc] init];
    platform.hardwareModel = [[VZMacHardwareModel alloc] initWithDataRepresentation:[[NSData alloc] initWithBase64EncodedString:stored[@"hardwareModel"] options:0]];
    platform.machineIdentifier = [[VZMacMachineIdentifier alloc] initWithDataRepresentation:[[NSData alloc] initWithBase64EncodedString:stored[@"ecid"] options:0]];
    platform.auxiliaryStorage = [[VZMacAuxiliaryStorage alloc] initWithURL:[NSURL fileURLWithPath:[guest stringByAppendingPathComponent:@"nvram.bin"]]];
    config.platform = platform;
    NSError *error = nil;
    VZDiskImageStorageDeviceAttachment *disk = [[VZDiskImageStorageDeviceAttachment alloc]
        initWithURL:[NSURL fileURLWithPath:[guest stringByAppendingPathComponent:@"disk.img"]] readOnly:NO error:&error];
    if (!disk) { writeJSON(@{@"diskOpenFailed": @YES, @"code": @(error.code)}, nil); return 70; }
    config.storageDevices = @[[[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:disk]];
    VZMacGraphicsDeviceConfiguration *graphics = [[VZMacGraphicsDeviceConfiguration alloc] init];
    graphics.displays = @[[[VZMacGraphicsDisplayConfiguration alloc] initWithWidthInPixels:1440 heightInPixels:900 pixelsPerInch:72]];
    config.graphicsDevices = @[graphics];
    config.keyboards = @[[[VZUSBKeyboardConfiguration alloc] init]];
    config.pointingDevices = @[[[VZUSBScreenCoordinatePointingDeviceConfiguration alloc] init]];
    config.entropyDevices = @[[[VZVirtioEntropyDeviceConfiguration alloc] init]];
    config.socketDevices = @[[[VZVirtioSocketDeviceConfiguration alloc] init]];
    config.networkDevices = @[]; config.audioDevices = @[]; // Bootstrap has NO network.
    VZSharedDirectory *share = [[VZSharedDirectory alloc] initWithURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"guest-transfer"]] readOnly:YES];
    VZVirtioFileSystemDeviceConfiguration *filesystem = [[VZVirtioFileSystemDeviceConfiguration alloc] initWithTag:VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag];
    filesystem.share = [[VZSingleDirectoryShare alloc] initWithDirectory:share];
    config.directorySharingDevices = @[filesystem];
    if (![config validateWithError:&error]) { writeJSON(@{@"validationFailed": @YES, @"code": @(error.code)}, nil); return 71; }
    VZVirtualMachine *machine = [[VZVirtualMachine alloc] initWithConfiguration:config];
    LabDelegate *delegate = [LabDelegate new]; machine.delegate = delegate;
    if (chdir(guest.fileSystemRepresentation)) return 77;
    struct stat previous;
    if (!lstat("control.sock", &previous)) {
        if (!S_ISSOCK(previous.st_mode) || previous.st_uid != getuid()) return 78;
        if (unlink("control.sock")) return 79;
    }
    int unixListener = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un unixAddress = {0}; unixAddress.sun_len = sizeof(unixAddress); unixAddress.sun_family = AF_UNIX;
    strlcpy(unixAddress.sun_path, "control.sock", sizeof(unixAddress.sun_path));
    if (unixListener < 0 || bind(unixListener, (void *)&unixAddress, sizeof(unixAddress)) || listen(unixListener, 8)) return 80;
    chmod("control.sock", 0600);
    fcntl(unixListener, F_SETFL, O_NONBLOCK);
    dispatch_source_t unixSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, unixListener, 0, dispatch_get_main_queue());
    __block unsigned activeConnections = 0;
    dispatch_source_set_event_handler(unixSource, ^{
        int client = accept(unixListener, NULL, NULL); if (client < 0) return;
        uid_t uid; gid_t gid;
        if (getpeereid(client, &uid, &gid) || uid != getuid() || activeConnections >= 8) { close(client); return; }
        activeConnections++;
        VZVirtioSocketDevice *device = (VZVirtioSocketDevice *)machine.socketDevices.firstObject;
        [device connectToPort:8080 completionHandler:^(VZVirtioSocketConnection *connection, NSError *connectError) {
            if (!connection || connectError) { close(client); activeConnections--; return; }
            // Duplicate then close the API object's descriptor, as official Tart
            // does, to avoid two owners closing the same underlying descriptor.
            int remote = fcntl(connection.fileDescriptor, F_DUPFD_CLOEXEC, 0);
            [connection close];
            if (remote < 0) { close(client); activeConnections--; return; }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                pumpSockets(client, remote);
                dispatch_async(dispatch_get_main_queue(), ^{ activeConnections--; });
            });
        }];
    }); dispatch_resume(unixSource);
    unsigned char random[16]; if (SecRandomCopyBytes(kSecRandomDefault, sizeof(random), random)) return 72;
    NSMutableString *password = [NSMutableString string]; for (unsigned i = 0; i < sizeof(random); i++) [password appendFormat:@"%02x", random[i]];
    NSString *passwordPath = [root stringByAppendingPathComponent:@"guest-console-password.txt"];
    if (![password writeToFile:passwordPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 73;
    chmod(passwordPath.fileSystemRepresentation, 0600);
    id security = ((id (*)(id, SEL, id))objc_msgSend)([securityClass alloc], NSSelectorFromString(@"initWithPassword:"), password);
    id server = ((id (*)(id, SEL, uint16_t, dispatch_queue_t, id))objc_msgSend)([serverClass alloc], NSSelectorFromString(@"initWithPort:queue:securityConfiguration:"), 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), security);
    ((void (*)(id, SEL, id))objc_msgSend)(server, NSSelectorFromString(@"setVirtualMachine:"), machine);
    callVoid0(server, @"start");
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    __block BOOL recorded = NO;
    dispatch_source_set_event_handler(timer, ^{
        uint16_t port = ((uint16_t (*)(id, SEL))objc_msgSend)(server, NSSelectorFromString(@"port"));
        if (port && !recorded) {
            if (!bindCount()) { callVoid0(server, @"stop"); exit(75); }
            writeJSON(@{@"host": @"::1", @"port": @(port), @"pid": @(getpid()), @"name": guestName,
                @"mode": @"owned-networkless-console", @"networkDevices": @0, @"passwordFile": passwordPath},
                [root stringByAppendingPathComponent:@"guest-console.json"]);
            writeJSON(@{@"ownedGuestConsole": @YES, @"networkDevices": @0, @"port": @(port), @"loopbackBindGuard": @YES}, nil);
            recorded = YES;
        }
    }); dispatch_resume(timer);
    [machine startWithCompletionHandler:^(NSError *startError) {
        if (startError) { writeJSON(@{@"guestStartFailed": @YES, @"domain": startError.domain, @"code": @(startError.code)}, nil); callVoid0(server, @"stop"); exit(1); }
        writeJSON(@{@"guestStarted": @YES, @"networkDevices": @0}, nil);
    }];
    signal(SIGPIPE, SIG_IGN);
    signalSources = [NSMutableArray arrayWithObject:unixSource];
    [signalSources addObject:timer];
    for (NSNumber *number in @[@(SIGINT), @(SIGTERM)]) {
        signal(number.intValue, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, number.intValue, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{
            callVoid0(server, @"stop");
            [machine stopWithCompletionHandler:^(NSError *stopError) { exit(stopError ? 1 : 0); }];
        }); dispatch_resume(source);
        [signalSources addObject:source];
    }
    [[NSRunLoop mainRunLoop] run];
    (void)delegate;
    return 0;
} }
