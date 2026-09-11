# claude-code-statusline-astro

Claude Code 터미널 맨 아래에 **지금 어디서 무엇을 하고 있는지**를 한 줄로 보여줍니다.

![상태라인 예시](docs/use.png)

프로젝트 폴더, git 브랜치, 모델, 컨텍스트 사용량, 5시간 사용 한도, 그리고 맨 뒤에
그날의 마스코트가 표시됩니다. Windows · macOS · Linux 어디서나 같은 모양입니다.

| 환경 | 쓰는 파일 | 필요한 것 |
| --- | --- | --- |
| Windows (PowerShell, cmd) | `scripts/statusline.ps1` | Windows PowerShell 5.1 (기본 설치됨) |
| macOS · Linux · WSL · Git Bash | `scripts/statusline.sh` | POSIX `sh` (`jq`는 있으면 쓰고 없어도 됨) |

> 개인 프로젝트입니다. Anthropic과는 관계가 없습니다.

---

# 설치

## 방법 1 — 플러그인 (추천)

Claude Code 안에서 그대로 입력하면 됩니다.

```
/plugin marketplace add black-astro/claude-code-statusline-astro
/plugin install statusline@black-astro
/statusline-install
```

마지막 `/statusline-install`까지 실행해야 설정이 적용됩니다. 플러그인은 상태라인을
직접 등록할 수 없어서, 이 커맨드가 스크립트 복사와 `settings.json` 수정을 대신 해
줍니다.

## 방법 2 — 한 줄 설치

**Windows (PowerShell)**

```powershell
irm https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.ps1 | iex
```

**macOS · Linux · WSL**

```sh
curl -fsSL https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.sh | sh
```

## 방법 3 — 직접 받아서

```sh
git clone https://github.com/black-astro/claude-code-statusline-astro.git
cd claude-code-statusline-astro

./install.sh          # macOS · Linux · WSL
.\install.ps1         # Windows
```

마스코트가 필요 없으면 `--no-mascot` (Windows는 `-NoMascot`)을 붙이세요.

## 설치하면 벌어지는 일

1. `~/.claude/` 에 스크립트 2개를 복사합니다 (`statusline`, `mascot-hook`)
2. `~/.claude/settings.json` 에 `statusLine` 항목과 훅 3개를 추가합니다
3. 원래 설정은 `settings.json.bak` 으로 백업합니다

**기존 설정은 지우지 않습니다.** 이미 쓰고 있던 다른 훅이나 권한 설정은 그대로 두고
필요한 항목만 더합니다. 여러 번 실행해도 중복으로 쌓이지 않습니다.

설치 후 **Claude Code를 새로 열어야** 상태라인이 나타납니다.

---

# 명령어

## Claude Code 안에서

플러그인으로 설치했다면 그대로 입력하면 됩니다.

| 명령 | 하는 일 |
| --- | --- |
| `/statusline-install` | 설치·재설치 (설정 병합까지) |
| `/statusline-today` | 오늘 뽑힌 마스코트 확인 |
| `/statusline-update` | 최신 버전으로 업데이트 |
| `/statusline-help` | 도움말 |

## 터미널에서

```sh
# macOS · Linux · WSL
sh ~/.claude/statusline.sh --version    # 버전 확인
sh ~/.claude/statusline.sh --today      # 오늘의 마스코트
sh ~/.claude/statusline.sh --help       # 도움말
```

```powershell
# Windows
powershell -File ~/.claude/statusline.ps1 -Version
powershell -File ~/.claude/statusline.ps1 -Today
powershell -File ~/.claude/statusline.ps1 -Help
```

`--today` 출력은 이런 모양입니다.

```
오늘의 마스코트  （✧ᴗ✧）  [레전드]
표정 4장         （✧ᴗ✧） （✦ᴗ✦） （★ᴗ★） （☆ᴗ☆）
대사              요청하신 작업 모두 완료했습니다! / 전부 끝냈습니다, 확인 부탁드려요!

얼굴은 날짜로 정해집니다. 내일 다시 뽑힙니다.
```

## 업데이트

설치 명령을 다시 실행하면 됩니다. 설정은 그대로 두고 스크립트만 최신으로 바뀝니다.

```sh
curl -fsSL https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.sh | sh
```
```powershell
irm https://raw.githubusercontent.com/black-astro/claude-code-statusline-astro/main/install.ps1 | iex
```

---

