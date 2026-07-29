# claude-code-statusline-astro

A cross-platform, colored status line for [Claude Code](https://claude.com/claude-code).

```
DIR claude-code-statusline-astro | GIT main | MODEL Opus 5 | CTX [ ▮▮▮▮▯▯▯▯▯▯ ] 42% | 5H [ ▮▮▮▮▮▮▯▯▯▯ ] 63% 2h05m
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

That restart is only needed to register the `statusLine` setting. Once it is
registered, Claude Code re-reads the script file on every invocation, so later
edits to the bar characters, colors or thresholds take effect within seconds in
every open session — no restart, no reinstall.

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
DIR claude-code-statusline-astro | GIT main | MODEL Opus 5 | CTX [ ▮▮▮▮▯▯▯▯▯▯ ] 42% | 5H [ ▮▮▮▮▮▮▯▯▯▯ ] 63% 2h05m
    └── project root              └── branch  └── model      └── context used  └── 5-hour limit used, resets in 2h05m
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
pool. It only appears for Claude.ai subscription plans, and only after some
session on the machine has received an API response.

The dim `2h05m` after the percentage is a **countdown to the window reset** —
when it hits zero, the allowance starts over. It is computed locally from the
`resets_at` timestamp already in the payload, so it costs nothing, makes no
network calls, and is always current even when the percentage itself is a
cached snapshot.

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

Logging the payload from four concurrent sessions on one account for two minutes
makes this concrete:

| session | invocations | `5H` reading | window ends at |
| --- | --- | --- | --- |
| A | 24 | 9%, never moved | 18:50 — still open |
| B (actively working) | 30 | 9% → 10% | 18:50 — still open |
| C | 24 | 11%, never moved | 13:50 — closed 50 min earlier |
| D | 25 | 9%, never moved | 19:00 **the previous day** |

Two things fall out of that. The idle sessions re-ran the script two dozen times
each and their number never moved once, while only the session actually calling
the API changed — re-running is not re-measuring. And the four sessions reported
*three different window boundaries*, which is only possible if each is holding
its own cached snapshot rather than reading shared live state.

So both symptoms are expected:

- **`/usage` and the web usage page disagree with the status line.** They ask the
  server for the value right now. The status line shows the value attached to
  this session's last API response.
- **Two terminals show different `5H` values.** Sessions C and D above were
  quoting windows that had already closed — their numbers were not merely late,
  they were answers to a question about a different five-hour period.

### What the status line does about it

The script cannot ask the API for the live value — it has no credentials and no
endpoint for that, and polling would spend the very allowance it is measuring.
But the drift between terminals is fixable without any of that, because **at
least one session is always holding the newest snapshot: the one you are
actively working in.**

So sessions share what they see. On every render, each session writes the
rate-limit snapshot it was handed to a small file under
`~/.claude/statusline-cache/`, and displays the best snapshot *any* session has
published: the newest window wins, and within the same window the highest
reading wins (account usage only rises while a window is open). The moment you
send a message in one terminal, every other terminal converges to that value on
its next 5-second refresh. No API calls, no tokens — just a ~40-byte file.

This is also why a freshly opened terminal shows a real `5H` value immediately
instead of `--%`: it inherits the account state from its neighbors.

Two markers remain for what sharing cannot fix:

- `~11%` dimmed — even the freshest snapshot anyone holds is from a window that
  already closed (every session has been idle past a reset). Send any message
  and it recovers.
- Sessions quoting the same open window can still sit a point apart for a
  moment (A and B above); nothing in the payload says which is newer, and the
  higher one wins by the ordering rule.

The countdown never has either problem — it ticks locally regardless of how old
the percentage is.

`CTX` does not have this problem — it is computed from the session's own
transcript, so it is accurate the moment it is drawn.

---

## Customization

Everything worth changing sits in a labeled block at the top of each script.

**Bar characters.**

```sh
BAR_FULL='▮'    BAR_EMPTY='▯'    BAR_GAP=''    BAR_PAD=' '      # statusline.sh
```
```powershell
$BarFull = [string][char]0x25AE                                 # statusline.ps1
$BarEmpty = [string][char]0x25AF
```

The default cells are U+25AE/U+25AF, the black and white vertical rectangles.
The glyph carries its own side margins, so cells set flush against each other
still separate into ten distinct blocks with a hairline gap, and the empty cell
is drawn as an outlined box — a visible border rather than a shaded fill. A
true square such as `■` (U+25A0) is constrained by the cell *width*, which in a
terminal is roughly half the cell height — that is why squares look small next
to rectangle and block glyphs. How thick the outline and how wide the gap
render is ultimately the font's decision.

Other pairings worth trying: `▉`/`░` (U+2589 / U+2591) for chunky blocks with
shaded empties, `█`/`░` (U+2588 / U+2591) for a continuous bar with no gaps,
`■`/`□` (U+25A0 / U+25A1) with `BAR_GAP=' '` for spaced squares, `●`/`○`
(U+25CF / U+25CB) for dots, or plain `#`/`-` if your font is limited.

The PowerShell version builds its glyphs from code points on purpose, so the
file survives being saved in any encoding.

**Actual glyph size** is your terminal's font size — no escape code can change
it for part of a line. If the bar still reads small, raise the terminal font
size, or pick a font that draws block elements to the full cell box (most
programming fonts do; some proportional-ish fonts leave a margin).

**Thresholds.** `WARN_AT` / `CRIT_AT` (`$WarnAt` / `$CritAt`), default 60 and 90.

**Bar width.** `BAR_LEN` / `$BarLength`, default 10.

**Project name length.** `DIR_MAX` / `$DirMax`, default 32.

**Colors.** Plain ANSI SGR codes. The meters use 256-color values —
`38;5;117` light blue, `38;5;214` amber, `38;5;203` red. On a terminal without
256-color support, swap those for `96`, `93` and `91`. The rest are basic
codes: `97` project, `95` main branch, `96` other branches, `93` model, `90` dim.

**No color at all.** Set `NO_COLOR=1` in the environment.

**Cache location.** Cross-session snapshots live in
`~/.claude/statusline-cache/` (one ~40-byte file per session, swept after 48
hours of inactivity). Set `STATUSLINE_CACHE_DIR` to move it.

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
`▮`/`▯`. Use a font with wider Unicode coverage, or switch the bar characters
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
터미널이 같은 한도를 나눠 씁니다. Claude.ai 구독 플랜에서만 표시됩니다.

퍼센트 뒤의 흐린 `2h05m`는 **창이 리셋되기까지 남은 시간**입니다. 0이 되면 허용량이
새로 시작됩니다. payload에 이미 들어 있는 `resets_at`으로 로컬에서 계산하는 값이라
네트워크 호출도 토큰 소모도 없고, 퍼센트가 오래된 스냅샷일 때조차 항상 정확하게
흘러갑니다.

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

같은 계정에서 동시에 돌아가는 세션 네 개의 payload를 2분간 기록해 보면 분명해집니다.

| 세션 | 실행 횟수 | `5H` 값 | 창 종료 시각 |
| --- | --- | --- | --- |
| A | 24회 | 9%, 한 번도 안 바뀜 | 18:50 — 아직 열려 있음 |
| B (작업 중) | 30회 | 9% → 10% | 18:50 — 아직 열려 있음 |
| C | 24회 | 11%, 한 번도 안 바뀜 | 13:50 — 50분 전에 닫힘 |
| D | 25회 | 9%, 한 번도 안 바뀜 | **전날** 19:00 |

두 가지가 드러납니다. 놀고 있던 세션들은 스크립트를 스무 번 넘게 다시 실행했는데도
숫자가 한 번도 움직이지 않았고, 실제로 API를 호출하던 세션만 값이 바뀌었습니다.
**다시 그리는 것은 다시 재는 것이 아닙니다.** 그리고 네 세션이 보고한 창 종료 시각이
**서로 다른 세 가지**였습니다. 각자 자기 스냅샷을 들고 있지 않다면 나올 수 없는
결과입니다.

그래서 두 현상 모두 정상입니다.

- **`/usage`나 웹 사용량 페이지와 다른 이유** — 그쪽은 서버에 지금 값을 물어봅니다.
  상태라인은 이 세션이 마지막으로 받은 응답에 붙어 있던 값을 보여줍니다.
- **터미널마다 다른 이유** — 위 표의 C와 D는 이미 닫힌 창의 값을 말하고 있었습니다.
  단순히 늦은 게 아니라, 아예 다른 5시간 구간에 대한 답이었습니다.

### 상태라인이 이 문제를 다루는 방법

스크립트가 API에 직접 실시간 값을 물어볼 수는 없습니다. 자격 증명도 공개 엔드포인트도
없고, 폴링은 측정하려는 허용량을 측정 때문에 소모하는 구조가 됩니다. 하지만 터미널
간의 어긋남은 그것 없이도 고칠 수 있습니다. **적어도 하나의 세션은 항상 최신 스냅샷을
들고 있기 때문입니다. 바로 지금 작업 중인 세션입니다.**

그래서 세션끼리 본 것을 공유합니다. 매 렌더링마다 각 세션은 자기가 받은 rate-limit
스냅샷을 `~/.claude/statusline-cache/`의 작은 파일에 기록하고, 표시할 때는 **모든
세션이 발행한 것 중 가장 좋은 스냅샷**을 고릅니다. 더 새로운 창이 이기고, 같은
창이면 더 높은 값이 이깁니다(창이 열려 있는 동안 계정 사용량은 줄지 않으므로). 한
터미널에서 메시지를 보내는 순간, 나머지 터미널들은 다음 5초 새로고침에서 그 값으로
수렴합니다. API 호출 0회, 토큰 0개, 40바이트짜리 파일이 전부입니다.

새로 연 터미널이 `--%` 대신 곧바로 실제 5H 값을 보여주는 것도 이 덕분입니다. 옆
세션들이 발행해 둔 계정 상태를 물려받기 때문입니다.

공유로도 못 고치는 경우를 위한 표시 두 가지는 남아 있습니다.

- `~11%` 흐림 — 모든 세션이 리셋 시각을 넘겨 놀고 있어서, 가장 최신 스냅샷조차 이미
  닫힌 창의 값일 때입니다. 아무 메시지나 보내면 회복됩니다.
- 같은 열린 창을 인용하는 세션들이 잠깐 1%p 어긋날 수 있습니다(위 표의 A와 B).
  payload에 어느 쪽이 더 최신인지 알려주는 정보가 없어서, 정렬 규칙상 높은 쪽이
  이깁니다.

카운트다운은 어느 경우에도 영향받지 않습니다. 퍼센트가 얼마나 오래됐든 로컬 시계로
정확히 흘러갑니다.

CTX에는 이 문제가 없습니다. 세션 자기 기록에서 계산하는 값이라 그리는 순간 정확합니다.

## 바꾸고 싶다면

스크립트 맨 위 블록만 고치면 됩니다. 막대 문양(`BAR_FULL`/`BAR_EMPTY`), 칸 사이
간격(`BAR_GAP`), 막대 길이(`BAR_LEN`), 색이 바뀌는 기준(`WARN_AT`/`CRIT_AT`),
프로젝트 이름 최대 길이(`DIR_MAX`), 주간 게이지 표시 여부가 전부 거기 모여 있습니다.
`NO_COLOR=1` 환경변수를 주면 색 없이 출력됩니다.

기본 채움 문자는 정사각형이 아니라 U+2589(왼쪽 7/8 블록)입니다. 셀 높이를 꽉 채우면서
너비는 7/8만 차지하기 때문에, 칸을 서로 붙여 놓아도 남는 1/8이 실선 같은 얇은 틈으로
보입니다. 구분 문자를 넣지 않고도 열 칸이 또렷하게 나뉘어 보이는 이유입니다. 반면
`■`(U+25A0) 같은 진짜 정사각형은 셀 **너비**에 맞춰 그려지는데 터미널 셀은 높이가
너비의 두 배쯤이라, 블록 문자 옆에 두면 작아 보입니다.

글리프의 실제 크기는 터미널 폰트 크기입니다. 한 줄의 일부만 크게 만드는 이스케이프
코드는 존재하지 않으므로, 더 크게 보고 싶으면 터미널 폰트 크기를 올리시면 됩니다.
