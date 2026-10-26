#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/pwr_mgt/IOPMLibDefs.h>
#include <Security/Security.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <bsm/audit.h>
#include <errno.h>
#include <dlfcn.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// launchd runs this signed user agent outside App Sandbox. The existing sudo
// grant permits only the two pmset commands. No root process or timer stays running.
static char marker[PATH_MAX];
static char directory[PATH_MAX];

#ifndef TOKENCOFFEE_TEAM_ID
#define TOKENCOFFEE_TEAM_ID "W65292CD8T"
#endif

static int has_lid(void) {
#ifdef SLEEP_GUARD_TESTING
    return getenv("SLEEP_GUARD_TEST_DESKTOP") == NULL;
#else
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return 0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    int exists = value && CFGetTypeID(value) == CFBooleanGetTypeID();
    if (value) CFRelease(value);
    return exists;
#endif
}

static int get_brightness(CGDirectDisplayID display, float *value) {
#ifdef SLEEP_GUARD_TESTING
    (void)display;
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/brightness", directory);
    FILE *file = fopen(path, "r");
    if (!file) return -1;
    int result = fscanf(file, "%f", value) == 1 ? 0 : -1;
    fclose(file);
    return result;
#else
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
    int (*get)(CGDirectDisplayID, float *) = framework ? dlsym(framework, "DisplayServicesGetBrightness") : NULL;
    return get ? get(display, value) : -1;
#endif
}

static int set_brightness(CGDirectDisplayID display, float value) {
#ifdef SLEEP_GUARD_TESTING
    (void)display;
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/brightness", directory);
    FILE *file = fopen(path, "w");
    if (!file) return -1;
    fprintf(file, "%.9g\n", (double)value);
    fclose(file);
    return 0;
#else
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
    int (*set)(CGDirectDisplayID, float) = framework ? dlsym(framework, "DisplayServicesSetBrightness") : NULL;
    return set ? set(display, value) : -1;
#endif
}

static int restore_brightness_file(const char *path) {
    FILE *file = fopen(path, "r");
    if (!file) return errno == ENOENT ? 0 : -1;
    unsigned display = 0;
    float previous = 0, current = 0;
    int valid = fscanf(file, "%u %f", &display, &previous) == 2 &&
        display != 0 && isfinite(previous) && previous >= 0 && previous <= 1;
    fclose(file);
    if (!valid) return -1;
#ifndef SLEEP_GUARD_TESTING
    if (!CGDisplayIsOnline(display)) return 0;
#endif
    if (get_brightness(display, &current) != 0) return -1;
    // Preserve a brightness change made by the user or another app.
    if (fabsf(current) < 0.0005f && set_brightness(display, previous) != 0) return -1;
    return unlink(path);
}

static int restore_brightness_matching(int keep_builtin) {
    DIR *entries = opendir(directory);
    if (!entries) return -1;
    int result = 0;
    struct dirent *entry;
    while ((entry = readdir(entries))) {
        unsigned display;
        int length = 0;
        if (sscanf(entry->d_name, "brightness-%u.owned%n", &display, &length) != 1 ||
            entry->d_name[length] != 0 || display == 0) continue;
#ifdef SLEEP_GUARD_TESTING
        if (keep_builtin && display == 1) continue;
#else
        if (keep_builtin && CGDisplayIsBuiltin(display)) continue;
#endif
        char path[PATH_MAX];
        if (snprintf(path, sizeof path, "%s/%s", directory, entry->d_name) >= (int)sizeof path ||
            restore_brightness_file(path) != 0) result = -1;
    }
    closedir(entries);
    return result;
}

static int restore_brightness(void) { return restore_brightness_matching(0); }

static int wake_display(void) {
#ifdef SLEEP_GUARD_TESTING
    return 0;
#else
    IOPMAssertionID assertion = kIOPMNullAssertionID;
    IOReturn result = IOPMAssertionDeclareUserActivity(CFSTR("Token Coffee - Display wake"), kIOPMUserActiveLocal, &assertion);
    if (result == kIOReturnSuccess) IOPMAssertionRelease(assertion);
    return result == kIOReturnSuccess ? 0 : -1;
#endif
}

