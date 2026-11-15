/*
 * RG353PS frontend selector for BaseOS package/profile installations.
 * A = launch once, START = save default, Y = remove one profile, X = remove
 * the entire package. Both removal modes preserve all per-profile instance
 * data and shared game resources.
 */
#define _DEFAULT_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <rg353ps-ui.h>

#define T(en, zh) baseos_ui_text((en), (zh))

#define MAX_INPUTS 32
#define MAX_FRONTENDS 64
#define ID_LEN 64
#define LABEL_LEN 160
#define PACKAGE_LEN 64
#define PROFILE_LEN 32
#define ROOT_LEN 320
#define PATH_LEN 320
#define CATALOG_PATH "/run/baseos-frontend-catalog"
#define CONFIG_PATH "/mnt/SDCARD/baseos.conf"
#define SELECTION_PATH "/run/baseos-frontend-selection"
#define MANAGER_PATH "/usr/sbin/baseos-frontend-manager"

struct frontend_entry {
    char id[ID_LEN];
    char label[LABEL_LEN];
    char package_id[PACKAGE_LEN];
    char profile_id[PROFILE_LEN];
    char root[ROOT_LEN];
    char package_dir[PATH_LEN];
    char profile_config[PATH_LEN];
    char kind[16];
    int priority;
    int disabled;
};

struct input_device {
    int fd;
    char path[PATH_LEN];
    char name[128];
};

static struct frontend_entry entries[MAX_FRONTENDS];
static struct input_device inputs[MAX_INPUTS];
static int entry_count;
static int input_count;
static int selected_item;
static int scroll_offset;
static int confirming_uninstall;
static int uninstall_package_action;
static volatile sig_atomic_t running = 1;
static char status_line[160] = "Choose a frontend profile.";
static char current_default_id[ID_LEN] = "auto";
static struct termios saved_termios;
static int termios_saved;
static int stdin_active;
static int return_to_diagnostics;

static int visible_item_count(void)
{
    return entry_count + 2; /* diagnostics/return row plus language toggle */
}

static void stop_running(int sig)
{
    (void)sig;
    running = 0;
}

static int copy_field(char *dst, size_t cap, const char *src)
{
    size_t n = strlen(src);
    if (n == 0 || n >= cap) return 0;
    memcpy(dst, src, n + 1);
    return 1;
}

static void load_current_default(void)
{
    FILE *fp;
    char line[256];

    (void)snprintf(current_default_id, sizeof(current_default_id), "auto");
    fp = fopen(CONFIG_PATH, "r");
    if (fp == NULL) return;

    /* Match baseos-frontend-session's setting(): the last frontend_id wins. */
    while (fgets(line, sizeof(line), fp) != NULL) {
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
        if (len > 0 && line[len - 1] == '\r') line[--len] = '\0';
        if (strncmp(line, "frontend_id=", 12) == 0) {
            const char *value = line + 12;
            size_t value_len = strlen(value);
            if (value_len > 0 && value_len < sizeof(current_default_id))
                memcpy(current_default_id, value, value_len + 1);
        }
    }
    (void)fclose(fp);
}

static int entry_is_default(const struct frontend_entry *entry)
{
    return strcmp(current_default_id, "auto") != 0 &&
           strcmp(entry->id, current_default_id) == 0;
}

/* Old archives extracted under Frontends/<name>/ are complete isolated
 * frontend bundles; their .system and Tools directories live in this root. */
static int entry_is_frontend_bundle(const struct frontend_entry *entry)
{
    static const char *prefixes[] = {
        "/mnt/SDCARD/Frontends/",
        "/mnt/TF2/Frontends/"
    };
    for (size_t i = 0; i < sizeof(prefixes) / sizeof(prefixes[0]); ++i) {
        size_t n = strlen(prefixes[i]);
        if (strncmp(entry->root, prefixes[i], n) == 0) {
            const char *name = entry->root + n;
            return name[0] != '\0' && strchr(name, '/') == NULL;
        }
    }
    return 0;
}

