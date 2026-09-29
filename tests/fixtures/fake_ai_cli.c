/*
 * fake_ai_cli.c — stand-in for `claude` / `kiro-cli chat` used by the adversarial tests.
 *
 * Compiled into binaries literally named `claude` and `kiro-cli`, so the process name (comm),
 * argv and process tree look like the real CLIs to ps, tmux and tmux-resurrect. It emulates
 * only what the restore layer depends on:
 *
 *   - session ids: a fresh launch gets a new id; `--resume <id>` / `-r <id>` / `--resume=<id>`
 *     (claude) or `chat --resume-id <id>` (kiro) resumes that id without forking, like the
 *     real CLIs; `--session-id <id>` pins one; `-c` / `--continue` (kiro: `-r`) picks the
 *     newest transcript in the cwd.
 *   - resume is scoped to the cwd: transcripts live at $FAKE_AI_HOME/<tool>/<cwd-slug>/<id>,
 *     and resuming an id that is not there prints the real "No conversation found" error and
 *     exits 1 (which is what triggers the `|| claude` cold fallback on restore).
 *   - lines read from the pane: "/clear" starts a new session id, "/resume <id>" switches
 *     session, "/exit" quits, "!<cmd>" runs a shell command (like Claude's Bash tool, e.g. a
 *     nested `claude -p`), anything else is a prompt: it is appended to the transcript and
 *     the prompt hook runs ($FAKE_AI_HOOK <tool>, via /bin/sh -c, with the hook JSON on stdin).
 *     A positional prompt on the command line is submitted the same way at startup; with
 *     -p / --print the CLI exits right after it.
 *   - every launch / resume / prompt / switch / exit is appended to $FAKE_AI_LOG, tab-separated:
 *     event pid $TMUX_PANE cwd session_id detail argv
 *   - $FAKE_AI_TITLE sets the pane title at startup (Claude does this); with
 *     $FAKE_AI_CLEAR_TITLE_ON_EXIT the title is emptied on exit.
 */
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char sid[128];
static char cwd[PATH_MAX];
static char argvline[8192];
static int is_kiro;

static const char *tool_name(void) { return is_kiro ? "kiro" : "claude"; }

static void new_id(char *out) {
    unsigned char b[16];
    FILE *u = fopen("/dev/urandom", "rb");
    if (!u || fread(b, 1, sizeof b, u) != sizeof b) {
        perror("urandom");
        exit(9);
    }
    fclose(u);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    sprintf(out,
            "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12],
            b[13], b[14], b[15]);
}

static void project_dir(char *out) {
    char slug[PATH_MAX];
    size_t i;
    for (i = 0; cwd[i] && i < sizeof slug - 1; i++) {
        char c = cwd[i];
        slug[i] = ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) ? c : '-';
    }
    slug[i] = 0;
    snprintf(out, PATH_MAX, "%s/%s/%s", getenv("FAKE_AI_HOME"), tool_name(), slug);
}

static void transcript_path(const char *id, char *out) {
    char dir[PATH_MAX];
    project_dir(dir);
    snprintf(out, PATH_MAX, "%s/%s", dir, id);
}

static int transcript_exists(const char *id) {
    char p[PATH_MAX];
    struct stat st;
    transcript_path(id, p);
    return stat(p, &st) == 0;
}

static void mkdir_p(const char *path) {
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

static void transcript_append(const char *text) {
    char dir[PATH_MAX], p[PATH_MAX];
    project_dir(dir);
    mkdir_p(dir);
    transcript_path(sid, p);
    FILE *f = fopen(p, "a");
    if (f) {
        fprintf(f, "%s\n", text);
        fclose(f);
    }
}

static void logev(const char *ev, const char *detail) {
    const char *log = getenv("FAKE_AI_LOG");
    const char *pane = getenv("TMUX_PANE");
    if (!log) return;
    FILE *f = fopen(log, "a");
    if (!f) return;
    fprintf(f, "%s\t%d\t%s\t%s\t%s\t%s\t%s\n", ev, (int)getpid(), pane ? pane : "", cwd, sid,
            detail ? detail : "", argvline);
    fclose(f);
}

static void run_hook(void) {
    const char *hook = getenv("FAKE_AI_HOOK");
    char cmd[PATH_MAX + 64];
    if (!hook || !*hook) return;
    snprintf(cmd, sizeof cmd, "%s %s", hook, tool_name());
    FILE *p = popen(cmd, "w");
    if (!p) return;
    fprintf(p, "{\"session_id\":\"%s\",\"cwd\":\"%s\",\"hook_event_name\":\"UserPromptSubmit\"}\n",
            sid, cwd);
    pclose(p);
}

static void prompt(const char *text) {
    transcript_append(text);
    logev("prompt", text);
    run_hook();
}

/* newest transcript in this cwd's project dir -> sid; 0 if none */
static int newest_in_cwd(void) {
    char dir[PATH_MAX], p[PATH_MAX];
    struct dirent *e;
    struct stat st;
    long best = -1;
    project_dir(dir);
    DIR *d = opendir(dir);
    if (!d) return 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        if (stat(p, &st) == 0 && (long)st.st_mtime >= best) {
            best = (long)st.st_mtime;
            snprintf(sid, sizeof sid, "%s", e->d_name);
        }
    }
    closedir(d);
    return best >= 0;
}

