# llm-serving — 사내 로컬 LLM 서빙 스택

`tomocube-buffalo`(Tailscale 100.117.22.53)에서 도는 llama.cpp 기반 OpenAI 호환
추론 서버. tami-slack-bot 의 메시지 분류·요약, core 의 `/release-note` 등이 이
엔드포인트 하나를 공유한다.

```
https://tomocube-buffalo.tail3e0efa.ts.net/v1   (tailscale serve, tailnet 전용)
        └── proxy → http://100.117.22.53:8080   (llama-server)
```

포트는 전부 **Tailscale 인터페이스에만 바인딩**한다(LAN·공인망 노출 없음).

## 현재 서빙 모델

| 항목 | 값 |
|---|---|
| 모델 | `unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q5_K_M` (21.7GB) |
| API 별칭 (`-a`) | `qwen3-instruct` |
| 컨텍스트 | 262144 (KV 캐시 q4_0) |
| VRAM | 약 28.8GB / 32.6GB (RTX 5090 1장) |

**2026-08-20 에 `Qwen3-Coder-30B-A3B-Instruct` 에서 교체했다.** 근거는 추측이
아니라 측정이다 — tami-slack-bot 의 golden set 98건(`uv run python -m
tami_slack_bot.eval_harness --model <별칭>`)으로 두 모델을 각각 2회씩 돌려 매번
같은 수치를 얻었다.

| 분류기 | qwen3-coder | Instruct-2507 |
|---|---|---|
| backfill 기간 인식 | 8/10 | **10/10** |
| 관련 이슈 찾기 | 8/10 | **10/10** |
| 후속 답장 의도 | 8/10 | **9/10** |
| 일반 요청 라우팅 | **29/30** | 27/30 |
| 나머지 4종 | 만점 | 만점 |
| **합계** | **91/98** | **94/98** |

코더 변종은 한국어 완곡·간접 요청("혹시 이거랑 관련된 이슈 있는지 찾아봐줄래요?",
"지난 5일간 크래시 리포트 좀 훑어봐줘")을 통째로 놓쳤다. 봇의 실제 작업이 코딩이
아니라 한국어 의도 분류와 한국어 요약이라 일반 instruct 쪽이 맞았다. 다만 일반
요청 라우팅만 2건 뒤진다(둘 다 Jira 를 잘못 쓰는 방향이 아니라 아무것도 안 하는
fail-safe 방향) — 라우터 프롬프트 쪽 과제로 남아 있다.

**GPU 가 1장이라 두 모델 동시 서빙은 불가능하다.** A/B 는 순차 교체만 된다.

## 구성

| 서비스 | 포트 | 용도 |
|---|---|---|
| `llama-server` | 8080 | 추론 본체 (GPU) |
| `llm-logproxy` | 8090 | mitmproxy 리버스 프록시 — 프롬프트/응답 전문 캡처가 필요할 때만 이쪽을 가리킨다. 8080 은 항상 무간섭 |
| `prometheus` | 9090 | 메트릭 수집 (`llama-server --metrics`) |
| `grafana` | 3001 | 대시보드 (익명 Viewer 허용) |
| `gpu-exporter` | (내부) | nvidia GPU 메트릭 |

- `models/` — GGUF 캐시(`LLAMA_CACHE`). 재다운로드를 막으므로 지우지 말 것.
  `api-keys.txt` 가 `--api-key-file` 로 쓰인다.
- `templates/`, `models/*.jinja` — 채팅 템플릿. **현재 구성은 쓰지 않는다**(아래
  참조).
- `stats.sh` — GPU/슬롯/처리량 한 눈에. `./stats.sh -w` 는 2초 갱신.

## 모델 교체 절차

1. `docker-compose.yml` 의 `llama` 서비스에서 두 곳을 바꾼다.
   - `-hf <HF repo>:<quant>`
   - `-a <별칭>` — 클라이언트가 `model` 필드에 보낼 이름
