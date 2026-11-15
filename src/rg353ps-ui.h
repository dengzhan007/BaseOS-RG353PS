#ifndef RG353PS_BASEOS_UI_H
#define RG353PS_BASEOS_UI_H

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define BASEOS_UI_CONFIG "/mnt/SDCARD/baseos.conf"
#define BASEOS_UI_CONFIG_TMP "/mnt/SDCARD/.baseos-ui.conf.tmp"
#define BASEOS_UI_FONT "/usr/share/consolefonts/baseos-cjk-16.psf"

static int baseos_ui_language_zh = 1;

static const char *baseos_ui_text(const char *english, const char *chinese)
{
    return baseos_ui_language_zh ? chinese : english;
}

static void baseos_ui_print_cells(const char *value, unsigned int max_cells)
{
    const unsigned char *p = (const unsigned char *)(value ? value : "");
    unsigned int cells = 0;

    while (*p != '\0' && cells < max_cells) {
        size_t count = 1;
        if ((*p & 0xe0u) == 0xc0u) count = 2;
        else if ((*p & 0xf0u) == 0xe0u) count = 3;
        else if ((*p & 0xf8u) == 0xf0u) count = 4;

        for (size_t i = 1; i < count; ++i) {
            if (p[i] == '\0' || (p[i] & 0xc0u) != 0x80u) {
                count = 1;
                break;
            }
        }
        (void)fwrite(p, 1, count, stdout);
        p += count;
        ++cells;
    }
}

static void baseos_ui_print_line(const char *value, unsigned int max_cells)
{
    baseos_ui_print_cells(value, max_cells);
    (void)putchar('\n');
}

static void baseos_ui_load_language(void)
{
    FILE *fp = fopen(BASEOS_UI_CONFIG, "r");
    char line[1024];

    /* New RG353PS installations default to Simplified Chinese. */
    baseos_ui_language_zh = 1;
    if (fp == NULL) return;

    while (fgets(line, sizeof(line), fp) != NULL) {
        if (strncmp(line, "ui_language=", 12) != 0) continue;
        if (strncmp(line + 12, "en", 2) == 0) baseos_ui_language_zh = 0;
        else if (strncmp(line + 12, "zh", 2) == 0) baseos_ui_language_zh = 1;
    }
    (void)fclose(fp);
}

static int baseos_ui_save_language(int use_chinese)
{
    FILE *in = NULL;
    FILE *out = NULL;
    char line[4096];
    int wrote = 0;
    int rc = -1;

    in = fopen(BASEOS_UI_CONFIG, "r");
    out = fopen(BASEOS_UI_CONFIG_TMP, "w");
    if (out == NULL) {
        if (in != NULL) (void)fclose(in);
        return -1;
    }

    if (in != NULL) {
        while (fgets(line, sizeof(line), in) != NULL) {
            if (strncmp(line, "ui_language=", 12) == 0) {
                if (!wrote) {
                    (void)fprintf(out, "ui_language=%s\n", use_chinese ? "zh" : "en");
                    wrote = 1;
                }
                continue;
            }
            if (fputs(line, out) == EOF) goto done;
        }
    }

    if (!wrote && fprintf(out, "ui_language=%s\n", use_chinese ? "zh" : "en") < 0)
        goto done;
    if (fflush(out) != 0) goto done;
    if (fsync(fileno(out)) != 0) goto done;
    rc = 0;

done:
    if (in != NULL) (void)fclose(in);
    if (fclose(out) != 0) rc = -1;
    if (rc == 0 && rename(BASEOS_UI_CONFIG_TMP, BASEOS_UI_CONFIG) != 0)
        rc = -1;
    if (rc != 0) (void)unlink(BASEOS_UI_CONFIG_TMP);
    return rc;
}

static int baseos_ui_toggle_language(void)
{
    int next = !baseos_ui_language_zh;
    if (baseos_ui_save_language(next) != 0) return -1;
    baseos_ui_language_zh = next;
    return 0;
}

static const char *baseos_ui_language_label(void)
{
    return baseos_ui_language_zh
        ? "语言：简体中文（A 切换 English）"
        : "Language: English (A for 中文)";
}

static void baseos_ui_load_console_font(void)
{
    pid_t child;
    int status = 0;

    if (access(BASEOS_UI_FONT, R_OK) != 0 || access("/usr/sbin/setfont", X_OK) != 0)
        return;

    child = fork();
    if (child < 0) return;
    if (child == 0) {
        int null_fd = open("/dev/null", O_WRONLY);
        if (null_fd >= 0) {
            (void)dup2(null_fd, STDOUT_FILENO);
            (void)dup2(null_fd, STDERR_FILENO);
            (void)close(null_fd);
        }
        execl("/usr/sbin/setfont", "setfont", "-C", "/dev/tty1",
              BASEOS_UI_FONT, (char *)NULL);
        _exit(127);
    }

    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return;
    }
}

static void baseos_ui_init(void)
{
    baseos_ui_load_language();
    baseos_ui_load_console_font();
}

#endif
