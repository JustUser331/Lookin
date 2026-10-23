#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

// В системных процессах загрузчик использует только libSystem. CF нужен после фильтра .app.
static struct {
    __typeof__(&CFURLCreateFromFileSystemRepresentation) CFURLCreateFromFileSystemRepresentation;
    __typeof__(&CFReadStreamCreateWithFile) CFReadStreamCreateWithFile;
    __typeof__(&CFRelease) CFRelease;
    __typeof__(&CFReadStreamOpen) CFReadStreamOpen;
    __typeof__(&CFPropertyListCreateWithStream) CFPropertyListCreateWithStream;
    __typeof__(&CFReadStreamClose) CFReadStreamClose;
    __typeof__(&CFGetTypeID) CFGetTypeID;
    __typeof__(&CFDictionaryGetTypeID) CFDictionaryGetTypeID;
    __typeof__(&CFDictionaryGetValue) CFDictionaryGetValue;
    __typeof__(&CFArrayGetTypeID) CFArrayGetTypeID;
    __typeof__(&CFStringGetTypeID) CFStringGetTypeID;
    __typeof__(&CFStringGetCString) CFStringGetCString;
    __typeof__(&CFArrayContainsValue) CFArrayContainsValue;
    __typeof__(&CFArrayGetCount) CFArrayGetCount;
    __typeof__(&CFStringCreateWithCString) CFStringCreateWithCString;
    __typeof__(&CFBooleanGetTypeID) CFBooleanGetTypeID;
    __typeof__(&CFBooleanGetValue) CFBooleanGetValue;
} api;

static bool LoadCoreFoundation(void) {
    void *framework = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW | RTLD_LOCAL);
    if (!framework) return false;
    api.CFURLCreateFromFileSystemRepresentation = dlsym(framework, "CFURLCreateFromFileSystemRepresentation");
    if (!api.CFURLCreateFromFileSystemRepresentation) return false;
    api.CFReadStreamCreateWithFile = dlsym(framework, "CFReadStreamCreateWithFile");
    if (!api.CFReadStreamCreateWithFile) return false;
    api.CFRelease = dlsym(framework, "CFRelease");
    if (!api.CFRelease) return false;
    api.CFReadStreamOpen = dlsym(framework, "CFReadStreamOpen");
    if (!api.CFReadStreamOpen) return false;
    api.CFPropertyListCreateWithStream = dlsym(framework, "CFPropertyListCreateWithStream");
    if (!api.CFPropertyListCreateWithStream) return false;
    api.CFReadStreamClose = dlsym(framework, "CFReadStreamClose");
    if (!api.CFReadStreamClose) return false;
    api.CFGetTypeID = dlsym(framework, "CFGetTypeID");
    if (!api.CFGetTypeID) return false;
    api.CFDictionaryGetTypeID = dlsym(framework, "CFDictionaryGetTypeID");
    if (!api.CFDictionaryGetTypeID) return false;
    api.CFDictionaryGetValue = dlsym(framework, "CFDictionaryGetValue");
    if (!api.CFDictionaryGetValue) return false;
    api.CFArrayGetTypeID = dlsym(framework, "CFArrayGetTypeID");
    if (!api.CFArrayGetTypeID) return false;
    api.CFStringGetTypeID = dlsym(framework, "CFStringGetTypeID");
    if (!api.CFStringGetTypeID) return false;
    api.CFStringGetCString = dlsym(framework, "CFStringGetCString");
    if (!api.CFStringGetCString) return false;
    api.CFArrayContainsValue = dlsym(framework, "CFArrayContainsValue");
    if (!api.CFArrayContainsValue) return false;
    api.CFArrayGetCount = dlsym(framework, "CFArrayGetCount");
    if (!api.CFArrayGetCount) return false;
    api.CFStringCreateWithCString = dlsym(framework, "CFStringCreateWithCString");
    if (!api.CFStringCreateWithCString) return false;
    api.CFBooleanGetTypeID = dlsym(framework, "CFBooleanGetTypeID");
    if (!api.CFBooleanGetTypeID) return false;
    api.CFBooleanGetValue = dlsym(framework, "CFBooleanGetValue");
    if (!api.CFBooleanGetValue) return false;
    return true;
}

static const void *Value(CFDictionaryRef dictionary, const char *name) {
    CFStringRef key = api.CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    const void *value = api.CFDictionaryGetValue(dictionary, key);
    api.CFRelease(key);
    return value;
}

