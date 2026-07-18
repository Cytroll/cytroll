#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

/*
 * cytrollhelper — TrollStore root execution proxy (Sileo/Filza/Dopamine pattern)
 *
 * Security (rootless):
 *   - Explicit system-tool allowlist (not all of /bin|/usr/bin)
 *   - Blocks signed system volume (SSV) paths
 *   - Jailbreak state confined to /var/jb
 *   - /var/mobile limited to app Data containers (vault / temp)
 */

static int path_has_prefix(const char *path, const char *prefix) {
    size_t plen = strlen(prefix);
    if (strncmp(path, prefix, plen) != 0) return 0;
    if (path[plen] == '\0' || path[plen] == '/') return 1;
    return 0;
}

static int is_blocked_system_path(const char *path) {
    static const char *blocked[] = {
        "/System",
        "/private/preboot",
        "/usr/standalone",
        "/private/var/MobileSoftwareUpdate",
        NULL
    };

    for (int i = 0; blocked[i]; i++) {
        if (path_has_prefix(path, blocked[i])) return 1;
    }
    return 0;
}

static int contains_path_traversal(const char *path) {
    if (strstr(path, "/../") != NULL) return 1;
    size_t len = strlen(path);
    if (len >= 3 && strcmp(path + len - 3, "/..") == 0) return 1;
    return 0;
}

/*
 * Bundled tools (tar/zstd/ldid/cytrollhelper itself) live at
 * <AppBundle>/Binaries/<tool>. Only trust this when the bundle sits inside
 * the *installed, read-only* app container (Bundle/Application).
 */
static const char *kBundleApplicationRoots[] = {
    "/private/var/containers/Bundle/Application",
    "/var/containers/Bundle/Application",
    NULL
};

static int is_bundled_binary_path(const char *path) {
    if (contains_path_traversal(path)) return 0;

    for (int i = 0; kBundleApplicationRoots[i]; i++) {
        if (path_has_prefix(path, kBundleApplicationRoots[i]) && strstr(path, ".app/Binaries/") != NULL) {
            return 1;
        }
    }
    return 0;
}

static int is_third_party_app_bundle_path(const char *path) {
    if (contains_path_traversal(path)) return 0;

    for (int i = 0; kBundleApplicationRoots[i]; i++) {
        if (!path_has_prefix(path, kBundleApplicationRoots[i])) continue;

        if (strstr(path, ".app/") != NULL) return 1;

        size_t len = strlen(path);
        if (len >= 4 && strcmp(path + len - 4, ".app") == 0) return 1;

        if (strstr(path, ".app.cytroll_") != NULL) return 1;
    }
    return 0;
}

static int is_third_party_install_container_path(const char *path) {
    if (!path || contains_path_traversal(path)) return 0;

    for (int i = 0; kBundleApplicationRoots[i]; i++) {
        const char *root = kBundleApplicationRoots[i];
        size_t rlen = strlen(root);
        if (!path_has_prefix(path, root)) continue;
        if (path[rlen] != '/') continue;

        const char *rest = path + rlen + 1;
        if (rest[0] == '\0') return 0;

        if (strchr(rest, '/') != NULL) return 0;

        size_t ulen = strlen(rest);
        if (ulen < 8 || ulen > 64) return 0;
        return 1;
    }
    return 0;
}

/* Narrow mobile paths — Documents/Library vault + app tmp/caches only. */
static int is_allowed_mobile_data_path(const char *path) {
    return path_has_prefix(path, "/var/mobile/Containers/Data/Application") ||
           path_has_prefix(path, "/private/var/mobile/Containers/Data/Application");
}

static int is_jb_path(const char *path) {
    return path_has_prefix(path, "/var/jb") ||
           path_has_prefix(path, "/private/var/jb");
}

/* Exact system tools Cytroll invokes — never open-ended /bin|/usr/bin. */
static int is_allowed_system_tool(const char *path) {
    static const char *allowed[] = {
        "/bin/rm",
        "/bin/cp",
        "/bin/mv",
        "/bin/mkdir",
        "/usr/bin/killall",
        NULL
    };
    for (int i = 0; allowed[i]; i++) {
        if (strcmp(path, allowed[i]) == 0) return 1;
    }
    return 0;
}

static int is_allowed_executable(const char *path) {
    if (!path || path[0] != '/') return 0;
    if (is_blocked_system_path(path)) return 0;
    if (contains_path_traversal(path)) return 0;

    /* Any tool installed under the rootless prefix (dpkg, apt, sh, …). */
    if (is_jb_path(path)) return 1;

    if (is_allowed_system_tool(path)) return 1;

    return is_bundled_binary_path(path);
}

static int argument_targets_system(const char *arg) {
    if (!arg || arg[0] != '/') return 0;
    if (is_blocked_system_path(arg)) return 1;
    if (contains_path_traversal(arg)) return 1;

    /* Procursus bootstrap extracts var/jb/ tree via tar -C / */
    if (strcmp(arg, "/") == 0) return 0;

    if (is_jb_path(arg)) return 0;

    if (is_allowed_mobile_data_path(arg)) return 0;

    if (path_has_prefix(arg, "/private/var/tmp") || path_has_prefix(arg, "/var/tmp") ||
        path_has_prefix(arg, "/tmp")) {
        return 0;
    }

    /* Per-app tweak injection */
    if (is_third_party_app_bundle_path(arg)) return 0;

    /* App Manager uninstall of a third-party install UUID container. */
    if (is_third_party_install_container_path(arg)) return 0;

    /* Everything else under /var is blocked */
    if (path_has_prefix(arg, "/var/") || path_has_prefix(arg, "/private/var/")) {
        return 1;
    }

    return 0;
}

static int validate_arguments(char *const args[]) {
    for (int i = 0; args[i] != NULL; i++) {
        if (argument_targets_system(args[i])) {
            fprintf(stderr, "cytrollhelper: blocked unsafe path: %s\n", args[i]);
            return 0;
        }
    }
    return 1;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <executable> [args...]\n", argv[0]);
        return 1;
    }

    const char *target = argv[1];

    if (!is_allowed_executable(target)) {
        fprintf(stderr, "cytrollhelper: executable not allowlisted: %s\n", target);
        return 1;
    }

    if (!validate_arguments(&argv[1])) {
        return 1;
    }

    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "cytrollhelper: could not escalate to root — continuing as uid %d (fine for mobile-owned /var/jb).\n", getuid());
    }

    execv(target, &argv[1]);
    perror("cytrollhelper: execv failed");
    return 1;
}
