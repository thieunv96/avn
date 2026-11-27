#!/usr/bin/env bash
# .claude/hooks/scope-guard.sh
# The outside-directory boundary (v2.13.0). One script, two events:
#
#   PreToolUse (Bash; Monitor commands arrive under the same matcher) — blocks
#     a command that names a path outside this session's directories and tells
#     the model to ask the user for /add-dir. Allowed without a grant: the
#     project directory; the parts of ~/.claude a session needs (CLAUDE.md,
#     rules, skills, agents, commands, plans, output-styles, and this project's
#     own folder under projects/, which holds its memory and transcripts); the
#     session scratchpad; device files such as /dev/null; and the program being
#     run (a conda python under ~/miniconda3 may run, and its activate script
#     may be sourced; reading files there still needs a grant). Everything else
#     — other projects and their transcripts, datasets and NAS mounts, the home
#     directory, /tmp, /etc — needs the user to type /add-dir <directory>; the
#     grant lasts for that session.
#   DirectoryAdded — fires for /add-dir and records the directory in
#     ~/.claude/avn-scope/<session id>, one absolute path per line. Files older
#     than 30 days are removed then. permissions.additionalDirectories in the
#     user settings and in the project's settings files (where /add-dir keeps a
#     directory it is told to remember) count as granted too. `--add-dir` at
#     startup and the /permissions Workspace tab do not fire the event, so this
#     hook cannot see them: use /add-dir inside the session. /clear starts a new
#     session id, and with it a new, empty grant file.
#
# The file tools are covered by Claude Code itself (permissions.blockReads/
# WritesOutsideWorkingDirectories in settings.json); this hook closes the Bash
# side, which those settings leave open for writes and program arguments.
#
# How the command is read: the way bash reads it — words with their quotes
# removed, comments dropped, heredoc bodies and $(...) substitutions told apart
# from the command around them, brace lists expanded. The same reader is in
# bash-guard.sh. When it is not sure (an unterminated quote, syntax it does not
# model) every absolute path in the text is judged instead.
#
# How a path is judged: under a granted directory → pass, without touching the
# disk (a stale NAS mount must not hang the hook); under a local root → pass
# unless a symlink on the way leads out; a character device or the standard
# streams → pass; a first component that does not exist on this machine
# (/api/v1, /div) → not a path, pass; otherwise block. A glob is judged by the
# directory it lists (/e*/hosts → /). The grant directory is always blocked,
# also through a glob or a variable that can expand to it or to a settings file
# whose additionalDirectories are trusted, so the obvious ways for the model to
# write its own grant are closed.
#
# Seatbelt caveats: only paths written out in the command are seen. Not seen:
# paths held in variables or built by a script, option values glued to a short
# flag (-o/tmp/x), leading NAME=value assignments, and whatever a program reads
# on its own. Arguments on the far side of a container or a remote shell
# (docker exec/run, kubectl exec, ssh) are not host paths and are skipped; host
# mounts (-v, --mount) are judged. The pattern of grep, a sed or awk script
# that opens no file itself, echo text and commit messages are skipped. Code —
# python -c, a heredoc or here-string that is an interpreter's program, what a
# pipe feeds into one — is scanned for absolute paths; the same given to a
# shell is read as a command line. Any other heredoc body is text. Machine
# credentials (~/.ssh, ~/.aws, ~/.kube, ~/.docker/config.json, any kubeconfig)
# are blocked with their own message: they are never granted, so no /add-dir
# advice. The same boundary applies in every guard profile; the profile stamp
# is not read.
#
# Contract: hook receives JSON on stdin; exit 0 = allow, exit 2 = block
# (stderr is shown to Claude as the reason). Fails closed without python3, like
# the other guards; malformed input and internal errors fail open, because this
# hook sees every Bash call.

set -u

block() { echo "BLOCKED by baseline policy: $1" >&2; exit 2; }

# Fail closed: without python3 the command cannot be inspected and the boundary
# would be silently disabled.
command -v python3 >/dev/null 2>&1 || \
  block "scope-guard needs python3 to inspect command paths; install python3 or run this command yourself."

