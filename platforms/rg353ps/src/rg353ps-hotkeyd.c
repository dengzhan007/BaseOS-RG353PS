#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_INPUTS 64
#define NAME_LEN 128
#define PATH_LEN 256
#define POWER_HOLD_MS 2000
/* A release shorter than this is a sleep request, not a power-off. 900 ms keeps
   "hold to shut down" (2 s) unambiguous and still tolerates a slow tap. */
#define POWER_SHORT_MS 900
/* Below this the press is switch bounce or an accidental graze. */
#define POWER_MIN_MS 40
/* After the wake-up press, ignore power events for a moment: the release of the
   key that woke the unit is still queued in the evdev buffer and would
   otherwise be seen as a fresh press. */
#define RESUME_GUARD_MS 3000
#define SLEEP_SCRIPT "/usr/sbin/rg353ps-sleep"
/* Written by baseos-frontend-session once a frontend that claims the power key
   has started; it holds that frontend's pid. */
#define POWER_OWNER_FILE "/run/baseos-power-frontend"

enum device_role { ROLE_NONE = 0, ROLE_VOLUME, ROLE_POWER, ROLE_KEYS };
struct input_device { int fd; enum device_role role; char path[PATH_LEN]; char name[NAME_LEN]; };
static struct input_device inputs[MAX_INPUTS];
static int input_count;
static volatile sig_atomic_t running = 1;
static long long power_press_start_ms = -1;
static long long power_ignore_until_ms = 0;
static int function_down;
static int mode_down;
static int storage_latched;
static int startup_checked;
static int startup_key_release_seen;
static int cable_state_initialized;
static int cable_was_connected;
static int sd_log_active;
static char ignored_input_paths[MAX_INPUTS][PATH_LEN];
static int ignored_input_count;
static long long startup_wait_start_ms;
static long long keys_first_seen_ms = -1;
static int missing_keys_reported;
static int stale_report_removed;
#define BOOT_LOG_STAGE "/run/rg353ps-boot-key.log"
#define BOOT_LOG_FINAL "/mnt/SDCARD/rg353ps-boot-key.log"

/* Debug switch, shared with baseos-usb-storage: the card copy of baseos.conf
   wins over the one in /etc. This daemon starts before BASEOS_BOOT is mounted,
   so the answer has to be looked up when a message is written rather than once
   at startup; it is cached briefly because the flush below runs every loop. */
static int debug_logging_enabled(void);
#define BOOT_STORAGE_REQUEST "/run/baseos-usb-storage.boot-request"

