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

#define MAX_INPUTS 32
#define MAX_FRONTENDS 64
#define ID_LEN 64
#define LABEL_LEN 160
#define PACKAGE_LEN 32
#define PROFILE_LEN 32
#define ROOT_LEN 32
#define PATH_LEN 320
#define CATALOG_PATH "/run/baseos-frontend-catalog"
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
    int priority;
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
static struct termios saved_termios;
static int termios_saved;
static int stdin_active;

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

static int load_catalog(void)
{
    FILE *fp = fopen(CATALOG_PATH, "r");
    char line[1200];
    entry_count = 0;
    if (fp == NULL) return 0;

    while (entry_count < MAX_FRONTENDS && fgets(line, sizeof(line), fp) != NULL) {
        char *fields[8];
        char *save = NULL;
        char *token;
        int count = 0;
        size_t len = strlen(line);
        if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
        if (len > 0 && line[len - 1] == '\r') line[--len] = '\0';
        token = strtok_r(line, "|", &save);
        while (token != NULL && count < 8) {
            fields[count++] = token;
            token = strtok_r(NULL, "|", &save);
        }
        if (count != 8 || token != NULL) continue;

        struct frontend_entry *entry = &entries[entry_count];
        memset(entry, 0, sizeof(*entry));
        if (!copy_field(entry->id, sizeof(entry->id), fields[0]) ||
            !copy_field(entry->label, sizeof(entry->label), fields[1]) ||
            !copy_field(entry->package_id, sizeof(entry->package_id), fields[2]) ||
            !copy_field(entry->profile_id, sizeof(entry->profile_id), fields[3]) ||
            !copy_field(entry->root, sizeof(entry->root), fields[4]) ||
            !copy_field(entry->package_dir, sizeof(entry->package_dir), fields[5]) ||
            !copy_field(entry->profile_config, sizeof(entry->profile_config), fields[6]))
            continue;
        entry->priority = atoi(fields[7]);
        ++entry_count;
    }
    (void)fclose(fp);
    if (selected_item >= entry_count) selected_item = entry_count > 0 ? entry_count - 1 : 0;
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
    const int visible = 10;
    if (selected_item < scroll_offset) scroll_offset = selected_item;
    if (selected_item >= scroll_offset + visible) scroll_offset = selected_item - visible + 1;
    if (scroll_offset < 0) scroll_offset = 0;
}

static void render_header(const char *title)
{
    (void)printf("\033[2J\033[H\033[?25l");
    (void)printf("\033[1;36m+------------------------------------------------------------------------------+\033[0m\n");
    (void)printf("\033[1;36m| %-76.76s |\033[0m\n", title);
    (void)printf("\033[1;36m+------------------------------------------------------------------------------+\033[0m\n");
}

static int count_package_profiles(const char *package_id)
{
    int count = 0;
    for (int i = 0; i < entry_count; ++i)
        if (strcmp(entries[i].package_id, package_id) == 0) ++count;
    return count;
}

