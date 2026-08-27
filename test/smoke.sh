#!/usr/bin/env bash
# Smoke tests. One test per claim the post makes.
#
# Every test hits the SAME action layer, whichever substrate drove it. That is the point:
# if the boundary holds, these assertions do not change when you switch substrate.
set -uo pipefail

: "${TOOLS_APP_URL:?set TOOLS_APP_URL, for example https://ffb-tools-abc.azurewebsites.net}"
: "${TOOLS_KEY:?set TOOLS_KEY (a function key for the tools app)}"

PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    printf '  PASS  %-52s %s\n' "${name}" "${actual}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-52s expected %s, got %s\n' "${name}" "${expected}" "${actual}"
    FAIL=$((FAIL + 1))
  fi
}

hdr=(-H "x-functions-key: ${TOOLS_KEY}" -H "Content-Type: application/json")
api="${TOOLS_APP_URL%/}/api"

echo "== Action layer, direct =="

code=$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "${api}/tools/orders/ORD-1001")
check "known order returns 200" "200" "${code}"

code=$(curl -s -o /dev/null -w '%{http_code}' "${hdr[@]}" "${api}/tools/orders/ORD-9999")
check "unknown order returns 404" "404" "${code}"

avail=$(curl -s "${hdr[@]}" "${api}/tools/inventory/SKU-DOCK" | python3 -c 'import json,sys; print(json.load(sys.stdin)["available"])')
check "SKU-DOCK starts with 2 available" "2" "${avail}"

echo
echo "== Idempotency: the same key never holds stock twice =="

KEY="resv-smoke-$(date +%s)"
body="{\"sku\":\"SKU-KEYBOARD\",\"quantity\":2,\"reservationKey\":\"${KEY}\"}"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${hdr[@]}" -d "${body}" "${api}/tools/reservations")
check "first reservation returns 201" "201" "${code}"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${hdr[@]}" -d "${body}" "${api}/tools/reservations")
check "replayed reservation returns 200" "200" "${code}"

created=$(curl -s -X POST "${hdr[@]}" -d "${body}" "${api}/tools/reservations" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["created"]).lower())')
check "replay reports created=false" "false" "${created}"

echo
echo "== Over-reservation is refused, not negotiated =="

over="{\"sku\":\"SKU-DOCK\",\"quantity\":5,\"reservationKey\":\"resv-over-$(date +%s)\"}"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${hdr[@]}" -d "${over}" "${api}/tools/reservations")
check "reserving more than free stock returns 409" "409" "${code}"

if [[ -n "${DURABLE_APP_URL:-}" && -n "${DURABLE_KEY:-}" ]]; then
  echo
  echo "== Option 2: durable agent on Functions =="

  start=$(curl -s -i -X POST \
    -H "x-functions-key: ${DURABLE_KEY}" \
    "${DURABLE_APP_URL%/}/api/fulfil/ORD-1002")

  code=$(printf '%s' "${start}" | head -1 | awk '{print $2}')
  check "start returns 202 Accepted" "202" "${code}"

  status_url=$(printf '%s' "${start}" | grep -i '^location:' | tr -d '\r' | awk '{print $2}')
  if [[ -z "${status_url}" ]]; then
    echo "  FAIL  no Location header on the 202"
    FAIL=$((FAIL + 1))
  else
    for _ in $(seq 1 30); do
      runtime_status=$(curl -s "${status_url}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("runtimeStatus",""))' 2>/dev/null || echo "")
      [[ "${runtime_status}" == "Completed" || "${runtime_status}" == "Failed" ]] && break
      sleep 4
    done
    check "orchestration completes" "Completed" "${runtime_status}"
  fi

  # The assertion that matters. One fulfilment, one customer message, no matter how many
  # times the orchestration replayed internally.
  count=$(curl -s "${hdr[@]}" "${api}/tools/notifications/ORD-1002" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  check "customer notified exactly once" "1" "${count}"
else
  echo
  echo "== Option 2 skipped: set DURABLE_APP_URL and DURABLE_KEY to run it =="
fi

echo
echo "-------------------------------------------"
printf 'passed %d, failed %d\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
