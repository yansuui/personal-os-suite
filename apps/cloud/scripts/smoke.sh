#!/usr/bin/env bash
# Use only against an already-running, writable test instance.
set +x
set -euo pipefail

: "${V2_ADMIN_SECRET:?Set V2_ADMIN_SECRET to the running service pairing secret}"
BASE_URL="${BASE_URL:-http://127.0.0.1:8787}"
BASE_URL="${BASE_URL%/}"
command -v curl >/dev/null || { printf 'curl is required\n' >&2; exit 1; }
command -v node >/dev/null || { printf 'Node.js 24 is required\n' >&2; exit 1; }
node -e 'if (Number(process.versions.node.split(".")[0]) < 24) process.exit(1)' \
  || { printf 'Node.js 24 or newer is required\n' >&2; exit 1; }

# Never print response bodies: pairing/run responses may contain credentials.
request() {
  curl --fail --silent --show-error --connect-timeout 5 --max-time 30 "$@"
}
json_field() {
  node --input-type=module -e '
    try {
      let data = "";
      for await (const chunk of process.stdin) data += chunk;
      let value = JSON.parse(data);
      for (const key of process.argv[1].split(".")) value = value[key];
      if (typeof value !== "string" && typeof value !== "number") throw new Error();
      if (value === "") throw new Error();
      process.stdout.write(String(value));
    } catch {
      console.error("Invalid API response field");
      process.exit(1);
    }
  ' "$1"
}
json_assert() {
  node --input-type=module -e '
    try {
      let data = "";
      for await (const chunk of process.stdin) data += chunk;
      const value = JSON.parse(data);
      if (!new Function("value", process.argv[1])(value)) throw new Error();
    } catch {
      console.error("Unexpected API response");
      process.exit(1);
    }
  ' "$1"
}

HEALTH_JSON=$(request "$BASE_URL/v2/health")
printf '%s' "$HEALTH_JSON" | json_assert \
  'return value.ok === true && value.protocolVersion === 2;'
printf 'PASS health\n'

PAIR_JSON=$(request -X POST "$BASE_URL/v2/pair" \
  -H "x-pair-secret: $V2_ADMIN_SECRET" -H 'Content-Type: application/json' \
  --data '{"name":"cloud-smoke-client","role":"client"}')
TOKEN=$(printf '%s' "$PAIR_JSON" | json_field token)
printf '%s' "$PAIR_JSON" | json_assert \
  'return value.device.role === "client" && !("tokenHash" in value.device);'
unset PAIR_JSON
trap 'unset TOKEN V2_ADMIN_SECRET' EXIT
printf 'PASS pair\n'

CONVERSATION_JSON=$(request -X POST "$BASE_URL/v2/conversations" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"title":"Cloud smoke"}')
CONVERSATION_ID=$(printf '%s' "$CONVERSATION_JSON" | json_field conversation.id)
printf '%s' "$CONVERSATION_JSON" | json_assert \
  'return value.conversation.ownerId === "default";'
printf 'PASS create conversation\n'

MESSAGE_JSON=$(request -X POST "$BASE_URL/v2/conversations/$CONVERSATION_ID/messages" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"clientRequestId":"smoke-message-1","text":"Smoke test"}')
RUN_ID=$(printf '%s' "$MESSAGE_JSON" | json_field run.id)
CURSOR=$(printf '%s' "$MESSAGE_JSON" | json_field message.seq)
printf '%s' "$MESSAGE_JSON" | json_assert \
  'return value.created === true && value.message.role === "user" && value.run.status === "queued" && value.message.seq === 1;'
printf 'PASS append message\n'

REPLAY_JSON=$(request -X POST "$BASE_URL/v2/conversations/$CONVERSATION_ID/messages" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data '{"clientRequestId":"smoke-message-1","text":"Smoke test"}')
printf '%s' "$REPLAY_JSON" | json_assert 'return value.created === false;'
[[ "$(printf '%s' "$REPLAY_JSON" | json_field run.id)" == "$RUN_ID" ]] \
  || { printf 'Idempotent replay changed run\n' >&2; exit 1; }
printf 'PASS message idempotency\n'

MESSAGES_JSON=$(request \
  "$BASE_URL/v2/conversations/$CONVERSATION_ID/messages?after=0&wait=0" \
  -H "Authorization: Bearer $TOKEN")
printf '%s' "$MESSAGES_JSON" | json_assert \
  'return value.messages.length === 1 && value.messages[0].text === "Smoke test" && value.nextCursor === 1;'
POLL_JSON=$(request \
  "$BASE_URL/v2/conversations/$CONVERSATION_ID/messages?after=$CURSOR&wait=0.2" \
  -H "Authorization: Bearer $TOKEN")
printf '%s' "$POLL_JSON" | json_assert \
  'return Array.isArray(value.messages) && value.messages.length === 0;'
[[ "$(printf '%s' "$POLL_JSON" | json_field nextCursor)" == "$CURSOR" ]] \
  || { printf 'Long-poll timeout changed cursor\n' >&2; exit 1; }
printf 'PASS long poll\n'

CANCEL_JSON=$(request -X POST "$BASE_URL/v2/runs/$RUN_ID/cancel" \
  -H "Authorization: Bearer $TOKEN")
printf '%s' "$CANCEL_JSON" | json_assert 'return value.run.status === "canceled";'
printf 'PASS cancel\n'
printf 'Cloud smoke passed; test device, conversation and message remain in the database.\n'