static void render(void)
{
    adjust_scroll();
    if (confirming_uninstall) {
        struct frontend_entry *entry = entry_count > 0 ? &entries[selected_item] : NULL;
        render_header("BaseOS  |  Confirm removal");
        if (entry == NULL) {
            (void)printf("\n  No frontend package is selected.\n");
        } else {
            (void)printf("\n  Package: %-62.62s\n", entry->package_id);
            (void)printf("  Selected profile: %-53.53s\n", entry->profile_id);
            (void)printf("  Profiles in this package: %-46d\n", count_package_profiles(entry->package_id));
            if (uninstall_package_action) {
                (void)printf("\n  REMOVE THE ENTIRE FRONTEND PACKAGE.\n");
                (void)printf("  All profiles and the shared program payload will be deleted.\n");
            } else {
                (void)printf("\n  Remove only the selected profile/configuration.\n");
                (void)printf("  The shared program remains if other profiles still exist.\n");
            }
            (void)printf("  All instance settings/data, Games/, Saves/ and shared cores stay.\n");
        }
        (void)printf("\n  A: confirm removal     B: cancel\n");
        fflush(stdout);
        return;
    }

    render_header("BaseOS  |  Frontend selector");
    (void)printf("\n  Select a frontend profile. Profiles from one package use separate settings.\n\n");
    if (entry_count == 0) {
        (void)printf("  No managed Frontends packages were found.\n");
        (void)printf("  Extract a package into /mnt/SDCARD/Frontends/<package-id>/.\n");
        (void)printf("\n  B: continue with the configured/default frontend\n");
    } else {
        (void)printf("  INSTALLED PROFILES\n");
        for (int i = scroll_offset; i < entry_count && i < scroll_offset + 10; ++i) {
            if (i == selected_item)
                (void)printf("  \033[1;32m> %-72.72s\033[0m\n", entries[i].label);
            else
                (void)printf("    %-72.72s\n", entries[i].label);
            (void)printf("      package=%-24.24s profile=%-18.18s source=%s\n",
                         entries[i].package_id, entries[i].profile_id,
                         strcmp(entries[i].root, "/mnt/TF2") == 0 ? "TF2" : "TF1");
        }
        (void)printf("\n  Selected ID: %s\n", entries[selected_item].id);
        (void)printf("  A: launch once    START: set default + launch\n");
        (void)printf("  Y: remove selected profile    X: uninstall entire frontend\n");
        (void)printf("  B: cancel and use the configured/default frontend\n");
        if (entry_count > 10)
            (void)printf("  Showing %d-%d of %d profiles\n", scroll_offset + 1,
                         scroll_offset + 10 < entry_count ? scroll_offset + 10 : entry_count,
                         entry_count);
    }
    (void)printf("\n  %s\n", status_line);
    (void)printf("  D-pad UP/DOWN to move.\n");
    fflush(stdout);
}

static void choose_launch(int set_default)
{
    if (entry_count <= 0) return;
    if (set_default) {
        int rc = run_manager("set-default", entries[selected_item].id);
        if (rc != 0) {
            (void)snprintf(status_line, sizeof(status_line), "Could not save default (manager exit %d).", rc);
            render();
            return;
        }
    }
    if (!write_selection(entries[selected_item].id)) {
        (void)snprintf(status_line, sizeof(status_line), "Could not write the one-time selection.");
        render();
        return;
    }
    running = 0;
}

static void uninstall_selected(void)
{
    int rc;
    char package[PACKAGE_LEN];
    char profile[PROFILE_LEN];
    int remove_package = uninstall_package_action;
    if (entry_count <= 0) return;
    (void)snprintf(package, sizeof(package), "%s", entries[selected_item].package_id);
    (void)snprintf(profile, sizeof(profile), "%s", entries[selected_item].profile_id);
    rc = run_manager(remove_package ? "uninstall-package" : "uninstall", entries[selected_item].id);
    if (rc != 0) {
        (void)snprintf(status_line, sizeof(status_line), "Uninstall failed (manager exit %d).", rc);
        confirming_uninstall = 0;
        render();
        return;
    }
    if (remove_package) {
        (void)snprintf(status_line, sizeof(status_line),
                       "Uninstalled frontend %s. Profile instance data and shared content were kept.", package);
    } else {
        (void)snprintf(status_line, sizeof(status_line),
                       "Removed profile %s/%s. Shared program/data were preserved.", package, profile);
    }
    confirming_uninstall = 0;
    uninstall_package_action = 0;
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
        if (entry_count > 0 && selected_item > 0) --selected_item;
        render();
        break;
    case BTN_DPAD_DOWN:
        if (entry_count > 0 && selected_item + 1 < entry_count) ++selected_item;
        render();
        break;
    case BTN_EAST:
        choose_launch(0);
        break;
    case BTN_START:
        choose_launch(1);
        break;
    case BTN_WEST: /* Y: remove this profile only. */
        if (entry_count > 0) {
            uninstall_package_action = 0;
            confirming_uninstall = 1;
            render();
        }
        break;
    case BTN_NORTH: /* X: remove the entire frontend package. */
        if (entry_count > 0) {
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
    (void)printf("\033[0m\033[2J\033[H\033[?25h");
    fflush(stdout);
    for (int i = 0; i < input_count; ++i)
        if (inputs[i].fd >= 0) (void)close(inputs[i].fd);
    return 0;
}
