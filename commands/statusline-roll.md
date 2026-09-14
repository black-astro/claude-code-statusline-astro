---
description: 오늘의 마스코트를 뽑는다 (하루 한 번)
allowed-tools: Bash
---

상태라인 마스코트를 뽑는다. 뽑기는 하루 한 번이고, 뽑기 전까지는 지금 마스코트가
그대로 유지된다.

플랫폼에 맞는 쪽을 실행하고 출력을 그대로 사용자에게 보여줄 것.

- Windows: `powershell -NoProfile -ExecutionPolicy Bypass -File ~/.claude/statusline.ps1 -Roll`
- macOS / Linux / WSL: `sh ~/.claude/statusline.sh --roll`

"오늘 뽑기는 이미 사용했습니다" 가 나오면 그대로 전달하고, 내일 다시 뽑을 수 있다고
안내한다. 뽑기에 실패하면 턴을 한 번 끝내 비밀키가 만들어졌는지 확인하라고 안내하고,
스크립트 자체가 없으면 `/statusline-install` 을 먼저 실행하라고 알린다.
