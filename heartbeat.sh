#!/usr/bin/env bash
#
# mon.red Heartbeat Monitor: sends one heartbeat of a GitHub Actions job to a heartbeat monitor of mon.red (https://mon.red).
#
# The inputs come only from the environment (action.yml puts them there), so nothing of them is ever a part of the code of the shell:
#   HB_URL      the URL of the monitor, a secret: https://ping.mon.red/<token>
#   HB_STATUS   success | failure | cancelled | skipped | start (job.status and needs.<job>.result give the first four)
#   HB_MESSAGE  a short text for mon.red. Empty: the workflow, the number of the run, the branch and the link to the run
#   HB_TIMEOUT  seconds for one request
#   HB_FAIL     true: the step fails when mon.red has not accepted the heartbeat
#
# What mon.red takes: the URL itself is a success, <url>/fail a failure (an alert at once), <url>/start the start of the job (mon.red
# counts how long it runs and alerts when the end does not come within the grace time), ?msg= a text of up to 200 bytes (mon.red keeps it
# as one line). It answers "OK" when it has taken the heartbeat (also when the monitor is paused), 404 to a token it does not know, 429
# after 60 heartbeats a minute for one monitor.
# Outputs: sent (true | false) and response-code (the HTTP code, empty when mon.red could not be reached).
# Exit code: 0, also when the heartbeat was not delivered, unless HB_FAIL is true. A wrong input always fails the step.
#
# Written for bash 3.2 too (macOS): no ${var,,}, no associative arrays.

VERSION=1.0.1   # the version of the release (in the User-Agent): change it with every release, CHANGELOG.md
MSG_MAX=200     # bytes: mon.red keeps no more of the text

sent=false     # the outputs: written once, when the script ends (finish)
rcode=''

finish() { if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'sent=%s\nresponse-code=%s\n' "$sent" "$rcode" >> "$GITHUB_OUTPUT"; fi; exit "$1"; }
fail()   { printf '::error::%s\n' "$1"; finish 1; }
line()   { printf '%s' "$1" | tr '\r\n\t' '   '; }
trim()   { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
lower()  { line "$1" | tr '[:upper:]' '[:lower:]'; }
bytes()  { local LC_ALL=C; printf '%s' "${#1}"; }

# the first $2 bytes of $1, without a character of UTF-8 cut in the middle: the bytes 10xxxxxx at the end continue a character, the
# byte before them starts it and tells how long it is (110xxxxx 2, 1110xxxx 3, 11110xxx 4); an incomplete one is dropped
cut_bytes()
{
  local LC_ALL=C
  local s=$1 max=$2 i n b need

  if [ "${#s}" -le "$max" ]; then printf '%s' "$s"; return; fi

  s=${s:0:max}
  n=0
  i=$(( ${#s} - 1 ))

  while [ "$i" -ge 0 ]; do
    printf -v b '%d' "'${s:i:1}"
    [ "$b" -lt 0 ] && b=$(( b + 256 ))
    if [ "$b" -ge 128 ] && [ "$b" -lt 192 ] && [ "$n" -lt 3 ]; then n=$(( n + 1 )); i=$(( i - 1 )); else break; fi
  done

  if [ "$i" -lt 0 ]; then return; fi

  printf -v b '%d' "'${s:i:1}"
  [ "$b" -lt 0 ] && b=$(( b + 256 ))

  if   [ "$b" -lt 128 ]; then need=1
  elif [ "$b" -lt 224 ]; then need=2
  elif [ "$b" -lt 240 ]; then need=3
  else                        need=4
  fi

  if [ "$need" -eq 1 ]; then
    s=${s:0:i+1}                                  # stray bytes after a plain one: dropped
  elif [ $(( n + 1 )) -lt "$need" ]; then
    s=${s:0:i}                                    # the last character is not whole
  fi

  printf '%s' "$s"
}

# ---- the inputs

url=$(trim "${HB_URL:-}")

if [ -z "$url" ]; then
  fail 'The input "url" is empty. Put the heartbeat URL of your mon.red monitor into a secret of the repository (for example MONRED_HEARTBEAT_URL) and pass it as url. Secrets are empty in pull requests from forks and from Dependabot: run the step only on schedule there'
fi

# the URL never shows in the log: neither the whole one nor its token (GitHub masks secrets itself, this covers a URL that came another way)
printf '::add-mask::%s\n' "$(line "$url")"

base=${url%%[?#]*}
base=${base%/}
token=${base##*/}

if [ "${#token}" -ge 8 ]; then printf '::add-mask::%s\n' "$(line "$token")"; fi

case "$base" in
  http://*|https://*) ;;
  *) fail 'The input "url" must start with https://, copy it from the card of your heartbeat monitor at mon.red' ;;
esac

status=$(lower "$(trim "${HB_STATUS:-}")")
[ -z "$status" ] && status=success

case "$status" in
  success)                   path=''       ;;
  start)                     path='/start' ;;
  failure|cancelled|skipped) path='/fail'  ;;
  *) fail "The input \"status\" is \"$(cut_bytes "$status" 40)\": use success, failure, cancelled, skipped (job.status gives them) or start" ;;
esac

timeout=$(trim "${HB_TIMEOUT:-}")
[ -z "$timeout" ] && timeout=10

case "$timeout" in
  *[!0-9]*|????*) fail "The input \"timeout\" must be a whole number of seconds from 1 to 300, it is \"$(cut_bytes "$(line "$timeout")" 40)\"" ;;
esac

timeout=$(( 10#$timeout ))
if [ "$timeout" -lt 1 ] || [ "$timeout" -gt 300 ]; then fail "The input \"timeout\" must be from 1 to 300 seconds, it is $timeout"; fi

strict=$(lower "$(trim "${HB_FAIL:-}")")
[ -z "$strict" ] && strict=false

case "$strict" in
  true|false) ;;
  *) fail "The input \"fail-on-error\" must be true or false, it is \"$(cut_bytes "$strict" 40)\"" ;;
esac

# ---- the text: one line of up to 200 bytes. Without a message of the user: "<workflow> #<run> on <branch>, <link to the run>": the
# name of the workflow is shortened when it is long, the rest is kept whole (without the link when even that is too long). A cancelled
# or skipped job is sent as a failure, the text says what it was

msg=$(trim "$(line "${HB_MESSAGE:-}")")

if [ -n "$msg" ]; then
  case "$status" in cancelled|skipped) msg="($status) $msg" ;; esac
  msg=$(cut_bytes "$msg" "$MSG_MAX")