static void stop_running(int sig) { (void)sig; running = 0; }
static int userdata_is_mounted(void) {
    FILE *fp = fopen("/proc/mounts", "r");
    char line[512];
    if (fp == NULL) return 0;
    while (fgets(line, sizeof(line), fp) != NULL) {
        char device[128], mountpoint[128], type[64];
        if (sscanf(line, "%127s %127s %63s", device, mountpoint, type) == 3 &&
            strcmp(mountpoint, "/mnt/SDCARD") == 0) {
            (void)fclose(fp);
            return 1;
        }
    }
    (void)fclose(fp);
    return 0;
}
static void flush_staged_log(void) {
    int in_fd, out_fd;
    char buf[1024];
    ssize_t n;
    if (!userdata_is_mounted()) return;
    /* With debug off this daemon writes nothing to the card. Drop whatever was
       staged before the card appeared, and clear a report left behind by an
       earlier build once, so the card does not keep a file nobody asked for. */
    if (!debug_logging_enabled()) {
        (void)unlink(BOOT_LOG_STAGE);
        if (!stale_report_removed) {
            (void)unlink(BOOT_LOG_FINAL);
            stale_report_removed = 1;
        }
        return;
    }

    in_fd = open(BOOT_LOG_STAGE, O_RDONLY | O_CLOEXEC);
    if (in_fd < 0) {
        if (sd_log_active) return;
        /* Start a fresh, compact report for this boot even if there was no
           pre-mount message to flush. */
        out_fd = open(BOOT_LOG_FINAL, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (out_fd >= 0) {
            (void)close(out_fd);
            sd_log_active = 1;
        }
        return;
    }
    /* First mount truncates the prior boot's report; after an unmount, staged
       messages are appended when BASEOS_DATA is mounted again. */
    out_fd = open(BOOT_LOG_FINAL, O_WRONLY | O_CREAT |
                  (sd_log_active ? O_APPEND : O_TRUNC) | O_CLOEXEC, 0644);
    if (out_fd < 0) { (void)close(in_fd); return; }
    while ((n = read(in_fd, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(out_fd, buf + off, (size_t)(n - off));
            if (w < 0) { if (errno == EINTR) continue; break; }
            off += w;
        }
    }
    (void)close(in_fd);
    (void)close(out_fd);
    (void)unlink(BOOT_LOG_STAGE);
    sd_log_active = 1;
}

static long long monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}
/* Read key=<value> from a shell-style config file. Returns 1 for yes/on/1,
   0 for anything else, -1 when the file or the key is absent. */
static int config_flag_yes(const char *path, const char *key) {
    FILE *fp = fopen(path, "r");
    char line[256];
    if (fp == NULL) return -1;
    while (fgets(line, sizeof(line), fp) != NULL) {
        char *eq = strchr(line, '=');
        char *value;
        int yes;
        if (eq == NULL) continue;
        *eq = '\0';
        if (strcmp(line, key) != 0) continue;
        value = eq + 1;
        while (*value == ' ' || *value == '\t') value++;
        value[strcspn(value, " \t\r\n")] = '\0';
        yes = (strcmp(value, "yes") == 0 || strcmp(value, "YES") == 0 ||
               strcmp(value, "1") == 0 || strcmp(value, "on") == 0);
        (void)fclose(fp);
        return yes ? 1 : 0;
    }
    (void)fclose(fp);
    return -1;
}
static int debug_logging_enabled(void) {
    static int cached = -1;
    static long long checked_ms = -1;
    long long now = monotonic_ms();
    int r;
    /* Neither the user partition nor BASEOS_BOOT is mounted for the first few
       seconds of every boot, so a value cached from /etc alone would outlive
       the card's own answer. The user partition wins because it is the only
       volume a PC still shows. */
    if (cached >= 0 && checked_ms >= 0 && now - checked_ms < 2000) return cached;
    r = config_flag_yes("/mnt/SDCARD/baseos.conf", "debug");
    if (r < 0) r = config_flag_yes("/mnt/boot/baseos.conf", "debug");
    if (r < 0) r = config_flag_yes("/etc/baseos.conf", "debug");
    cached = (r > 0) ? 1 : 0;
    checked_ms = now;
    return cached;
}
static int keep_persistent_log_message(const char *message) {
    /* Keep the removable-card report focused on startup decisions and hotkey
       events. Full input enumeration remains available in the kernel log. */
    if (strstr(message, "started; boot-key") != NULL ||
        strstr(message, "BOOT_KEY_CHECK") != NULL ||
        strstr(message, "ROLE_KEYS device found") != NULL ||
        strstr(message, "boot storage gate") != NULL ||
        strstr(message, "entering USB storage mode") != NULL ||
        strstr(message, "USB storage mode finished") != NULL ||
        strstr(message, "USB storage helper exited") != NULL ||
        strstr(message, "boot-triggered USB storage session returned") != NULL ||
        strstr(message, "read error") != NULL ||
        strstr(message, "poll failed") != NULL ||
        strstr(message, "cannot fork USB storage mode") != NULL ||
        strstr(message, "waitpid failed for USB storage mode") != NULL ||
        strstr(message, "mapped=FUNCTION") != NULL ||
        strstr(message, "mapped=MODE") != NULL)
        return 1;
    return 0;
}

static void log_message(const char *message) {
    char line[512];
    int fd;
    int n = snprintf(line, sizeof(line), "rg353ps-hotkeyd: %s\n", message);
    fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        if (n > 0) (void)write(fd, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line)-1);
        (void)close(fd);
    }
    if (n > 0 && keep_persistent_log_message(message) && debug_logging_enabled()) {
        /* BASEOS_DATA is deliberately unmounted while it is exported over USB.
           Never write through the now-unmounted /mnt/SDCARD mountpoint into
           the system rootfs; stage those messages in tmpfs and flush on return. */
        const char *path = userdata_is_mounted() ? BOOT_LOG_FINAL : BOOT_LOG_STAGE;
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (fd >= 0) {
            (void)write(fd, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line)-1);
            (void)close(fd);
        }
    }
}
static enum device_role role_for_name(const char *name) {
    if (strstr(name, "gpio-keys-vol") != NULL) return ROLE_VOLUME;
    if (strcmp(name, "rk805 pwrkey") == 0) return ROLE_POWER;
    if (strstr(name, "gpio-keys") != NULL || strstr(name, "gpio_keys") != NULL ||
        strstr(name, "adc-keys") != NULL)
        return ROLE_KEYS;
    return ROLE_NONE;
}
static int usb_cable_connected(void) {
    DIR *dir;
    struct dirent *entry;
    char path[PATH_LEN], value[64];

    /* When the OTG port is connected to a PC, the UDC state is the most
       direct signal even if usb_role/extcon is absent or reports host mode. */
    dir = opendir("/sys/class/udc");
    if (dir != NULL) {
        while ((entry = readdir(dir)) != NULL) {
            FILE *fp;
            if (entry->d_name[0] == '.') continue;
            (void)snprintf(path, sizeof(path), "/sys/class/udc/%s/state", entry->d_name);
            fp = fopen(path, "r");
            if (fp != NULL) {
                if (fgets(value, sizeof(value), fp) != NULL) {
                    value[strcspn(value, "\r\n")] = '\0';
                    if (strcmp(value, "attached") == 0 || strcmp(value, "powered") == 0 ||
                        strcmp(value, "default") == 0 || strcmp(value, "addressed") == 0 ||
                        strcmp(value, "configured") == 0 || strcmp(value, "suspended") == 0) {
                        (void)fclose(fp); (void)closedir(dir); return 1;
                    }
                }
                (void)fclose(fp);
            }
        }
        (void)closedir(dir);
    }

    dir = opendir("/sys/class/usb_role");
    if (dir != NULL) {
        while ((entry = readdir(dir)) != NULL) {
            FILE *fp;
            if (entry->d_name[0] == '.') continue;
            (void)snprintf(path, sizeof(path), "/sys/class/usb_role/%s/role", entry->d_name);
            fp = fopen(path, "r");
            if (fp != NULL) {
                if (fgets(value, sizeof(value), fp) != NULL &&
                    (strstr(value, "device") != NULL || strstr(value, "peripheral") != NULL)) {
                    (void)fclose(fp); (void)closedir(dir); return 1;
                }
                (void)fclose(fp);
            }
        }
        (void)closedir(dir);
    }
    dir = opendir("/sys/class/extcon");
    if (dir != NULL) {
        while ((entry = readdir(dir)) != NULL) {
            const char *cables[] = {"cable.USB/state", "cable.USB-DEVICE/state"};
            if (entry->d_name[0] == '.') continue;
            for (size_t i = 0; i < sizeof(cables)/sizeof(cables[0]); ++i) {
                FILE *fp;
                (void)snprintf(path, sizeof(path), "/sys/class/extcon/%s/%s", entry->d_name, cables[i]);
                fp = fopen(path, "r");
                if (fp != NULL) {
                    if (fgets(value, sizeof(value), fp) != NULL && value[0] == '1') {
                        (void)fclose(fp); (void)closedir(dir); return 1;
                    }
                    (void)fclose(fp);
                }
            }
        }
        (void)closedir(dir);
    }
    return 0;
}
static int enter_usb_storage_mode(int boot_mode) {
    pid_t child = fork();
    int status;
    if (child < 0) { log_message("cannot fork USB storage mode"); return 0; }
    if (child == 0) {
        if (boot_mode)
            execl("/usr/sbin/baseos-usb-storage", "baseos-usb-storage", "--boot", (char *)NULL);
        else
            execl("/usr/sbin/baseos-usb-storage", "baseos-usb-storage", (char *)NULL);
        _exit(127);
    }
    log_message(boot_mode ? "Function/Mode held at startup; entering USB storage mode" :
                "Function/Mode held while USB cable is connected; entering USB storage mode");
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) continue;
        log_message("waitpid failed for USB storage mode");
        return 0;
    }
    log_message("USB storage mode finished");
    if (WIFEXITED(status)) {
        char result_msg[128];
        int exit_status = WEXITSTATUS(status);
        (void)snprintf(result_msg, sizeof(result_msg),
                       "USB storage helper exited status=%d", exit_status);
        log_message(result_msg);
        return exit_status == 0;
    }
    if (WIFSIGNALED(status)) {
        char result_msg[128];
        (void)snprintf(result_msg, sizeof(result_msg),
                       "USB storage helper exited by signal=%d", WTERMSIG(status));
        log_message(result_msg);
    } else {
        log_message("USB storage helper exited without a normal process status");
    }
    return 0;
}
static int already_open(const char *path) {
    for (int i=0; i<input_count; ++i)
        if (inputs[i].fd >= 0 && strcmp(inputs[i].path,path)==0) return 1;
    return 0;
}
static void discover_inputs(void) {
    DIR *dir = opendir("/dev/input");
    struct dirent *entry;
    if (dir == NULL) return;
    while ((entry = readdir(dir)) != NULL && input_count < MAX_INPUTS) {
        char path[PATH_LEN], name[NAME_LEN] = "unknown input";
        int fd;
        enum device_role role;
        struct input_device *dev;
        if (strncmp(entry->d_name,"event",5)!=0) continue;
        if (snprintf(path,sizeof(path),"/dev/input/%s",entry->d_name)>=(int)sizeof(path)) continue;
        if (already_open(path)) continue;
        fd=open(path,O_RDONLY|O_NONBLOCK|O_CLOEXEC);
        if(fd<0) continue;
        if(ioctl(fd,EVIOCGNAME(sizeof(name)-1),name)<0) { (void)close(fd); continue; }
        name[sizeof(name)-1]='\0';
        role=role_for_name(name);
        if(role==ROLE_NONE) {
            int seen = 0;
            for (int k = 0; k < ignored_input_count; ++k)
                if (strcmp(ignored_input_paths[k], path) == 0) { seen = 1; break; }
            if (!seen) {
                char msg[256];
                (void)snprintf(msg, sizeof(msg), "input device not assigned a hotkey role: %s (%s)", path, name);
                log_message(msg);
                if (ignored_input_count < MAX_INPUTS)
                    (void)snprintf(ignored_input_paths[ignored_input_count++], PATH_LEN, "%s", path);
            }
            (void)close(fd);
            continue;
        }
        dev=&inputs[input_count++];
        dev->fd=fd; dev->role=role;
        (void)snprintf(dev->path,sizeof(dev->path),"%s",path);
        (void)snprintf(dev->name,sizeof(dev->name),"%s",name);
        if (role == ROLE_KEYS) {
            unsigned long key_bits[(KEY_MAX + (sizeof(unsigned long) * 8)) /
                                   (sizeof(unsigned long) * 8)];
            memset(key_bits, 0, sizeof(key_bits));
            if (ioctl(fd, EVIOCGKEY(sizeof(key_bits)), key_bits) >= 0) {
                char pressed[256];
                size_t used = 0;
                int listed = 0;
                pressed[0] = '\0';
                for (int code = 0; code <= KEY_MAX; ++code) {
                    if (key_bits[code / (sizeof(unsigned long) * 8)] &
                        (1UL << (code % (sizeof(unsigned long) * 8)))) {
                        int n = snprintf(pressed + used, sizeof(pressed) - used,
                                         "%s%d", listed ? "," : "", code);
                        if (n > 0 && (size_t)n < sizeof(pressed) - used) {
                            used += (size_t)n;
                            listed = 1;
                        }
                    }
                }
                {
                    char msg[384];
                    (void)snprintf(msg, sizeof(msg),
                        "EVIOCGKEY snapshot for %s: pressed_linux_key_codes=%s",
                        path, listed ? pressed : "(none)");
                    log_message(msg);
                }
                int fn = (key_bits[KEY_F1 / (sizeof(unsigned long) * 8)] &
                          (1UL << (KEY_F1 % (sizeof(unsigned long) * 8)))) != 0;
#ifdef KEY_FN
                fn = fn || ((key_bits[KEY_FN / (sizeof(unsigned long) * 8)] &
                             (1UL << (KEY_FN % (sizeof(unsigned long) * 8)))) != 0);
#endif
                /* RG353PS physical Function key is reported as BTN_MODE (316). */
                fn = fn || ((key_bits[BTN_MODE / (sizeof(unsigned long) * 8)] &
                             (1UL << (BTN_MODE % (sizeof(unsigned long) * 8)))) != 0);
                int mode = (key_bits[KEY_MODE / (sizeof(unsigned long) * 8)] &
                            (1UL << (KEY_MODE % (sizeof(unsigned long) * 8)))) != 0;
                mode = mode || ((key_bits[KEY_MENU / (sizeof(unsigned long) * 8)] &
                                 (1UL << (KEY_MENU % (sizeof(unsigned long) * 8)))) != 0);
                function_down = function_down || fn;
                mode_down = mode_down || mode;
                if (fn || mode) log_message("Function/Mode is already held when input device opens");
            }
        }
        {
            char msg[200];
            (void)snprintf(msg,sizeof(msg),"watching %s (%s)",path,name);
            log_message(msg);
        }
    }
    (void)closedir(dir);
}
static int adjust_playback_volume(int up) {
    pid_t child=fork();
    int status;
    if(child<0) { log_message("fork failed while adjusting volume"); return 0; }
    if(child==0) {
        int nullfd=open("/dev/null",O_WRONLY);
        if(nullfd>=0) {
            (void)dup2(nullfd,STDOUT_FILENO); (void)dup2(nullfd,STDERR_FILENO);
            if(nullfd>STDERR_FILENO) (void)close(nullfd);
        }
        execl("/usr/bin/amixer","amixer","-c","1","set","Master","playback",up?"5%+":"5%-",(char *)NULL);
        execl("/bin/amixer","amixer","-c","1","set","Master","playback",up?"5%+":"5%-",(char *)NULL);
        _exit(127);
    }
    while(waitpid(child,&status,0)<0) {
        if(errno==EINTR) continue;
        log_message("waitpid failed while adjusting volume"); return 0;
    }
    if(WIFEXITED(status)&&WEXITSTATUS(status)==0) {
        log_message(up?"volume up: playback changed by 5%":"volume down: playback changed by 5%");
        return 1;
    }
    log_message(up?"volume up failed: amixer returned an error":"volume down failed: amixer returned an error");
    return 0;
}
/* Deep sleep is delegated to /usr/sbin/rg353ps-sleep, which owns the
   unbind -> mem -> rebind sequence. Staying in waitpid() while the script runs
   is deliberate: the event loop must not process power events during the
   sleep, and the daemon has nothing else to do until the unit wakes. */