# 설정 바꾸기

고칠 거리는 전부 스크립트 맨 위에 모여 있습니다. `~/.claude/statusline.ps1` 또는
`~/.claude/statusline.sh` 를 열어 값만 바꾸면 됩니다.

| 바꾸고 싶은 것 | sh | PowerShell |
| --- | --- | --- |
| 막대 길이 | `BAR_LEN=10` | `$BarLength = 10` |
| 막대 문양 | `BAR_FULL='◼'` `BAR_EMPTY='◻'` | `$BarFull` `$BarEmpty` |
| 색 바뀌는 기준 | `WARN_AT=60` `CRIT_AT=90` | `$WarnAt` `$CritAt` |
| 프로젝트 이름 최대 길이 | `DIR_MAX=32` | `$DirMax = 32` |
| 주간(7일) 게이지 켜기 | `SHOW_SEVEN_DAY=1` | `$ShowSevenDay = $true` |
| 마스코트 끄기 | `SHOW_MASCOT=0` | `$ShowMascot = $false` |
| 등급 확률 | `MASCOT_ODDS='400 350 180 60 10'` | `$MascotOdds` |
| 마스코트 대사 끄기 | `SHOW_MASCOT_TALK=0` | `$ShowMascotTalk = $false` |

색을 아예 빼고 싶으면 `NO_COLOR=1` 환경변수를 주면 됩니다.

막대 문양으로 자주 쓸 만한 조합: `▮`/`▯`, `▉`/`░`, `█`/`░`, `●`/`○`, 폰트가 빈약하면
`#`/`-` 도 괜찮습니다.

---

# 문제가 생기면

**상태라인이 안 보여요**
Claude Code를 완전히 닫았다 여세요. 그래도 없으면 `~/.claude/settings.json` 에
`statusLine` 항목이 있는지 확인하세요.

**글자가 깨져서 네모로 나와요**
터미널 폰트가 해당 글자를 못 그리는 경우입니다. D2Coding, Cascadia Code, JetBrains
Mono 같은 폰트로 바꾸거나, 막대 문양을 `#`/`-` 로 바꾸세요.

**색이 안 나와요**
`NO_COLOR` 환경변수가 설정돼 있는지 확인하세요. 일부 구형 터미널은 256색을
지원하지 않습니다.

**5H가 `--%` 로만 나와요**
Claude.ai 구독 플랜에서만 사용량이 내려옵니다. API 키로 쓰는 경우에는 값이
오지 않습니다.

**마스코트가 안 보여요**
훅이 등록된 뒤 **턴이 한 번 끝나야** 나타납니다. 질문을 하나 던져 보세요. 그래도
없으면 `settings.json` 의 `hooks` 에 `mascot-hook` 항목 3개가 있는지 확인하세요.

**직접 확인해 보고 싶어요**

```sh
echo '{"workspace":{"current_dir":"/tmp"},"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":42}}' | sh ~/.claude/statusline.sh
```

한 줄이 출력되면 정상입니다.

---
---

# 각 항목 설명

## DIR — 프로젝트 폴더

지금 작업 중인 저장소의 **루트 폴더 이름**입니다. 전체 경로가 아니라 프로젝트
이름만 보여줍니다. 하위 폴더 깊숙이 들어가 있어도 이름이 그대로 유지되는 쪽이
여러 터미널을 구분하는 데 낫기 때문입니다. 32자가 넘으면 앞을 자르고 뒤를 남깁니다.

git 저장소가 아니면 그냥 현재 폴더 이름이 나옵니다.

## GIT — 브랜치

현재 브랜치입니다. `main`과 `master`는 **보라색**, 나머지는 **하늘색**으로 칠해서
기본 브랜치에 그냥 커밋하려는 상황을 눈치챌 수 있게 했습니다.

브랜치가 아직 없거나 git 저장소가 아니면 `-` 로 표시됩니다.

## MODEL — 지금 쓰는 모델

Claude Code가 알려주는 모델 이름을 그대로 보여줍니다.

## CTX — 컨텍스트 사용량

지금 세션이 컨텍스트 창을 얼마나 먹었는지입니다. **이 값만 실시간입니다.** 100%에
가까워지면 오래된 대화가 밀려나기 시작하므로, 긴 작업 중에 이 숫자를 보고 정리할
시점을 잡으면 됩니다.

## 5H — 5시간 사용 한도