static CFPropertyListRef ReadPlist(const char *path) {
    CFURLRef url = api.CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    if (!url) return NULL;
    CFReadStreamRef stream = api.CFReadStreamCreateWithFile(NULL, url);
    api.CFRelease(url);
    if (!stream) return NULL;
    CFPropertyListRef result = NULL;
    if (api.CFReadStreamOpen(stream)) result = api.CFPropertyListCreateWithStream(NULL, stream, 0, kCFPropertyListImmutable, NULL, NULL);
    api.CFReadStreamClose(stream);
    api.CFRelease(stream);
    return result;
}

__attribute__((constructor)) static void LoadSelectedLookinApp(void) {
    char executable[PATH_MAX], bundlePath[PATH_MAX];
    uint32_t capacity = sizeof(executable);
    if (_NSGetExecutablePath(executable, &capacity) || !realpath(executable, bundlePath)) return;
    // Только главный executable пользовательского .app, без расширений и системных служб.
    if (!strstr(bundlePath, "/Containers/Bundle/Application/")) return;
    char *slash = strrchr(bundlePath, '/');
    if (!slash) return;
    char executableName[PATH_MAX];
    strlcpy(executableName, slash + 1, sizeof(executableName));
    *slash = 0;
    size_t length = strlen(bundlePath);
    if (length < 4 || strcmp(bundlePath + length - 4, ".app")) return;
    void *(*getClass)(const char *) = dlsym(RTLD_DEFAULT, "objc_getClass");
    if (getClass && getClass("Lookin")) return;

    Dl_info image;
    if (!dladdr((const void *)&LoadSelectedLookinApp, &image) || !image.dli_fname) return;
    char directory[PATH_MAX], path[PATH_MAX];
    strlcpy(directory, image.dli_fname, sizeof(directory));
    slash = strrchr(directory, '/');
    if (!slash) return;
    *slash = 0;
    snprintf(path, sizeof(path), "%s/owner.lock", directory);
    int owner = open(path, O_RDONLY | O_CLOEXEC);
    if (owner < 0) return;
    int locked = flock(owner, LOCK_SH | LOCK_NB);
    int lockError = errno;
    if (!locked) flock(owner, LOCK_UN);
    close(owner);
    // Desktop держит эксклюзивную блокировку. При выходе или crash ядро её снимает.
    if (locked != -1 || lockError != EWOULDBLOCK) return;

    if (!LoadCoreFoundation()) return;
    snprintf(path, sizeof(path), "%s/config.plist", directory);
    CFPropertyListRef config = ReadPlist(path);
    if (!config || api.CFGetTypeID(config) != api.CFDictionaryGetTypeID()) { if (config) api.CFRelease(config); return; }
    CFDictionaryRef dictionary = config;
    CFArrayRef bundleIDs = Value(dictionary, "bundleIDs");
    CFStringRef server = Value(dictionary, "serverPath");
    CFBooleanRef enabled = Value(dictionary, "enabled");
    if (!enabled || api.CFGetTypeID(enabled) != api.CFBooleanGetTypeID() || !api.CFBooleanGetValue(enabled) ||
        !bundleIDs || api.CFGetTypeID(bundleIDs) != api.CFArrayGetTypeID() ||
        !server || api.CFGetTypeID(server) != api.CFStringGetTypeID()) { api.CFRelease(config); return; }

    snprintf(path, sizeof(path), "%s/Info.plist", bundlePath);
    CFPropertyListRef info = ReadPlist(path);
    if (info && api.CFGetTypeID(info) == api.CFDictionaryGetTypeID()) {
        CFStringRef bundleID = Value(info, "CFBundleIdentifier");
        CFStringRef declaredExecutable = Value(info, "CFBundleExecutable");
        char expectedExecutable[PATH_MAX];
        if (bundleID && api.CFGetTypeID(bundleID) == api.CFStringGetTypeID() &&
            declaredExecutable && api.CFGetTypeID(declaredExecutable) == api.CFStringGetTypeID() &&
            api.CFStringGetCString(declaredExecutable, expectedExecutable, sizeof(expectedExecutable), kCFStringEncodingUTF8) &&
            !strcmp(expectedExecutable, executableName) &&
            api.CFArrayContainsValue(bundleIDs, CFRangeMake(0, api.CFArrayGetCount(bundleIDs)), bundleID) &&
            api.CFStringGetCString(server, path, sizeof(path), kCFStringEncodingUTF8)) {
            dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        }
    }
    if (info) api.CFRelease(info);
    api.CFRelease(config);
}
