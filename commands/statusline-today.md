---
description: 오늘 뽑힌 마스코트를 보여준다
allowed-tools: Bash
---

설치된 상태라인 스크립트로 오늘의 마스코트를 확인한다.

플랫폼에 맞는 쪽을 실행하고, 출력을 그대로 사용자에게 보여줄 것.

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/statusline.ps1 -Today`
- macOS / Linux / WSL: `sh ~/.claude/statusline.sh --today`

"아직 뽑기 전입니다" 가 나오면, 훅이 설치된 뒤 턴이 한 번 끝나야 얼굴이 정해진다고
안내한다. 스크립트 자체가 없으면 `/statusline-install` 을 먼저 실행하라고 안내한다.
