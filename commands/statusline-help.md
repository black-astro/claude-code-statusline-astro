---
description: 상태라인 사용법과 명령어를 보여준다
allowed-tools: Bash
---

상태라인 사용법을 한국어로 정리해서 보여준다. 아래 내용을 그대로 출력하되, 먼저
설치 여부를 확인해서 (`~/.claude/statusline.sh` 또는 `~/.claude/statusline.ps1` 존재)
설치돼 있지 않으면 `/statusline-install` 부터 안내할 것.

```
명령어
  /statusline-install   설치 · 재설치
  /statusline-roll      오늘의 마스코트 뽑기 (하루 한 번)
  /statusline-today     지금 쓰고 있는 마스코트 확인
  /statusline-update    최신 버전으로 업데이트
  /statusline-help      이 도움말

터미널에서
  sh ~/.claude/statusline.sh --roll | --today | --version | --help
  powershell -File ~/.claude/statusline.ps1 -Roll | -Today | -Version | -Help

읽는 법
  DIR    프로젝트 폴더        GIT   브랜치 (main·master 는 보라색)
  MODEL  쓰는 모델            CTX   컨텍스트 사용량 (실시간)
  5H     5시간 한도 + 남은 시간
  맨 뒤  내 마스코트 — 작업 중·완료 직후·알림 때만 말합니다

마스코트 뽑기
  커먼 40% · 언커먼 35% · 레어 18% · 유니크 6% · 레전드 1%
  레전드는 글자마다 색이 흐릅니다.
  뽑기는 하루 한 번, 직접 돌립니다. 뽑기 전까지 지금 얼굴이 유지됩니다.

설정
  스크립트 맨 위 블록에서 막대 모양 · 색 기준 · 마스코트 on/off 를 바꿉니다.
  자세한 내용은 저장소 README 를 참고하세요.
```