/* A frontend that declares "baseos: power-owned" in its launch script handles
   the power key itself while it runs, because only it knows how to flush its
   own state. The supervisor publishes that frontend's pid here and removes the
   file when the frontend exits or is paused, so a crashed or finished frontend
   hands the key straight back to this daemon. */
static int frontend_owns_power(void) {
    char buf[32];
    long pid = 0;
    int fd = open(POWER_OWNER_FILE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    (void)close(fd);
    if (n <= 0) return 0;
    buf[n] = '\0';
    if (sscanf(buf, "%ld", &pid) != 1 || pid <= 0) return 0;
    return kill((pid_t)pid, 0) == 0;
}

static void enter_deep_sleep(void) {    pid_t child;
    int status = 0;
    if (access(SLEEP_SCRIPT, X_OK) != 0) {
        log_message("sleep script missing or not executable; ignoring short press");
        return;
    }
    child = fork();
    if (child < 0) {
        log_message("fork failed; cannot enter deep sleep");
        return;
    }
    if (child == 0) {
        int nullfd = open("/dev/null", O_RDWR);
        if (nullfd >= 0) {
            (void)dup2(nullfd, STDIN_FILENO);
            (void)dup2(nullfd, STDOUT_FILENO);
            (void)dup2(nullfd, STDERR_FILENO);
            if (nullfd > STDERR_FILENO) (void)close(nullfd);
        }
        execl(SLEEP_SCRIPT, "rg353ps-sleep", (char *)NULL);
        _exit(127);
    }
    log_message("power key released short; entering deep sleep");
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) {
            if (!running) break;
            continue;
        }
        status = 0;
        break;
    }
    power_press_start_ms = -1;
    power_ignore_until_ms = monotonic_ms() + RESUME_GUARD_MS;
    if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
        log_message("deep sleep ended with an error status; see /var/log/rg353ps-sleep.log");
    else
        log_message("woke from deep sleep");
}

