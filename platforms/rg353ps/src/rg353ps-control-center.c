/*
 * RG353PS interactive bring-up console.
 * Diagnostic UI only; this is not the final BaseOS game launcher.
 * Reads Linux evdev and redraws a text menu on framebuffer console tty1.
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

#define MAX_INPUTS 64
#define PATH_LEN 256
#define NAME_LEN 128
#define USB_REQUEST_PATH "/run/baseos-usb-storage.request"
#define USB_PAUSED_PATH "/run/baseos-frontend-paused"

enum input_role { ROLE_OTHER = 0, ROLE_GAME, ROLE_FUNCTION, ROLE_STICK, ROLE_VOLUME, ROLE_POWER };
enum screen_id { SCREEN_HOME = 0, SCREEN_CONTROLS, SCREEN_AUDIO, SCREEN_WIFI, SCREEN_SYSTEM, SCREEN_HELP };

struct input_device {
    int fd;
    enum input_role role;
    char path[PATH_LEN];
    char name[NAME_LEN];
};

static struct input_device inputs[MAX_INPUTS];
static int input_count;
static volatile sig_atomic_t running = 1;
static int current_screen = SCREEN_HOME;
static int selected_item;
static int event_count;
static int function_count;
static int key_count;
static int axis_x = 511, axis_y = 511, axis_rx = 511, axis_ry = 511;
static int joy_y_direction;
static char last_event[160] = "Waiting for controller input...";
static struct termios saved_termios;
static int termios_saved;
static int return_to_selector;

#define MENU_COUNT 9

static const char *menu_item_label(int index)
{
    switch (index) {
    case 0: return T("Controller input test", "手柄输入测试");
    case 1: return T("Audio devices", "音频设备信息");
    case 2: return T("Wi-Fi status", "Wi-Fi 状态");
    case 3: return T("System and power", "系统与电源信息");
    case 4: return T("Button mapping help", "按键说明");
    case 5: return T("Frontend selector", "前端选择器");
    case 6: return T("USB mass-storage mode", "USB 大容量存储");
    case 7: return baseos_ui_language_label();
    case 8: return T("Return to frontend selector", "返回前端选择器");
    default: return "";
    }
}

static int visible_menu_count(void)
{
    /* Language is always visible; the return action exists only when launched
     * as a child of the frontend selector. */
    return return_to_selector ? MENU_COUNT : MENU_COUNT - 1;
}

static void stop_running(int sig)
{
    (void)sig;
    running = 0;
}

static enum input_role role_for_name(const char *name)
{
    if (strstr(name, "gpio-keys-control") != NULL) return ROLE_GAME;
    if (strstr(name, "adc-keys") != NULL) return ROLE_FUNCTION;
    if (strstr(name, "adc-joystick") != NULL) return ROLE_STICK;
    if (strstr(name, "gpio-keys-vol") != NULL) return ROLE_VOLUME;
    if (strcmp(name, "rk805 pwrkey") == 0) return ROLE_POWER;
    return ROLE_OTHER;
}

static void discover_inputs(void)
{
    DIR *dir = opendir("/dev/input");
    struct dirent *entry;
    input_count = 0;
    if (dir == NULL) return;

    while ((entry = readdir(dir)) != NULL && input_count < MAX_INPUTS) {
        struct input_device *dev;
        char path[PATH_LEN];
        char name[NAME_LEN] = "unknown input";
        int fd;

        if (strncmp(entry->d_name, "event", 5) != 0) continue;
        if (snprintf(path, sizeof(path), "/dev/input/%s", entry->d_name) >= (int)sizeof(path)) continue;
        fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) < 0) {
            (void)close(fd);
            continue;
        }

        dev = &inputs[input_count++];
        dev->fd = fd;
        dev->role = role_for_name(name);
        (void)snprintf(dev->path, sizeof(dev->path), "%s", path);
        (void)snprintf(dev->name, sizeof(dev->name), "%s", name);
    }
    (void)closedir(dir);
}

