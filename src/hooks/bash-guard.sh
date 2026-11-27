#!/usr/bin/env bash
# .claude/hooks/bash-guard.sh
# PreToolUse hook for the Bash tool. Deterministic guard layer — unlike
# permission prefix-rules, this sees the full command string and cannot be
# bypassed by reordering flags or chaining commands. A block here fires
# BEFORE permission rules are evaluated and wins over any allow rule; it
# cannot be approved through — a blocked command must be run by the user.
#
# Contract: hook receives JSON on stdin; exit 0 = allow, exit 2 = block
# (stderr is shown to Claude as the reason). Keep patterns conservative:
# false positives just make Claude ask the user, which is acceptable.
#
# Guard profiles: the installer stamps profile=strict|relaxed into
# .claude/avn-version (tamper-protected by rule 14, file-guard and the Edit
# deny rules). The relaxed profile — for isolated systems with no real
# secrets — lifts only the project-local secret rules (3b, 4); everything
# else applies in every profile. Anything but the exact value "relaxed"
# (missing file/line, unknown value) means strict — fail-safe default.

set -u

block() { echo "BLOCKED by baseline policy: $1" >&2; exit 2; }

# Data-destroying commands stay blocked, and the model is told to hand the
# exact command to the user (v2.13.0) instead of looking for another way in.
HANDOFF="Do not reshape the command to get past this guard. If it is still needed, show the user the exact command and what it changes, and ask them to run it."
block_data() { block "$1 $HANDOFF"; }

# Fail closed: without python3 the JSON parse below yields an empty command
# and every guard is silently disabled.
command -v python3 >/dev/null 2>&1 || \
  block "bash-guard needs python3 to inspect commands; install python3 or run this command yourself."

CMD=$(python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("tool_input", {}).get("command", ""))
except Exception:
    print("")
')

# Guard profile: read from the tamper-protected version stamp; anything other
# than an exact "profile=relaxed" line means strict — fail-safe default.
PROFILE="strict"
_stamp="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/avn-version"
if [ -f "$_stamp" ] && [ "$(sed -n 's/^profile=//p' "$_stamp" 2>/dev/null | head -n1)" = "relaxed" ]; then
  PROFILE="relaxed"
fi

# 1) Pushing to main/master (any remote, any flag order). The ref must stand
#    alone (space/colon-delimited) so branches like feat/main-page pass.
#    Real protection is server-side branch protection; this is the local seatbelt.
if echo "$CMD" | grep -Eq '\bgit\b.*\bpush\b.*(\s|:)(main|master)(\s|$)'; then
  block "git push to main/master. Create a branch and open a PR."
fi

