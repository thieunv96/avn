#!/usr/bin/env bash
# Self-test for .claude/hooks/scope-guard.sh — baseline repo only, never installed.
# Feeds PreToolUse (Bash, Read, Grep, Glob) and DirectoryAdded JSON into the hook and asserts the
# exit code (0 = allow, 2 = block). The project, the "other" directories, HOME
# and the scratchpad all live in one scratch tree, so the results never depend
# on the host machine. Usage: bash tests/scope-guard-test.sh

set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/src/hooks/scope-guard.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }

PASS=0 FAIL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# P project · O a sibling directory · N a fake NAS · H home · S the session scratchpad
P="$TMP/proj"; O="$TMP/outside"; N="$TMP/nas"; H="$TMP/home"; S="$TMP/claude-tmp/sess1/scratchpad"
PY="$H/miniconda3/bin/python"
mkdir -p "$P/src/deep" "$P/logs" "$P/tests" "$P/deploy" "$P/build" "$O" "$N/ds" "$S" \
         "$H/.claude/projects" "$H/miniconda3/bin" "$H/miniconda3/lib/python3.11" \
         "$H/miniconda3/etc/profile.d"
: > "$P/src/app.py"; : > "$P/README.md"; : > "$P/notes.txt"
: > "$O/a.txt"; : > "$O/script.py"; : > "$N/ds/x.txt"
: > "$H/.claude/CLAUDE.md"; : > "$PY"; : > "$H/miniconda3/lib/python3.11/site.py"
: > "$H/miniconda3/etc/profile.d/conda.sh"
ln -s "$N/ds" "$P/data"          # a symlink that leaves the project
ln -s "$P/src" "$P/inlink"       # a symlink that stays inside
# ~/.claude: this project's own folder (Claude Code names it after the path), another
# project's folder, a rule, the credentials file, and a virtualenv outside the project
SLUG="$(printf '%s' "$P" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$H/.claude/projects/$SLUG/memory" "$H/.claude/projects/-other-project" \
         "$H/.claude/rules" "$H/venvs/cv/bin"
: > "$H/.claude/projects/$SLUG/memory/MEMORY.md"; : > "$H/.claude/projects/-other-project/a.jsonl"
: > "$H/.claude/rules/x.md"; : > "$H/.claude/.credentials.json"; : > "$H/venvs/cv/bin/activate"

export CLAUDE_PROJECT_DIR="$P" HOME="$H"
SESSION="s1"; CWD="$P"

# payload TOOL COMMAND — a PreToolUse event for TOOL in the current SESSION and CWD
payload() {
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": sys.argv[1],
                  "session_id": sys.argv[3], "cwd": sys.argv[4], "scratchpad_dir": sys.argv[5],
                  "tool_input": {"command": sys.argv[2]}}))' "$1" "$2" "$SESSION" "$CWD" "$S"
}
run_hook() { printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; }
# verdict EXPECTED GOT LABEL
verdict() {
  if [ "$2" -eq "$1" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL: expected %s got %s — %s\n' "$1" "$2" "$3" >&2
  fi
}
# check EXPECTED COMMAND — a Bash call
check()     { local j; j=$(payload Bash "$2"); run_hook "$j"; verdict "$1" $? "[$SESSION] $2"; }
# check_raw EXPECTED RAW_JSON — arbitrary stdin
check_raw() { run_hook "$2"; verdict "$1" $? "raw $2"; }
# check_msg NEEDLE COMMAND — must block and say NEEDLE on stderr
check_msg() {
  local j err got
  j=$(payload Bash "$2")
  err=$(printf '%s' "$j" | bash "$HOOK" 2>&1 >/dev/null); got=$?
  if [ "$got" -eq 2 ] && printf '%s' "$err" | grep -qF -- "$1"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL: expected a block mentioning "%s", got exit %s — %s\n' "$1" "$got" "$2" >&2
  fi
}
# grant DIR — the DirectoryAdded event that /add-dir DIR fires
grant() {
  local j
  j=$(python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "DirectoryAdded", "session_id": sys.argv[2],
                  "cwd": sys.argv[3], "directory": sys.argv[1], "source": "slash_command"}))' "$1" "$SESSION" "$CWD")
  run_hook "$j"; verdict 0 $? "DirectoryAdded $1"
}