SCOPE_GUARD_PY=$(cat <<'PY'
import json, os, re, stat, sys, time

proj_arg, home = sys.argv[1], sys.argv[2]


def out(verdict):
    # bytes, so a path that is not valid UTF-8 cannot turn a block into a crash
    sys.stdout.buffer.write((verdict + "\n").encode("utf-8", "backslashreplace"))
    sys.stdout.flush()
    sys.exit(0)


try:
    d = json.load(sys.stdin)
    if not isinstance(d, dict):
        raise ValueError("not an object")
except Exception:
    out("OK")  # nothing parseable to judge — same fail-open as the other guards

if not home or not os.path.isabs(proj_arg):
    out("OK")

claude_home = os.path.join(home, ".claude")
grant_dir = os.path.join(claude_home, "avn-scope")
sid = d.get("session_id")
sid = re.sub(r"[^A-Za-z0-9._-]", "_", sid)[:64] if isinstance(sid, str) and sid else ""
grant_file = os.path.join(grant_dir, sid) if sid else ""
event = d.get("hook_event_name")

# ---- DirectoryAdded: /add-dir granted a directory for this session ----
if event == "DirectoryAdded":
    directory = d.get("directory")
    if grant_file and isinstance(directory, str) and os.path.isabs(directory):
        try:
            os.makedirs(grant_dir, exist_ok=True)
            with open(grant_file, "a", encoding="utf-8") as fh:
                fh.write(os.path.normpath(directory) + "\n")
            cutoff = time.time() - 30 * 86400
            for name in os.listdir(grant_dir):
                old = os.path.join(grant_dir, name)
                if old != grant_file and os.path.isfile(old) and os.path.getmtime(old) < cutoff:
                    os.remove(old)
        except OSError as exc:
            print("scope-guard: could not record the grant: %s" % exc, file=sys.stderr)
    out("OK")

if isinstance(event, str) and event and event != "PreToolUse":
    out("OK")
ti = d.get("tool_input")
command = ti.get("command") if isinstance(ti, dict) else None
if not isinstance(command, str) or not command.strip():
    out("OK")


# ---- the directories this session may use ----
def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


roots = []


def add_root(path):
    if isinstance(path, str) and os.path.isabs(path):
        for p in (os.path.normpath(path), os.path.realpath(path)):
            if p not in roots:
                roots.append(p)


add_root(proj_arg)
# Inside ~/.claude only what a session needs is open: instructions, rules, skills,
# agents, plans, and this project's own memory and transcripts (Claude Code names
# that folder after the project path). Other projects' transcripts and the settings
# need /add-dir ~/.claude; the credentials file is never granted.
for part in ("CLAUDE.md", "rules", "skills", "agents", "commands", "plans", "output-styles"):
    add_root(os.path.join(claude_home, part))
proj_variants = {os.path.normpath(proj_arg), os.path.realpath(proj_arg)}
for variant in proj_variants:
    add_root(os.path.join(claude_home, "projects", re.sub(r"[^A-Za-z0-9]", "-", variant)))
scratch = d.get("scratchpad_dir")
scratch = os.path.normpath(scratch) if isinstance(scratch, str) and os.path.isabs(scratch) else ""
add_root(scratch)
# scratchpad_dir is a documented hook field (Claude Code 2.1.257+), absent when the
# session has no scratchpad. Fallback for an event without it: the default place of
# the scratchpad, /tmp/claude-<uid>/<project>/<session id>/scratchpad.
raw_sid = d.get("session_id")
SCRATCH_FALLBACK = None
if not scratch and isinstance(raw_sid, str) and re.fullmatch(r"[A-Za-z0-9-]{6,}", raw_sid):
    SCRATCH_FALLBACK = re.compile(r"^/tmp/claude-\d+/[^/]+/" + re.escape(raw_sid) + r"/scratchpad(/|$)")

grants = []


def add_grant(path):
    if isinstance(path, str) and path.strip():
        path = os.path.expanduser(path.strip())
        if os.path.isabs(path):
            path = os.path.normpath(path)
            if path not in grants:
                grants.append(path)


if grant_file:
    try:
        with open(grant_file, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                add_grant(line)
    except OSError:
        pass
# Directories the user added for good count as granted: permissions.additionalDirectories
# in the user settings and in this project's settings files (where /add-dir stores a
# directory it is told to remember).
SETTINGS_FILES = [os.path.join(claude_home, "settings.json")]
for variant in sorted(proj_variants):
    SETTINGS_FILES += [os.path.join(variant, ".claude", name) for name in ("settings.json", "settings.local.json")]
for settings_file in SETTINGS_FILES:
    try:
        with open(settings_file, encoding="utf-8") as fh:
            extra = json.load(fh).get("permissions", {}).get("additionalDirectories", [])
        for item in extra if isinstance(extra, list) else []:
            add_grant(item)
    except Exception:
        pass

cwd0 = d.get("cwd")
cwd0 = os.path.normpath(cwd0) if isinstance(cwd0, str) and os.path.isabs(cwd0) else os.path.normpath(proj_arg)

CRED_PATHS = [os.path.join(home, n) for n in (".ssh", ".aws", ".kube", ".docker/config.json",
                                               ".claude/.credentials.json")]
DEVICE = re.compile(r"^/dev/(null|zero|full|random|urandom|tty|stdin|stdout|stderr|fd/\d+)$")


def verdict(path, depth=0):
    """None when the path may be used, else (kind, path)."""
    if path == "/":
        return ("ROOT", path)
    if under(path, grant_dir):
        return ("GRANTS", path)
    if any(under(path, c) for c in CRED_PATHS) or os.path.basename(path) == "kubeconfig":
        return ("CREDENTIALS", path)  # never granted, whatever /add-dir covered
    for g in grants:
        if under(path, g):
            return None  # granted: never touch the disk there (stale mounts hang)
    for r in roots:
        if under(path, r):
            return walk(path, r, depth)
    if SCRATCH_FALLBACK and SCRATCH_FALLBACK.match(path):
        return None
    if path == "/dev":
        return None  # listing the devices; anything below is judged one by one
    if path.startswith("/dev/"):
        if DEVICE.match(path):
            return None
        try:
            if stat.S_ISCHR(os.lstat(path).st_mode):
                return None
        except OSError:
            pass
    first = "/" + path.strip("/").split("/", 1)[0]
    if not os.path.lexists(first):
        return None  # not a path on this machine: /api/v1, /div
    return ("OUTSIDE", path)


def walk(path, root, depth):
    """Inside a local root: follow the components and judge where a symlink leads."""
    if depth > 8:
        return ("OUTSIDE", path)
    rel = os.path.relpath(path, root)
    if rel == ".":
        return None
    parts = rel.split(os.sep)
    cur = root
    for i, part in enumerate(parts):
        cur = os.path.join(cur, part)
        try:
            st = os.lstat(cur)
        except OSError:
            return None  # nothing there yet: it stays inside this root
        if stat.S_ISLNK(st.st_mode):
            try:
                target = os.readlink(cur)
            except OSError:
                return None
            target = os.path.normpath(os.path.join(os.path.dirname(cur), target))
            return verdict(os.path.normpath(os.path.join(target, *parts[i + 1:])), depth + 1)
    return None


def norm(path):
    """normpath, except that ".." after a symlink inside a local root follows the link
    first, as the kernel does: data/../x with data -> /nas/ds is /nas/x, not ./x."""
    if "/../" not in path + "/":
        return os.path.normpath(path)
    cur = "/"
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part != "..":
            cur = os.path.join(cur, part)
            continue
        try:
            if any(under(cur, r) for r in roots) and os.path.islink(cur):
                cur = os.path.normpath(os.path.join(os.path.dirname(cur), os.readlink(cur)))
        except OSError:
            pass
        cur = os.path.dirname(cur) or "/"
    return cur


# ---- shell reader: identical in bash-guard.sh and scope-guard.sh (the tests compare the two) ----
class Unsure(Exception):
    """Shell syntax this reader does not model. The caller takes its cautious path."""


class Word(str):
    """One shell word with its quotes removed, or an operator (op). unq: the same text with
    every quoted character replaced by NUL. splits: the shell may still turn the word into
    other words (an unquoted glob, brace list, tilde or variable). var: it holds a $
    expansion. inner: the command lines of its $(...) and `...` substitutions. body: the
    text of a heredoc; quoted: that heredoc's delimiter was quoted, so the body is literal.
    arith: a (( ... )) command."""
    op = splits = var = body = quoted = arith = False
    inner = ()
    unq = ""


OPERATORS = ("&>>", "<<<", "<<-", "&>", ">>", ">&", "<&", "<<", "<>", ">|", "||", "&&", ";;",
             "|&", ";", "|", "&", "(", ")", "<", ">")
META = " \t\n;|&()<>"                   # a carriage return is an ordinary character for bash
REDIR_OUT = {">", ">>", "&>", "&>>", ">|", "<>", ">&"}
REDIR_IN = {"<", "<&"}
FEEDS = {"<<", "<<-", "<<<"}
SPLITS = re.compile(r"[*?\[$`]|\{[^{}]*(,|\.\.)[^{}]*\}|^~|[=:]~")
ANSI = re.compile(r"\\(x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|[0-7]{1,3}|.)", re.S)
ANSI_MAP = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
            "e": "\x1b", "E": "\x1b", "\\": "\\", "'": "'", '"': '"', "?": "?"}


def _ansi(body):
    """The text of a $'...' string with its escapes decoded."""
    def one(m):
        s = m.group(1)
        if s[0] in "xu" and len(s) > 1:
            return chr(int(s[1:], 16))
        if s[0] in "01234567":
            return chr(int(s, 8) & 0xFF)
        return ANSI_MAP.get(s, "\\" + s)
    return ANSI.sub(one, body)


def _ansi_end(text, i):
    """Index of the quote that closes the $'...' string whose content starts at i."""
    while i < len(text) and text[i] != "'":
        i += 2 if text[i] == "\\" else 1
    if i >= len(text):
        raise Unsure("quote")
    return i


def _backtick_end(text, i):
    while i < len(text):
        if text[i] == "\\":
            i += 2
        elif text[i] == "`":
            return i + 1
        else:
            i += 1
    raise Unsure("backtick")


def _closing(text, i, opener):
    """Index after the bracket that closes the ( or { opened just before i. Inside $( ... )
    a heredoc body is skipped, so the quotes and brackets of a commit message do not count."""
    closer, depth, n, pending = (")" if opener == "(" else "}"), 1, len(text), []
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
        elif c == "#" and opener == "(" and text[i - 1] in " \t\n;|&(":
            j = text.find("\n", i)                      # a comment: bash ignores a bracket in it too
            i = n if j < 0 else j
        elif c == "\n" and pending:
            i += 1
            for delim, strip in pending:
                while i < n:
                    j = text.find("\n", i)
                    j = n if j < 0 else j
                    line, i = text[i:j], min(j + 1, n)
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
            pending = []
        elif opener == "(" and text.startswith("<<", i) and not text.startswith("<<<", i):
            strip = text.startswith("<<-", i)
            i += 3 if strip else 2
            while i < n and text[i] in " \t":
                i += 1
            j = i
            while j < n and text[j] not in META:
                j += 1
            pending.append((re.sub(r"[\\'\"]", "", text[i:j]), strip))
            i = j
        elif text.startswith("$'", i):
            i = _ansi_end(text, i + 2) + 1
        elif c == "'":
            i = text.find("'", i + 1) + 1
            if not i:
                raise Unsure("quote")
        elif c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 2
                elif text[i] == "`":
                    i = _backtick_end(text, i + 1)
                elif text.startswith("$(", i) or text.startswith("${", i):
                    i = _closing(text, i + 2, text[i + 1])
                else:
                    i += 1
            if i >= n:
                raise Unsure("quote")
            i += 1
        elif c == "`":
            i = _backtick_end(text, i + 1)
        elif text.startswith("$(", i) or text.startswith("${", i):
            i = _closing(text, i + 2, text[i + 1])
        elif c == opener:
            depth, i = depth + 1, i + 1
        elif c == closer:
            depth, i = depth - 1, i + 1
            if not depth:
                return i
        else:
            i += 1
    raise Unsure("bracket")


def _substitution(text, i):
    """(index after it, the command lines it runs) for the $(...) or backtick at i."""
    if text[i] == "`":
        end = _backtick_end(text, i + 1)
        return end, [text[i + 1:end - 1].replace("\\`", "`")]
    end = _closing(text, i + 2, "(")
    if text.startswith("$((", i) and _closing(text, i + 3, "(") == end - 1:
        return end, _nested(text[i + 3:end - 2])        # arithmetic: only what runs inside it
    return end, [text[i + 2:end - 1]]


def _nested(region, quotes=True):
    """The command lines of the substitutions inside an arithmetic or ${...} expression, or
    inside a heredoc body (quotes=False: a quote does not protect anything there)."""
    found, i, n = [], 0, len(region)
    while i < n:
        c = region[i]
        if c == "\\":
            i += 2
        elif c == "'" and quotes:
            j = region.find("'", i + 1)
            i = n if j < 0 else j + 1
        elif c == "`" or region.startswith("$(", i):
            i, bodies = _substitution(region, i)
            found += bodies
        else:
            i += 1
    return found


def _read_word(text, i):
    """(Word, index after it) for the word that starts at i."""
    n, val, unq, inner, var = len(text), [], [], [], False
    while i < n and text[i] not in META:
        c = text[i]
        if c == "\\":
            if i + 1 >= n:
                raise Unsure("escape")
            if text[i + 1] != "\n":
                val.append(text[i + 1])
                unq.append("\0")
            i += 2
        elif text.startswith("$'", i):
            j = _ansi_end(text, i + 2)
            s = _ansi(text[i + 2:j])
            if "\0" in s:
                raise Unsure("NUL")
            val.append(s)
            unq.append("\0" * len(s))
            i = j + 1
        elif c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise Unsure("quote")
            val.append(text[i + 1:j])
            unq.append("\0" * (j - i - 1))
            i = j + 1
        elif c == '"' or text.startswith('$"', i):
            i += 1 if c == '"' else 2
            start = len(val)
            while True:
                if i >= n:
                    raise Unsure("quote")
                d = text[i]
                if d == '"':
                    i += 1
                    break
                if d == "\\" and i + 1 < n and text[i + 1] in '"\\$`\n':
                    if text[i + 1] != "\n":
                        val.append(text[i + 1])
                    i += 2
                elif d == "`" or text.startswith("$(", i):
                    j, bodies = _substitution(text, i)
                    inner += bodies
                    var = True
                    val.append(text[i:j])
                    i = j
                elif text.startswith("${", i):
                    j = _closing(text, i + 2, "{")
                    inner += _nested(text[i + 2:j - 1])
                    var = True
                    val.append(text[i:j])
                    i = j
                else:
                    var = var or d == "$"
                    val.append(d)
                    i += 1
            unq.append("\0" * sum(len(s) for s in val[start:]))
        elif c == "`" or text.startswith("$(", i) or text.startswith("${", i):
            if text.startswith("${", i):
                j = _closing(text, i + 2, "{")
                inner += _nested(text[i + 2:j - 1])
            else:
                j, bodies = _substitution(text, i)
                inner += bodies
            var = True
            val.append(text[i:j])
            unq.append(text[i:j])
            i = j
        else:
            var = var or c == "$"
            val.append(c)
            unq.append(c)
            i += 1
    w = Word("".join(val))
    w.unq, w.inner, w.var = "".join(unq), tuple(inner), var
    w.splits = bool(SPLITS.search(w.unq))
    return w, i


def _op(text):
    w = Word(text)
    w.op = True
    return w


def lex(text):
    """The command line as bash reads it, as far as these hooks need: words (quotes removed),
    operators, no comments, each heredoc body placed right after its << operator. An unquoted
    newline comes back as the operator ";". Raises Unsure on syntax it does not model."""
    if "\0" in text:
        raise Unsure("NUL")
    out, pending, i, n = [], [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("\\\n", i):
            i += 2
        elif c in " \t":
            i += 1
        elif c == "#":                                  # only reached at the start of a word
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c == "\n":
            i += 1
            for slot, strip, delim in pending:         # the heredocs opened on this line, in order
                lines = []
                while i < n:                            # bash: a missing delimiter ends at end of input
                    j = text.find("\n", i)
                    j = n if j < 0 else j
                    line, i = text[i:j], min(j + 1, n)
                    line = line.lstrip("\t") if strip else line
                    if line == delim:
                        break
                    lines.append(line)
                body = Word("\n".join(lines))
                body.body, body.quoted = True, out[slot].quoted
                if not body.quoted:                     # the shell expands an unquoted body
                    body.inner = tuple(_nested(body, False))
                    body.var = "$" in body or "`" in body
                out[slot] = body
            pending = []
            out.append(_op(";"))
        else:
            op = next((o for o in OPERATORS if text.startswith(o, i)), None)
            if op is None:
                w, i = _read_word(text, i)
                if not (w.isdigit() and "\0" not in w.unq and i < n and text[i] in "<>"):
                    out.append(w)                       # the 2 of 2>file is a descriptor, not a word
                continue
            if text.startswith("((", i):               # (( arithmetic )), unless it is two subshells
                end = _closing(text, i + 1, "(")
                if _closing(text, i + 2, "(") == end - 1:
                    w = Word(text[i:end])
                    w.arith, w.var, w.inner = True, True, tuple(_nested(text[i + 2:end - 2]))
                    out.append(w)
                    i = end
                    continue
            i += len(op)
            out.append(_op(op))
            if op in ("<<", "<<-"):
                while i < n and text[i] in " \t":
                    i += 1
                start = i
                delim, i = _read_word(text, i)
                if not delim:
                    raise Unsure("heredoc delimiter")
                slot = Word("")
                slot.body, slot.quoted = True, text[start:i] != delim
                out.append(slot)
                pending.append((len(out) - 1, op == "<<-", str(delim)))
    return out


class Cmd(object):
    """A simple command: its words, its redirects as (operator, target or None), and the
    text it is fed on stdin (heredoc bodies and here-strings)."""

    def __init__(self):
        self.words, self.redirs, self.feeds = [], [], []

    def __bool__(self):
        return bool(self.words or self.redirs or self.feeds)

    __nonzero__ = __bool__


def pipelines(tokens):
    """The token list as pipelines of simple commands: [[Cmd, ...], ...]."""
    result, pipe, cmd, i, n = [], [], Cmd(), 0, len(tokens)
    while i < n:
        t = tokens[i]
        nxt = tokens[i + 1] if i + 1 < n and not tokens[i + 1].op else None
        if not t.op:
            cmd.words.append(t)
        elif t in FEEDS or t in REDIR_OUT or t in REDIR_IN:
            if t not in FEEDS:
                cmd.redirs.append((str(t), nxt))        # nxt None: >(...) or a missing target
            elif nxt is not None:
                cmd.feeds.append(nxt)
            i += 1 if nxt is not None else 0
        else:
            if cmd:
                pipe.append(cmd)
            cmd = Cmd()
            if t not in ("|", "|&"):
                if pipe:
                    result.append(pipe)
                pipe = []
        i += 1
    if cmd:
        pipe.append(cmd)
    if pipe:
        result.append(pipe)
    return result


SED_ADDRESS = re.compile(r"\d+(~\d+)?|\$")
SED_RANGE = re.compile(r"\s*,\s*\+?")


def sed_pure(script):
    """True for a sed script made only of addresses and the commands that print, delete or
    substitute. r/R/w/W read and write files and e runs a command, as do the w and e flags
    of s: such a script is not text only."""
    n = len(script)

    def closing(i, delim):              # index after the next unescaped delim, -1 if none
        while 0 <= i < n:
            if script[i] == "\\":
                i += 2
            elif script[i] == delim:
                return i + 1
            else:
                i += 1
        return -1

    i = 0
    while True:
        while i < n and script[i] in " \t\n;}":
            i += 1
        if i >= n:
            return True
        for _ in range(2):              # up to two addresses
            m = SED_ADDRESS.match(script, i)
            if m:
                i = m.end()
            elif script[i:i + 1] == "/":
                i = closing(i + 1, "/")
                if i < 0:
                    return False
                while i < n and script[i] in "IM":
                    i += 1
            else:
                break
            m = SED_RANGE.match(script, i)
            if not m:
                break
            i = m.end()
        while i < n and script[i] in " \t!":
            i += 1
        c = script[i:i + 1]
        if c == "{":
            i += 1
            continue
        if c and c in "pdqQ=nNDPgGhHxl":
            i += 1
            while i < n and script[i].isdigit():
                i += 1
        elif c and c in "sy" and i + 1 < n and not (script[i + 1].isalnum() or script[i + 1] in " \\\n"):
            i = closing(closing(i + 2, script[i + 1]), script[i + 1])
            if i < 0:
                return False
            while c == "s" and i < n and (script[i] in "gpIiMm" or script[i].isdigit()):
                i += 1
        else:
            return False
        if i < n and script[i] not in " \t\n;}":
            return False


def awk_pure(program):
    """True for an awk program that only reads its input and prints: no getline, system(),
    pipe, redirect, ARGV change or @include."""
    return not re.search(r"getline|system|ARGV|[|>@]", program)


SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
CODE_OPTS = {"python": {"-c"}, "node": {"-e", "--eval", "-p", "--print"}, "php": {"-r"}}


def kind(prog):
    """shell, python, node, perl, ruby or php for a program that runs code; else ''."""
    if prog in SHELLS:
        return "shell"
    if re.match(r"python[0-9.]*$", prog):
        return "python"
    return prog if prog in ("node", "perl", "ruby", "php") else ""


# options known to take no value; any other option may swallow the next word, and then
# there is no telling which word is the program
PLAIN_OPTS = {
    "shell": re.compile(r"-[a-zA-Z]+$|--(norc|noprofile|login|posix|restricted|verbose)$"),
    "python": re.compile(r"-[bBdEhiIOqRsSuvVxP]+$"),
    "node": re.compile(r"--[a-z][a-z0-9-]*=.*$|--(no|trace|experimental|harmony)-[a-z0-9-]+$"),
    "perl": re.compile(r"-(?![IMmxCF]$)[a-zA-Z0-9.:]+$"),
    "ruby": re.compile(r"-(?![IrCEFKx]$)[a-zA-Z0-9]+$"),
    "php": re.compile(r"-[nq]$"),
}
SHELL_VALUE_OPTS = {"-o", "-O", "+o", "+O", "--rcfile", "--init-file"}


def source(prog, args):
    """Where a shell or an interpreter takes its program from: ("code", i) for -c/-e CODE,
    ("module", i) for python -m, ("file", i) for a script operand, ("stdin", None) when it
    names none, ("unknown", None) when an option this reader does not know comes first."""
    k, i = kind(prog), 0
    while i < len(args):
        a = args[i]
        nxt = i + 1 if i + 1 < len(args) else None
        code = ((k == "shell" and re.match(r"-[a-zA-Z]*c[a-zA-Z]*$", a))
                or (k in ("perl", "ruby") and re.match(r"-[a-zA-Z0-9]*[eE]$", a))
                or a in CODE_OPTS.get(k, ()))
        if code or (k == "python" and a == "-m"):
            return ("stdin", None) if nxt is None else ("code" if code else "module", nxt)
        if a == "-" or (k == "shell" and re.match(r"-[a-zA-Z]*s[a-zA-Z]*$", a)):
            return ("stdin", None)
        if k == "shell" and a in SHELL_VALUE_OPTS:
            i += 2
            continue
        if not a.startswith("-"):
            return ("file", i)
        if k in PLAIN_OPTS and a not in ("--version", "--help") and not PLAIN_OPTS[k].match(a):
            return ("unknown", None)
        i += 1
    return ("stdin", None)
# ---- end of shell reader ----


# ---- turning a word of the command into a path ----
REMOTE_SPEC = re.compile(r"^[A-Za-z0-9_.-]+(@[A-Za-z0-9_.-]+)?:")


GRANTS = object()   # to_path: the word is a pattern that can land on the protected files
# The grant files, and the settings files whose additionalDirectories are trusted
# above, each with the .claude directory it lives in.
PROTECTED = [(grant_dir + "/", claude_home), (os.path.join(claude_home, "settings.json"), claude_home)]
for variant in sorted(proj_variants):
    PROTECTED += [(os.path.join(variant, ".claude", name), os.path.join(variant, ".claude"))
                  for name in ("settings.json", "settings.local.json")]


def reaches_protected(prefix):
    """True when a glob or a variable that starts with `prefix` can expand to a
    protected file. A prefix that stops before the .claude name cannot: `*` does
    not match a hidden directory."""
    if under(os.path.normpath(prefix), grant_dir):
        return True
    return any(target.startswith(prefix) and len(prefix) > len(os.path.dirname(dot_claude)) + 1
               for target, dot_claude in PROTECTED)


def to_path(word, vcwd, bare_ok=False):
    """The path a word names; None when it names none; GRANTS for a glob or variable
    that can reach the protected files."""
    w = str(word).strip("`")
    mask = getattr(word, "unq", "") or ""
    if len(mask) != len(w):
        mask = w                        # not from the reader: every character counts as unquoted
    if not w or "://" in w or REMOTE_SPEC.match(w):
        return None  # URL, host:path, container:path
    for name, value in (("HOME", home), ("PWD", vcwd)):
        m = re.match(r"\$\{?%s\}?(?=/|$)" % name, w)
        if m:
            w = value + w[m.end():]
            mask = w
    if mask.startswith("~"):
        w = home + w[1:] if w == "~" or w.startswith("~/") else os.path.expanduser(w)
        mask = w
        if w.startswith("~"):
            return None  # no such user
    # where the shell still has work to do: an unquoted glob, or a variable anywhere
    cut = next((i for i, ch in enumerate(w) if ch in "$`" or (ch in "*?[" and mask[i] == ch)), None)
    if cut is not None:
        prefix = w[:cut]
        if reaches_protected(prefix if os.path.isabs(prefix) else os.path.join(vcwd, prefix)):
            return GRANTS
        if w[cut] in "$`":
            return None  # another variable: cannot be resolved here (documented miss)
        # a glob lists the directory its fixed part ends in: /e*/hosts → /, src/app*.py → src
        w = prefix if prefix.endswith("/") else os.path.dirname(prefix)
        w = w or ("/" if prefix.startswith("/") else ".")
        bare_ok = True
    if os.path.isabs(w):
        return norm(w)
    if not (bare_ok or "/" in w or w in (".", "..")):
        try:
            if not os.path.islink(os.path.join(vcwd, w)):
                return None  # a bare word: a subcommand, a name, a number
        except OSError:
            return None
    return norm(os.path.join(vcwd, w))


def brace_span(mask):
    """(open, close, commas) of the first unquoted brace list in a word, or None."""
    i = mask.find("{")
    while i >= 0:
        depth, commas = 0, []
        for j in range(i, len(mask)):
            if mask[j] == "{":
                depth += 1
            elif mask[j] == "," and depth == 1:
                commas.append(j)
            elif mask[j] == "}":
                depth -= 1
                if not depth:
                    break
        if not depth and commas:
            return i, j, commas
        i = mask.find("{", i + 1)
    return None


def brace_alternatives(word):
    """The words bash makes of an unquoted brace list: a{b,c}d → abd, acd. The word itself
    when it has none; None when there are more than 64."""
    mask = getattr(word, "unq", "") or ""
    if len(mask) != len(word) or "{" not in mask:
        return [word]
    done, todo = [], [(str(word), mask)]
    while todo:
        text, m = todo.pop()
        span = brace_span(m)
        if span is None:
            done.append((text, m))
        else:
            a, b, commas = span
            cuts = [a] + commas + [b]
            for x, y in zip(cuts, cuts[1:]):
                todo.append((text[:a] + text[x + 1:y] + text[b + 1:], m[:a] + m[x + 1:y] + m[b + 1:]))
        if len(done) + len(todo) > 64:
            return None
    alternatives = []
    for text, m in done:
        w = Word(text)
        w.unq = m
        alternatives.append(w)
    return alternatives


def judge_word(word, vcwd, bare_ok=False):
    alternatives = brace_alternatives(word)
    if alternatives is None:
        return ("BRACES", str(word))
    for alt in alternatives:
        path = to_path(alt, vcwd, bare_ok)
        if path is GRANTS:
            return ("GRANTS", str(word))
        hit = verdict(path) if path else None
        if hit:
            return hit
    return None


# an absolute path inside code: "/x…" but not "//" (integer division, a comment)
ABS_IN_CODE = re.compile(r"(?<![\w.:/-])(~?/(?!/)[A-Za-z0-9_.+@%-][A-Za-z0-9_.+@%/-]*)")


def scan_code(code):
    for m in ABS_IN_CODE.finditer(code):
        hit = judge_word(m.group(1), "/")
        if hit:
            return hit
    return None


# ---- judging the commands ----
KEYWORDS = {"if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
            "esac", "in", "function", "select", "!", "{", "}", "[[", "]]"}
WRAPPERS = {"env", "nohup", "timeout", "nice", "time", "xargs", "command", "exec", "stdbuf",
            "setsid", "ionice", "sudo"}
WRAPPER_VALUE_FLAGS = {
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "nice": {"-n", "--adjustment"},
    "xargs": {"-I", "-n", "-P", "-L", "-s", "-d", "-E"},
    "ionice": {"-c", "-n", "-p"},
    "sudo": {"-u", "-g"},
    "env": {"-u"},
}
NO_ARGS = {"echo", "printf", "export", "ssh", "sshpass", "expr", "let", "test", "[", "bc", "tr",
           "true", "false", "df"}
ACTIVATORS = {"conda.sh", "mamba.sh", "activate"}   # sourced to start an environment: run, not read
FIND_FILE_FLAGS = {"-fprint", "-fprint0", "-fprintf", "-fls", "-newer", "-anewer", "-cnewer", "-samefile"}
CODE_RUNNERS = re.compile(r"^(python[0-9.]*|node|perl|ruby|php)$")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
DURATION = re.compile(r"^[0-9.]+[smhd]?$")
# grep-like tools: the options that give the pattern, a pattern file, or a value; and
# how to tell that a script opens no file itself (None: the pattern is always text)
GREP = ({"-e", "--regexp"}, {"-f", "--file"}, set(), None)
SED = ({"-e", "--expression"}, {"-f", "--file"}, set(), sed_pure)
AWK = (set(), {"-f", "--file"}, {"-v", "--assign", "-F", "--field-separator"}, awk_pure)
TEXT_TOOLS = {"grep": GREP, "egrep": GREP, "fgrep": GREP, "rg": GREP, "ag": GREP, "ack": GREP,
              "sed": SED, "gsed": SED, "awk": AWK, "gawk": AWK, "mawk": AWK,
              "jq": (set(), {"-f", "--from-file"}, set(),
                     lambda script: not re.search(r"\b(import|include)\b", script))}
DOCKER_VALUE_FLAGS = {"--context", "-H", "--host", "--config", "-c", "-l", "--log-level"}
COMPOSE_VALUE_FLAGS = {"-f", "--file", "-p", "--project-name", "--project-directory",
                       "--env-file", "--profile"}
COMPOSE_HOST_FILES = {"-f", "--file", "--env-file", "--project-directory"}
RUN_HOST_FILES = {"--env-file", "--cidfile", "--label-file"}
MESSAGE_FLAGS = {"-m", "--message", "--body", "--title", "--notes"}


def base(word):
    return os.path.basename(word.strip("`"))


def plain_words(args):
    """Every word that can be a path: bare words, and the value of --opt=VALUE / key=VALUE."""
    res, prev = [], ""
    for a in args:
        separator = a == "/" and re.fullmatch(r"-[A-Za-z]", prev)   # cut -d /, sort -t /
        prev = a
        if a == "--" or separator:
            continue
        if a.startswith("-"):
            if "=" in a:
                res.append(a.split("=", 1)[1])
            continue
        m = re.match(r"^[A-Za-z_][A-Za-z0-9_.-]*=(.*)$", a)
        res.append(m.group(1) if m else a)
    return res


def pattern_operands(args, pattern_opts, file_opts, value_opts):
    """grep/sed/awk/jq: (files, scripts). Every plain word is a file except the pattern or
    script. When an option gives the pattern (-e, --regexp=…, -f, also at the end of a
    cluster such as -rne) every plain word is a file, also the ones before it:
    grep -rn DIR -e PATTERN."""
    named = pattern_opts | file_opts
    end = args.index("--") if "--" in args else len(args)
    seen = any(a.split("=", 1)[0] in named or (named and re.fullmatch(r"-[A-Za-z]+[ef]", a))
               for a in args[:end])
    files, scripts, options, j = [], [], True, 0
    while j < len(args):
        a = args[j]
        nxt = args[j + 1] if j + 1 < len(args) else None
        if options and a == "--":
            options = False
        elif options and (a in pattern_opts or a in file_opts or a in value_opts):
            if nxt is not None:
                (scripts if a in pattern_opts else files).append(nxt)
            j += 1
        elif options and a.startswith("-") and a != "-":
            if "=" in a:
                key, value = a.split("=", 1)
                (scripts if key in pattern_opts else files).append(value)
        elif not seen:
            seen = True
            scripts.append(a)
            if getattr(a, "splits", False):
                files.append(a)         # the shell may turn it into file names
        else:
            files.append(a)
        j += 1
    return files, scripts


def host_side(spec):
    host = spec.split(":", 1)[0]
    return [host] if host.startswith(("/", "~", ".", "$")) else []  # else a named volume


def mount_source(spec):
    res = []
    for part in spec.split(","):
        key, _, value = part.partition("=")
        if key in ("source", "src") and value.startswith(("/", "~", ".", "$")):
            res.append(value)
    return res


def docker_words(prog, args):
    """Only the host side of a docker command: compose files, mounts, cp."""
    res, j = [], 0
    if prog == "docker-compose":
        sub = "compose"
    else:
        while j < len(args) and args[j].startswith("-"):
            j += 2 if args[j] in DOCKER_VALUE_FLAGS else 1
        if j >= len(args):
            return res
        sub = args[j]
        j += 1
    if sub == "compose":
        while j < len(args) and args[j].startswith("-"):
            a = args[j]
            name, eq, value = a.partition("=")
            if a in COMPOSE_VALUE_FLAGS:
                if a in COMPOSE_HOST_FILES and j + 1 < len(args):
                    res.append(args[j + 1])
                j += 2
            else:
                if eq and name in COMPOSE_HOST_FILES:
                    res.append(value)
                j += 1
        if j >= len(args):
            return res
        sub = args[j]
        j += 1
    rest = args[j:]
    if sub == "exec":
        return res
    if sub in ("run", "create"):
        k = 0
        while k < len(rest):
            a = rest[k]
            name, eq, value = a.partition("=")
            nxt = rest[k + 1] if k + 1 < len(rest) else None
            if a in ("-v", "--volume") and nxt is not None:
                res += host_side(nxt)
                k += 2
            elif a == "--mount" and nxt is not None:
                res += mount_source(nxt)
                k += 2
            elif a in RUN_HOST_FILES and nxt is not None:
                res.append(nxt)
                k += 2
            else:
                if eq and name in ("-v", "--volume"):
                    res += host_side(value)
                elif eq and name == "--mount":
                    res += mount_source(value)
                elif eq and name in RUN_HOST_FILES:
                    res.append(value)
                k += 1
        return res
    if sub == "cp":
        return res + [a for a in rest if not a.startswith("-") and not re.match(r"^[^/:]+:", a)]
    return res + plain_words(rest)


def stdin_program(c):
    """"shell" or "code" when this command is a shell or an interpreter that reads its
    program from stdin (bash, python3 -); "" otherwise."""
    words, i = c.words, 0
    while i < len(words) and (words[i] in KEYWORDS or ASSIGN.match(words[i]) or base(words[i]) in WRAPPERS
                              or (i and (words[i].startswith("-") or DURATION.match(words[i])))):
        i += 1
    if i >= len(words):
        return ""
    k = kind(base(words[i]))
    if not k or source(base(words[i]), words[i + 1:])[0] not in ("stdin", "unknown"):
        return ""
    return "shell" if k == "shell" else "code"


def judge_segment(words, state, depth):
    words = [w for w in words if not getattr(w, "arith", False)]
    n, i = len(words), 0
    while i < n and (words[i] in KEYWORDS or ASSIGN.match(words[i])):
        i += 1
    vcwd = state["cwd"]
    while i < n and base(words[i]) in WRAPPERS:
        wrapper = base(words[i])
        flags = WRAPPER_VALUE_FLAGS.get(wrapper, ())
        i += 1
        while i < n:
            a = words[i]
            chdir = wrapper == "env" and (a in ("-C", "--chdir") or a.startswith("--chdir="))
            if chdir or (wrapper == "xargs" and a in ("-a", "--arg-file")):
                value = a.split("=", 1)[1] if "=" in a else (words[i + 1] if i + 1 < n else "")
                hit = judge_word(value, vcwd, True) if value else None
                if hit:
                    return hit
                if chdir and value:
                    vcwd = to_path(value, vcwd, True) or vcwd   # env -C DIR: the command runs there
                i += 1 if "=" in a else 2
            elif a in flags:
                i += 2
            elif a.startswith("-") or ASSIGN.match(a) or (wrapper == "timeout" and DURATION.match(a)):
                i += 1
            else:
                break
    if i >= n:
        return None
    prog, args = base(words[i]), words[i + 1:]  # the program itself is never judged

    if prog in ("cd", "pushd"):
        if args and args[0] == "-":
            return None
        target = next((a for a in args if not a.startswith("-")), "~")
        hit = judge_word(target, vcwd, True)
        if hit:
            return hit
        state["cwd"] = to_path(target, vcwd, True) or vcwd
        return None
    if prog in NO_ARGS or (prog == "kubectl" and "exec" in args):
        return None
    if prog in ("source", "."):
        script = args[0] if args else ""
        return None if os.path.basename(script) in ACTIVATORS else judge_word(script, vcwd, True)
    if prog == "eval":
        return analyse(" ".join(args), vcwd, depth + 1) if depth < 3 else scan_code(" ".join(args))

    if prog in ("docker", "podman", "docker-compose"):
        cands = docker_words(prog, args)
    elif prog in SHELLS:
        rest, j = [], 0
        while j < len(args):
            if re.fullmatch(r"-[a-zA-Z]*c", args[j]) and j + 1 < len(args):
                hit = analyse(args[j + 1], vcwd, depth + 1) if depth < 3 else scan_code(args[j + 1])
                if hit:
                    return hit
                j += 2
            else:
                rest.append(args[j])
                j += 1
        cands = plain_words(rest)
    elif CODE_RUNNERS.match(prog):
        rest, j = [], 0
        while j < len(args):
            if args[j] in ("-c", "-e", "--eval", "-p", "--print", "-r") and j + 1 < len(args):
                hit = scan_code(args[j + 1])
                if hit:
                    return hit
                j += 2
            else:
                rest.append(args[j])
                j += 1
        cands = plain_words(rest)
    elif prog in TEXT_TOOLS:
        pattern_opts, file_opts, value_opts, pure = TEXT_TOOLS[prog]
        files, scripts = pattern_operands(args, pattern_opts, file_opts, value_opts)
        for script in scripts:
            if pure is not None and not pure(script):       # a script that opens a file itself
                hit = scan_code(script)
                if hit:
                    return hit
        cands = plain_words(files)
    elif prog == "find":
        cands, j = [], 0
        while j < len(args) and (args[j] in ("-L", "-H", "-P", "-D") or args[j].startswith("-O")):
            j += 2 if args[j] == "-D" else 1                # find's own options come first
        while j < len(args) and not (args[j].startswith("-") or args[j] in ("!", "(", "\\(")):
            cands.append(args[j])           # the starting points
            j += 1
        while j < len(args):
            if args[j] in ("-exec", "-execdir", "-ok", "-okdir"):
                inner = [w for w in args[j + 1:] if w not in ("{}", "+", ";")]
                hit = judge_segment(inner, {"cwd": vcwd}, depth) if inner else None
                if hit:
                    return hit              # the command find runs is a command like any other
                break
            if args[j] in FIND_FILE_FLAGS and j + 1 < len(args):
                cands.append(args[j + 1])
                j += 1
            j += 1
    elif prog in ("git", "gh"):
        rest, j = [], 0
        while j < len(args):
            if args[j] in MESSAGE_FLAGS and j + 1 < len(args):
                j += 2
            else:
                rest.append(args[j])
                j += 1
        cands = plain_words(rest)
    else:
        cands = plain_words(args)

    for word in cands:
        hit = judge_word(word, vcwd)
        if hit:
            return hit
    return None


def judge_command(c, state, depth, sink):
    """One simple command: its redirects, the command lines and code inside it, its words."""
    vcwd = state["cwd"]
    for op, target in c.redirs:
        if target is None or (op in (">&", "<&") and re.fullmatch(r"[0-9]+|-", target)):
            continue                        # >(…), or a file-descriptor copy
        hit = judge_word(target, vcwd, True)
        if hit:
            return hit
    lines = [b for w in c.words for b in w.inner] + [b for f in c.feeds for b in f.inner]
    lines += [b for _, t in c.redirs if t is not None for b in t.inner]
    # stdin text is code when this command reads its program from stdin, or when the
    # pipeline ends in a shell or an interpreter that does (cat <<EOF | sh, echo … | python3)
    how = stdin_program(c) or sink
    fed = list(c.feeds)
    if sink and c.words and base(c.words[0]) in ("echo", "printf"):
        fed += c.words[1:]
    for text in fed if how else []:
        if how == "shell":
            lines.append(str(text))
        else:
            hit = scan_code(text)
            if hit:
                return hit
    for text in lines:
        hit = analyse(text, vcwd, depth + 1) if depth < 3 else scan_code(text)
        if hit:
            return hit
    return judge_segment(c.words, state, depth)


def analyse(text, vcwd, depth=0):
    state = {"cwd": vcwd}
    for pipe in pipelines(lex(text)):
        sink = ""
        for c in pipe[1:]:
            sink = sink or ("" if c.feeds else stdin_program(c))
        for c in pipe:
            hit = judge_command(c, state, depth, sink)
            if hit:
                return hit
    return None


try:
    hit = analyse(command, cwd0)
except Unsure:
    hit = scan_code(command)    # not sure how bash reads it: judge every absolute path in the text
except Exception as exc:  # an analysis bug must not brick Bash
    print("scope-guard: analysis failed (%s); command not judged" % exc, file=sys.stderr)
    out("OK")

if not hit:
    out("OK")
kind_of_hit, path = hit
if kind_of_hit == "ROOT":
    out("BLOCK this command names the filesystem root (/), which is outside this session's "
        "directories. Name the specific directory you need, tell the user why, and ask them to "
        "type /add-dir <directory>.")
if kind_of_hit == "GRANTS":
    out("BLOCK " + path + " holds the directory grants and is written by /add-dir only. Do not "
        "read or change it; ask the user to type /add-dir <directory>.")
if kind_of_hit == "CREDENTIALS":
    out("BLOCK " + path + " is a machine-credentials location and is never granted to a session. "
        "If the task needs something from it, stop and ask the user to do that step themselves.")
if kind_of_hit == "BRACES":
    out("BLOCK the brace list in " + path[:120] + " expands to more paths than this guard checks. "
        "Write the paths out, or split the command.")
if re.search(r"/claude-\d+/[^/]+/[^/]+/tasks/[^/]+\.output$", path):
    out("BLOCK " + path + " is the output file of a background command, outside this session's "
        "directories for shell commands. Read it with the Read tool instead; no /add-dir is needed "
        "for that.")
message = ("BLOCK this command uses a path outside this session's directories: " + path + ". Do "
           "not work around it. Tell the user which directory you need and why, and ask them to "
           "type /add-dir <directory> (a directory, not a file); one grant lasts until the session "
           "ends.")
if path == "/tmp" or path.startswith(("/tmp/", "/var/tmp/")):
    message += " Temporary files go in the session scratchpad" + (": " + scratch if scratch else "") + "."
out(message)
PY
)

VERDICT=$(python3 -c "$SCOPE_GUARD_PY" "${CLAUDE_PROJECT_DIR:-$PWD}" "${HOME:-}")

case "$VERDICT" in
  BLOCK\ *) block "${VERDICT#BLOCK }" ;;
  *)        exit 0 ;;
esac