static int dim_one_display(CGDirectDisplayID display) {
    float previous = 0;
    if (get_brightness(display, &previous) != 0 || !isfinite(previous) || previous < 0 || previous > 1) return -1;
    if (previous == 0) return 0;
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/brightness-%u.owned", directory, display) >= (int)sizeof path) return -1;
    if (access(path, F_OK) != 0) {
        int journal = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (journal < 0) return -1;
        int written = dprintf(journal, "%u %.9g\n", display, (double)previous);
        int saved = fsync(journal);
        close(journal);
        if (written < 0 || saved != 0) return -1;
        int directory_fd = open(directory, O_RDONLY | O_CLOEXEC);
        if (directory_fd < 0) return -1;
        saved = fsync(directory_fd);
        close(directory_fd);
        if (saved != 0) return -1;
    }
    return set_brightness(display, 0);
}

static int dim_display(int all) {
#ifdef SLEEP_GUARD_TESTING
    (void)all;
    return dim_one_display(1);
#else
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) return -1;
    int result = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (!all && !CGDisplayIsBuiltin(displays[i])) continue;
        float value;
        // Some external monitors expose no backlight control. The black cover
        // still reduces their emitted light without changing the desktop renderer.
        if (all && get_brightness(displays[i], &value) != 0) continue;
        if (dim_one_display(displays[i]) != 0) result = -1;
    }
    return result;
#endif
}

static int sleep_display(void) {
    if (restore_brightness() != 0) return -1;
#ifdef SLEEP_GUARD_TESTING
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/display-action", directory);
    FILE *file = fopen(path, "w");
    if (!file) return -1;
    fputs("sleep\n", file);
    fclose(file);
    return 0;
#else
    if (CGDisplayIsAsleep(CGMainDisplayID())) return 0;
    pid_t child = fork();
    if (child == 0) { execl("/usr/bin/pmset", "pmset", "displaysleepnow", (char *)NULL); _exit(127); }
    if (child < 0) return -1;
    int status = 0;
    while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return -1;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
#endif
}

static int display_command(const char *command) {
    if (strcmp(command, "DIM") == 0) {
        if (restore_brightness_matching(1) != 0) return -1;
        return dim_display(0);
    }
    if (strcmp(command, "DIM_ALL") == 0) return dim_display(1);
    if (strcmp(command, "RESTORE") == 0) return restore_brightness();
    if (strcmp(command, "SLEEP") == 0) return sleep_display();
    if (strcmp(command, "WAKE") == 0) return wake_display();
    return -1;
}