# ---- inside the project: reads, writes, redirects, relative paths ----
check 0 'cat src/app.py'
check 0 "cat $P/src/app.py"
check 0 'pytest -q >/dev/null 2>&1'
check 0 'python train.py > logs/t.log 2>&1 &'
check 0 'cd src && cat ../README.md'
check 0 'cat inlink/app.py'                     # a symlink that stays inside the project
check 0 'git status && git diff --stat'
check 0 'ls'

# ---- no grant needed: ~/.claude, the scratchpad, device files, the program being run ----
check 0 "cat $H/.claude/CLAUDE.md"
check 0 "ls $H/.claude/rules"
check 0 "cat $H/.claude/projects/$SLUG/memory/MEMORY.md"   # this project's own memory and sessions
check 0 "echo data > $S/tmp.json"
check 0 "python $S/probe.py"
check 0 'dd if=/dev/zero of=logs/blob.bin bs=1k count=1'
check 0 'head -c 8 /dev/urandom'
check 0 'echo hi > /dev/stderr'
check 0 "CUDA_VISIBLE_DEVICES=0 nohup $PY train.py > logs/t.log 2>&1 &"
check 0 "timeout 60 $PY -m pytest tests/"
check 0 "env PYTHONUNBUFFERED=1 $PY train.py"
check 0 "source $H/miniconda3/etc/profile.d/conda.sh && conda activate cv"
check 0 "source $H/venvs/cv/bin/activate"       # activating an environment is running it
check 0 'ls /dev'
check 0 'ls /dev/video*'                        # device files, also through a glob
check 0 'ls -l /dev/nvidia*'
check 0 $'cd src\n'"$PY"$' run.py'              # a new line starts a new command
check 0 'LD_LIBRARY_PATH=/usr/local/lib ./build/app'   # leading assignments are not judged

# ---- text that only looks like a path ----
check 0 "sed '/tmp/d' notes.txt"
check 0 "awk '/tmp/ {print}' notes.txt"
check 0 "grep -rn '/etc/nginx' deploy/"
check 0 "grep -rn '/api/v1' src/"
check 0 "find . -name '/tmp*'"
check 0 'curl -s http://localhost:8000/media/x.png -o logs/x.png'
check 0 "echo '</div>' >> src/page.html"
check 0 'echo /etc/hosts'
check 0 'git commit -m "fix: stop writing to /tmp"'
check 0 $'git commit -m "$(cat <<\'EOF\'\nsee /etc/hosts\nEOF\n)"'
check 0 $'cat > notes.txt <<\'EOF\'\npaths: /etc/hosts\nEOF'
check 0 'expr 6 / 2'
check 0 'echo $(( 10 / 2 ))'                    # shell arithmetic, not the filesystem root
check 0 'if (( total / 2 > 3 )); then echo big; fi'
check 0 "echo a/b | tr / '\\n'"                 # a character set
check 0 'echo "$(git rev-parse --short HEAD)"'
check 0 'python -c "print(7 // 2)"'             # integer division, not a path
check 0 $'python - <<\'EOF\'\nmid = len(a) // 2\nEOF'
check 0 'node -e "x = 1 // a comment"'
check 0 'git branch -r | cut -d / -f 2'         # a separator given to an option
check 0 'sort -t / -k 2 notes.txt'
check 0 'df -h /'
check 0 'ls src # see /etc for the rest'        # a shell comment
check 0 'git clone https://github.com/x/y.git vendor/y'
check 0 'scp user@host:/etc/hosts .'
check 0 'rsync -a src/ host:/data/'
check 0 'python -c "print(1 / 2)"'

# ---- the far side of a container or a remote shell is not this machine ----
check 0 'docker exec web cat /etc/nginx/nginx.conf'
check 0 'docker run --rm -v "$PWD":/work -w /work img ls /usr/lib'
check 0 'docker run --rm -v data:/var/lib/data img'    # a named volume, not a host path
check 0 'docker compose exec web ls /tmp'
check 0 'kubectl exec pod -- cat /etc/hosts'
check 0 "ssh host 'tail -n 5 /var/log/syslog'"

# ---- documented misses: only paths written out in the command are seen ----
check 0 'cat "$DATA_DIR/x.txt"'
check 0 'ls $(pwd)/tmp'
check 0 "PYTHONPATH=$O python x.py"