# 1b) Bare push while the checkout sits on main/master — `git push`, `git push
#     origin`, `git push -u origin HEAD` push the current branch without naming
#     it, so the ref-name match above never fires. An explicit non-HEAD refspec
#     (git push origin feat/x) still passes even from master; HEAD:dest is
#     judged by rule 1 on the destination name. Detached HEAD or a non-git dir
#     passes — this is a seatbelt, not a parser.
if echo "$CMD" | grep -Eq '\bgit\b.*\bpush\b'; then
  CUR_BRANCH="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [ "$CUR_BRANCH" = "main" ] || [ "$CUR_BRANCH" = "master" ]; then
    PUSH_TARGET=$(python3 -c '
import shlex, sys
try:
    toks = shlex.split(sys.argv[1])
except ValueError:
    toks = sys.argv[1].split()
SEP = {"&&", "||", ";", "|", "&"}
current = False
for i, t in enumerate(toks):
    if t != "push":
        continue
    seg = []
    for u in toks[i + 1:]:
        if u in SEP:
            break
        seg.append(u)
    pos = [u for u in seg if not u.startswith("-")]
    refspecs = pos[1:]
    if not refspecs or "HEAD" in refspecs:
        current = True
print("CURRENT" if current else "EXPLICIT")
' "$CMD")
    if [ "$PUSH_TARGET" = "CURRENT" ]; then
      block "bare git push while the checkout is on $CUR_BRANCH pushes to $CUR_BRANCH. Create a branch and open a PR."
    fi
  fi
fi

# 2) rm safety, token-based (shlex) so flag order, case (-Rf) and position
#    (rm build -rf) cannot dodge it. Any token whose basename is rm starts an
#    invocation that runs to the next separator, so find -exec / xargs / sudo
#    forms stay caught while quoted strings ("rm -rf /") no longer match.
#    2a) recursive+force in any combination — always blocked.
#    2b) recursive rm (force or not) whose operand is an absolute or ~ path
#        resolving outside the project dir and outside /tmp — the agent must
#        not delete trees it does not own. Relative operands and unexpanded
#        $vars are skipped: seatbelt, not a parser.
if echo "$CMD" | grep -Eq '\brm\b'; then
  RM_VERDICT=$(python3 -c '
import os, shlex, sys
proj = sys.argv[2]
def split(s):
    try:
        return shlex.split(s)
    except ValueError:
        return s.split()
toks = split(sys.argv[1])
SEP = {"&&", "||", ";", "|", "&"}
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
# Also scan the argument of a shell `-c` (sh -c "…", bash -c "…") so a
# destructive command hidden in a shell string is still seen; a `-c` that
# belongs to another tool (grep -c, wc -c) is left alone, and plain data such
# as `echo "rm -rf /"` has no -c and stays allowed.
streams = [toks]
seg_cmd = None
for i, t in enumerate(toks):
    if t in SEP:
        seg_cmd = None
        continue
    if seg_cmd is None and not t.startswith("-"):
        seg_cmd = os.path.basename(t)
    if t == "-c" and i + 1 < len(toks) and seg_cmd in SHELLS:
        streams.append(split(toks[i + 1]))
roots = {os.path.realpath(p) for p in (proj, "/tmp", os.environ.get("TMPDIR") or "/tmp")}
def under(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")
for stream in streams:
    for i, t in enumerate(stream):
        if os.path.basename(t) != "rm":
            continue
        seg = []
        for u in stream[i + 1:]:
            if u in SEP:
                break
            seg.append(u)
        rec = force = False
        operands = []
        for u in seg:
            if u == "--recursive":
                rec = True
            elif u == "--force":
                force = True
            elif len(u) > 1 and u.startswith("-") and not u.startswith("--"):
                rec = rec or "r" in u[1:] or "R" in u[1:]
                force = force or "f" in u[1:]
            elif not u.startswith("-"):
                operands.append(u)
        if rec and force:
            print("RECURSIVE_FORCE")
            sys.exit()
        if rec:
            for op in operands:
                if "$" in op:
                    continue
                if op.startswith("~") or os.path.isabs(op):
                    real = os.path.realpath(os.path.expanduser(op))
                    if not any(under(real, r) for r in roots):
                        print("OUTSIDE " + op)
                        sys.exit()
print("")
' "$CMD" "${CLAUDE_PROJECT_DIR:-$PWD}")
  case "$RM_VERDICT" in
    RECURSIVE_FORCE)
      block_data "rm with recursive+force." ;;
    OUTSIDE\ *)
      block_data "recursive rm targets a path outside this project (${RM_VERDICT#OUTSIDE })." ;;
  esac
fi

# Rules 3, 14 and 15 read the command the way bash does (v2.13.0). Until v2.12.0
# they matched words anywhere on the line, so a search pattern, a commit message
# or `2>/dev/null` was blocked like a real access: in a month of transcripts
# every block of rules 3a/3b/14 was one of those. One python run now reads the
# command — words with their quotes removed, comments dropped, heredoc bodies
# and $(...) substitutions told apart from the command around them — and
# reports, on its first output line, whether a guard file would be changed
# (rule 14) and whether a worktree would be added (rule 15); the rest of its
# output is SCAN, the text rules 3a/3b search.
#
# SCAN is the command without the parts that are text and nothing else:
#   - the pattern of grep/rg and a sed script that only prints, deletes or
#     substitutes (one with r/w/e can open a file itself and stays in);
#   - the message of git commit/tag/merge/stash/notes;
#   - inline python or node code (python -c, node -e, a heredoc that is the
#     program), reduced to its string literals plus any .env mention.
# Such a word is dropped only when the shell leaves it alone: a word with an
# unquoted glob, brace list, tilde or variable, or with a substitution, stays.
# Everything else stays too — file operands, redirect targets, heredoc bodies,
# awk/jq/perl/ruby code — and nothing is dropped from a pipeline that ends in a
# shell or an interpreter reading its program from the pipe.
#
# Whenever the reader is not sure how bash would read the command (an
# unterminated quote, syntax it does not model, an option it does not know) the
# v2.12.0 behaviour applies: the whole line is searched. The command goes in on
# stdin, so its length does not matter.
ANALYSE_PY=$(cat <<'PY'
import os, re, sys

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

ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
# words that stand in front of the program of a simple command
PREFIXES = {"env", "nohup", "time", "command", "exec", "sudo", "nice", "timeout", "stdbuf",
            "setsid", "if", "then", "else", "elif", "while", "until", "do", "!", "{"}


def program_index(words, more=()):
    """Index of the program a simple command runs: after assignments, shell keywords and
    wrappers such as env, sudo or timeout (with their options and a duration)."""
    k, wrapped = 0, False
    while k < len(words):
        w = words[k]
        if os.path.basename(w) in PREFIXES or os.path.basename(w) in more:
            wrapped = True
        elif not (ASSIGN.match(w) or (wrapped and (w.startswith("-") or re.fullmatch(r"[0-9.]+[smhd]?", w)))):
            break
        k += 1
    return k


def shell_strings(words):
    """(texts, their indexes): what a shell runs as a command line — the arguments of eval,
    and the word after sh -c, also when xargs or find -exec starts that shell."""
    k = program_index(words)
    if k < len(words) and os.path.basename(words[k]) == "eval":
        return [" ".join(words[k + 1:])], set(range(k + 1, len(words)))
    found, shell = [], False
    for j, w in enumerate(words):
        if os.path.basename(w) in SHELLS:
            shell = True
        elif shell and re.fullmatch(r"-[a-zA-Z]*c[a-zA-Z]*", w) and j + 1 < len(words):
            found.append(j + 1)
    return [str(words[j]) for j in found], set(found)


def nested_lines(c):
    """The command lines inside a simple command: its substitutions, the string given to
    sh -c or eval, and a heredoc or here-string that is a shell's script."""
    found = [b for w in c.words for b in w.inner]
    found += [b for body in c.feeds for b in body.inner]
    found += [b for _, t in c.redirs if t is not None for b in t.inner]
    found += shell_strings(c.words)[0]
    k = program_index(c.words)
    if k < len(c.words):
        prog = os.path.basename(c.words[k])
        if kind(prog) == "shell" and source(prog, c.words[k + 1:])[0] in ("stdin", "unknown"):
            found += [str(b) for b in c.feeds]
    return found


def fed_by_pipe(pipe, j):
    """True when command j is a shell or an interpreter that reads its program from the
    pipe: whatever the commands before it print may be code."""
    c = pipe[j]
    k = program_index(c.words)
    if j == 0 or k >= len(c.words) or c.feeds:
        return False
    prog = os.path.basename(c.words[k])
    return bool(kind(prog)) and source(prog, c.words[k + 1:])[0] in ("stdin", "unknown")


# ---------------------------------------------------------------- rule 3: SCAN
TEMPLATES = re.compile(r"\.env\.(example|sample|template|dist)([^A-Za-z0-9_.]|$)")
DOTENV = re.compile(r"\.env([^a-zA-Z0-9_]|$)|\.env\.")
LITERAL = re.compile(r"'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\"")
FSTRING = re.compile(r"(?<![A-Za-z0-9_])[rRbBuU]?[fF][rR]?[\"']")
MESSAGE_SUBCOMMANDS = {"commit", "tag", "merge", "stash", "notes"}
ALIASES = {"egrep": "grep", "fgrep": "grep", "gsed": "sed", "gawk": "awk", "mawk": "awk"}
TEXT_ONLY = {"grep", "rg", "sed"}       # their pattern or script is dropped from SCAN
# Per program: short options without a value, options whose next word is a value
# (kept), the option that introduces the pattern, the option that reads it from a
# file, and the long options without a value. Anything else: nothing is dropped.
MODELS = {
    "grep": ("rRniIlLcoqsvwxEFPHhazbUuZ",
             {"-A", "-B", "-C", "-m", "-d", "-D", "--include", "--exclude", "--exclude-dir",
              "--max-count", "--after-context", "--before-context", "--context"},
             {"-e", "--regexp"}, {"-f", "--file"},
             {"--recursive", "--line-number", "--ignore-case", "--files-with-matches",
              "--files-without-match", "--count", "--only-matching", "--quiet", "--silent",
              "--invert-match", "--word-regexp", "--line-regexp", "--extended-regexp",
              "--fixed-strings", "--perl-regexp", "--with-filename", "--no-filename", "--text",
              "--null", "--no-messages", "--color", "--colour"}),
    "rg": ("niIlLcoqsvwxFPHhazuUS",
           {"-A", "-B", "-C", "-m", "-g", "-t", "-T", "-j", "-M", "--glob", "--type", "--type-not",
            "--max-count", "--after-context", "--before-context", "--context", "--threads",
            "--max-columns"},
           {"-e", "--regexp"}, {"-f", "--file"},
           {"--line-number", "--ignore-case", "--smart-case", "--files-with-matches", "--count",
            "--only-matching", "--quiet", "--invert-match", "--word-regexp", "--fixed-strings",
            "--hidden", "--no-ignore", "--no-heading", "--with-filename", "--no-filename",
            "--pcre2", "--multiline", "--text", "--follow", "--color"}),
    "sed": ("nErsuz", set(), {"-e", "--expression"}, {"-f", "--file"},
            {"--quiet", "--silent", "--regexp-extended", "--separate", "--null-data", "--debug",
             "--posix", "--in-place"}),
    "awk": ("", {"-v", "--assign", "-F", "--field-separator"}, set(), {"-f", "--file"}, set()),
}


def pattern_args(name, args):
    """Indexes of the arguments that hold the pattern or script. Empty when it is read from
    a file, glued to its option, or an option is not understood: then nothing is dropped.
    With -e the first plain word is a file, not the pattern (grep -rn DIR -e PATTERN)."""
    noval, value, pattern, from_file, longs = MODELS[name]
    given, positional, options, i, n = [], [], True, 0, len(args)
    while i < n:
        a = args[i]
        if not options or a == "-" or not a.startswith("-"):
            positional.append(i)
            options = options and name != "awk"     # awk stops reading options at its program
            i += 1
        elif a == "--":
            options = False
            i += 1
        elif a in pattern:
            given.append(i + 1)
            i += 2
        elif a in from_file:
            return []
        elif a in value:
            i += 2
        elif a.startswith("--"):
            key = a.split("=", 1)[0]
            if key in pattern or key in from_file or not (key in longs or (key in value and "=" in a)):
                return []
            i += 1
        elif (name == "sed" and a.startswith("-i")) or (name == "awk" and a.startswith("-F")):
            i += 1
        elif all(ch in noval for ch in a[1:]):
            i += 1
        else:
            return []
    return [g for g in given if g < n] if given else positional[:1]


def droppable(w):
    """A word the shell leaves alone: nothing in it is expanded into other words and it
    runs no substitution. Only such a word can be text and nothing else."""
    return not w.splits and not w.inner


def literal_text(w):
    """True for "$(cat <<'EOF' ... EOF)" in double quotes: a substitution that only prints a
    heredoc whose delimiter is quoted. Text and nothing else — the usual commit message."""
    if len(w.inner) != 1 or set(w.unq) != {"\0"} or not (w.startswith("$(") and w.endswith(")")):
        return False
    try:
        pipes = pipelines(lex(w.inner[0]))
    except Unsure:
        return False
    if len(pipes) != 1 or len(pipes[0]) != 1:
        return False
    c = pipes[0][0]
    return c.words == ["cat"] and not c.redirs and len(c.feeds) == 1 and c.feeds[0].body and c.feeds[0].quoted


def reduce_code(code, lang):
    """Inline python or node code: its string literals plus any dotenv mention; attribute
    access such as item.key disappears. Kept whole when the strings cannot be told apart for
    sure: a backtick or triple-quoted string, a python f-string, a quote left unpaired on its
    line, or (node) a slash outside the strings, which may start a regex."""
    rest = LITERAL.sub("", code)
    if ("`" in code or "'''" in code or '"""' in code or "'" in rest or '"' in rest
            or (lang == "python" and FSTRING.search(code)) or (lang == "node" and "/" in rest)):
        return code
    keep = [m.group(1) if m.group(1) is not None else m.group(2) for m in LITERAL.finditer(code)]
    if DOTENV.search(TEMPLATES.sub(r"\2", code)):
        keep.append(".env")
    return " ".join(k for k in keep if k)


def scrub_words(words, depth):
    k = program_index(words, ("xargs",))    # xargs grep PATTERN: the file names come from stdin
    if k >= len(words):
        return list(words)
    prog, head, args = os.path.basename(words[k]), list(words[:k + 1]), list(words[k + 1:])
    name = ALIASES.get(prog, prog)
    if name in TEXT_ONLY:
        for idx in sorted(pattern_args(name, args), reverse=True):
            if droppable(args[idx]) and (name != "sed" or sed_pure(args[idx])):
                del args[idx]
    elif prog == "git":
        sub = next((a for a in args if not a.startswith("-")), "")
        if sub in MESSAGE_SUBCOMMANDS:
            for idx in range(len(args) - 1, 0, -1):
                if args[idx - 1] in ("-m", "--message") and (droppable(args[idx]) or literal_text(args[idx])):
                    del args[idx]
    elif kind(prog) in ("python", "node", "shell"):
        where, at = source(prog, args)
        if where == "code" and droppable(args[at]):
            if kind(prog) != "shell":
                args[at] = reduce_code(args[at], kind(prog))
            elif depth < 3:
                args[at] = scrub(args[at], depth + 1)
    return head + args


def scrub_feed(c, body, depth):
    """A heredoc body or here-string: reduced only when it is the python or node program."""
    k = program_index(c.words)
    if k < len(c.words) and not body.inner:
        prog = os.path.basename(c.words[k])
        if source(prog, c.words[k + 1:])[0] == "stdin":
            if kind(prog) in ("python", "node"):
                return reduce_code(body, kind(prog))
            if kind(prog) == "shell" and depth < 3:
                return scrub(body, depth + 1)
    return body


def scrub(text, depth=0):
    lines = []
    for pipe in pipelines(lex(text)):
        # … | python3, … | sh: what the earlier commands print may be code, so keep it all
        whole = any(fed_by_pipe(pipe, j) for j in range(len(pipe)))
        for c in pipe:
            words = list(c.words) if whole else scrub_words(c.words, depth)
            words += [t for _, t in c.redirs if t is not None]
            words += [b if whole else scrub_feed(c, b, depth) for b in c.feeds]
            lines.append(" ".join(words))
    return "\n".join(lines)


# -------------------------------------------- rule 14: changing a guard file
GUARD_PATH = re.compile(r"\.claude/(hooks/|settings(\.local)?\.json|verify-commands|avn-version)")
GUARD_NAMES = {"avn-version", "bash-guard.sh", "file-guard.sh", "agent-guard.sh", "scope-guard.sh",
               "verify-gate.sh", "verify-commands", "settings.local.json"}
NAME_IN_TEXT = re.compile(r"(^|[^\w.-])(" + "|".join(re.escape(n) for n in sorted(GUARD_NAMES))
                          + r")($|[^\w.-])")
GUARD_DIR = re.compile(r"(^|/)\.claude(/hooks)?/?$")
HARD_MUT = {"mv", "cp", "rm", "chmod", "chown", "tee", "truncate", "ln", "patch", "dd", "install"}
HARD_OLD = re.compile(r"\b(mv|cp|rm|chmod|chown|tee|truncate|ln|patch|dd|install)\b")
# the v2.12.0 test: any of these on a line that names a guard path
OLD_MUT = re.compile(r">|\bgit\s+checkout\b|\b(mv|cp|rm|chmod|chown|tee|sed|awk|truncate|ln|patch|dd"
                     r"|install|python[0-9.]*|perl|ruby|node|npx)\b")
SED = {"sed", "gsed"}
AWK = {"awk", "gawk", "mawk"}
INTERPRETERS = re.compile(r"^(python[0-9.]*|perl|ruby|node|npx)$")
LAUNCHERS = {"xargs", "find", "busybox", "parallel", "watch"}
DECLARE = {"export", "declare", "local", "readonly", "typeset"}
# inline code that can write a file, run a command or load more code
WRITEISH = re.compile(r"\b(open|write\w*|os|subprocess|shutil|pathlib|Path|exec\w*|eval|__import__"
                      r"|unlink\w*|remove\w*|rename\w*|rmtree|system|popen|spawn\w*|fs|child_process"
                      r"|File|IO|fopen|file_put_contents)\b|\b(require|import)\s*\(")


SAFE_MODULES = {"json", "sys", "re", "math", "collections", "itertools", "functools", "textwrap",
                "pprint", "datetime", "string", "operator", "statistics"}
REACHES_OUT = re.compile(r"__|\b(getattr|setattr|globals|locals|vars|compile|modules|breakpoint|input)\b")


def python_reads_only(code):
    """True for python code that can only read stdin and print: it imports nothing but a few
    modules that cannot touch a file, and uses no name that writes, runs or loads code."""
    if WRITEISH.search(code) or REACHES_OUT.search(code):
        return False
    roots = re.findall(r"\bfrom\s+([A-Za-z0-9_]+)", code)
    rest = re.sub(r"\bfrom\s+[\w.]+\s+import\s+[\w., \t*]+", " ", code)
    for names in re.findall(r"\bimport\s+([A-Za-z0-9_., \t]+)", rest):
        roots += [n.split()[0].split(".")[0] for n in names.split(",") if n.split()]
    return all(r in SAFE_MODULES for r in roots)


def is_guard(word):
    w = word.strip("()")
    if GUARD_PATH.search(w) or os.path.basename(w.rstrip("/")) in GUARD_NAMES:
        return True
    return "=" in w and is_guard(w.split("=", 1)[1])      # dd of=…, --output=…


def mentions_guard(text):
    return bool(GUARD_PATH.search(text) or NAME_IN_TEXT.search(text))


def sed_changes(rest, runs):
    """rest: the words after sed. runs: sed is the program here, not a word given to grep."""
    if any(a.startswith("--in-place") or re.match(r"-[a-zA-Z]*i", a) for a in rest):
        return True
    if not runs:
        return False
    scripts = pattern_args("sed", rest)
    return not scripts or any(not sed_pure(rest[s]) for s in scripts)


def awk_changes(rest, runs):
    inplace = any(a.startswith("-i") or a.startswith("--include") for a in rest)
    if not runs:
        return inplace and any("inplace" in a for a in rest)
    progs = pattern_args("awk", rest)
    return inplace or not progs or any(not awk_pure(rest[p]) for p in progs)


def changes_files(c, k, prog, j, in_play, state):
    """True when this simple command can change a guard file. in_play: a guard file is named
    in this pipeline, or by its path anywhere in the command, or the shell stands in .claude."""
    words, args = c.words, c.words[k + 1:]
    if INTERPRETERS.match(prog):
        if any(mentions_guard(t) for t in list(args) + [str(b) for b in c.feeds]):
            return True
        if not in_play:
            return False
        if state["cd"] or state["var"] or any(a.splits or a.var or a.inner for a in args):
            return True
        where, at = source(prog, args)
        if where == "file":
            return False                    # a script that is not given the guard file
        if where == "module":
            return args[at] != "json.tool"
        if where == "unknown":
            return True                     # an option this hook does not know: no telling what runs
        code = [args[at]] if where == "code" else [str(b) for b in c.feeds]
        if not code:                        # no program named: it comes from stdin, unseen
            return j > 0 or any(op in REDIR_IN for op, _ in c.redirs)
        # inline code passes only as python that can do no more than read stdin and print
        return not (kind(prog) == "python" and all(python_reads_only(t) for t in code))
    if not in_play:
        return False
    skip, launched = shell_strings(words)[1], False
    for i, w in enumerate(words):
        if i in skip:
            continue
        b, tail = os.path.basename(w), os.path.basename(w.split("=", 1)[1]) if "=" in w else ""
        if b in HARD_MUT or tail in HARD_MUT or (i > k and INTERPRETERS.match(b)) or INTERPRETERS.match(tail):
            return True
        runs = i == k or launched           # after xargs, find or busybox the next program runs
        if b in SED and sed_changes(words[i + 1:], runs):
            return True
        if b in AWK and awk_changes(words[i + 1:], runs):
            return True
        if WIDE and "\0" in w.unq and not w.inner and (OLD_MUT if re.search(r"\s", w) else HARD_OLD).search(w):
            return True                     # quoted text: the v2.12.0 test
        launched = launched or b in LAUNCHERS
    return False


def judge(pipe, depth, state):
    flat = [w for c in pipe for w in c.words] + [t for c in pipe for _, t in c.redirs if t is not None]
    named = (any(is_guard(w) for w in flat if not w.startswith("-"))
             or any(mentions_guard(b) for c in pipe for b in c.feeds))     # … or it arrives on stdin
    for j, c in enumerate(pipe):
        words = c.words
        k = program_index(words)
        prog = os.path.basename(words[k]) if k < len(words) else ""
        args = words[k + 1:]
        # what this command sets up for the ones after it
        if any(ASSIGN.match(w) and is_guard(w.split("=", 1)[1]) for w in words[:k]) or (
                prog in DECLARE and any("=" in a and is_guard(a.split("=", 1)[1]) for a in args)):
            state["var"] = True
        if prog in ("cd", "pushd") and any(GUARD_DIR.search(a) for a in args):
            state["cd"] = True
        in_play = WIDE or named or state["cd"]
        lines = nested_lines(c)
        # xargs and find put file names into the command they start: in the string they
        # hand to a shell, any word may become a guard file
        strings = shell_strings(words)[0] if any(os.path.basename(w) in LAUNCHERS for w in words) else []
        if fed_by_pipe(pipe, j):            # … | sh, … | python3: the program comes down the pipe
            fed = [str(b) for up in pipe[:j] for b in up.feeds]
            fed += [str(w) for up in pipe[:j] for w in up.words[1:]]
            # the text is in view only when echo, printf or a bare cat with a heredoc prints it
            shown = all(not up.words or os.path.basename(up.words[0]) in ("echo", "printf")
                        or (up.words == ["cat"] and up.feeds) for up in pipe[:j])
            if kind(prog) == "shell" and shown:
                lines += fed
            elif in_play or any(mentions_guard(t) for t in fed):
                return True
        for t in lines:
            if depth < 3:
                if mutates(t, depth + 1, dict(state, launched=True) if t in strings else state):
                    return True
            elif (in_play or mentions_guard(t)) and OLD_MUT.search(t):
                return True
        for op, target in c.redirs:
            if op not in REDIR_OUT or (target is not None and op == ">&" and re.fullmatch(r"[0-9]+|-", target)):
                continue
            if target is not None and is_guard(target):
                return True
            # a target the shell still has to expand, a relative one after cd .claude, or
            # any file at all in a command that xargs or find fills in
            loose = (target is None or target.splits or target.var
                     or (state["cd"] and not target.startswith("/"))
                     or (state.get("launched") and not target.startswith("/dev/")))
            if loose and in_play:
                return True
        if changes_files(c, k, prog, j, in_play, state):
            return True
        git = next((i for i, w in enumerate(words) if os.path.basename(w) == "git"), None)
        if git is not None and "checkout" in words[git + 1:]:
            if WIDE:
                return True                 # v2.12.0: any git checkout on a line that names a guard path
            for o in words[words.index("checkout", git + 1) + 1:]:
                o = o.strip("()")
                b = os.path.basename(o.rstrip("/"))
                if not o.startswith("-") and (b in GUARD_NAMES or b == ".claude" or o in (".", "./")
                                              or "/.claude" in o or o.startswith(".claude")):
                    return True
    return False


def mutates(text, depth, state):
    return any(judge(pipe, depth, state) for pipe in pipelines(lex(text)))


# ------------------------------------------------- rule 15: git worktree add
GIT_VALUE_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def adds_worktree(text, depth=0):
    for pipe in pipelines(lex(text)):
        for c in pipe:
            w = c.words
            for i, t in enumerate(w):
                if os.path.basename(t) != "git":
                    continue
                j = i + 1
                while j < len(w) and w[j].startswith("-"):
                    j += 2 if w[j] in GIT_VALUE_OPTS else 1
                if j < len(w) and w[j] == "worktree":
                    j += 1
                    while j < len(w) and w[j].startswith("-"):
                        j += 1
                    if j < len(w) and w[j] == "add":
                        return True
            for t in nested_lines(c):
                if adds_worktree(t, depth + 1) if depth < 3 else WORKTREE_OLD.search(t):
                    return True
    return False


WORKTREE_OLD = re.compile(r"\bgit\b[^\n;|&]*\bworktree\b[^\n;|&]*\badd\b")

text = sys.stdin.read()
# A guard file is named by its .claude/ path somewhere in the command: every
# construct that can change a file counts, wherever it stands.
WIDE = bool(GUARD_PATH.search(text))
try:
    scan = scrub(text)
except Exception:
    scan = text                 # not sure how bash reads it: search the whole line, as before
try:
    guard = mutates(text, 0, {"cd": False, "var": False})
except Exception:
    guard = bool(mentions_guard(text) and OLD_MUT.search(text))     # the v2.12.0 test
try:
    worktree = "worktree" in text and adds_worktree(text)
except Exception:
    worktree = bool(WORKTREE_OLD.search(text))
report = "avn-analysis guard=%d worktree=%d\n%s" % (bool(guard), bool(worktree), scan)
sys.stdout.buffer.write(report.encode("utf-8", "backslashreplace"))
PY
)
ANALYSIS=$(printf '%s' "$CMD" | python3 -c "$ANALYSE_PY" 2>/dev/null)
case "$ANALYSIS" in
  "avn-analysis guard="[01]" worktree="[01]*)
    ANALYSIS_HEAD=${ANALYSIS%%$'\n'*}
    SCAN=${ANALYSIS#"$ANALYSIS_HEAD"}
    case "$ANALYSIS_HEAD" in *"guard=1"*) GUARD_MUT=BLOCK ;; *) GUARD_MUT=OK ;; esac
    case "$ANALYSIS_HEAD" in *"worktree=1"*) WT_VERDICT=ADD ;; *) WT_VERDICT="" ;; esac
    ;;
  *)
    # The analysis did not run: every rule falls back to the whole line, as in v2.12.0.
    SCAN="$CMD"
    GUARD_MUT=OK
    if echo "$CMD" | grep -Eq '\.claude/(hooks/|settings(\.local)?\.json|verify-commands|avn-version)|(^|[^[:alnum:]_.-])(avn-version|(bash|file|agent|scope)-guard\.sh|verify-gate\.sh|verify-commands|settings\.local\.json)($|[^[:alnum:]_.-])' && \
       echo "$CMD" | grep -Eq '>|\bgit\s+checkout\b|\b(mv|cp|rm|chmod|chown|tee|sed|awk|truncate|ln|patch|dd|install|python[0-9.]*|perl|ruby|node|npx)\b'; then
      GUARD_MUT=BLOCK
    fi
    WT_VERDICT=""
    echo "$CMD" | grep -Eq '\bgit\b.*\bworktree\b.*\badd\b' && WT_VERDICT=ADD
    ;;