static void handle_input(struct input_device *dev) {
    struct input_event ev;
    ssize_t count;
    while((count=read(dev->fd,&ev,sizeof(ev)))==(ssize_t)sizeof(ev)) {
        if(ev.type!=EV_KEY) continue;
        if(dev->role==ROLE_VOLUME) {
            if((ev.value==1||ev.value==2)&&(ev.code==KEY_VOLUMEUP||ev.code==KEY_VOLUMEDOWN))
                (void)adjust_playback_volume(ev.code==KEY_VOLUMEUP);
        } else if(dev->role==ROLE_POWER&&ev.code==KEY_POWER) {
            long long now = monotonic_ms();
            if (frontend_owns_power()) {
                /* The running frontend owns short taps and the hold. Clear the
                   press state so the first press after it hands the key back is
                   not read as a continuation of this one. */
                power_press_start_ms = -1;
                continue;
            }
            if(now < power_ignore_until_ms) {
                /* Still inside the post-resume guard window. Drop whatever the
                   kernel queued while we were asleep. */
                power_press_start_ms = -1;
                continue;
            }
            if(ev.value==1) {
                if(power_press_start_ms<0) power_press_start_ms=now;
            } else if(ev.value==0) {
                long long held = power_press_start_ms>=0 ? now-power_press_start_ms : -1;
                power_press_start_ms=-1;
                if(held>=POWER_MIN_MS && held<POWER_SHORT_MS) enter_deep_sleep();
            }
        } else if (dev->role == ROLE_KEYS && ev.type == EV_KEY) {
            int down = (ev.value != 0);
            char msg[192];
            (void)snprintf(msg, sizeof(msg),
                "KEY_EVENT device=%s code=%u value=%d%s%s",
                dev->name, ev.code, ev.value,
                (ev.code == KEY_F1 || ev.code == KEY_FN || ev.code == BTN_MODE) ? " mapped=FUNCTION" :
                (ev.code == KEY_MODE || ev.code == KEY_MENU) ? " mapped=MODE" : "",
                down ? " state=DOWN" : " state=UP");
            log_message(msg);
            if (ev.code == KEY_F1 || ev.code == KEY_FN || ev.code == BTN_MODE) function_down = down;
            if (ev.code == KEY_MODE || ev.code == KEY_MENU) mode_down = down;
        }
    }
    if(count<0&&errno!=EAGAIN&&errno!=EINTR) {
        char msg[200];
        (void)snprintf(msg,sizeof(msg),"read error on %s: %s",dev->path,strerror(errno));
        log_message(msg);
    }
}
int main(void) {
    struct pollfd pollfds[MAX_INPUTS];
    (void)signal(SIGINT,stop_running); (void)signal(SIGTERM,stop_running); (void)signal(SIGHUP,stop_running);
    (void)setsid();
    (void)unlink(BOOT_LOG_STAGE);
    sd_log_active = 0;
    startup_wait_start_ms = monotonic_ms();
    /* BASEOS_BOOT is not mounted yet, so this first answer can only reflect
       /etc/baseos.conf. The card's own setting takes effect a couple of seconds
       later, once the flush below can read it. */
    if (debug_logging_enabled())
        log_message("started; boot-key report enabled by debug=yes; target=" BOOT_LOG_FINAL);
    else
        log_message("started; boot-key report off; set debug=yes in baseos.conf on the card to enable");
    while(running) {
        int nfds=0, rc;
        discover_inputs();
        flush_staged_log();
        if (!startup_checked) {
            int key_device_found = 0;
            for (int i = 0; i < input_count; ++i) {
                if (inputs[i].fd >= 0 && inputs[i].role == ROLE_KEYS) {
                    key_device_found = 1;
                    break;
                }
            }
            /* Do not consume the one-shot boot-key check before gpio-keys
               exists. On this board input devices may appear after daemon
               startup; discover_inputs() will retry on subsequent loops. */
            if (!key_device_found && !missing_keys_reported &&
                monotonic_ms() - startup_wait_start_ms >= 5000) {
                log_message("BOOT_KEY_CHECK result=not_sampled reason=no_ROLE_KEYS_input_device_found_after_5_seconds; continuing to monitor");
                missing_keys_reported = 1;
            }
            if (key_device_found && keys_first_seen_ms < 0) {
                keys_first_seen_ms = monotonic_ms();
                log_message("ROLE_KEYS device found; waiting 1500ms to collect startup key events");
            }
            /* adc-keys can register after gpio-keys-control. Keep polling all
               key devices briefly before making the one-shot boot decision. */
            if (key_device_found && keys_first_seen_ms >= 0 &&
                monotonic_ms() - keys_first_seen_ms >= 1500) {
                char boot_msg[256];
                startup_checked = 1;
                startup_key_release_seen = !(function_down || mode_down);
                /* Publish the storage gate before rcS sees READY; otherwise
                   tty1 can launch NextUI over the storage prompt. */
                if (function_down) {
                    int request = open(BOOT_STORAGE_REQUEST, O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0600);
                    if (request >= 0) {
                        close(request);
                        log_message("boot storage gate enabled before startup-ready signal");
                    } else {
                        log_message("WARNING: could not create boot storage gate");
                    }
                }
                {
                    int ready = open("/run/rg353ps-hotkeyd.ready", O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0600);
                    if (ready >= 0) close(ready);
                }
                if (function_down) {
                    (void)snprintf(boot_msg, sizeof(boot_msg),
                        "BOOT_KEY_CHECK result=sampled key_device_found=1 function_down=1 mode_down=%d decision=USB_STORAGE",
                        mode_down);
                    log_message(boot_msg);
                    storage_latched = 1;
                    if (enter_usb_storage_mode(1)) {
                        (void)unlink(BOOT_STORAGE_REQUEST);
                        log_message("boot-triggered USB storage session returned successfully; boot storage gate cleared");
                    } else {
                        /* Do not silently launch the frontend over a failed
                           Function-triggered storage attempt. The failure
                           stays visible and the user can retry by reconnecting
                           the cable with Function held, or reboot normally. */
                        log_message("boot-triggered USB storage failed; keeping boot storage gate active to prevent frontend launch");
                    }
                } else {
                    (void)snprintf(boot_msg, sizeof(boot_msg),
                        "BOOT_KEY_CHECK result=sampled key_device_found=1 function_down=0 mode_down=%d decision=NORMAL_BOOT",
                        mode_down);
                    log_message(boot_msg);
                    log_message("normal boot; hold Function while powering on to enter USB storage, then connect the data cable when prompted");
                }
            }
        }
        for(int i=0;i<input_count;++i) {
            if(inputs[i].fd<0) continue;
            pollfds[nfds].fd=inputs[i].fd; pollfds[nfds].events=POLLIN; pollfds[nfds].revents=0; ++nfds;
        }
        {
            int timeout=100;
            if(power_press_start_ms>=0) {
                long long left=POWER_HOLD_MS-(monotonic_ms()-power_press_start_ms);
                timeout=left>0?(int)left:0;
            }
            rc=poll(pollfds,(nfds_t)nfds,timeout);
        }
        if(rc<0) {
            if(errno==EINTR) continue;
            log_message("poll failed; retrying");
            { struct timespec pause={0,100000000L}; (void)nanosleep(&pause,NULL); }
            continue;
        }
        if(power_press_start_ms>=0&&monotonic_ms()-power_press_start_ms>=POWER_HOLD_MS) {
            power_press_start_ms=-1;
            log_message("power held for 2 seconds; syncing and powering off");
            sync();
            execl("/sbin/poweroff","poweroff",(char *)NULL);
            log_message("poweroff command failed");
        }
        if (startup_checked && !(function_down || mode_down))
            startup_key_release_seen = 1;
        {
            int cable_now = usb_cable_connected();
            if (!cable_state_initialized) {
                cable_was_connected = cable_now;
                cable_state_initialized = 1;
            } else if (startup_key_release_seen && !storage_latched &&
                       function_down && cable_now && !cable_was_connected) {
                storage_latched = 1;
                (void)enter_usb_storage_mode(0);
            }
            cable_was_connected = cable_now;
        }
        if (!(function_down || mode_down))
            storage_latched = 0;
        if(rc==0) continue;
        {
            int p=0;
            for(int i=0;i<input_count;++i) {
                if(inputs[i].fd<0) continue;
                if((pollfds[p].revents&POLLIN)!=0) handle_input(&inputs[i]);
                if((pollfds[p].revents&(POLLHUP|POLLERR|POLLNVAL))!=0) {
                    (void)close(inputs[i].fd); inputs[i].fd=-1;
                }
                ++p;
            }
        }
    }
    for(int i=0;i<input_count;++i) if(inputs[i].fd>=0) (void)close(inputs[i].fd);
    log_message("stopped");
    return 0;
}