# ---- machine credentials are never granted: blocked without /add-dir advice ----
check_msg 'never granted' 'cat ~/.ssh/id_rsa'
check_msg 'never granted' 'ls ~/.ssh'            # bash-guard rule 3a needs the trailing slash; this hook does not
check_msg 'never granted' 'kubectl --kubeconfig /etc/k8s/kubeconfig get pods'
check_msg 'never granted' "cat $H/.claude/.credentials.json"

# ---- outside the session directories: blocked until /add-dir ----
check 2 'cat /etc/hosts'
check 2 'cat /proc/cpuinfo'
check 2 'ls ~'
check 2 'ls /'
check 2 "find / -name '*.pt'"
check 2 "cat $O/a.txt"
check 2 "grep -rn foo $O"
check 2 "ls $O/*.txt"
check 2 "find $O -name '*.txt'"
check 2 "git -C $O status"
check 2 "cd $O && ls"
check 2 'cat ../outside/a.txt'
check 2 'cd src/deep && cat ../../../outside/a.txt'
check 2 'cat data/x.txt'                        # the symlink leaves the project
check 2 'ls data'
check 2 "cat $H/miniconda3/lib/python3.11/site.py"   # reading there is not running it
check 2 "$PY $O/script.py"
check 2 "python train.py --data $N/ds"
check 2 "python train.py --data=$N/ds"
check 2 "python train.py data.root=$N/ds"
check 2 "docker run -v $N/ds:/data img"
check 2 "docker run --mount type=bind,source=$N/ds,target=/data img"
check 2 "docker cp web:/app/log.txt $O/log.txt"
check 2 "tar -xzf $O/a.tgz -C src"
check 2 "cp a.txt $O/"
check 2 "ln -s $N/ds data2"
check 2 'cat /e*/hosts'                         # a glob in the first component lists /
check 2 'cat /et?/hosts'
check 2 'cd /e* && cat hosts'
check 2 'ls ~root'                              # another user's home
check 2 "source $O/script.py"                   # sourcing a script from elsewhere
check 2 'find . -name x -exec cat /etc/hosts \;'
check 2 'find . -fprint /tmp/found.txt'
check 2 'env -C /etc cat hosts'
check 2 'ls ~/.claude'                          # only the parts a session needs are open
check 2 'ls ~/.claude/projects'
check 2 "cat $H/.claude/projects/-other-project/a.jsonl"   # another project's sessions

# ---- writes and redirects outside ----
check 2 "echo x > $O/new.txt"
check 2 'mkdir -p /tmp/a/b/c'
check 2 "make &>> $O/all.log"
check 2 "pytest | tee $O/log.txt"
check 2 "echo hi>$O/x;ls"                       # no spaces around the operators
check 2 '(echo x)>/tmp/f'                       # a redirect glued to another operator
check 2 'true;>/tmp/f'
check_msg 'scratchpad' 'echo x > /tmp/avn-scope-probe.txt'
check_msg '/add-dir' "cat $O/a.txt"
# the output file of this project's background commands is read with the Read tool, which
# the hook lets through (see the file-tool cases below); another project's is just outside
check_msg 'Read tool' "tail -n 20 /tmp/claude-1000/$SLUG/0d78bd80-5707/tasks/b1.output"
check_msg '/add-dir' 'tail -n 20 /tmp/claude-1000/-home-u-proj/0d78bd80-5707/tasks/b1.output'

# ---- inline code and nested shells ----
check 2 "python -c \"print(open('$O/a.txt').read())\""
check 2 "bash -c \"cat $O/a.txt\""
check 2 "X=\$(cat $O/a.txt)"
check 2 'echo "$(cat /etc/hosts)"'              # a substitution inside quotes is still a command
check 2 "LIST=\"\$(ls $N/ds)\""
check 2 "echo \`cat $O/a.txt\`"
check 2 $'python - <<\'EOF\'\nopen("'"$O"$'/a.txt")\nEOF'
check 2 $'bash <<\'EOF\'\ncat '"$O"$'/a.txt\nEOF'
check 2 "echo it's; cat $O/a.txt"               # unbalanced quote: fallback tokeniser
check 2 "grep -rnw $O -e foo"                   # -e gives the pattern, so the first word is a directory
check 2 "grep -rn --regexp=foo $O"
check 2 "sed -n -e p $O/a.txt"
check 0 'grep -rn -e foo -e bar src/'
check 2 $'echo "use << EOF for a heredoc"\ncat '"$O"'/a.txt'    # no terminator: not a heredoc
check 2 $'cat <<EOF-1\ntext\nEOF-1\ncat '"$O"'/a.txt'           # the delimiter is EOF-1, not EOF
check 2 $'cat <<\'EOF\' | sh\ncat '"$O"$'/a.txt\nEOF'             # a heredoc piped into a shell is a script
check 2 "bash <<< 'cat $O/a.txt'"                # so is a here-string given to one
check 0 "grep foo <<< 'see /etc/hosts'"          # text for grep, not a path