esac

# 3a) Reading the machine's own credentials via shell — home-directory key
#     material and cluster configs. These belong to the developer's machine,
#     not the project, so they stay blocked in EVERY profile.
if echo "$SCAN" | grep -Eq '(kubeconfig|\.kube/|\.ssh/|\.aws/|\.docker/config\.json)'; then
  block "command touches home-directory/machine credentials (~/.ssh, ~/.aws, ~/.kube, kubeconfig) — blocked in every profile."
fi

# 3b) Reading project-local secret material via shell (cat/less/head/tail/
#     grep/base64/cp on sensitive paths) — Read() deny rules do not cover
#     Bash. Placeholder templates (.env.example/sample/template/dist) are
#     scrubbed out first; the boundary class excludes "." and word chars so
#     .env.example.bak stays blocked, and \2 re-inserts the boundary so
#     adjacent tokens survive (`cat .env .env.example` still matches on the
#     remaining `.env`). Lifted in the relaxed profile.
if [ "$PROFILE" = "strict" ]; then
  SCRUBBED=$(printf '%s\n' "$SCAN" | sed -E 's/\.env\.(example|sample|template|dist)([^A-Za-z0-9_.]|$)/\2/g')
  if echo "$SCRUBBED" | grep -Eq '(\.env([^a-zA-Z0-9_]|$)|\.env\.|\.pem\b|\.key\b|\.p12\b|\.pfx\b|credentials\.json|secrets/)'; then
    block "command touches secret/credential paths."
  fi
