# claude-code-statusline-astro

A cross-platform, colored status line for [Claude Code](https://claude.com/claude-code).

```
DIR C:\workspace\my-project | GIT develop | MODEL Opus 5 | CTX [▰▰▰▰▱▱▱▱▱▱] 42% | 5H [▰▰▰▰▰▰▱▱▱▱] 63%
```

Two implementations that print byte-identical output, so your status line looks
the same on every machine you work on:

| Platform | Script | Requirements |
| --- | --- | --- |
| Windows (PowerShell, cmd) | `scripts/statusline.ps1` | Windows PowerShell 5.1 — preinstalled |
| macOS, Linux, WSL, Git Bash | `scripts/statusline.sh` | POSIX `sh` — `jq` used when present, not required |

> Community project. Not affiliated with or endorsed by Anthropic.

## What it shows

| Segment | Source field | Color |
| --- | --- | --- |
| `DIR` | `workspace.current_dir`, falling back to `cwd` | cyan |
| `GIT` | `git branch --show-current` in that directory | magenta |
| `MODEL` | `model.display_name` | yellow |
| `CTX` | `context_window.used_percentage` | green / amber / red |
| `5H` | `rate_limits.five_hour.used_percentage` | green / amber / red |

The two meters change color with load: green below 60%, amber from 60%, red
from 85%. That is the whole point of the thing — you notice you are running out
of context without reading a number.

Missing data never breaks the line. Outside a git repository the branch shows
`-`; before Claude Code reports usage the meters show `[----------] --%`.

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

### About cmd.exe

You do not need to do anything special for cmd. Claude Code launches the status
line command itself through `cmd.exe` on Windows, and the PowerShell invocation
above works from there. `scripts/statusline.cmd` is included for anyone who
wants a single batch entry point — it forwards stdin to the PowerShell script,
since batch cannot parse JSON.

## Configuration

Set `NO_COLOR=1` in the environment to get plain text with no ANSI codes.

Everything else is a small edit near the top of the script. The bar characters:

```sh
BAR_FULL='▰'      # statusline.sh
BAR_EMPTY='▱'
```

```powershell
$BarFull  = [string][char]0x25B0   # statusline.ps1
$BarEmpty = [string][char]0x25B1
```

The PowerShell version builds those from code points on purpose, so the file
survives being saved in any encoding. Some combinations worth trying:
`█`/`░` (U+2588 / U+2591), `⬢`/`⬡` (U+2B22 / U+2B21), `●`/`○` (U+25CF / U+25CB).

Colors are plain ANSI SGR codes — `96` cyan, `95` magenta, `93` yellow, `92`
green, `91` red, `90` dim. Swap the numbers to retheme it.

## How it works

Claude Code runs the configured command every few seconds and passes a JSON
payload on stdin describing the current session. The script reads that payload,
pulls out five fields, and writes exactly one line to stdout. Whatever it prints
becomes the status line, so the script sends nothing to stderr and swallows its
own errors — a broken status line should degrade to `-` and `--%`, never vanish.

The shell version uses `jq` when it is installed and falls back to `sed` for the
few flat fields it needs, so it has no hard dependencies on a stock macOS or
Linux box.

## Troubleshooting

**The status line does not appear.** Confirm the path in `settings.json` points
at a file that exists, then run the script by hand:

```sh
echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":63}}}' | sh ~/.claude/statusline.sh
```

**Boxes or question marks instead of bars.** The terminal font has no glyph for
`▰`/`▱`. Use a Nerd Font or a font with wide Unicode coverage, or switch the bar
characters to `#`/`-`.

**Colors show up as literal `[96m` text.** The terminal is not interpreting ANSI
codes. Windows Terminal handles them; very old `conhost` sessions may not. Set
`NO_COLOR=1` as a fallback.

**`bad interpreter` on Linux after cloning on Windows.** The file picked up CRLF
line endings. `.gitattributes` forces LF for `*.sh`, so re-clone or run
`dos2unix ~/.claude/statusline.sh`.

## Contributing

Issues and pull requests are welcome. If you change one implementation, change
the other to match — the two scripts are expected to produce identical output
for the same input, and that is the main thing worth reviewing.

## License

MIT — see [LICENSE](LICENSE).

---

## 한국어

Claude Code용 크로스 플랫폼 상태라인입니다. Windows(PowerShell, cmd), macOS,
Linux, WSL, Git Bash에서 모두 같은 모양으로 동작합니다.

현재 폴더, git 브랜치, 모델명, 컨텍스트 사용률, 5시간 사용률을 한 줄로 보여주고,
두 사용률 게이지는 60% 이상이면 노란색, 85% 이상이면 빨간색으로 바뀝니다. 숫자를
읽지 않아도 한도가 가까워지는 게 보이는 것이 이 도구의 목적입니다.

설치는 위의 **Install** 항목을 그대로 따르면 됩니다. 플러그인으로 설치할 경우
Claude Code 플러그인은 메인 상태라인을 직접 등록할 수 없기 때문에, 같이 들어 있는
`/statusline-install` 커맨드가 스크립트 복사와 `settings.json` 병합을 대신
처리합니다. 기존 설정은 지우지 않고 `statusLine` 항목만 추가하며, 원본은
`settings.json.bak`으로 백업합니다.

막대 문양과 색은 스크립트 상단의 몇 줄만 고치면 바뀝니다. `NO_COLOR=1` 환경변수를
주면 색 없이 출력됩니다.