# ---- second review (v2.13.0): the hook reads the command as bash does ----
check 2 $': # <<EOF\ncat /etc/hosts\nEOF'                   # a heredoc marker inside a comment is no heredoc
check 2 $'echo "<<EOF "\ncat /etc/hosts\nEOF'               # ...nor one inside quotes
check 2 $'ls #\'\ncat /etc/hosts\n#\''                      # quotes inside comments pair with nothing
check 2 "cat '((' /etc/hosts '))'"                          # quoted parentheses are not arithmetic
check 2 ': $(( $(cp /etc/hosts src/h.txt; echo 0) ))'       # a substitution inside arithmetic still runs
check 2 'cat {x,/etc/hosts}'                                 # brace expansion
check 2 "cat {x,$O/a.txt}"
check 2 "cat \$'/etc/hosts'"                                 # ANSI-C quoting
check 2 "cat \$'$O/a\\x2etxt'"
check 2 "echo /x >> \$'$H/.claude/avn-scope/s1'"            # the grant file, however it is spelled
check 2 "echo /x >> {y,$H/.claude/avn-scope/s1}"
check 2 $'sudo python3 - <<\'EOF\'\nprint(open(\'/etc/hosts\').read())\nEOF'
check 2 $'env bash <<\'EOF\'\ncat /etc/hosts\nEOF'
check 2 $'cat <<\'EOF\' | python3\nprint(open(\'/etc/hosts\').read())\nEOF'
check 2 "echo 'cat /etc/hosts' | sh"
check 2 "bash <<< 'cat ../outside/a.txt'"                    # shell code from a here-string: relative paths too
check 2 $'bash <<\'EOF\'\ncat ../outside/a.txt\nEOF'
check 2 'cat data/../ds/x.txt'                               # .. after a symlink that leaves the project
check 2 'find -L /etc -name hosts -exec cat {} +'           # find's own options come before the start points
check 2 "grep -- '-*' /etc/hosts"
check 2 "grep --color '' /etc/hosts"
check 2 "grep -T '' /etc/hosts"
check 2 'grep -v {x,/etc/hosts}'
check 2 'grep --file=/etc/hosts src/app.py'
check 2 $'awk \'BEGIN{while((getline l < "/etc/hosts")>0) print l}\''   # a script that opens a file itself
check 2 "sed -n 'w /tmp/out.txt' src/app.py"
check 2 'yq /etc/hosts'
check 0 'mkdir -p src/{a,b,c}'                               # brace expansion inside the project
check 0 'for i in {1..5}; do echo $i; done'
check 0 "printf '%s\\n' \$'a\\tb'"
check 0 'grep -A 3 -m 1 TODO src/app.py'
check 0 "sed -n '/tmp/p' notes.txt | head -3"
check 0 'echo $((1 << 4)) > notes.txt'
check 0 'if [[ -f src/app.py && $x < 5 ]]; then echo ok; fi'

# ---- the grant file is written by /add-dir only ----
check 2 "echo $N >> $H/.claude/avn-scope/s1"
check 2 "cd $H/.claude && echo $N >> avn-scope/s1"
check 2 "cat $H/.claude/avn-scope/s1"
check 2 "echo /x >> $H/.claude/avn-sc*/s1"      # a glob that can land on the grant files
check 2 "for f in $H/.claude/avn-s*/*; do echo /x >> \"\$f\"; done"
check 2 "echo /x >> $H/.claude/avn-scope/\$SID" # ...or a variable
check 2 "sed -i s/a/b/ $H/.claude/settin*.json" # the user settings this hook trusts