fi

# 4) Printing environment secrets — covers $VAR and ${var} in any case.
#    Lifted in the relaxed profile (isolated system, no real secrets).
if [ "$PROFILE" = "strict" ] && \
   echo "$CMD" | grep -Eiq '\bprintenv\b|\benv\b\s*$|echo\s+.*\$\{?[a-zA-Z_]*(secret|token|key|password|passwd)'; then
  block "printing environment variables that may contain secrets."
fi

# 5) Pipe-from-internet execution
if echo "$CMD" | grep -Eq '(curl|wget)\b.*\|\s*(ba)?sh\b'; then
  block "piping downloaded content into a shell."
fi

# 6) Destructive SQL anywhere in a command line. TABLE keyword is optional in
#    real SQL (TRUNCATE users); the name must start with a letter so coreutils
#    `truncate -s 0 file` passes.
if echo "$CMD" | grep -Eiq '\b(drop\s+(table|database|schema)|truncate\s+(table\s+)?[a-zA-Z_"`])'; then
  block_data "destructive SQL (DROP/TRUNCATE); schema changes belong in a reviewed migration."
fi

# 7) SQL DELETE/UPDATE without a WHERE clause — mass data change. Line-level
#    check: a WHERE anywhere in the command clears it, so a bare DELETE inside
#    a multi-statement string can slip through — this is a seatbelt, not a parser.
if echo "$CMD" | grep -Eiq '\bdelete\s+from\s' && ! echo "$CMD" | grep -Eiq '\bwhere\b'; then
  block_data "SQL DELETE without WHERE (add the WHERE clause if you meant one)."