static const char *key_name(unsigned int code)
{
    switch (code) {
    case BTN_DPAD_UP: return "DPAD UP";
    case BTN_DPAD_DOWN: return "DPAD DOWN";
    case BTN_DPAD_LEFT: return "DPAD LEFT";
    case BTN_DPAD_RIGHT: return "DPAD RIGHT";
    case BTN_SOUTH: return "B (bottom / BTN_SOUTH)";
    case BTN_EAST: return "A (right / BTN_EAST)";
    case BTN_WEST: return "Y (left / BTN_WEST)";
    case BTN_NORTH: return "X (top / BTN_NORTH)";
    case KEY_POWER: return "POWER";
    case BTN_TL: return "L1 / TL";
    case BTN_TR: return "R1 / TR";
    case BTN_TL2: return "L2 / TL2";
    case BTN_TR2: return "R2 / TR2";
    case BTN_THUMBL: return "L3 / THUMBL";
    case BTN_THUMBR: return "R3 / THUMBR";
    case BTN_SELECT: return "SELECT";
    case BTN_START: return "START";
    case KEY_F1: return "F1";
    case KEY_F2: return "F2";
    case KEY_ESC: return "ESC";
    case KEY_ENTER: return "ENTER";
    case KEY_VOLUMEUP: return "VOLUME UP";
    case KEY_VOLUMEDOWN: return "VOLUME DOWN";
    default: return NULL;
    }
}

static int read_value(const char *path, char *dst, size_t dst_len)
{
    FILE *fp;
    size_t len;
    if (dst_len == 0) return 0;
    dst[0] = '\0';
    fp = fopen(path, "r");
    if (fp == NULL) {
        (void)snprintf(dst, dst_len, "unavailable");
        return 0;
    }
    if (fgets(dst, (int)dst_len, fp) == NULL) {
        (void)snprintf(dst, dst_len, "unavailable");
        (void)fclose(fp);
        return 0;
    }
    (void)fclose(fp);
    len = strlen(dst);
    while (len > 0 && (dst[len - 1] == '\n' || dst[len - 1] == '\r' || dst[len - 1] == '\0'))
        dst[--len] = '\0';
    return 1;
}

static void print_file(const char *path, int max_lines, int *row)
{
    FILE *fp = fopen(path, "r");
    char line[160];
    int count = 0;
    if (fp == NULL) {
        printf("  %s: %s\n", path, T("unavailable", "不可用"));
        ++(*row);
        return;
    }
    while (count < max_lines && *row < 25 && fgets(line, sizeof(line), fp) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        printf("  ");
        baseos_ui_print_line(line, 34);
        ++(*row);
        ++count;
    }
    (void)fclose(fp);
}

static void render_header(const char *title)
{
    printf("\033%%G\033[2J\033[H\033[?25l");
    printf("\033[1;36m==================================\033[0m\n");
    printf("\033[1;36m");
    baseos_ui_print_line(title, 34);
    printf("\033[0m----------------------------------\n");
}

static void print_last_input(void)
{
    printf("  %s", T("Last:", "最近按键："));
    baseos_ui_print_line(last_event, 27);
}

static void render_home(void)
{
    char operstate[64], battery[64];
    render_header(T("BaseOS RG353PS / Diagnostics", "BaseOS RG353PS / 系统诊断"));
    (void)read_value("/sys/class/net/wlan0/operstate", operstate, sizeof(operstate));
    (void)read_value("/sys/class/power_supply/battery/capacity", battery, sizeof(battery));

    baseos_ui_print_line(T("D-pad to move, A to open, B to back.",
                          "方向键移动，A 确认，B 返回。"), 34);
    baseos_ui_print_line(T("FUNCTION toggles live input monitor.",
                          "功能键切换实时输入监视。"), 34);
    printf("\n");
    for (int i = 0; i < visible_menu_count(); ++i) {
        printf("%s ", i == selected_item ? "\033[1;32m>" : " ");
        baseos_ui_print_line(menu_item_label(i), 32);
        if (i == selected_item) printf("\033[0m");
    }
    printf("----------------------------------\n");
    printf("Wi-Fi: ");
    baseos_ui_print_cells(operstate, 10);
    printf("  %s: ", T("Battery", "电量"));
    baseos_ui_print_line(battery, 5);
    printf("%s:%d  %s:%d\n", T("Keys", "按键"), key_count,
           T("Function", "功能键"), function_count);
    print_last_input();
}

static void render_controls(void)
{
    render_header(T("Controller input test", "手柄输入测试"));
    baseos_ui_print_line(T("D-pad: move    A: confirm", "方向键：移动    A：确认"), 34);
    baseos_ui_print_line(T("B: back        FUNCTION: monitor", "B：返回        功能键：监视"), 34);
    baseos_ui_print_line(T("L1/R1: shoulder buttons", "L1/R1：肩键输入"), 34);
    printf("\n");
    printf("L X:%d Y:%d  R X:%d Y:%d\n", axis_x, axis_y, axis_rx, axis_ry);
    printf("%s:%d  %s:%d\n", T("Key downs", "按键次数"), key_count,
           T("Events", "事件"), event_count);
    printf("%s:%d\n", T("Function presses", "功能键次数"), function_count);
    print_last_input();
}

