#include "termx_python_bridge.h"

#include <Python.h>

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <TargetConditionals.h>

#define TERMX_PYTHON_VERSION "3.14"
#define TERMX_PYTHON_TAG "3.14"

static char g_support_root[4096];
static char g_stdlib_path[4096];
static bool g_support_root_set = false;
static bool g_stdlib_path_set = false;
static bool g_initialized = false;
static pthread_mutex_t g_run_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_interrupt_requested = 0;

static int append_module_path(PyConfig *config, const char *path) {
    if (path == NULL || path[0] == '\0') {
        return 0;
    }
    wchar_t *wpath = Py_DecodeLocale(path, NULL);
    if (wpath == NULL) {
        return -1;
    }
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, wpath);
    PyMem_RawFree(wpath);
    return PyStatus_Exception(status) ? -1 : 0;
}

static const char *platform_slice_name(void) {
#if TARGET_OS_IPHONE
#if TARGET_OS_SIMULATOR
    return "ios-arm64_x86_64-simulator";
#else
    return "ios-arm64";
#endif
#else
    return "macos-arm64_x86_64";
#endif
}

static const char *platform_dynload_subdir(void) {
#if TARGET_OS_IPHONE
#if TARGET_OS_SIMULATOR
#if defined(__arm64__)
    return "lib-arm64";
#else
    return "lib-x86_64";
#endif
#else
    return "lib-arm64";
#endif
#else
    return "lib";
#endif
}

static const char *platform_config_subdir(void) {
#if TARGET_OS_IPHONE
#if TARGET_OS_SIMULATOR
#if defined(__arm64__)
    return "arm64-iphonesimulator";
#else
    return "x86_64-iphonesimulator";
#endif
#else
    return "arm64-iphoneos";
#endif
#else
    return "macos-arm64_x86_64";
#endif
}

static int join3(char *out, size_t out_len, const char *a, const char *b, const char *c) {
    int written = snprintf(out, out_len, "%s/%s/%s", a, b, c);
    if (written < 0 || (size_t)written >= out_len) {
        return -1;
    }
    return 0;
}

static int join2(char *out, size_t out_len, const char *a, const char *b) {
    int written = snprintf(out, out_len, "%s/%s", a, b);
    if (written < 0 || (size_t)written >= out_len) {
        return -1;
    }
    return 0;
}

static int discover_support_root_from_dylib(char *out, size_t out_len) {
    Dl_info info;
    if (dladdr((void *)Py_Initialize, &info) == 0 || info.dli_fname == NULL) {
        return -1;
    }

    char framework_path[4096];
    strncpy(framework_path, info.dli_fname, sizeof(framework_path) - 1);
    framework_path[sizeof(framework_path) - 1] = '\0';

    char *marker = strstr(framework_path, ".xcframework/");
    if (marker == NULL) {
        return -1;
    }
    marker[strlen(".xcframework/")] = '\0';
    const size_t root_len = (size_t)(marker - framework_path + strlen(".xcframework"));
    if (root_len + 1 > out_len) {
        return -1;
    }
    memcpy(out, framework_path, root_len);
    out[root_len] = '\0';
    return 0;
}

static const char *effective_support_root(void) {
    if (g_support_root_set) {
        return g_support_root;
    }
    if (discover_support_root_from_dylib(g_support_root, sizeof(g_support_root)) == 0) {
        g_support_root_set = true;
    }
    return g_support_root_set ? g_support_root : NULL;
}

int termx_python_set_stdlib_path(const char *stdlib_path) {
    if (stdlib_path == NULL || stdlib_path[0] == '\0') {
        return -1;
    }
    strncpy(g_stdlib_path, stdlib_path, sizeof(g_stdlib_path) - 1);
    g_stdlib_path[sizeof(g_stdlib_path) - 1] = '\0';
    g_stdlib_path_set = true;
    return 0;
}