# ---- /add-dir: one grant per directory, per session ----
grant "$N"
check 0 "ls $N/ds"
check 0 'cat data/x.txt'                        # the symlink now lands in a granted directory
check 0 "python train.py --data=$N/ds"
check 0 "docker run -v $N/ds:/data img"
check 2 "cat $O/a.txt"                          # a grant covers its own directory only
SESSION="s2"
check 2 "ls $N/ds"                              # another session starts without grants
SESSION="s3"
grant "$H"                                      # even a grant of the whole home directory...
check 0 "cat $H/miniconda3/lib/python3.11/site.py"
check_msg 'never granted' 'ls ~/.ssh'           # ...never covers credentials
check 2 "cat $H/.claude/avn-scope/s3"           # ...nor the grant files
SESSION="s1"

# ---- grant files older than 30 days are removed at the next grant ----
: > "$H/.claude/avn-scope/stale"
python3 -c 'import os, sys, time; t = time.time() - 40 * 86400; os.utime(sys.argv[1], (t, t))' "$H/.claude/avn-scope/stale"
grant "$TMP/extra"
[ ! -e "$H/.claude/avn-scope/stale" ]; verdict 0 $? "a stale grant file is cleaned up"
[ -f "$H/.claude/avn-scope/s1" ];      verdict 0 $? "the current grant file survives the cleanup"

# ---- user-level additionalDirectories count as granted ----
printf '{"permissions": {"additionalDirectories": ["%s"]}}\n' "$O" > "$H/.claude/settings.json"
check 0 "cat $O/a.txt"
rm -f "$H/.claude/settings.json"
check 2 "cat $O/a.txt"
# ...and so does a directory /add-dir remembered in the project's local settings
mkdir -p "$P/.claude"
printf '{"permissions": {"additionalDirectories": ["%s"]}}\n' "$O" > "$P/.claude/settings.local.json"
check 0 "cat $O/a.txt"
rm -f "$P/.claude/settings.local.json"
check 2 "cat $O/a.txt"

# ---- without scratchpad_dir in the event, the scratchpad is recognised by the session id ----
check_raw 0 '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"abc-123","cwd":"'"$P"'","tool_input":{"command":"echo x > /tmp/claude-1000/-proj/abc-123/scratchpad/a.txt"}}'
check_raw 2 '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"abc-123","cwd":"'"$P"'","tool_input":{"command":"echo x > /tmp/claude-1000/-proj/other-999/scratchpad/a.txt"}}'

# ---- other tools, other events, malformed input ----
check_raw 2 "$(payload Monitor "tail -f $O/a.txt")"    # Monitor arrives under the Bash matcher
check_raw 0 'not-json'
check_raw 0 '{}'
check_raw 0 '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":""}}'
check_raw 0 '{"hook_event_name":"DirectoryAdded","directory":"/x"}'    # no session id: nothing to record
check_raw 0 '{"hook_event_name":"Stop","session_id":"s1"}'

# ---- third review (v2.13.0) ----
check 2 $'echo $(: #) ; grep -e \'\ncat /etc/hosts\n\'\\\' )'     # a comment inside $( ... )
check 2 $'true\r# ; cat /etc/hosts'                               # a carriage return is not a space
check 2 "cat /etc/\$'\\ud800' /etc/hosts"                         # a path the answer cannot print as UTF-8
check 2 $'cat <<\'EOF\' | python3 -W ignore\nprint(open(\'/etc/hosts\').read())\nEOF'

# ---- a command the reader is not sure about: every absolute path in the text is judged ----
check 2 "echo 'unterminated; cat $O/a.txt"
check 0 "echo 'unterminated; cat src/app.py"