static void render_audio(void)
{
    int row = 0;
    render_header(T("Audio devices", "音频设备信息"));
    baseos_ui_print_line(T("ALSA sound cards:", "ALSA 声卡："), 34);
    print_file("/proc/asound/cards", 4, &row);
    baseos_ui_print_line(T("PCM devices:", "PCM 设备："), 34);
    print_file("/proc/asound/pcm", 5, &row);
    baseos_ui_print_line(T("Volume +/- adjusts BaseOS Master.", "音量 +/- 调节 BaseOS Master。"), 34);
    baseos_ui_print_line(T("This screen does not play sound.", "此页面不会自动播放声音。"), 34);
    baseos_ui_print_line(T("B: back", "B：返回"), 34);
}

static void render_wifi(void)
{
    char value[128];
    int row = 0;
    render_header(T("Wi-Fi status", "Wi-Fi 状态"));
    (void)read_value("/sys/class/net/wlan0/operstate", value, sizeof(value));
    printf("%s: ", T("Interface", "网卡状态"));
    baseos_ui_print_line(value, 26);
    (void)read_value("/sys/class/net/wlan0/address", value, sizeof(value));
    printf("MAC: ");
    baseos_ui_print_line(value, 30);
    (void)read_value("/sys/class/rfkill/rfkill0/state", value, sizeof(value));
    printf("rfkill: ");
    baseos_ui_print_line(value, 26);
    baseos_ui_print_line(T("Kernel wireless:", "内核无线信息："), 34);
    print_file("/proc/net/wireless", 4, &row);
    baseos_ui_print_line(T("BaseOS does not join an AP here.", "此页面不会连接 Wi-Fi。"), 34);
    baseos_ui_print_line(T("B: back", "B：返回"), 34);
}

static void render_system(void)
{
    char value[128];
    int row = 0;
    render_header(T("System and power", "系统与电源信息"));
    (void)read_value("/proc/device-tree/model", value, sizeof(value));
    printf("%s: ", T("Device", "设备"));
    baseos_ui_print_line(value, 28);
    (void)read_value("/proc/uptime", value, sizeof(value));
    printf("%s: ", T("Uptime", "运行时间"));
    baseos_ui_print_line(value, 27);
    (void)read_value("/sys/class/power_supply/battery/status", value, sizeof(value));
    printf("%s: ", T("Battery", "电池"));
    baseos_ui_print_line(value, 28);
    (void)read_value("/sys/class/power_supply/battery/capacity", value, sizeof(value));
    printf("%s: ", T("Charge", "电量"));
    baseos_ui_print_line(value, 28);
    (void)read_value("/sys/class/thermal/thermal_zone0/temp", value, sizeof(value));
    printf("%s: ", T("CPU temp", "CPU 温度"));
    baseos_ui_print_line(value, 28);
    baseos_ui_print_line(T("Memory:", "内存："), 34);
    print_file("/proc/meminfo", 3, &row);
    baseos_ui_print_line(T("B: back", "B：返回"), 34);
}

static void render_help(void)
{
    render_header(T("Button mapping", "按键说明"));
    baseos_ui_print_line(T("D-pad / left stick: move", "方向键 / 左摇杆：移动"), 34);
    baseos_ui_print_line(T("A (right): select / open", "A（右侧）：确认 / 打开"), 34);
    baseos_ui_print_line(T("B (bottom): back", "B（下方）：返回"), 34);
    baseos_ui_print_line(T("L1/R1: shoulder buttons", "L1/R1：左/右肩键"), 34);
    baseos_ui_print_line(T("FUNCTION: live input monitor", "功能键：实时输入监视"), 34);
    baseos_ui_print_line(T("Volume +/-: adjust volume", "音量 +/-：调节音量"), 34);
    baseos_ui_print_line(T("Short Power: system information", "短按电源键：系统信息"), 34);
    baseos_ui_print_line(T("Hold Power 2s: clean shutdown", "长按电源键 2 秒：关机"), 34);
    baseos_ui_print_line(T("FUNCTION + Power at boot: USB", "开机时按住功能键：USB 存储"), 34);
    baseos_ui_print_line(T("B: back", "B：返回"), 34);
}