static int sleep_disabled(void) {
#ifdef SLEEP_GUARD_TESTING
    FILE *file = fopen(getenv("SLEEP_GUARD_TEST_STATE"), "r");
    int value = 0;
    if (file) { (void)fscanf(file, "%d", &value); fclose(file); }
    return value;
#else
    io_registry_entry_t root = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain");
    if (!root) root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return -1;
    CFTypeRef value = IORegistryEntryCreateCFProperty(root, CFSTR("SleepDisabled"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    int disabled = -1;
    if (value && CFGetTypeID(value) == CFBooleanGetTypeID()) disabled = CFBooleanGetValue(value);
    if (value) CFRelease(value);
    return disabled;
#endif
}

static int set_sleep_disabled(int disabled) {
#ifdef SLEEP_GUARD_TESTING
    if (getenv("SLEEP_GUARD_TEST_DENY")) return -1;
    FILE *file = fopen(getenv("SLEEP_GUARD_TEST_STATE"), "w");
    if (!file) return -1;
    fprintf(file, "%d\n", disabled);
    fclose(file);
    return 0;
#else
    pid_t child = fork();
    if (child == 0) {
        execl("/usr/bin/sudo", "sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep",
              disabled ? "1" : "0", (char *)NULL);
        _exit(127);
    }
    if (child < 0) return -1;
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
#endif
}

static int restore_owned_setting(void) {
    if (access(marker, F_OK) != 0) return errno == ENOENT ? 0 : -1;
    if (sleep_disabled() != 0 && (set_sleep_disabled(0) != 0 || sleep_disabled() != 0)) return -1;
    return unlink(marker);
}

static void restore_clamshell_state(void) {
#ifndef SLEEP_GUARD_TESTING
    if (!has_lid()) return;
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return;
    io_connect_t connection = IO_OBJECT_NULL;
    if (IOServiceOpen(root, mach_task_self(), 0, &connection) == KERN_SUCCESS) {
        uint64_t input = 0;
        uint32_t count = 0;
        (void)IOConnectCallScalarMethod(connection, kPMSetClamshellSleepState, &input, 1, NULL, &count);
        IOServiceClose(connection);
    }
    IOObjectRelease(root);
#endif
}

static int failure(const char *code) {
    fprintf(stderr, "Sleep protection: %s\n", code);
    return 1;
}

static int recover_settings(void) {
    int interrupted = access(marker, F_OK) == 0;
    // A brightness failure must not leave the system sleep override enabled.
    int brightness_restored = restore_brightness();
    int sleep_restored = restore_owned_setting();
    if (interrupted) restore_clamshell_state();
    return brightness_restored == 0 && sleep_restored == 0 ? 0 : -1;
}

static int run_session(int input_fd, int output_fd, pid_t parent, int listener) {
    int queue = kqueue();
    if (queue < 0) { dprintf(output_fd, "ERROR events\n"); return 1; }
    struct kevent changes[6], event;
    EV_SET(&changes[0], parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    EV_SET(&changes[1], input_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
    int signals[] = {SIGTERM, SIGINT, SIGHUP};
    for (int i = 0; i < 3; i++) {
        signal(signals[i], SIG_IGN);
        EV_SET(&changes[i + 2], signals[i], EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    }
    if (listener >= 0) EV_SET(&changes[5], listener, EVFILT_READ, EV_ADD, 0, 0, NULL);
    if (kevent(queue, changes, listener >= 0 ? 6 : 5, NULL, 0, NULL) != 0) {
        close(queue); dprintf(output_fd, "ERROR events\n"); return 1;
    }
    int previous = sleep_disabled();
    if (previous < 0) { close(queue); dprintf(output_fd, "ERROR state\n"); return 1; }
    if (!previous && has_lid()) {
        int journal = open(marker, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (journal < 0) { close(queue); dprintf(output_fd, "ERROR journal\n"); return 1; }
        int saved = fsync(journal);
        close(journal);
        int directory_fd = open(directory, O_RDONLY | O_CLOEXEC);
        if (directory_fd < 0 || fsync(directory_fd) != 0) saved = -1;
        if (directory_fd >= 0) close(directory_fd);
        if (saved != 0) { unlink(marker); close(queue); dprintf(output_fd, "ERROR journal\n"); return 1; }
        if (set_sleep_disabled(1) != 0 || sleep_disabled() != 1) {
            (void)restore_owned_setting();
            close(queue); dprintf(output_fd, "ERROR permission\n"); return 1;
        }
    }
    dprintf(output_fd, "READY\n");
    // EOF, app termination, and shutdown signals all restore the owned setting.
    // kqueue sleeps in the kernel. It does no work between these events.
    char command[64];
    size_t used = 0;
    for (;;) {
        int result = kevent(queue, NULL, 0, &event, 1, NULL);
        if (result < 0) { if (errno == EINTR) continue; break; }
        if (event.filter != EVFILT_READ) break;
        if (listener >= 0 && event.ident == (uintptr_t)listener) {
            int other = accept(listener, NULL, NULL);
            if (other >= 0) {
                int enabled = 1;
                setsockopt(other, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof enabled);
                (void)send(other, "ERROR busy\n", 11, MSG_DONTWAIT);
                close(other);
            }
            continue;
        }
        char input[256];
        ssize_t count = read(input_fd, input, sizeof input);
        if (count <= 0) break;
        for (ssize_t i = 0; i < count; i++) {
            if (input[i] == '\n') {
                command[used] = 0;
                if (display_command(command) != 0) dprintf(output_fd, "DISPLAY_ERROR\n");
                used = 0;
            } else if (used < sizeof command - 1) {
                command[used++] = input[i];
            }
        }
    }
    int brightness_restored = restore_brightness();
    int restored = restore_owned_setting();
    restore_clamshell_state();
    close(queue);
    if (restored != 0 || brightness_restored != 0) {
        dprintf(output_fd, "ERROR restore\n"); return 1;
    }
    dprintf(output_fd, "STOPPED\n");
    return 0;
}

static int authenticate_peer(int connection, pid_t *pid) {
    uid_t uid;
    gid_t gid;
    socklen_t size = sizeof *pid;
    if (getpeereid(connection, &uid, &gid) != 0 || uid != getuid() ||
        getsockopt(connection, SOL_LOCAL, LOCAL_PEERPID, pid, &size) != 0 || *pid <= 1) return -1;
#ifdef SLEEP_GUARD_TESTING
    return getenv("SLEEP_GUARD_TEST_REJECT_PEER") ? -1 : 0;
#else
    audit_token_t audit;
    size = sizeof audit;
    if (getsockopt(connection, SOL_LOCAL, LOCAL_PEERTOKEN, &audit, &size) != 0) return -1;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, pid);
    CFDataRef token = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&audit, sizeof audit);
    const void *keys[] = {kSecGuestAttributePid, kSecGuestAttributeAudit};
    const void *values[] = {number, token};
    CFDictionaryRef attributes = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus result = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    if (result == errSecSuccess) result = SecRequirementCreateWithString(
        CFSTR("anchor apple generic and identifier \"com.pardeike.TokenCoffee\" and certificate leaf[subject.OU] = \"" TOKENCOFFEE_TEAM_ID "\""),
        kSecCSDefaultFlags, &requirement);
    if (result == errSecSuccess) result = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    CFRelease(attributes);
    CFRelease(number);
    CFRelease(token);
    if (result != errSecSuccess) fprintf(stderr, "Peer identity check failed: OSStatus %d\n", (int)result);
    return result == errSecSuccess ? 0 : -1;
#endif
}

static int run_server(const char *path) {
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlcpy(address.sun_path, path, sizeof address.sun_path) >= sizeof address.sun_path) return failure("socket-path");
    address.sun_len = sizeof address;
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) return failure("socket");
    fcntl(listener, F_SETFD, FD_CLOEXEC);
    if (fcntl(listener, F_SETFL, O_NONBLOCK) != 0) { close(listener); return failure("socket"); }
    // The agent holds the exclusive lock before replacing an interrupted socket.
    if (unlink(path) != 0 && errno != ENOENT) { close(listener); return failure("socket-path"); }
    mode_t previous_mask = umask(0077);
    int bound = bind(listener, (struct sockaddr *)&address, sizeof address);
    umask(previous_mask);
    if (bound != 0 || chmod(path, 0600) != 0 || listen(listener, 4) != 0) {
        close(listener); unlink(path); return failure("socket-listen");
    }
    int queue = kqueue();
    if (queue < 0) { close(listener); unlink(path); return failure("events"); }
    struct kevent changes[4], event;
    EV_SET(&changes[0], listener, EVFILT_READ, EV_ADD, 0, 0, NULL);
    int signals[] = {SIGTERM, SIGINT, SIGHUP};
    for (int i = 0; i < 3; i++) {
        signal(signals[i], SIG_IGN);
        EV_SET(&changes[i + 1], signals[i], EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    }
    int result = kevent(queue, changes, 4, NULL, 0, NULL);
#ifdef SLEEP_GUARD_TESTING
    if (result == 0) dprintf(STDOUT_FILENO, "LISTENING\n");
#endif
    while (result == 0) {
        if (kevent(queue, NULL, 0, &event, 1, NULL) < 0) { if (errno == EINTR) continue; result = -1; break; }
        if (event.filter != EVFILT_READ) break;
        int connection = accept(listener, NULL, NULL);
        if (connection < 0) { if (errno == EINTR || errno == EAGAIN) continue; result = -1; break; }
        fcntl(connection, F_SETFD, FD_CLOEXEC);
        fcntl(connection, F_SETFL, 0);
        int enabled = 1;
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof enabled);
        struct timeval timeout = {.tv_sec = 2};
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
        pid_t parent = 0;
        if (authenticate_peer(connection, &parent) != 0) dprintf(connection, "ERROR identity\n");
        else if (recover_settings() != 0) dprintf(connection, "ERROR restore\n");
        else (void)run_session(connection, connection, parent, listener);
        close(connection);
    }
    close(queue);
    close(listener);
    unlink(path);
    return result == 0 ? 0 : failure("events");
}

// The installer verifies rejection using this helper's identity, not the app's.
static int probe_server(const char *path) {
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlcpy(address.sun_path, path, sizeof address.sun_path) >= sizeof address.sun_path) return failure("socket-path");
    address.sun_len = sizeof address;
    int connection = socket(AF_UNIX, SOCK_STREAM, 0);
    if (connection < 0) return failure("probe-socket");
    struct timeval timeout = {.tv_sec = 5};
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    if (connect(connection, (struct sockaddr *)&address, sizeof address) != 0) {
        close(connection); return failure("probe-connect");
    }
    char reply[64];
    size_t used = 0;
    while (used < sizeof reply - 1) {
        ssize_t count = read(connection, reply + used, 1);
        if (count != 1) break;
        if (reply[used++] == '\n') break;
    }
    reply[used] = 0;
    close(connection);
    return strcmp(reply, "ERROR identity\n") == 0 ? 0 : failure("foreign-peer-accepted");
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) return failure("arguments");
    int recover = strcmp(argv[1], "recover") == 0;
    int serve = strcmp(argv[1], "serve") == 0;
    int probe = strcmp(argv[1], "probe") == 0;
#ifdef SLEEP_GUARD_TESTING
    int guard = strcmp(argv[1], "guard") == 0 && argc == 3;
    if (!recover && !serve && !guard && !probe) return failure("arguments");
#else
    if ((!recover && !serve && !probe) || argc != 2) return failure("arguments");
#endif
    struct passwd *user = getpwuid(getuid());
    if (!user) return failure("user");
    char lock_path[PATH_MAX], socket_path[PATH_MAX];
#ifdef SLEEP_GUARD_TESTING
    if (snprintf(directory, sizeof directory, "%s", getenv("SLEEP_GUARD_TEST_DIRECTORY")) >= (int)sizeof directory ||
        snprintf(socket_path, sizeof socket_path, "%s/agent.sock", directory) >= (int)sizeof socket_path) return failure("path");
#else
    if (snprintf(directory, sizeof directory, "%s/Library/Application Support/TokenCoffee/Sleep Protection", user->pw_dir) >= (int)sizeof directory ||
        snprintf(socket_path, sizeof socket_path, "%s/Library/Containers/com.pardeike.TokenCoffee/Data/.sleep-agent.sock", user->pw_dir) >= (int)sizeof socket_path) return failure("path");
#endif
    if (probe) return probe_server(socket_path);
    if (snprintf(marker, sizeof marker, "%s/owned", directory) >= (int)sizeof marker ||
        snprintf(lock_path, sizeof lock_path, "%s/lock", directory) >= (int)sizeof lock_path) return failure("path");
    int lock = open(lock_path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lock < 0) return failure("setup");
    if (flock(lock, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK) {
#ifdef SLEEP_GUARD_TESTING
            if (guard) dprintf(STDOUT_FILENO, "ERROR busy\n");
#endif
            return recover ? 0 : 1;
        }
        return failure("lock");
    }
    if (recover_settings() != 0) return failure("restore");
    if (recover) return 0;
#ifdef SLEEP_GUARD_TESTING
    if (guard) {
        char *end = NULL;
        long parent = strtol(argv[2], &end, 10);
        if (!end || *end || parent <= 1 || parent > INT_MAX) return failure("pid");
        return run_session(STDIN_FILENO, STDOUT_FILENO, (pid_t)parent, -1);
    }
#endif
    return run_server(socket_path);
}