# ---- file tools (v2.13.1): Read, Grep and Glob meet the same boundary as Bash ----
# tool_payload TOOL INPUT_JSON — a PreToolUse event for a file tool
tool_payload() {
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": sys.argv[1],
                  "session_id": sys.argv[3], "cwd": sys.argv[4], "scratchpad_dir": sys.argv[5],
                  "tool_input": json.loads(sys.argv[2])}))' "$1" "$2" "$SESSION" "$CWD" "$S"
}
# check_tool EXPECTED TOOL INPUT_JSON
check_tool() { local j; j=$(tool_payload "$2" "$3"); run_hook "$j"; verdict "$1" $? "[$SESSION] $2 $3"; }
# check_tool_msg NEEDLE TOOL INPUT_JSON — must block and say NEEDLE on stderr
check_tool_msg() {
  local j err got
  j=$(tool_payload "$2" "$3")
  err=$(printf '%s' "$j" | bash "$HOOK" 2>&1 >/dev/null); got=$?
  if [ "$got" -eq 2 ] && printf '%s' "$err" | grep -qF -- "$1"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL: expected a block mentioning "%s", got exit %s — %s %s\n' "$1" "$got" "$2" "$3" >&2
  fi
}
SESSION="f1"                                    # a session without any grant
mkdir -p "$H/.claude/plugins/cache/p/skills/s/references"
: > "$H/.claude/plugins/cache/p/skills/s/references/guide.md"
: > "$H/.claude/GIT-CONVENTIONS.md"; : > "$H/.claude/settings.json"
TASKS="/tmp/claude-1000/$SLUG/0d78bd80-5707/tasks"
# inside the project
check_tool 0 Read "{\"file_path\": \"$P/src/app.py\"}"
check_tool 0 Read '{"file_path": "src/app.py"}'             # relative to the session's cwd
check_tool 0 Read "{\"file_path\": \"$P/inlink/app.py\"}"   # a symlink that stays inside
check_tool 0 Read "{\"file_path\": \"$P/src/not-yet.py\"}"  # nothing there: the tool reports that itself
check_tool 0 Grep '{"pattern": "/etc/hosts"}'               # no path: the project; the pattern is text
check_tool 0 Grep "{\"pattern\": \"foo\", \"path\": \"$P/src\", \"glob\": \"*.py\"}"
check_tool 0 Glob '{"pattern": "**/*.py"}'
check_tool 0 Glob "{\"pattern\": \"*.py\", \"path\": \"$P/src\"}"
check_tool 0 Glob "{\"pattern\": \"$P/src/**/*.py\"}"
# outside the project: blocked until /add-dir
check_tool 2 Read '{"file_path": "/etc/hosts"}'
check_tool 2 Read "{\"file_path\": \"$O/a.txt\"}"
check_tool 2 Read '{"file_path": "../outside/a.txt"}'
check_tool 2 Read "{\"file_path\": \"$P/data/x.txt\"}"      # the symlink leaves the project
check_tool 2 Read '{"file_path": "~/notes.txt"}'
check_tool 2 Grep "{\"pattern\": \"foo\", \"path\": \"$N/ds\"}"
check_tool 2 Glob "{\"pattern\": \"*.txt\", \"path\": \"$O\"}"
check_tool 2 Glob "{\"pattern\": \"$O/**/*.txt\"}"          # an absolute pattern lists its fixed directory
check_tool 2 Glob '{"pattern": "/e*/hosts"}'
check_tool 2 Glob '{"pattern": "../outside/*.txt"}'         # a relative pattern that climbs out
check_tool 2 Glob "{\"pattern\": \"$O/a.txt\"}"             # a pattern without a wildcard is a path
check_tool 0 Glob '{"pattern": "src/app.py"}'
CWD="$P/src"
check_tool 0 Read '{"file_path": "../README.md"}'           # the shell has moved into a subdirectory
check_tool 2 Read '{"file_path": "../../outside/a.txt"}'
CWD="$P"
check_tool_msg '/add-dir' Read "{\"file_path\": \"$O/a.txt\"}"
# ~/.claude: what Bash may use, plus the plugins and the top-level .md files
check_tool 0 Read "{\"file_path\": \"$H/.claude/CLAUDE.md\"}"
check_tool 0 Read "{\"file_path\": \"$H/.claude/rules/x.md\"}"
check_tool 0 Read "{\"file_path\": \"$H/.claude/projects/$SLUG/memory/MEMORY.md\"}"
check_tool 0 Read "{\"file_path\": \"$H/.claude/plugins/cache/p/skills/s/references/guide.md\"}"
check_tool 0 Glob "{\"pattern\": \"**/*.md\", \"path\": \"$H/.claude/plugins/cache/p\"}"
check_tool 0 Read "{\"file_path\": \"$H/.claude/GIT-CONVENTIONS.md\"}"
check_tool 2 Read "{\"file_path\": \"$H/.claude/settings.json\"}"
check_tool 2 Read "{\"file_path\": \"$H/.claude/projects/-other-project/a.jsonl\"}"
check_tool 2 Read "{\"file_path\": \"$H/.claude/avn-scope/s1\"}"
check_tool 2 Grep "{\"pattern\": \"x\", \"path\": \"$H/.claude\"}"
check_tool 2 Glob "{\"pattern\": \"$H/.claude/*.md\"}"      # lists ~/.claude itself
check_tool_msg 'never granted' Read "{\"file_path\": \"$H/.claude/.credentials.json\"}"
check_tool_msg 'never granted' Read "{\"file_path\": \"$H/.ssh/id_rsa\"}"
check 2 "cat $H/.claude/plugins/cache/p/skills/s/references/guide.md"   # Bash keeps its narrower list
check 2 "cat $H/.claude/GIT-CONVENTIONS.md"
# the scratchpad, and the output file of this project's background commands
check_tool 0 Read "{\"file_path\": \"$S/notes.md\"}"
check_tool 0 Read "{\"file_path\": \"$TASKS/b1.output\"}"
check_tool 2 Read '{"file_path": "/tmp/claude-1000/-other-project/0d78bd80-5707/tasks/b1.output"}'
check_tool 2 Read "{\"file_path\": \"$TASKS/../../../x.output\"}"
# a path that only looks like one is judged like any other path
check_tool 2 Read "{\"file_path\": \"$O/claude-1/$SLUG/x/tasks/a.output\"}"
check_tool 2 Read "{\"file_path\": \"$H/.claude/avn-scope/claude-1/$SLUG/x/tasks/a.output\"}"
check_tool_msg 'never granted' Read "{\"file_path\": \"$H/.ssh/claude-1/$SLUG/x/tasks/a.output\"}"
# a top-level .md that is a symlink is judged by where it leads
ln -s "$O/a.txt" "$H/.claude/linked-out.md"; ln -s rules/x.md "$H/.claude/linked-in.md"
check_tool 2 Read "{\"file_path\": \"$H/.claude/linked-out.md\"}"
check_tool 0 Read "{\"file_path\": \"$H/.claude/linked-in.md\"}"
# past its fixed part a Glob pattern may not start over somewhere else
check_tool 2 Glob '{"pattern": "{/etc,src}/*"}'
check_tool 2 Glob '{"pattern": "{../outside,src}/*.txt"}'
check_tool 2 Glob '{"pattern": "*/../../outside/*.txt"}'
check_tool 0 Glob '{"pattern": "src/{deep,x}/**/*.py"}'
check_tool 0 Glob '{"pattern": "**/*.{py,md}"}'
# one grant covers the file tools and Bash alike
grant "$O"
check_tool 0 Read "{\"file_path\": \"$O/a.txt\"}"
check_tool 0 Glob "{\"pattern\": \"$O/**/*.txt\"}"
check_tool 2 Read "{\"file_path\": \"$N/ds/x.txt\"}"
# the write tools are not judged here: permissions.blockWritesOutsideWorkingDirectories refuses them
check_tool 0 Write "{\"file_path\": \"$N/new.txt\", \"content\": \"x\"}"
check_tool 0 Edit "{\"file_path\": \"$N/ds/x.txt\", \"old_string\": \"a\", \"new_string\": \"b\"}"
# input the hook cannot read is not judged
check_tool 0 Read '{}'
check_tool 0 Read '{"file_path": 7}'
SESSION="s1"

# ---- the shell reader is the same text in this hook and in bash-guard.sh ----
reader_of() { sed -n '/^# ---- shell reader/,/^# ---- end of shell reader ----/p' "$1"; }
READER_HERE="$(reader_of "$HOOK")"
[ -n "$READER_HERE" ] && [ "$READER_HERE" = "$(reader_of "$(dirname "$HOOK")/bash-guard.sh")" ]
verdict 0 $? "the shell reader block is identical in scope-guard.sh and bash-guard.sh"

# ---- fail closed without python3 ----
SHIM="$TMP/shim"; mkdir -p "$SHIM"
ln -s "$(command -v bash)" "$SHIM/bash"
J="$(payload Bash 'ls')"
printf '%s' "$J" | PATH="$SHIM" bash "$HOOK" >/dev/null 2>&1
verdict 2 $? "python3 missing must fail closed"

printf '\nscope-guard-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