5시간 단위로 갱신되는 사용 한도입니다. CTX와 달리 **계정 전체 기준**이라 열어 둔
모든 터미널이 같은 한도를 나눠 씁니다. Claude.ai 구독 플랜에서만 표시됩니다.

퍼센트 뒤의 흐린 `1h49m` 은 **한도가 초기화되기까지 남은 시간**입니다. payload에
이미 들어 있는 값으로 로컬에서 계산하기 때문에 네트워크 호출도 토큰 소모도 없고,
퍼센트가 오래된 값일 때조차 항상 정확합니다.

## 7D — 주간 한도 (기본 꺼짐)

7일 단위 한도입니다. 줄이 길어져서 기본은 꺼져 있습니다.

## 게이지 색

| 색 | 뜻 |
| --- | --- |
| 초록 | 60% 미만 |
| 주황 | 60% 이상 |
| 빨강 | 90% 이상 |
| `--%` 흐린 빈 막대 | 아직 값이 안 내려옴 |
| `~11%` 흐리게 | 오래된 값 (아래 설명) |

막대는 값이 있든 없든 항상 열 칸이라 숫자가 나타날 때 줄이 흔들리지 않습니다.

---

# 마스코트 뽑기

줄 맨 뒤의 얼굴은 **하루에 한 번 뽑는 그날의 마스코트**입니다.

## 등급

| 등급 | 확률 | 색 | 얼굴 수 |
| --- | --- | --- | --- |
| 커먼 | 40% | 흰색 | 12 |
| 언커먼 | 35% | 초록 | 12 |
| 레어 | 18% | 하늘색 | 12 |
| 유니크 | 6% | 보라 | 9 |
| 레전드 | 1% | **무지개** | 5 |
| **DEV** | 10% *(등록된 키만)* | **무지개** | 4 |

레전드는 100일에 하루쯤 나옵니다. 얼굴은 전부 54개입니다.

`DEV` 는 메인테이너 전용 등급입니다. 등록된 키를 가진 사람에게만 나오고, 그 경우
나머지 등급이 비례해서 줄어듭니다 (커먼 36%, 언커먼 31.5%, 레어 16.2%, 유니크 5.4%,
레전드 0.9%). 다른 사람의 키로는 나오지 않습니다.

```
（¬‿¬）   （☞ﾟヮﾟ）☞   （◣_◢）   ᕙ（⇀‸↼）ᕗ
```

## 내 키도 DEV로 등록하려면

스크립트의 `DEV_KEY_HASHES` 에는 키가 아니라 **키의 해시**만 들어 있습니다. 해시로는
키를 되돌릴 수 없어서 공개돼 있어도 괜찮습니다.

자기 해시를 구하는 명령입니다.

```sh
# macOS · Linux
tr -d '[:space:]' < ~/.claude/statusline-cache/.gacha-key | sha256sum
```
```powershell
# Windows
$k = (Get-Content ~/.claude/statusline-cache/.gacha-key -Raw).Trim()
$s = [System.Security.Cryptography.SHA256]::Create()
(-join ($s.ComputeHash([Text.Encoding]::UTF8.GetBytes($k)) | % { $_.ToString('x2') }))
```

나온 값을 `statusline.sh` 의 `DEV_KEY_HASHES` 또는 `statusline.ps1` 의
`$DevKeyHashes` 에 추가하면 자기 사본에서 DEV 등급이 열립니다.

## 등급이 오르면 말이 트입니다

작업이 끝나면 얼굴 옆에 한마디 합니다. 등급이 낮을수록 울음소리에 가깝고, 높아질수록
문장이 또렷해집니다.

| 등급 | 이런 식으로 말합니다 |
| --- | --- |
| 커먼 | `왕!` `냥!` `삐약!` `음냐` |
| 언커먼 | `다했다!` `끝!` `됐다!` `오케이!` |
| 레어 | `다 됐어요` `끝났어요` `해냈어요!` |
| 유니크 | `작업 완료했어요!` `깔끔하게 끝냈어요!` |
| 레전드 | `요청하신 작업 모두 완료했습니다!` |
| DEV | `빌드 통과.` `커밋하시죠.` `테스트 전부 초록불.` |

대사는 턴마다 바뀌고, 작업 중에는 말하지 않습니다. 필요 없으면
`SHOW_MASCOT_TALK=0` 으로 끌 수 있습니다.

## 움직입니다