int termx_python_set_support_root(const char *xcframework_root) {
    if (xcframework_root == NULL || xcframework_root[0] == '\0') {
        return -1;
    }
    strncpy(g_support_root, xcframework_root, sizeof(g_support_root) - 1);
    g_support_root[sizeof(g_support_root) - 1] = '\0';
    g_support_root_set = true;
    return 0;
}

static int configure_python_home(PyConfig *config, const char *slice_root) {
    wchar_t *whome = Py_DecodeLocale(slice_root, NULL);
    if (whome == NULL) {
        return -1;
    }
    PyStatus status = PyConfig_SetString(config, &config->home, whome);
    PyMem_RawFree(whome);
    return PyStatus_Exception(status) ? -1 : 0;
}

static int configure_search_paths(PyConfig *config, const char *support_root, const char *site_packages) {
    char path[4096];
    const char *slice = platform_slice_name();

    if (join2(path, sizeof(path), support_root, "lib/python" TERMX_PYTHON_TAG) != 0) {
        return -1;
    }
    if (g_stdlib_path_set) {
        if (append_module_path(config, g_stdlib_path) != 0) {
            return -1;
        }
    } else if (append_module_path(config, path) != 0) {
        return -1;
    }

#if TARGET_OS_IPHONE
    const char *dynload = platform_dynload_subdir();
    if (join3(path, sizeof(path), support_root, slice, dynload) != 0) {
        return -1;
    }
    if (join2(path, sizeof(path), path, "python" TERMX_PYTHON_TAG "/lib-dynload") != 0) {
        return -1;
    }
    if (append_module_path(config, path) != 0) {
        return -1;
    }

    const char *platform_cfg = platform_config_subdir();
    if (join3(path, sizeof(path), support_root, slice, "platform-config") != 0) {
        return -1;
    }
    if (join2(path, sizeof(path), path, platform_cfg) != 0) {
        return -1;
    }
    if (append_module_path(config, path) != 0) {
        return -1;
    }
#else
    if (join3(path, sizeof(path), support_root, slice, "Python.framework/Versions/" TERMX_PYTHON_TAG "/lib/python" TERMX_PYTHON_TAG "/lib-dynload") != 0) {
        return -1;
    }
    if (append_module_path(config, path) != 0) {
        return -1;
    }
#endif

    if (site_packages != NULL && site_packages[0] != '\0') {
        if (append_module_path(config, site_packages) != 0) {
            return -1;
        }
    }

    return 0;
}

/* Builds the interpreter with our embedded-stdlib layout. When argv is given,
   the command line is parsed into the config (parse_argv) so a later
   Py_RunMain() behaves exactly like the python CLI -- handling --version, -c,
   -m and script paths -- without Py_BytesMain rebuilding the config from
   scratch and losing these paths. */