static void render(void)
{
    switch (current_screen) {
    case SCREEN_CONTROLS: render_controls(); break;
    case SCREEN_AUDIO: render_audio(); break;
    case SCREEN_WIFI: render_wifi(); break;
    case SCREEN_SYSTEM: render_system(); break;
    case SCREEN_HELP: render_help(); break;
    case SCREEN_HOME:
    default: render_home(); break;
    }
    fflush(stdout);
}

static void navigate_menu(int delta)
{
    int count = visible_menu_count();
    selected_item += delta;
    if (selected_item < 0) selected_item = count - 1;
    if (selected_item >= count) selected_item = 0;
    if (current_screen == SCREEN_HOME) render();
}

static void close_inputs(void)
{
    for (int i = 0; i < input_count; ++i) {
        if (inputs[i].fd >= 0) (void)close(inputs[i].fd);
        inputs[i].fd = -1;
    }
    input_count = 0;
}

static void open_frontend_selector(void)
{
    pid_t child;
    int status = 0;

    /* Only the active child may read gamepad events while a nested UI runs.
     * Otherwise queued presses are replayed by this parent after waitpid(). */
    close_inputs();
    (void)unlink("/run/baseos-frontend-selection");
    child = fork();
    if (child < 0) {
        discover_inputs();
        (void)snprintf(last_event, sizeof(last_event), "Could not start frontend selector");
        render();
        return;
    }
    if (child == 0) {
        pid_t manager;
        int manager_status = 0;
        (void)setenv("BASEOS_SELECTOR_RETURN_TO_DIAGNOSTICS", "1", 1);
        manager = fork();
        if (manager < 0) _exit(127);
        if (manager == 0) {
            execl("/usr/sbin/baseos-frontend-manager", "baseos-frontend-manager",
                  "catalog", (char *)NULL);
            _exit(127);
        }
        while (waitpid(manager, &manager_status, 0) < 0) {
            if (errno != EINTR) _exit(127);
        }
        if (!WIFEXITED(manager_status) || WEXITSTATUS(manager_status) != 0)
            _exit(1);
        execl("/usr/sbin/rg353ps-frontend-selector", "rg353ps-frontend-selector", (char *)NULL);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            discover_inputs();
            (void)snprintf(last_event, sizeof(last_event), "Frontend selector wait failed");
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
        (void)snprintf(last_event, sizeof(last_event), "Frontend selector failed; returned to diagnostics");
    else
        (void)snprintf(last_event, sizeof(last_event), "Returned from frontend selector");
    render();
}

static void request_usb_storage(void) {
    const char *supervised = getenv("BASEOS_DIAGNOSTIC_SUPERVISED");
    int direct_pause = return_to_selector &&
                       (supervised == NULL || strcmp(supervised, "1") != 0);
    pid_t child;
    int status = 0, child_done = 0, request_seen = 0;

    child = fork();
    if (child < 0) {
        (void)snprintf(last_event, sizeof(last_event), "Could not request USB storage mode");
        render();
        return;
    }
    if (child == 0) {
        (void)chdir("/");
        execl("/usr/sbin/baseos-usb-storage", "baseos-usb-storage", (char *)NULL);
        _exit(127);
    }
    if (!direct_pause) {
        (void)snprintf(last_event, sizeof(last_event),
                       "USB storage requested; waiting for safe frontend shutdown");
        render();
        return;
    }
    /* Selector-launched diagnostics have no session-supervisor pause loop.
     * Own the same request/pause handshake here; leave the exported volume
     * as the working directory before acknowledging that it is safe to unmount. */
    (void)chdir("/");
    (void)snprintf(last_event, sizeof(last_event),
                   "USB storage requested; preparing diagnostic pause");
    render();
    for (int i = 0; i < 150; ++i) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) { child_done = 1; break; }
        if (waited < 0 && errno != EINTR) { child_done = 1; status = 127 << 8; break; }
        if (access(USB_REQUEST_PATH, F_OK) == 0) { request_seen = 1; break; }
        (void)usleep(100000);
    }
    if (request_seen) {
        int pause_fd = open(USB_PAUSED_PATH, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (pause_fd < 0) {
            (void)kill(child, SIGTERM);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            (void)snprintf(last_event, sizeof(last_event),
                           "USB storage aborted: could not acknowledge diagnostic pause");
        } else {
            (void)close(pause_fd);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            (void)unlink(USB_PAUSED_PATH);
            (void)unlink(USB_REQUEST_PATH);
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
                (void)snprintf(last_event, sizeof(last_event),
                               "USB storage session finished; diagnostics resumed");
            else
                (void)snprintf(last_event, sizeof(last_event),
                               "USB storage failed; inspect /mnt/boot/rg353ps-usb-storage.log");
        }
    } else {
        if (!child_done) {
            (void)kill(child, SIGTERM);
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        }
        (void)snprintf(last_event, sizeof(last_event),
                       "USB storage did not reach the pause handshake; local storage was not exported");
    }
    render();
}
static void select_menu_item(void)
{
    switch (selected_item) {
    case 0: current_screen = SCREEN_CONTROLS; break;
    case 1: current_screen = SCREEN_AUDIO; break;
    case 2: current_screen = SCREEN_WIFI; break;
    case 3: current_screen = SCREEN_SYSTEM; break;
    case 4: current_screen = SCREEN_HELP; break;
    case 5:
        open_frontend_selector();
        return;
    case 6:
        request_usb_storage();
        return;
    case 7:
        if (baseos_ui_toggle_language() == 0)
            (void)snprintf(last_event, sizeof(last_event), "%s",
                baseos_ui_language_zh ? "已切换为简体中文。" : "Language changed to English.");
        else
            (void)snprintf(last_event, sizeof(last_event), "%s",
                T("Could not save ui_language in baseos.conf.", "无法保存语言设置。"));
        render();
        return;
    case 8:
        running = 0;
        return;
    default: current_screen = SCREEN_HOME; break;
    }
    render();
}

