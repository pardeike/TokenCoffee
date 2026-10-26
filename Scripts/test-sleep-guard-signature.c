#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <string.h>
#include "../Sources/SleepGuard/AppIdentity.h"

// Check real signed artifacts without launching them or reading account data.
int main(int argc, char **argv) {
    if (argc < 3 || (argc % 2) != 1) return 2;
    SecRequirementRef requirement = NULL;
    OSStatus status = SecRequirementCreateWithString(TOKENCOFFEE_APP_REQUIREMENT,
        kSecCSDefaultFlags, &requirement);
    if (status != errSecSuccess) return 1;
    int result = 0;
    for (int i = 1; i < argc; i += 2) {
        int accept = strcmp(argv[i], "accept") == 0;
        if (!accept && strcmp(argv[i], "reject") != 0) { result = 2; break; }
        CFURLRef path = CFURLCreateFromFileSystemRepresentation(NULL,
            (const UInt8 *)argv[i + 1], strlen(argv[i + 1]), false);
        SecStaticCodeRef code = NULL;
        status = SecStaticCodeCreateWithPath(path, kSecCSDefaultFlags, &code);
        if (status == errSecSuccess) status = SecStaticCodeCheckValidity(code,
            kSecCSStrictValidate, requirement);
        if ((status == errSecSuccess) != accept) {
            fprintf(stderr, "Unexpected signature result for %s: OSStatus %d\n", argv[i + 1], (int)status);
            result = 1;
        }
        if (code) CFRelease(code);
        CFRelease(path);
    }
    CFRelease(requirement);
    return result;
}