fi
if echo "$CMD" | grep -Eiq '\bupdate\s+\S+\s+set\s' && ! echo "$CMD" | grep -Eiq '\bwhere\b'; then
  block_data "SQL UPDATE without WHERE (add the WHERE clause if you meant one)."
fi

# 8) Redis keyspace wipe (also catches piped forms like `echo flushall | redis-cli`)
if echo "$CMD" | grep -Eiq '\bflush(all|db)\b'; then
  block_data "redis FLUSHALL/FLUSHDB wipes the keyspace."
fi

# 9) Mongo drops — requires the mongo-shell shape, so pandas df.drop(...) passes
if echo "$CMD" | grep -Eq '\bdropDatabase\b|\bdb\.[a-zA-Z_][a-zA-Z0-9_]*\.drop\s*\('; then
  block_data "mongo dropDatabase()/collection.drop() destroys data."
fi

# 10) Docker volume destruction — (\s+\S+)* tolerates flags between the binary
#     and the subcommand (e.g. docker --context prod volume rm)
if echo "$CMD" | grep -Eq '\bdocker(\s+\S+)*\s+volume\s+(rm|prune)\b'; then
  block_data "docker volume rm/prune destroys data volumes."
fi
if echo "$CMD" | grep -Eq '\bdocker(\s+\S+)*\s+system\s+prune\b.*--volumes'; then
  block_data "docker system prune --volumes destroys data volumes."