2. **`--chat-template-file` 을 남기지 말 것.** 이 옵션은 특정 모델 전용
   템플릿을 강제한다(과거 `models/qwen3-coder.jinja` 를 코더 변종에 물려
   썼다). 다른 모델로 바꾸면서 그대로 두면 엉뚱한 템플릿이 씌워져 응답 품질이
   조용히 망가진다. `--jinja` 만 두면 GGUF 내장 템플릿을 쓴다.
3. `docker compose up -d llama`
4. **소비자 쪽 모델 이름을 별칭과 일치시킨다.** tami-slack-bot 은
   `D:\00.TAMI\tami-slack-bot\.env` 의 `TAMI_LLM_MODEL`. 어긋나면 봇은 에러를
   내지 않고 **조용히 전부 안전 폴백**만 하므로 알아채기 어렵다. 수정 후
   `Restart-Service TamiSlackBot`(관리자 권한 필요).

교체 전 `docker-compose.yml.bak-<날짜>` 로 백업해 둘 것.

다운로드가 오래 걸리는 모델(20GB+)은 현재 서빙을 유지한 채 미리 캐시에 받아두면
다운타임을 로딩 시간만으로 줄일 수 있다 — GPU 를 거의 안 쓰는 임시 컨테이너로
받는다.

```bash
docker run -d --name llama-dl --gpus all \
  -v ~/llm-serving/models:/models -e LLAMA_CACHE=/models \
  --entrypoint /app/llama-server ghcr.io/ggml-org/llama.cpp:server-cuda \
  -hf <repo>:<quant> --host 127.0.0.1 --port 8099 -ngl 0 -c 512
# /health 가 200 이면 다운로드+로딩 완료. 이후 docker rm -f llama-dl
```

## 호스트 재부팅 후 502 가 뜰 때

`restart: unless-stopped` 인데도 컨테이너가 안 올라온 것이다. 부팅 시점에 NVIDIA
드라이버가 아직 준비되지 않아 아래로 재시작 시도가 소진된다.

```
nvidia-container-cli: initialization error: nvml error: driver not loaded
```

`docker inspect llama-server --format '{{.State.Error}}'` 로 확인되면,
`nvidia-smi` 로 드라이버가 정상인지 본 뒤 다시 올린다.

```bash
cd ~/llm-serving && docker compose up -d
```

2026-08-20 에 이 상태로 **8일간 방치**돼 tami-slack-bot 의 모든 LLM 분류가
폴백으로만 돌고 있었다. 봇이 조용하거나 분류가 이상하면 설정보다 **이 엔드포인트
생사를 먼저** 확인할 것.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://100.117.22.53:8080/health
curl -s http://100.117.22.53:8080/v1/models -H "Authorization: Bearer $(head -1 models/api-keys.txt)"
```

## 주의

- **이 디렉토리는 git 으로 관리된다**(2026-08-20 부터). 설정을 바꿨으면 커밋할
  것 — 그게 변경 이력의 유일한 출처다. `models/`(58GB 캐시 + 자격증명) · `.env` ·
  `proxy-logs/`(프롬프트 원문) 는 추적하지 않는다. 이유는 `.gitignore` 에 있다.
  `~/.bashrc` 때문에 `git` 이 `rtk git` 으로 잡힐 수 있으니 아래 별칭 항목 참조.
- `.env` 의 `LLAMA_API_KEY` 와 `models/api-keys.txt` 는 자격증명이다.
- `~/.bashrc` 가 `ls`/`head` 등을 `rtk` 로 별칭 잡아두었는데 이 호스트엔 rtk 가
  설치돼 있지 않다. 스크립트나 SSH 비대화형 실행에서 `command not found` 가 나면
  `/bin/ls` 처럼 절대경로로 우회한다.
- **`~/docker-compose.yml` 과 혼동 금지.** 홈 디렉토리에 별도 Ollama 스택
  (포트 11434)이 남아 있지만 **현재 쓰이지 않으며 실행 중이 아니다**. 위
  엔드포인트를 바꾸려면 반드시 `~/llm-serving/docker-compose.yml` 을 고쳐야
  한다.
