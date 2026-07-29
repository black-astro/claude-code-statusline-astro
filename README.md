# claude-code-statusline-astro

A cross-platform, colored status line for [Claude Code](https://claude.com/claude-code).

```
DIR claude-code-statusline-astro | GIT main | MODEL Opus 5 | CTX [ ■ ■ ■ ■ □ □ □ □ □ □ ] 42% | 5H [ ■ ■ ■ ■ ■ ■ □ □ □ □ ] 63%
```

Two implementations that print byte-identical output, so your status line looks
the same on every machine you work on:

| Platform | Script | Requirements |
| --- | --- | --- |
| Windows (PowerShell, cmd) | `scripts/statusline.ps1` | Windows PowerShell 5.1 — preinstalled |
| macOS, Linux, WSL, Git Bash | `scripts/statusline.sh` | POSIX `sh` — `jq` used when present, not required |

> Community project. Not affiliated with or endorsed by Anthropic.

---

## Install

### As a Claude Code plugin

```
/plugin marketplace add black-astro/claude-code-statusline-astro
/plugin install statusline@black-astro
/statusline-install
```

Claude Code plugins cannot register the main status line by themselves, so the
bundled `/statusline-install` command does the last step: it copies the right
script for your platform into `~/.claude/` and merges a `statusLine` entry into
your `~/.claude/settings.json`.

### One-line install

macOS / Linux / WSL:

```sh
curl -fsSL https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.sh | sh
```

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.ps1 | iex
```

### From a clone

```sh
git clone https://github.com/black-astro/claude-code-statusline-astro.git
cd claude-code-statusline-astro
sh install.sh          # macOS / Linux / WSL
.\install.ps1          # Windows
```

### Manual

Copy the script for your platform into `~/.claude/`, then add a `statusLine`
entry to `~/.claude/settings.json`. Keep every other key in that file.

Windows:

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/YOU/.claude/statusline.ps1",
    "refreshInterval": 5
  }
}
```

macOS / Linux:

```json
{
  "statusLine": {
    "type": "command",
    "command": "sh \"/home/you/.claude/statusline.sh\"",
    "refreshInterval": 5
  }
}
```

Restart Claude Code or open a new session to see it.

Every installer backs up your existing `settings.json` to `settings.json.bak`
and only adds the `statusLine` key — nothing else in the file is touched.

### About cmd.exe

You do not need to do anything special for cmd. Claude Code launches the status
line command itself through `cmd.exe` on Windows, and the PowerShell invocation
above works from there. `scripts/statusline.cmd` is included for anyone who
wants a single batch entry point — it forwards stdin to the PowerShell script,
since batch cannot parse JSON.

---

## Reading the status line

```
DIR claude-code-statusline-astro | GIT main | MODEL Opus 5 | CTX [ ■ ■ ■ ■ □ □ □ □ □ □ ] 42% | 5H [ ■ ■ ■ ■ ■ ■ □ □ □ □ ] 63%
    └── project root              └── branch  └── model      └── context used   └── 5-hour limit used
```

### `DIR` — project root

The name of the repository root you are working in, not the full path. If you
are three directories deep inside a project, this still shows the project name,
because that is what identifies the session. Outside a git repository it falls
back to the name of the current directory. Names longer than 32 characters lose
their head, not their tail: `…ly-long-project-name`.

### `GIT` — branch

The current branch. **Magenta** for `main` and `master`, **sky blue** for every
other branch — so you notice at a glance when you are about to commit to the
default branch. Detached HEAD shows the short commit hash. Outside a repository
it shows a dim `-`.

### `MODEL` — active model

Whatever Claude Code reports as the current model display name.

### `CTX` — context window used

**This is the one people misread, so: it is not a time limit and not a billing
number.** The context window is how much of the conversation the model can see
at once. Every message you send, every file that gets read, and every tool
result piles into it. At 100% Claude Code compacts the conversation — it
summarizes the older parts to make room, and detail gets lost in the process.

`CTX` is therefore **per session**. A fresh terminal starts at 0%. Two terminals
showing different numbers is not a bug; they are different conversations. Watch
it when you are deep into a long task: crossing into amber is a good moment to
finish the current thread rather than start a new subtask.

### `5H` — five-hour usage limit

Percentage of your rolling five-hour usage allowance consumed. Unlike `CTX`,
this is **account-wide** — every terminal you have open draws from the same
pool. It only appears for Claude.ai subscription plans, and only after the
session has received its first API response.

### `7D` — seven-day usage limit (off by default)

The weekly allowance, same shape as `5H`. It is off by default to keep the line
short. Turn it on by editing one line near the top of the script:

```sh
SHOW_SEVEN_DAY=1        # statusline.sh
```
```powershell
$ShowSevenDay = $true   # statusline.ps1
```

### Meter colors and markers

| State | Meaning |
| --- | --- |
| light blue | under 60% |
| amber | 60% and above |
| red | 90% and above |
| `--%` with a dim empty bar | value not reported yet |
| `~` before the number, dimmed | stale snapshot — see below |

The bar is always ten cells wide whether or not a value is present, so the line
never jitters as numbers appear.

---

## How fresh are the usage numbers?

Short answer: **`CTX` is current, `5H` and `7D` are a snapshot that lags.**

`refreshInterval: 5` makes Claude Code re-run the script every five seconds, and
the script re-renders every time. But re-rendering is not re-measuring. The
script only ever draws the numbers Claude Code hands it on stdin, and it has no
way to query the API itself. Claude Code refreshes `rate_limits` when the
session receives an API response — so between your messages, the number is
frozen at whatever it was when Claude last replied in *that* session.

That explains the two things people notice:

- **`/usage` disagrees with the status line.** `/usage` asks the server for the
  current value. The status line shows the value attached to this session's last
  API response, which may be many minutes old.
- **Two terminals show different `5H` values.** The limit is account-wide, but
  each session caches its own last-seen snapshot, and they drift apart. Capturing
  131 real payloads across concurrent sessions on one account produced `5H`
  readings of 11%, 5%, 3%, 9% and 6% — all valid, all from different moments.

A session that has been idle long enough can even be holding a snapshot from a
five-hour window that has already expired. When the reported `resets_at` is in
the past, the number is definitely wrong, so the status line marks it: `~11%`,
dimmed. Send any message and it refreshes.

`CTX` does not have this problem — it is computed from the session's own
transcript, so it is accurate the moment it is drawn.

---

## Customization

Everything worth changing sits in a labeled block at the top of each script.

**Bar characters.** Some combinations worth trying: `█`/`░` (U+2588 / U+2591),
`▰`/`▱` (U+25B0 / U+25B1), `●`/`○` (U+25CF / U+25CB), or plain `#`/`-` if your
font is limited.

```sh
BAR_FULL='■'    BAR_EMPTY='□'    BAR_GAP=' '    BAR_PAD=' '     # statusline.sh
```
```powershell
$BarFull = [string][char]0x25A0                                 # statusline.ps1
$BarEmpty = [string][char]0x25A1
```

The PowerShell version builds its glyphs from code points on purpose, so the
file survives being saved in any encoding.

**Thresholds.** `WARN_AT` / `CRIT_AT` (`$WarnAt` / `$CritAt`), default 60 and 90.

**Bar width.** `BAR_LEN` / `$BarLength`, default 10.

**Project name length.** `DIR_MAX` / `$DirMax`, default 32.

**Colors.** Plain ANSI SGR codes. The meters use 256-color values —
`38;5;117` light blue, `38;5;214` amber, `38;5;203` red. On a terminal without
256-color support, swap those for `96`, `93` and `91`. The rest are basic
codes: `97` project, `95` main branch, `96` other branches, `93` model, `90` dim.

**No color at all.** Set `NO_COLOR=1` in the environment.

---

## How it works

Claude Code runs the configured command on every session event and, with
`refreshInterval` set, every N seconds as well. It passes a JSON payload on
stdin describing the session. The script pulls out the fields it needs and
writes exactly one line to stdout; whatever it prints becomes the status line.

Because that output is the status line, the script sends nothing to stderr and
swallows its own errors. A broken status line should degrade to `-` and `--%`,
never vanish and never spray error text across your terminal.

The shell version uses `jq` when it is installed and falls back to `sed` for the
few flat fields it needs, so it has no hard dependencies on a stock macOS or
Linux box.

---

## Troubleshooting

**The status line does not appear.** Confirm the path in `settings.json` points
at a file that exists, then run the script by hand:

```sh
echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":63}}}' | sh ~/.claude/statusline.sh
```

**`5H` stays at `--%`.** Rate limits are only reported on Claude.ai subscription
plans, and only after the session's first API response. Send a message.

**Boxes or question marks instead of bars.** The terminal font has no glyph for
`■`/`□`. Use a font with wider Unicode coverage, or switch the bar characters
to `#`/`-`.

**Colors show up as literal `[38;5;117m` text.** The terminal is not
interpreting ANSI codes. Set `NO_COLOR=1` as a fallback.

**Meter colors look wrong but the rest is fine.** The terminal is 16-color only.
Replace the three 256-color meter codes with `96`, `93`, `91`.

**`bad interpreter` on Linux after cloning on Windows.** The file picked up CRLF
line endings. `.gitattributes` forces LF for `*.sh`, so re-clone or run
`dos2unix ~/.claude/statusline.sh`.

---

## Contributing

Issues and pull requests are welcome. If you change one implementation, change
the other to match — the two scripts are expected to produce identical output
for the same input, and that is the main thing worth reviewing.

## License

MIT — see [LICENSE](LICENSE).

---

# 한국어

Claude Code용 크로스 플랫폼 상태라인입니다. Windows(PowerShell, cmd), macOS,
Linux, WSL, Git Bash에서 모두 같은 모양으로 동작합니다.

설치는 위 **Install** 항목을 그대로 따르면 됩니다. 플러그인으로 설치하는 경우
Claude Code 플러그인은 메인 상태라인을 직접 등록할 수 없기 때문에, 같이 들어 있는
`/statusline-install` 커맨드가 스크립트 복사와 `settings.json` 병합을 대신
처리합니다. 기존 설정은 건드리지 않고 `statusLine` 항목만 추가하며, 원본은
`settings.json.bak`으로 백업합니다.

## 각 항목이 뜻하는 것

**DIR** — 지금 작업 중인 저장소의 루트 폴더 이름입니다. 전체 경로가 아니라 프로젝트
이름만 보여줍니다. 하위 폴더 깊숙이 들어가 있어도 프로젝트 이름이 그대로 유지되는
쪽이 세션을 구분하는 데 유용하기 때문입니다. 32자를 넘으면 앞을 자르고 뒤를
남깁니다.

**GIT** — 현재 브랜치입니다. `main`과 `master`는 **보라색**, 나머지 브랜치는
**하늘색**으로 표시해서 기본 브랜치에 커밋하려는 상황을 눈치챌 수 있게 했습니다.

**MODEL** — 현재 모델 이름입니다.

**CTX** — **컨텍스트 사용률입니다. 시간 제한도 요금도 아닙니다.** 컨텍스트 윈도우는
모델이 한 번에 볼 수 있는 대화의 총량입니다. 주고받은 메시지, 읽어들인 파일, 도구
실행 결과가 전부 여기에 쌓입니다. 100%에 도달하면 Claude Code가 오래된 대화를
요약(compact)해서 자리를 만드는데, 이 과정에서 세부 내용이 사라집니다.

그래서 CTX는 **세션마다 완전히 별개**입니다. 새 터미널을 열면 0%에서 시작하고, 두
터미널의 숫자가 다른 건 버그가 아니라 서로 다른 대화이기 때문입니다. 긴 작업 중에
앰버 색으로 넘어가면 새 갈래를 시작하기보다 지금 하던 흐름을 마무리하는 편이 좋다는
신호로 보시면 됩니다.

**5H** — 5시간 롤링 사용 한도입니다. CTX와 달리 **계정 전체 기준**이라 열어둔 모든
터미널이 같은 한도를 나눠 씁니다. Claude.ai 구독 플랜에서만, 그리고 세션이 첫 API
응답을 받은 뒤에만 표시됩니다.

**7D** — 주간(7일) 사용 한도입니다. 줄이 길어져서 기본은 꺼져 있고, 스크립트 위쪽의
`SHOW_SEVEN_DAY=1`(sh) 또는 `$ShowSevenDay = $true`(PowerShell) 한 줄만 고치면
켜집니다.

**색상** — 60% 미만은 연파랑, 60% 이상은 앰버, 90% 이상은 빨강입니다. 값이 아직
없으면 `--%`로 표시하고, 오래된 값이면 `~11%`처럼 물결표를 붙이고 흐리게 처리합니다.

## 사용량 게이지는 실시간인가?

**CTX는 실시간이고, 5H와 7D는 시차가 있는 스냅샷입니다.**

`refreshInterval: 5` 설정 때문에 Claude Code가 5초마다 스크립트를 다시 실행하고
화면도 다시 그립니다. 하지만 다시 그리는 것과 다시 재는 것은 다릅니다. 스크립트는
Claude Code가 stdin으로 건네준 숫자를 그릴 뿐이고, 직접 API에 사용량을 물어볼 방법이
없습니다. `rate_limits` 값은 **해당 세션이 API 응답을 받을 때** 갱신되므로, 메시지를
주고받지 않는 동안에는 마지막 응답 시점의 값에 멈춰 있습니다.

여기서 말씀하신 두 가지 현상이 그대로 설명됩니다.

- **`/usage` 값과 다른 이유** — `/usage`는 서버에 지금 값을 물어봅니다. 상태라인은 이
  세션이 마지막으로 받은 응답에 붙어 있던 값을 보여줍니다. 몇 분 전 값일 수 있습니다.
- **터미널마다 다른 이유** — 한도 자체는 계정 공용이지만 세션마다 자기가 마지막으로
  본 스냅샷을 들고 있어서 서로 어긋납니다. 실제로 같은 계정의 동시 실행 세션에서
  payload 131건을 떠 보니 5H 값이 11%, 5%, 3%, 9%, 6%로 제각각이었습니다. 전부 유효한
  값이고, 단지 측정 시점이 다를 뿐입니다.

오래 놀린 세션은 이미 지나간 5시간 창의 스냅샷을 들고 있을 수도 있습니다. 응답에 담긴
`resets_at`이 현재 시각보다 과거이면 그 숫자는 확실히 틀린 값이므로, 상태라인이
`~11%`처럼 흐리게 표시해서 알려줍니다. 아무 메시지나 보내면 갱신됩니다.

CTX에는 이 문제가 없습니다. 세션 자기 기록에서 계산하는 값이라 그리는 순간 정확합니다.

## 바꾸고 싶다면

스크립트 맨 위 블록만 고치면 됩니다. 막대 문양(`BAR_FULL`/`BAR_EMPTY`), 칸 사이
간격(`BAR_GAP`), 막대 길이(`BAR_LEN`), 색이 바뀌는 기준(`WARN_AT`/`CRIT_AT`),
프로젝트 이름 최대 길이(`DIR_MAX`), 주간 게이지 표시 여부가 전부 거기 모여 있습니다.
`NO_COLOR=1` 환경변수를 주면 색 없이 출력됩니다.