fi

# 11) kubectl broad-scope deletes (targeted deletes still go through the ask rule)
if echo "$CMD" | grep -Eq '\bkubectl(\s+\S+)*\s+delete\s+(namespace|ns)\b'; then
  block_data "kubectl delete namespace."
fi
if echo "$CMD" | grep -Eq '\bkubectl(\s+\S+)*\s+delete\b' && \
   echo "$CMD" | grep -Eq -- '--all(-namespaces)?\b|(^|\s)-A\b'; then
  block_data "kubectl delete with broad scope (--all / -A)."
fi

# 12) git clean with force deletes untracked files (the user's work).
#     Preview with `git clean -n` stays allowed.
if echo "$CMD" | grep -Eq '\bgit(\s+-[^ ]+|\s+-C\s+\S+)*\s+clean\b' && \
   echo "$CMD" | grep -Eq '(^|\s)-[a-zA-Z]*f[a-zA-Z]*\b|--force\b'; then
  block "git clean -f deletes untracked files. Preview with git clean -n and ask the user."
fi

# 13) Discarding uncommitted changes — `git checkout .`, any checkout with a
#     `--` pathspec (`checkout -- f`, `checkout HEAD -- src/`), and any
#     `git restore` that is not purely --staged all rewrite working-tree files.
#     Branch switching (`checkout feat/x`, `-b`, `--track origin/x`) and
#     unstaging (`restore --staged .`) still pass. The worktree match covers
#     short combos like -W and -SW.
if echo "$CMD" | grep -Eq '\bgit\s+checkout\s+((\S+\s+)?--\s+)?\.([/[:space:]]|$)' || \
   echo "$CMD" | grep -Eq '\bgit\s+checkout\b[^|;&]*\s--(\s|$)'; then
  block "git checkout of a pathspec discards uncommitted changes to those files. Ask the user."