static int initialize_with_argv(int argc, char **argv, int *exit_code) {
    if (g_initialized) {
        return 0;
    }

    PyPreConfig preconfig;
    PyConfig config;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    PyConfig_InitIsolatedConfig(&config);

    preconfig.utf8_mode = 1;
    preconfig.configure_locale = 1;
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
    config.module_search_paths_set = 1;
    /* Isolated config leaves this at 0, which leaves sys.stdout/sys.stderr
       unattached to the C streams. */
    config.configure_c_stdio = 1;
    /* CPython defaults this to 1 on iOS, which swaps sys.stdout/sys.stderr for
       _apple_support.SystemLog writers aimed at the Apple system log. In a
       terminal we want the real descriptors, otherwise print() vanishes from
       the session while os.write(1, ...) still works. */
    config.use_system_logger = 0;

    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        PyConfig_Clear(&config);
        if (PyStatus_IsExit(status)) {
            if (exit_code != NULL) { *exit_code = status.exitcode; }
            return 1;
        }
        return -1;
    }

    if (argc > 0 && argv != NULL) {
        config.parse_argv = 1;
        status = PyConfig_SetBytesArgv(&config, (Py_ssize_t)argc, argv);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            if (PyStatus_IsExit(status)) {
                if (exit_code != NULL) { *exit_code = status.exitcode; }
                return 1;
            }
            return -1;
        }
    }

    /* BeeWare app-bundle layout: $APP/python/lib/python3.14 (+ lib-dynload/.fwork). */
    if (g_stdlib_path_set) {
        char python_home[4096];
        char dynload[4096];
        strncpy(python_home, g_stdlib_path, sizeof(python_home) - 1);
        python_home[sizeof(python_home) - 1] = '\0';
        /* .../python/lib/python3.14 → .../python/lib → .../python */
        char *slash = strrchr(python_home, '/');
        if (slash == NULL) {
            PyConfig_Clear(&config);
            return -1;
        }
        *slash = '\0';
        slash = strrchr(python_home, '/');
        if (slash == NULL) {
            PyConfig_Clear(&config);
            return -1;
        }
        *slash = '\0';

        if (configure_python_home(&config, python_home) != 0) {
            PyConfig_Clear(&config);
            return -1;
        }
        if (append_module_path(&config, g_stdlib_path) != 0) {
            PyConfig_Clear(&config);
            return -1;
        }
        if (snprintf(dynload, sizeof(dynload), "%s/lib-dynload", g_stdlib_path) >= (int)sizeof(dynload)) {
            PyConfig_Clear(&config);
            return -1;
        }
        if (append_module_path(&config, dynload) != 0) {
            PyConfig_Clear(&config);
            return -1;
        }
    } else {
        const char *support_root = effective_support_root();
        if (support_root == NULL) {
            PyConfig_Clear(&config);
            return -1;
        }

        const char *slice = platform_slice_name();
        char slice_root[4096];
#if TARGET_OS_IPHONE
        if (join2(slice_root, sizeof(slice_root), support_root, slice) != 0) {
            PyConfig_Clear(&config);
            return -1;
        }
#else
        if (join3(slice_root, sizeof(slice_root), support_root, slice, "Python.framework/Versions/" TERMX_PYTHON_TAG) != 0) {
            PyConfig_Clear(&config);
            return -1;
        }
#endif

        if (configure_python_home(&config, slice_root) != 0) {
            PyConfig_Clear(&config);
            return -1;
        }

        if (configure_search_paths(&config, support_root, NULL) != 0) {
            PyConfig_Clear(&config);
            return -1;
        }
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        if (PyStatus_IsExit(status)) {
            /* --version / --help: Python printed its output and wants to exit. */
            if (exit_code != NULL) { *exit_code = status.exitcode; }
            return 1;
        }
        return -1;
    }

    g_initialized = true;
    return 0;
}

int termx_python_initialize(void) {
    return initialize_with_argv(0, NULL, NULL) == 0 ? 0 : -1;
}

int termx_python_is_initialized(void) {
    return g_initialized ? 1 : 0;
}

static int apply_environment(const char *const *envp, int interactive) {
    if (setenv("LANG", "en_US.UTF-8", 1) != 0) {
        return -1;
    }
    if (interactive) {
        setenv("TERMX_INTERACTIVE", "1", 1);
    } else {
        unsetenv("TERMX_INTERACTIVE");
    }
    if (envp == NULL) {
        return 0;
    }
    for (const char *const *cursor = envp; *cursor != NULL; cursor++) {
        const char *entry = *cursor;
        const char *eq = strchr(entry, '=');
        if (eq == NULL) {
            continue;
        }
        size_t key_len = (size_t)(eq - entry);
        if (key_len == 0) {
            continue;
        }
        char *key = malloc(key_len + 1);
        if (key == NULL) {
            return -1;
        }
        memcpy(key, entry, key_len);
        key[key_len] = '\0';
        const char *value = eq + 1;
        setenv(key, value, 1);
        free(key);
    }
    return 0;
}