얼굴마다 표정이 여러 장 있고, **Claude가 작업하는 동안** 번갈아 나옵니다. 눈을
깜빡이거나 반짝임이 바뀌는 정도라 요란하지 않습니다. 작업이 끝나면 첫 번째 표정으로
멈추고 한마디 합니다.

```
작업 중   （・ω・） ↔ （－ω－）                눈 깜빡임
작업 끝   （・ω・） 왕!                        고정 + 대사
실패      （；へ：） 앗...                     빨간색
```

모든 표정은 글자 수가 같아서 줄이 흔들리지 않습니다.

**레전드와 DEV는 색이 흐릅니다.** 표정 4장이 돌아가는 동안 글자 색도 무지개를 따라
계속 바뀝니다. 빨강 → 주황 → 노랑 → 초록 → 하늘 → 파랑 → 보라 → 분홍 순으로
스르륵 넘어가고, DEV는 같은 무지개를 거꾸로 돕니다.

```
레전드   ✧（◕ᴗ◕）✧  ✦（◕ᴗ◕）✦  ✧（◕ᴗ◕）✦  ✦（◕ᴗ◕）✧   + 색상 순환
```

## 하루 한 번

오늘의 얼굴은 **날짜로 정해집니다.** 이 컴퓨터의 비밀키와 오늘 날짜를 HMAC-SHA256으로
묶어 계산하기 때문에, 몇 번을 다시 그려도 그날은 같은 얼굴이 나옵니다. 날짜가 바뀌면
자동으로 새로 뽑힙니다.

비밀키는 설치 후 첫 턴이 끝날 때 난수로 한 번 만들어지고
(`~/.claude/statusline-cache/.gacha-key`), 그 뒤로는 건드리지 않습니다. 이 파일을 지우면
얼굴도 새로 정해지니 그대로 두시면 됩니다.

---

# 사용량 숫자는 실시간인가

**CTX는 실시간이고, 5H와 7D는 시차가 있습니다.**

`refreshInterval: 5` 설정으로 5초마다 스크립트가 다시 실행되지만, Claude Code가
넘겨주는 사용량 값은 **그 세션이 마지막으로 API 응답을 받은 시점에 멈춰 있습니다.**
가만히 열어만 둔 터미널은 그때 값을 계속 들고 있어서, 터미널마다 다른 숫자를
보여주고 웹 사용량 페이지와도 어긋납니다.

## 이 스크립트가 하는 일

세션마다 자기가 받은 값을 `~/.claude/statusline-cache/` 에 적어 두고, 그릴 때는
**모든 세션이 적어 둔 값 중 가장 최신 것**을 씁니다. 같은 시간대라면 그중 가장 높은
값을 택합니다. 사용량은 창이 열려 있는 동안 오르기만 하기 때문입니다.

덕분에 여러 터미널을 띄워 놓아도 전부 같은 숫자를 보여주고, 방금 작업한 창의
최신 값이 나머지 창에도 바로 반영됩니다.

이미 끝난 창의 값이면 `~11%` 처럼 물결표를 붙이고 흐리게 칠합니다. 남은 시간
카운트다운은 로컬 시계로 계산하므로 이 문제와 무관하게 항상 정확합니다.

---

# 어떻게 동작하나

Claude Code는 상태라인 스크립트에 세션 정보를 JSON으로 넘겨주고, 스크립트가
출력한 **한 줄**을 그대로 표시합니다.

```
Claude Code ──JSON──> statusline.ps1 / .sh ──한 줄──> 화면
```

마스코트는 조금 다릅니다. Claude Code는 "지금 작업 중인지"를 상태라인에 알려주지
않기 때문에, 훅 3개가 그 상태를 파일에 적어 두고 상태라인이 읽어 갑니다.

| 훅 | 언제 | 적는 값 |
| --- | --- | --- |
| `UserPromptSubmit` | 질문을 보낼 때 | `working` |
| `Stop` | 답이 끝났을 때 | `done` |
| `StopFailure` | 실패했을 때 | `error` |

훅을 설치하지 않으면 이 파일이 아예 생기지 않고, 마스코트도 나오지 않습니다.
상태라인은 마스코트가 없던 때와 똑같이 그려집니다.

쓰는 파일은 전부 `~/.claude/statusline-cache/` 안에 있고, 이틀 넘게 손대지 않은
것은 자동으로 지웁니다.

---

# 라이선스

MIT