fi
if echo "$CMD" | grep -Eq '\bgit\s+restore\b'; then
  if ! echo "$CMD" | grep -Eq -- '--staged\b' || \
     echo "$CMD" | grep -Eq -- '--worktree\b|(^|\s)-[a-zA-Z]*W\b'; then
    block "git restore rewrites working-tree files and discards uncommitted changes; only --staged (unstage) passes. Ask the user."
  fi
fi

# 13b) git stash drop/clear permanently deletes stashed work.
if echo "$CMD" | grep -Eq '\bgit\b.*\bstash\s+(drop|clear)\b'; then
  block "git stash drop/clear permanently deletes stashed work. Ask the user."
fi

# 15) git worktree add — worktrees are banned in a governed repo (v2.13.0):
#     work stays in the current checkout and a branch is created there. Judged
#     on the words bash would run (the analysis before rule 3), so a commit
#     message or a grep pattern that only mentions the words passes; `list`,
#     `remove` and `prune` stay allowed for cleaning up worktrees that already
#     exist. The deny rules (EnterWorktree, `git worktree add`, Agent
#     isolation), agent-guard and the WorktreeCreate hook cover the other ways
#     in.
[ "$WT_VERDICT" = "ADD" ] && \
  block "git worktree add — worktrees are disabled in this baseline. Work in the current checkout and create a branch there (git checkout -b)."