static void go_back(void)
{
    if (current_screen != SCREEN_HOME) {
        current_screen = SCREEN_HOME;
        render();
    }
}

static void handle_key_event(struct input_device *dev, const struct input_event *ev)
{
    const char *name = key_name(ev->code);
    char detail[100];
    if (ev->value == 1) {
        ++event_count;
        if (dev->role == ROLE_GAME)
            ++key_count;
    }
    if (name == NULL)
        (void)snprintf(detail, sizeof(detail), "KEY code %u", ev->code);
    else
        (void)snprintf(detail, sizeof(detail), "%s", name);

    if (dev->role == ROLE_FUNCTION) {
        if (ev->value == 1) {
            ++function_count;
            (void)snprintf(last_event, sizeof(last_event), "FUNCTION pressed (%s, code %u)", detail, ev->code);
            current_screen = current_screen == SCREEN_CONTROLS ? SCREEN_HOME : SCREEN_CONTROLS;
            render();
        } else if (ev->value == 0) {
            (void)snprintf(last_event, sizeof(last_event), "FUNCTION released (%s)", detail);
            if (current_screen == SCREEN_CONTROLS) render();
        }
        return;
    }
    if (dev->role == ROLE_VOLUME) {
        if ((ev->value == 1 || ev->value == 2) &&
            (ev->code == KEY_VOLUMEUP || ev->code == KEY_VOLUMEDOWN)) {
            (void)snprintf(last_event, sizeof(last_event),
                           "Volume %s detected; global playback hotkey service handles mixer",
                           ev->code == KEY_VOLUMEUP ? "UP" : "DOWN");
            render();
        }
        return;
    }
    if (dev->role == ROLE_POWER && ev->code == KEY_POWER) {
        if (ev->value == 1) {
            (void)snprintf(last_event, sizeof(last_event),
                           "POWER pressed: short tap shows status; global service handles 2s hold");
            current_screen = SCREEN_SYSTEM;
        } else if (ev->value == 0) {
            (void)snprintf(last_event, sizeof(last_event),
                           "POWER released; global service handles long-press shutdown");
        }
        if (ev->value == 0 || ev->value == 1) render();
        return;
    }
    if (dev->role != ROLE_GAME)
        return;

    (void)snprintf(last_event, sizeof(last_event), "%s %s", detail,
                   ev->value == 0 ? "released" : ev->value == 2 ? "repeating" : "pressed");
    if (ev->value == 1) {
        switch (ev->code) {
        case BTN_DPAD_UP:
            if (current_screen == SCREEN_HOME) { navigate_menu(-1); return; }
            break;
        case BTN_DPAD_DOWN:
            if (current_screen == SCREEN_HOME) { navigate_menu(1); return; }
            break;
        case BTN_EAST: /* Nintendo A, physically at the right. */
            if (current_screen == SCREEN_HOME) { select_menu_item(); return; }
            break;
        case BTN_SOUTH: /* Nintendo B, physically at the bottom. */
            if (current_screen != SCREEN_HOME) { go_back(); return; }
            break;
        default:
            break;
        }
    }
    render();
}