static int redirect_stdio(int stdin_fd, int stdout_fd, int stderr_fd, int saved[3]) {
    for (int fd = 0; fd < 3; fd++) {
        saved[fd] = -1;
    }

    struct {
        int target;
        int source;
    } mapping[3] = {
        {STDIN_FILENO, stdin_fd},
        {STDOUT_FILENO, stdout_fd},
        {STDERR_FILENO, stderr_fd},
    };

    for (int i = 0; i < 3; i++) {
        if (mapping[i].source < 0) {
            continue;
        }
        saved[i] = dup(mapping[i].target);
        if (saved[i] < 0) {
            return -1;
        }
        if (dup2(mapping[i].source, mapping[i].target) < 0) {
            return -1;
        }
    }
    return 0;
}

static void restore_stdio(int saved[3]) {
    struct {
        int target;
        int saved_fd;
    } mapping[3] = {
        {STDIN_FILENO, saved[0]},
        {STDOUT_FILENO, saved[1]},
        {STDERR_FILENO, saved[2]},
    };

    for (int i = 0; i < 3; i++) {
        if (mapping[i].saved_fd < 0) {
            continue;
        }
        dup2(mapping[i].saved_fd, mapping[i].target);
        close(mapping[i].saved_fd);
    }
}

void termx_python_interrupt(void) {
    g_interrupt_requested = 1;
    if (g_initialized) {
        PyErr_SetInterrupt();
    }
}

int termx_python_run(int argc, char **argv, const char *cwd,
                     const char *const *envp, int stdin_fd, int stdout_fd, int stderr_fd,
                     int interactive) {
    if (argc <= 0 || argv == NULL) {
        return 2;
    }

    pthread_mutex_lock(&g_run_lock);
    g_interrupt_requested = 0;

    /* Environment first: Py_PreInitialize reads LANG to configure the locale. */
    if (apply_environment(envp, interactive) != 0) {
        pthread_mutex_unlock(&g_run_lock);
        return 1;
    }

    if (cwd != NULL && cwd[0] != '\0') {
        if (chdir(cwd) != 0) {
            pthread_mutex_unlock(&g_run_lock);
            return 1;
        }
    }

    int saved_stdio[3];
    if (redirect_stdio(stdin_fd, stdout_fd, stderr_fd, saved_stdio) != 0) {
        pthread_mutex_unlock(&g_run_lock);
        return 1;
    }

    int init_exit = 0;
    int init_state = initialize_with_argv(argc, argv, &init_exit);
    if (init_state != 0) {
        /* 1 = Python printed --version/--help and asked to exit; -1 = real failure. */
        fflush(stdout);
        fflush(stderr);
        restore_stdio(saved_stdio);
        pthread_mutex_unlock(&g_run_lock);
        return init_state > 0 ? init_exit : 127;
    }

    const char *pythonpath = getenv("PYTHONPATH");
    if (pythonpath != NULL && pythonpath[0] != '\0' && g_initialized) {
        PyObject *sys = PyImport_ImportModule("sys");
        if (sys != NULL) {
            PyObject *sys_path = PyObject_GetAttrString(sys, "path");
            PyObject *path = PyUnicode_FromString(pythonpath);
            if (sys_path != NULL && path != NULL) {
                PyList_Insert(sys_path, 0, path);
            }
            Py_XDECREF(path);
            Py_XDECREF(sys_path);
            Py_DECREF(sys);
        }
    }

    /* Py_RunMain executes what parse_argv put in the config and finalizes the
       interpreter on the way out -- so no Py_Finalize() here, and the next
       command re-initializes from scratch. */
    int exit_code = Py_RunMain();
    g_initialized = false;
    fflush(stdout);
    fflush(stderr);
    restore_stdio(saved_stdio);

    pthread_mutex_unlock(&g_run_lock);
    (void)g_interrupt_requested;
    return exit_code;
}