static const char *current_default_label(void)
{
    static char missing_label[ID_LEN + 32];

    if (strcmp(current_default_id, "auto") == 0)
        return "AUTO (priority-based discovery)";
    for (int i = 0; i < entry_count; ++i) {
        if (entry_is_default(&entries[i])) {
            if (entries[i].disabled) {
                (void)snprintf(missing_label, sizeof(missing_label),
                               "%s (disabled; choose another)", entries[i].label);
                return missing_label;
            }
            return entries[i].label;
        }
    }

    (void)snprintf(missing_label, sizeof(missing_label),
                   "%s (not listed here)", current_default_id);
    return missing_label;
}

static int load_catalog(void)
{
    FILE *fp = fopen(CATALOG_PATH, "r");
    char line[1200];
    entry_count = 0;
    if (fp == NULL) return 0;

    while (entry_count < MAX_FRONTENDS && fgets(line, sizeof(line), fp) != NULL) {
        char *fields[10];
        char *save = NULL;
        char *token;
        int count = 0;
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
        if (len > 0 && line[len - 1] == '\r') line[--len] = '\0';
        token = strtok_r(line, "|", &save);
        while (token != NULL && count < 10) {
            fields[count++] = token;
            token = strtok_r(NULL, "|", &save);
        }
        if ((count != 9 && count != 10) || token != NULL) continue;

        struct frontend_entry *entry = &entries[entry_count];
        memset(entry, 0, sizeof(*entry));
        if (!copy_field(entry->id, sizeof(entry->id), fields[0]) ||
            !copy_field(entry->label, sizeof(entry->label), fields[1]) ||
            !copy_field(entry->package_id, sizeof(entry->package_id), fields[2]) ||
            !copy_field(entry->profile_id, sizeof(entry->profile_id), fields[3]) ||
            !copy_field(entry->root, sizeof(entry->root), fields[4]) ||
            !copy_field(entry->package_dir, sizeof(entry->package_dir), fields[5]) ||
            !copy_field(entry->profile_config, sizeof(entry->profile_config), fields[6]) ||
            !copy_field(entry->kind, sizeof(entry->kind), fields[8]))
            continue;
        entry->priority = atoi(fields[7]);
        entry->disabled = count == 10 && strcmp(fields[9], "disabled") == 0;
        ++entry_count;
    }
    (void)fclose(fp);
    if (selected_item >= visible_item_count())
        selected_item = visible_item_count() > 0 ? visible_item_count() - 1 : 0;
    if (selected_item < 0) selected_item = 0;
    return entry_count;
}

static void discover_inputs(void)
{
    DIR *dir = opendir("/dev/input");
    struct dirent *entry;
    if (dir == NULL) return;

    input_count = 0;
    while ((entry = readdir(dir)) != NULL && input_count < MAX_INPUTS) {
        char path[PATH_LEN];
        char name[128] = "unknown input";
        int fd;
        int duplicate = 0;

        if (strncmp(entry->d_name, "event", 5) != 0) continue;
        if (snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name) >= (int)sizeof(path)) continue;
        fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0) {
            (void)close(fd);
            continue;
        }
        name[sizeof(name) - 1] = '\0';
        if (strstr(name, "gpio-keys-control") == NULL) {
            (void)close(fd);
            continue;
        }
        for (int i = 0; i < input_count; ++i) {
            if (strcmp(inputs[i].path, path) == 0) duplicate = 1;
        }
        if (duplicate) {
            (void)close(fd);
            continue;
        }
        inputs[input_count].fd = fd;
        (void)snprintf(inputs[input_count].path, sizeof(inputs[input_count].path), "%s", path);
        (void)snprintf(inputs[input_count].name, sizeof(inputs[input_count].name), "%s", name);
        ++input_count;
    }
    (void)closedir(dir);
}