static int joy_direction(int value)
{
    if (value < 270) return 1;
    if (value > 750) return -1;
    return 0;
}

static void handle_axis_event(const struct input_event *ev)
{
    int direction;
    switch (ev->code) {
    case ABS_X: axis_x = ev->value; break;
    case ABS_Y:
        axis_y = ev->value;
        direction = joy_direction(ev->value);
        if (current_screen == SCREEN_HOME && direction != 0 && joy_y_direction == 0)
            navigate_menu(direction);
        joy_y_direction = direction;
        break;
    case ABS_RX: axis_rx = ev->value; break;
    case ABS_RY: axis_ry = ev->value; break;
    default: return;
    }
    ++event_count;
    (void)snprintf(last_event, sizeof(last_event), "AXIS code %u value %d", ev->code, ev->value);
    if (current_screen == SCREEN_CONTROLS) render();
}

static void handle_input(struct input_device *dev)
{
    struct input_event ev;
    ssize_t count;
    while ((count = read(dev->fd, &ev, sizeof(ev))) == (ssize_t)sizeof(ev)) {
        if (ev.type == EV_KEY) handle_key_event(dev, &ev);
        else if (ev.type == EV_ABS && dev->role == ROLE_STICK) handle_axis_event(&ev);
    }
    if (count < 0 && errno != EAGAIN && errno != EINTR) {
        (void)snprintf(last_event, sizeof(last_event), "Read error from %s: %s", dev->name, strerror(errno));
        render();
    }
}

static void handle_keyboard_byte(unsigned char ch, int *escape_state)
{
    if (*escape_state == 1) {
        *escape_state = ch == '[' ? 2 : 0;
        return;
    }
    if (*escape_state == 2) {
        *escape_state = 0;
        if (ch == 'A') navigate_menu(-1);
        else if (ch == 'B') navigate_menu(1);
        else if ((ch == 'C' || ch == 'D') && current_screen != SCREEN_HOME) go_back();
        return;
    }
    if (ch == 27) *escape_state = 1;
    else if (ch == 'q' || ch == 'Q') go_back();
    else if (ch == 'f' || ch == 'F') {
        current_screen = current_screen == SCREEN_CONTROLS ? SCREEN_HOME : SCREEN_CONTROLS;
        render();
    } else if (ch == '\n' || ch == '\r' || ch == ' ') {
        if (current_screen == SCREEN_HOME) select_menu_item();
        else go_back();
    } else if (ch == 'w' || ch == 'W') navigate_menu(-1);
    else if (ch == 's' || ch == 'S') navigate_menu(1);
}

int main(void)
{
    struct pollfd pollfds[MAX_INPUTS + 1];
    int stdin_active = 0;
    int escape_state = 0;

    (void)signal(SIGINT, stop_running);
    (void)signal(SIGTERM, stop_running);
    (void)signal(SIGHUP, stop_running);
    return_to_selector = getenv("BASEOS_RETURN_TO_SELECTOR") != NULL &&
                         strcmp(getenv("BASEOS_RETURN_TO_SELECTOR"), "1") == 0;
    baseos_ui_init();
    if (selected_item >= visible_menu_count()) selected_item = 0;
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

    (void)printf("\033[?25l");
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
            pollfds[nfds].fd = inputs[i].fd;
            pollfds[nfds].events = POLLIN;
            pollfds[nfds].revents = 0;
            ++nfds;
        }

        rc = poll(pollfds, (nfds_t)nfds, nfds == 0 ? 1000 : -1);
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
                    for (ssize_t i = 0; i < n; ++i) handle_keyboard_byte(bytes[i], &escape_state);
                }
                index = 1;
            }
            for (int i = 0; i < input_count; ++i) {
                if (inputs[i].fd >= 0 && (pollfds[index + i].revents & POLLIN) != 0)
                    handle_input(&inputs[i]);
                if (inputs[i].fd >= 0 &&
                    (pollfds[index + i].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
                    (void)close(inputs[i].fd);
                    inputs[i].fd = -1;
                }
            }
        }
    }

    if (termios_saved) (void)tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
    (void)printf("\033[0m\033[?25h\n");
    fflush(stdout);
    for (int i = 0; i < input_count; ++i)
        if (inputs[i].fd >= 0) (void)close(inputs[i].fd);
    return 0;
}