elif [ -n "${GITHUB_RUN_ID:-}" ]; then
  rest=" #${GITHUB_RUN_NUMBER:-?}"
  [ -n "${GITHUB_REF_NAME:-}" ] && rest="$rest on $GITHUB_REF_NAME"
  case "$status" in cancelled|skipped) rest="$rest was $status" ;; esac
  rest=$(line "$rest")

  link=", ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
  [ $(( $(bytes "$rest") + $(bytes "$link") )) -gt 170 ] && link=''
  rest=$(cut_bytes "$rest$link" 170)

  msg="$(cut_bytes "$(line "${GITHUB_WORKFLOW:-Workflow}")" $(( MSG_MAX - $(bytes "$rest") )))$rest"
fi

# ---- the request: one retry after 3 seconds when mon.red could not be reached or answered 5xx. No redirects: the URL from the card is
# the one to call, a redirect leads elsewhere (http://ping.mon.red/<token> goes to the site, not to the heartbeat)

# curl writes the code of the answer on a line of its own after everything else: before it the body or, without an answer, its error
send()
{
  local res

  if [ -n "$msg" ]; then
    res=$(curl -sS --max-time "$timeout" -A "mon-red-heartbeat-action/$VERSION" -G --data-urlencode "msg=$msg" -w '\n%{http_code}' "$base$path" 2>&1)
  else
    res=$(curl -sS --max-time "$timeout" -A "mon-red-heartbeat-action/$VERSION" -w '\n%{http_code}' "$base$path" 2>&1)
  fi

  code=${res##*$'\n'}
  body=${res%$'\n'*}

  case "$code" in [1-5][0-9][0-9]) ;; *) code=000 ;; esac
}

send

case "$code" in
  000|5??) sleep 3; send ;;
esac

# ---- the result

case "$status" in
  cancelled|skipped) shown="$status, sent as a failure" ;;
  *)                 shown=$status ;;
esac

[ "$code" != 000 ] && rcode=$code

case "$code" in
  2??)
    if [ "$(trim "$body")" = OK ]; then
      sent=true
      printf '::notice::Heartbeat sent to mon.red (status: %s)\n' "$shown"
      finish 0
    fi
    problem='The URL answered, but not as a heartbeat URL of mon.red. Copy the URL again from the card of your heartbeat monitor at mon.red into the secret'
    ;;
  000)
    problem="Could not reach mon.red: $(cut_bytes "$(trim "$(line "$body")")" 200)"
    [ "$problem" = 'Could not reach mon.red: ' ] && problem='Could not reach mon.red'
    ;;
  3??)
    problem="mon.red answered HTTP $code (a redirect), the heartbeat was not accepted. Use the https:// URL from the card of your heartbeat monitor"
    ;;
  404)
    problem='mon.red does not know this heartbeat URL (HTTP 404). Copy the URL again from the card of your heartbeat monitor at mon.red into the secret'
    ;;
  429)
    problem='mon.red takes up to 60 heartbeats a minute for one monitor, this one was refused (HTTP 429)'
    ;;
  *)
    problem="mon.red answered HTTP $code, the heartbeat was not accepted"
    ;;
esac

if [ "$strict" = true ]; then
  printf '::error::%s\n' "$problem"
  finish 1
fi

printf '::warning::%s (the step does not fail: fail-on-error is false)\n' "$problem"
finish 0