static int run_manager(const char *action, const char *id)
{
    pid_t child = fork();
    int status = 0;
    if (child < 0) return -1;
    if (child == 0) {
        if (id != NULL)
            execl(MANAGER_PATH, "baseos-frontend-manager", action, id, (char *)NULL);
        else
            execl(MANAGER_PATH, "baseos-frontend-manager", action, (char *)NULL);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (!WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

static int write_selection(const char *id)
{
    int fd = open(SELECTION_PATH, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    size_t len = strlen(id);
    ssize_t n;
    if (fd < 0) return 0;
    n = write(fd, id, len);
    if (n != (ssize_t)len || write(fd, "\n", 1) != 1) {
        (void)close(fd);
        return 0;
    }
    (void)fsync(fd);
    (void)close(fd);
    return 1;
}

static void adjust_scroll(void)
{
    const int visible = 5;
    if (entry_count <= visible) {
        scroll_offset = 0;
        return;
    }
    if (selected_item >= entry_count) {
        scroll_offset = entry_count - visible;
    } else {
        if (selected_item < scroll_offset) scroll_offset = selected_item;
        if (selected_item >= scroll_offset + visible) scroll_offset = selected_item - visible + 1;
    }
    if (scroll_offset < 0) scroll_offset = 0;
    if (scroll_offset > entry_count - visible) scroll_offset = entry_count - visible;
}

static void render_header(const char *title)
{
    (void)printf("\033%%G\033[2J\033[H\033[?25l");
    (void)printf("\033[1;36m==================================\033[0m\n");
    (void)printf("\033[1;36m");
    baseos_ui_print_line(title, 34);
    (void)printf("\033[0m----------------------------------\n");
}

static int count_package_profiles(const char *package_id)
{
    int count = 0;
    for (int i = 0; i < entry_count; ++i) {
        if (strcmp(entries[i].package_id, package_id) == 0) ++count;
    }
    return count;
}

static void render(void)
{
    adjust_scroll();
    if (confirming_uninstall) {
        struct frontend_entry *entry =
            selected_item >= 0 && selected_item < entry_count ? &entries[selected_item] : NULL;
        render_header(T("Confirm removal", "确认卸载"));
        if (entry == NULL) {
            baseos_ui_print_line(T("No frontend selected.", "没有选择前端。"), 34);
        } else {
            printf("%s: ", T("Package", "前端"));
            baseos_ui_print_line(entry->package_id, 29);
            printf("%s: ", T("Profile", "配置"));
            baseos_ui_print_line(entry->profile_id, 29);
            if (entry->disabled)
                baseos_ui_print_line(T("Status: DISABLED", "状态：已禁用"), 34);
            if (uninstall_package_action) {
                baseos_ui_print_line(T("DELETE complete frontend program.", "删除整个前端程序目录。"), 34);
                printf("  ");
                baseos_ui_print_line(entry->package_dir, 34);
            } else {
                baseos_ui_print_line(T("Remove this profile only.", "仅删除当前配置。"), 34);
                baseos_ui_print_line(T("Shared program/data are kept.", "保留共享程序和数据。"), 34);
            }
            printf("%s: %d\n", T("Profiles", "配置数"), count_package_profiles(entry->package_id));
            baseos_ui_print_line(T("Games, Saves and shared cores stay.", "Games、存档和共享核心保留。"), 34);
        }
        baseos_ui_print_line(T("A: confirm    B: cancel", "A：确认    B：取消"), 34);
        fflush(stdout);
        return;
    }

    render_header(T("BaseOS / Frontend selector", "BaseOS / 前端选择器"));
    printf("%s: ", T("Default", "默认启动"));
    baseos_ui_print_line(current_default_label(), 26);
    printf("%s: %d\n", T("Profiles", "已安装配置"), entry_count);

    if (entry_count == 0) {
        baseos_ui_print_line(T("No compatible frontend found.", "没有找到可用前端。"), 34);
        baseos_ui_print_line(T("Install under Frontends/.", "请安装到 Frontends/ 目录。"), 34);
    } else {
        int end = scroll_offset + 5;
        if (end > entry_count) end = entry_count;
        for (int i = scroll_offset; i < end; ++i) {
            printf("%s ", i == selected_item ? "\033[1;32m>" : " ");
            if (entries[i].disabled)
                printf("\033[1;31m%s\033[0m ", T("[DISABLED]", "[禁用]"));
            else if (entry_is_default(&entries[i]))
                printf("\033[1;33m%s\033[0m ", T("[DEFAULT]", "[默认]"));
            baseos_ui_print_line(entries[i].label, 29);
            printf("  ");
            baseos_ui_print_cells(entries[i].package_id, 15);
            printf(" / ");
            baseos_ui_print_line(entries[i].profile_id, 13);
            if (i == selected_item) printf("\033[0m");
        }
        if (entry_count > 5) {
            printf("  %s %d-%d/%d\n", T("Showing", "显示"),
                   scroll_offset + 1, end, entry_count);
        }
    }

    printf("----------------------------------\n");
    printf("%s ", selected_item == entry_count ? "\033[1;32m>" : " ");
    baseos_ui_print_line(
        return_to_diagnostics ? T("Return to diagnostics", "返回诊断页面")
                              : T("BaseOS Diagnostics", "BaseOS 诊断页面"), 34);
    if (selected_item == entry_count) printf("\033[0m");
    printf("%s ", selected_item == entry_count + 1 ? "\033[1;32m>" : " ");
    baseos_ui_print_line(baseos_ui_language_label(), 32);
    if (selected_item == entry_count + 1) printf("\033[0m");

    if (selected_item >= 0 && selected_item < entry_count) {
        printf("%s ", T("A: launch", "A：启动"));
        printf(" %s\n", T("START: set default", "START：设为默认"));
        printf("%s ", T("SELECT: enable/disable", "SELECT：启用/禁用"));
        printf(" %s\n", T("X: uninstall", "X：卸载"));
        if (strcmp(entries[selected_item].kind, "managed") == 0)
            baseos_ui_print_line(T("Y: remove profile", "Y：删除配置"), 34);
    } else if (selected_item == entry_count) {
        baseos_ui_print_line(
            return_to_diagnostics ? T("A: return to diagnostics", "A：返回诊断页面")
                                  : T("A: open diagnostics", "A：打开诊断页面"), 34);
    } else if (selected_item == entry_count + 1) {
        baseos_ui_print_line(T("A: switch interface language", "A：切换界面语言"), 34);
    }

    printf("%s: ", T("Status", "状态"));
    baseos_ui_print_line(status_line, 25);
    baseos_ui_print_line(T("UP/DOWN: move    B: back", "上下：移动    B：返回"), 34);
    fflush(stdout);
}

static void close_inputs(void)
{
    for (int i = 0; i < input_count; ++i) {
        if (inputs[i].fd >= 0) (void)close(inputs[i].fd);
        inputs[i].fd = -1;
    }
    input_count = 0;
}

static void open_diagnostics(void)
{
    pid_t child;
    int status = 0;

    /* The waiting selector must not accumulate gamepad events while the
     * diagnostics child owns the controller. */
    close_inputs();
    child = fork();
    if (child < 0) {
        discover_inputs();
        (void)snprintf(status_line, sizeof(status_line), "Could not start diagnostics.");
        render();
        return;
    }
    if (child == 0) {
        (void)setenv("BASEOS_RETURN_TO_SELECTOR", "1", 1);
        (void)setenv("BASEOS_DIAGNOSTIC_SUPERVISED", "0", 1);
        execl("/usr/sbin/rg353ps-control-center", "rg353ps-control-center", (char *)NULL);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            discover_inputs();
            (void)snprintf(status_line, sizeof(status_line), "Diagnostics wait failed.");
            render();
            return;
        }
    }
    if (access("/run/baseos-frontend-selection", F_OK) == 0) {
        running = 0;
        return;
    }
    discover_inputs();
    baseos_ui_load_language();
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        (void)snprintf(status_line, sizeof(status_line), "Diagnostics returned with an error.");
    else
        (void)snprintf(status_line, sizeof(status_line), "Returned from BaseOS Diagnostics.");
    load_current_default();
    (void)load_catalog();
    render();
}

static void choose_launch(int set_default)
{
    if (selected_item == entry_count) {
        if (return_to_diagnostics) {
            /* Return to the diagnostic menu that opened this nested selector. */
            running = 0;
        } else {
            open_diagnostics();
        }
        return;
    }
    if (selected_item == entry_count + 1) {
        if (baseos_ui_toggle_language() == 0) {
            (void)snprintf(status_line, sizeof(status_line), "%s",
                T("Language changed.", "界面语言已切换。"));
        } else {
            (void)snprintf(status_line, sizeof(status_line), "%s",
                T("Could not save ui_language.", "无法保存语言设置。"));
        }
        render();
        return;
    }
    if (entry_count <= 0 || selected_item < 0 || selected_item >= entry_count) return;
    if (entries[selected_item].disabled) {
        (void)snprintf(status_line, sizeof(status_line),
                       "This frontend is disabled. Enable it before launching.");
        render();
        return;
    }
    if (set_default) {
        int rc = run_manager("set-default", entries[selected_item].id);
        if (rc != 0) {
            (void)snprintf(status_line, sizeof(status_line), "Could not save default (manager exit %d).", rc);
            render();
            return;
        }
        load_current_default();
    }
    if (!write_selection(entries[selected_item].id)) {
        (void)snprintf(status_line, sizeof(status_line), "Could not write the one-time selection.");
        render();
        return;
    }
    running = 0;
}

static void toggle_selected_status(void)
{
    int rc;
    const struct frontend_entry *entry;
    const char *action;

    if (entry_count <= 0 || selected_item < 0 || selected_item >= entry_count) return;
    entry = &entries[selected_item];
    if (strcmp(entry->kind, "legacy-adapter") == 0) {
        action = entry->disabled ? "enable-legacy" : "disable-legacy";
    } else if (strcmp(entry->kind, "compat") == 0) {
        action = entry->disabled ? "enable-compat" : "uninstall-compat";
    } else {
        action = entry->disabled ? "enable-package" : "disable-package";
    }
    rc = run_manager(action, entry->id);
    if (rc != 0) {
        (void)snprintf(status_line, sizeof(status_line),
                       "Could not change frontend status (manager exit %d).", rc);
        render();
        return;
    }
    (void)snprintf(status_line, sizeof(status_line), "%s %s.",
                   entry->disabled ? "Enabled" : "Disabled", entry->label);
    load_current_default();
    (void)load_catalog();
    render();
}

static void uninstall_selected(void)
{
    int rc;
    char package[PACKAGE_LEN];
    char profile[PROFILE_LEN];
    int remove_package = uninstall_package_action;
    if (entry_count <= 0 || selected_item < 0 || selected_item >= entry_count) return;
    (void)snprintf(package, sizeof(package), "%s", entries[selected_item].package_id);
    (void)snprintf(profile, sizeof(profile), "%s", entries[selected_item].profile_id);
    const int is_compat = strcmp(entries[selected_item].kind, "compat") == 0;
    const int is_legacy_adapter = strcmp(entries[selected_item].kind, "legacy-adapter") == 0;
    const int is_legacy_bundle = is_legacy_adapter && entry_is_frontend_bundle(&entries[selected_item]);
    const char *action = is_compat
        ? (remove_package ? "delete-compat" : "uninstall-compat")
        : is_legacy_adapter
            ? (remove_package ? "delete-legacy-adapter" : "disable-legacy")
            : (remove_package ? "uninstall-package" : "uninstall");
    rc = run_manager(action, entries[selected_item].id);
    if (rc != 0) {
        (void)snprintf(status_line, sizeof(status_line), "Uninstall failed (manager exit %d).", rc);
        confirming_uninstall = 0;
        render();
        return;
    }
    if (is_legacy_bundle && remove_package) {
        (void)snprintf(status_line, sizeof(status_line),
                       "Deleted complete legacy frontend directory %s, including its bundled resources.", package);
    } else if (is_legacy_adapter && remove_package) {
        (void)snprintf(status_line, sizeof(status_line),
                       "Deleted adapter directory for %s; no isolated bundle root was found.", package);
    } else if (is_legacy_adapter) {
        (void)snprintf(status_line, sizeof(status_line),
                       "Disabled legacy adapter %s; all original files were kept.", package);
    } else if (is_compat && remove_package) {
        (void)snprintf(status_line, sizeof(status_line),
                       "Deleted legacy frontend %s. Per-instance data and shared content were kept.", package);
    } else if (is_compat) {
        (void)snprintf(status_line, sizeof(status_line),
                       "Removed BaseOS compatibility for %s; original files were kept.", package);
    } else if (remove_package) {
        (void)snprintf(status_line, sizeof(status_line),
                       "Uninstalled frontend %s. Profile instance data and shared content were kept.", package);
    } else {
        (void)snprintf(status_line, sizeof(status_line),
                       "Removed profile %s/%s. Shared program/data were preserved.", package, profile);
    }
    confirming_uninstall = 0;
    uninstall_package_action = 0;
    load_current_default();
    (void)load_catalog();
    render();
}

static void handle_key(unsigned int code, int value)
{
    if (value != 1) return;
    if (confirming_uninstall) {
        if (code == BTN_EAST) uninstall_selected();
        else if (code == BTN_SOUTH) {
            confirming_uninstall = 0;
            uninstall_package_action = 0;
            (void)snprintf(status_line, sizeof(status_line), "Removal cancelled.");
            render();
        }
        return;
    }

    switch (code) {
    case BTN_DPAD_UP:
        if (visible_item_count() > 0 && selected_item > 0) --selected_item;
        render();
        break;
    case BTN_DPAD_DOWN:
        if (visible_item_count() > 0 && selected_item + 1 < visible_item_count()) ++selected_item;
        render();
        break;
    case BTN_EAST:
        choose_launch(0);
        break;
    case BTN_START:
        choose_launch(1);
        break;
    case BTN_WEST: /* Y: remove one managed package profile. */
        if (selected_item >= 0 && selected_item < entry_count &&
            strcmp(entries[selected_item].kind, "managed") == 0) {
            uninstall_package_action = 0;
            confirming_uninstall = 1;
            render();
        } else if (selected_item >= 0 && selected_item < entry_count) {
            (void)snprintf(status_line, sizeof(status_line),
                           "Y removes a managed profile; SELECT toggles frontend status.");
            render();
        }
        break;
    case BTN_SELECT:
        if (selected_item >= 0 && selected_item < entry_count)
            toggle_selected_status();
        break;
    case BTN_NORTH: /* X: remove the entire frontend package. */
        if (selected_item >= 0 && selected_item < entry_count) {
            uninstall_package_action = 1;
            confirming_uninstall = 1;
            render();
        }
        break;
    case BTN_SOUTH:
        running = 0;
        break;
    default:
        break;
    }
}

static void handle_input(struct input_device *dev)
{
    struct input_event ev;
    ssize_t count;
    while ((count = read(dev->fd, &ev, sizeof(ev))) == (ssize_t)sizeof(ev)) {
        if (ev.type == EV_KEY) handle_key(ev.code, ev.value);
    }
    if (count < 0 && errno != EAGAIN && errno != EINTR) {
        (void)snprintf(status_line, sizeof(status_line), "Input read error: %s", strerror(errno));
        render();
    }
}

static void handle_terminal_byte(unsigned char ch, int *escape_state)
{
    if (*escape_state == 1) {
        *escape_state = ch == '[' ? 2 : 0;
        return;
    }
    if (*escape_state == 2) {
        *escape_state = 0;
        if (ch == 'A') handle_key(BTN_DPAD_UP, 1);
        else if (ch == 'B') handle_key(BTN_DPAD_DOWN, 1);
        return;
    }
    if (ch == 27) *escape_state = 1;
    else if (ch == 'w' || ch == 'W') handle_key(BTN_DPAD_UP, 1);
    else if (ch == 's' || ch == 'S') handle_key(BTN_DPAD_DOWN, 1);
    else if (ch == 'a' || ch == 'A' || ch == '\n' || ch == '\r') handle_key(BTN_EAST, 1);
    else if (ch == 'd' || ch == 'D') handle_key(BTN_START, 1);
    else if (ch == 'u' || ch == 'U' || ch == 'y' || ch == 'Y') handle_key(BTN_WEST, 1);
    else if (ch == 'e' || ch == 'E') handle_key(BTN_SELECT, 1);
    else if (ch == 'x' || ch == 'X') handle_key(BTN_NORTH, 1);
    else if (ch == 'b' || ch == 'B' || ch == 'q' || ch == 'Q') handle_key(BTN_SOUTH, 1);
}

int main(void)
{
    struct pollfd pollfds[MAX_INPUTS + 1];
    int escape_state = 0;
    (void)signal(SIGINT, stop_running);
    (void)signal(SIGTERM, stop_running);
    (void)signal(SIGHUP, stop_running);
    (void)unlink(SELECTION_PATH);
    return_to_diagnostics = getenv("BASEOS_SELECTOR_RETURN_TO_DIAGNOSTICS") != NULL &&
                            strcmp(getenv("BASEOS_SELECTOR_RETURN_TO_DIAGNOSTICS"), "1") == 0;
    baseos_ui_init();
    (void)snprintf(status_line, sizeof(status_line), "%s",
                   T("Choose a frontend profile.", "请选择一个前端配置。"));
    load_current_default();
    (void)load_catalog();
    discover_inputs();

    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &saved_termios) == 0) {
        struct termios raw = saved_termios;
        raw.c_lflag &= (tcflag_t)~(ICANON | ECHO);
        raw.c_iflag &= (tcflag_t)~(IXON | ICRNL);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0) termios_saved = 1;
        stdin_active = 1;
    }

    render();
    while (running) {
        int nfds = 0;
        int rc;
        if (stdin_active) {
            pollfds[nfds].fd = STDIN_FILENO;
            pollfds[nfds].events = POLLIN;
            pollfds[nfds].revents = 0;
            ++nfds;
        }
        for (int i = 0; i < input_count; ++i) {
            if (inputs[i].fd < 0) continue;
            pollfds[nfds].fd = inputs[i].fd;
            pollfds[nfds].events = POLLIN;
            pollfds[nfds].revents = 0;
            ++nfds;
        }
        rc = poll(pollfds, (nfds_t)nfds, nfds == 0 ? 1000 : 100);
        if (rc < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (rc == 0) continue;
        {
            int index = 0;
            if (stdin_active) {
                if ((pollfds[0].revents & POLLIN) != 0) {
                    unsigned char bytes[32];
                    ssize_t n = read(STDIN_FILENO, bytes, sizeof(bytes));
                    for (ssize_t i = 0; i < n; ++i) handle_terminal_byte(bytes[i], &escape_state);
                }
                index = 1;
            }
            for (int i = 0; i < input_count; ++i) {
                if (inputs[i].fd < 0) continue;
                if ((pollfds[index].revents & POLLIN) != 0) handle_input(&inputs[i]);
                if ((pollfds[index].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
                    (void)close(inputs[i].fd);
                    inputs[i].fd = -1;
                }
                ++index;
            }
        }
    }

    if (termios_saved) (void)tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
    /*
     * The selector runs on the Linux text console. When SDL/KMSDRM takes
     * over, that console's last cell buffer can remain underneath the
     * frontend and reappear during reboot while the graphics owner exits.
     * Clear the console on every selector exit (launch, cancel or signal)
     * so shutdown never reveals a stale selector frame.
     */
    (void)printf("\033[0m\033[2J\033[H\033[?25l");
    fflush(stdout);
    for (int i = 0; i < input_count; ++i)
        if (inputs[i].fd >= 0) (void)close(inputs[i].fd);
    return 0;
}