static int takes_value(const char *a) {
    static const char *claude_opts[] = {"--model", "--permission-mode", "--agent", "--settings",
                                        "--effort", "--name", "-n", "--append-system-prompt",
                                        "--add-dir", "--mcp-config", NULL};
    static const char *kiro_opts[] = {"--agent", "--model", "--effort", "--trust-tools", NULL};
    const char **o = is_kiro ? kiro_opts : claude_opts;
    for (; *o; o++)
        if (!strcmp(a, *o)) return 1;
    return 0;
}

int main(int argc, char **argv) {
    const char *base = strrchr(argv[0], '/');
    const char *resume = NULL, *pinned = NULL, *positional = NULL;
    int cont = 0, npos = 0, print_mode = 0, i = 1;
    char line[4096];

    base = base ? base + 1 : argv[0];
    is_kiro = !strcmp(base, "kiro-cli");
    if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "?");
    argvline[0] = 0;
    for (int k = 0; k < argc; k++) {
        strncat(argvline, argv[k], sizeof argvline - strlen(argvline) - 2);
        if (k + 1 < argc) strcat(argvline, " ");
    }

    if (is_kiro) {
        if (i >= argc || strcmp(argv[i], "chat")) {
            fprintf(stderr, "kiro-cli: only `kiro-cli chat` is emulated\n");
            return 2;
        }
        i++;
    }
    for (; i < argc; i++) {
        const char *a = argv[i];
        if (!is_kiro && (!strcmp(a, "--resume") || !strcmp(a, "-r"))) {
            if (i + 1 < argc && argv[i + 1][0] != '-') resume = argv[++i];
            else { fprintf(stderr, "fake claude: interactive picker not emulated\n"); return 3; }
        } else if (!is_kiro && !strncmp(a, "--resume=", 9)) {
            resume = a + 9;
        } else if (!is_kiro && !strcmp(a, "--session-id") && i + 1 < argc) {
            pinned = argv[++i];
        } else if (!is_kiro && (!strcmp(a, "-c") || !strcmp(a, "--continue"))) {
            cont = 1;
        } else if (!is_kiro && (!strcmp(a, "-p") || !strcmp(a, "--print"))) {
            print_mode = 1;
        } else if (is_kiro && !strcmp(a, "--resume-id") && i + 1 < argc) {
            resume = argv[++i];
        } else if (is_kiro && !strncmp(a, "--resume-id=", 12)) {
            resume = a + 12;
        } else if (is_kiro && (!strcmp(a, "-r") || !strcmp(a, "--resume"))) {
            cont = 1;
        } else if (takes_value(a) && i + 1 < argc) {
            i++;
        } else if (a[0] == '-') {
            /* boolean flag, e.g. --dangerously-skip-permissions */
        } else {
            positional = a;
            npos++;
        }
    }
    if (npos > 1) {
        fprintf(stderr, "error: too many arguments. Expected 1 argument but got %d.\n", npos);
        logev("argv-error", "too many arguments");
        return 1;
    }

    if (resume) {
        snprintf(sid, sizeof sid, "%s", resume);
        if (!transcript_exists(resume)) {
            fprintf(stderr, "No conversation found with session ID: %s\n", resume);
            logev("resume-fail", resume);
            return 1;
        }
        logev("resume", resume);
    } else if (cont) {
        if (!newest_in_cwd()) {
            fprintf(stderr, "No conversation found to continue\n");
            logev("continue-fail", "");
            return 1;
        }
        logev("continue", sid);
    } else {
        if (pinned) snprintf(sid, sizeof sid, "%s", pinned);
        else new_id(sid);
        logev("launch", "");
    }

    if (getenv("FAKE_AI_TITLE")) {
        printf("\033]2;%s\033\\", getenv("FAKE_AI_TITLE"));
        fflush(stdout);
    }
    printf("[fake %s] session %s in %s\n", tool_name(), sid, cwd);
    fflush(stdout);
    if (positional) prompt(positional);
    if (print_mode) {
        logev("exit", "");
        return 0;
    }

    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        if (!strcmp(line, "/exit")) break;
        if (line[0] == '!') {
            int rc = system(line + 1);
            (void)rc;
        } else if (!strcmp(line, "/clear")) {
            new_id(sid);
            logev("clear", "");
        } else if (!strncmp(line, "/resume ", 8)) {
            if (transcript_exists(line + 8)) {
                snprintf(sid, sizeof sid, "%s", line + 8);
                logev("switch", line + 8);
            } else {
                logev("switch-fail", line + 8);
            }
        } else {
            prompt(line);
        }
        printf("[fake %s] session %s\n", tool_name(), sid);
        fflush(stdout);
    }
    if (getenv("FAKE_AI_CLEAR_TITLE_ON_EXIT")) {
        printf("\033]2;\033\\");
        fflush(stdout);
    }
    logev("exit", "");
    return 0;
}