# 14) Mutating the baseline guard layer via shell — .claude/hooks/*,
#     settings(.local).json, verify-commands, avn-version. The Edit-tool
#     vector is closed by the deny rules + file-guard; this closes the shell
#     vector. Until v2.12.0 a command that named a guard path was blocked when
#     the line held any `>`, or any of mv, cp, rm, chmod, chown, tee, sed, awk,
#     truncate, ln, patch, dd, install, python, perl, ruby, node, npx or `git
#     checkout` — and every such block in a month of transcripts was a plain
#     read. The analysis before rule 3 runs the same test without what cannot
#     change a file:
#       - an output redirect to a literal target that is not a guard file
#         (2>/dev/null, > listing.txt); a target the shell still has to expand
#         ("$F", *.sh) keeps counting;
#       - sed whose script only prints, deletes or substitutes and has no -i,
#         and awk whose program only reads and prints;
#       - python, perl, ruby, node or npx as the program of a command, when its
#         arguments name no guard file and hold no variable or glob, and its
#         program is a script file, `-m json.tool`, or inline python that can
#         only read stdin and print (it imports nothing that can touch a file).
#         A program that comes down a pipe keeps counting, and so does an
#         interpreter started by xargs or find -exec, or given an option this
#         hook does not know.
#     Everything else counts wherever it stands on a line that names a guard
#     path, also inside the string given to sh -c or eval, a heredoc or a
#     $(...) substitution, so `for f in .claude/hooks/*.sh; do chmod -x "$f";
#     done` stays blocked. After `cd .claude` (or .claude/hooks), or once a
#     variable holds a guard path, every later command is judged that way too.
#     A guard file named only by its bare name (`sed -i … avn-version`) is
#     judged within its pipeline, as the old 14b backstop did. `git checkout`
#     of a guard file, of .claude, or of the whole tree is blocked: restoring an
#     old avn-version stamp would flip the guard profile. Legitimate updates are
#     unaffected: install.sh / avn update rewrite these files inside a script,
#     which this hook never sees on the command line. Still a seatbelt: a
#     deliberately obfuscated command can slip.
[ "$GUARD_MUT" = "BLOCK" ] && \
  block "modifying or reverting baseline guard files (.claude/hooks/, settings.json, verify-commands, avn-version). Run avn update / re-run install.sh, or edit them yourself."

exit 0
