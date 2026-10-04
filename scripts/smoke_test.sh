#!/usr/bin/env bash
# MicroLink end-to-end smoke test — exercises the real golden path through
# the API gateway against the already-running docker compose stack.
set -o pipefail

BASE="http://localhost:8080/api"
PASS=0
FAIL=0
STAMP=$(date +%s)
CUST_TOKEN=""; OWNER_TOKEN=""; AGENT_TOKEN=""; ADMIN_TOKEN=""
OWNER_ID=""; AGENT_ID=""; SHOP_ID=""; ORDER_ID=""

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1 -- $2"; FAIL=$((FAIL+1)); }

# req METHOD PATH TOKEN BODY -> sets RESP (body) and CODE (http status)
req() {
  local method="$1" path="$2" token="${3:-}" body="${4:-}"
  local args=(-s -w "\n%{http_code}" -X "$method" "$BASE$path" -H "Content-Type: application/json")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ] && args+=(-d "$body")
  local out
  out=$(curl "${args[@]}")
  CODE=$(echo "$out" | tail -n1)
  RESP=$(echo "$out" | sed '$d')
}

jget() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

echo "=== 1. Gateway + service health ==="
for svc in "gateway:8080" "user:8001" "shop:8002" "recommendation:8003" "navigation:8004" "delivery:8005" "crowdsource:8006" "admin:8007"; do
  name=${svc%%:*}; port=${svc##*:}
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/$([ "$name" = gateway ] && echo health || echo docs)")
  [ "$code" = "200" ] && pass "$name-service reachable ($code)" || fail "$name-service reachable" "got $code"
done

echo "=== 2. Register users (customer, shop_owner, delivery_agent) ==="
CUST_EMAIL="cust_$STAMP@test.com"
OWNER_EMAIL="owner_$STAMP@test.com"
AGENT_EMAIL="agent_$STAMP@test.com"
PW="TestPass123!"

req POST /auth/register "" "{\"email\":\"$CUST_EMAIL\",\"password\":\"$PW\",\"full_name\":\"Test Customer\",\"role\":\"user\"}"
[ "$CODE" = "201" ] && { CUST_TOKEN=$(echo "$RESP" | jget "['access_token']"); pass "register customer"; } || fail "register customer" "$CODE $RESP"

req POST /auth/register "" "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$PW\",\"full_name\":\"Test Owner\",\"role\":\"shop_owner\"}"
[ "$CODE" = "201" ] && { OWNER_TOKEN=$(echo "$RESP" | jget "['access_token']"); OWNER_ID=$(echo "$RESP" | jget "['user']['id']"); pass "register shop_owner"; } || fail "register shop_owner" "$CODE $RESP"

req POST /auth/register "" "{\"email\":\"$AGENT_EMAIL\",\"password\":\"$PW\",\"full_name\":\"Test Agent\",\"role\":\"delivery_agent\"}"
[ "$CODE" = "201" ] && { AGENT_TOKEN=$(echo "$RESP" | jget "['access_token']"); AGENT_ID=$(echo "$RESP" | jget "['user']['id']"); pass "register delivery_agent"; } || fail "register delivery_agent" "$CODE $RESP"

echo "=== 3. Admin provisioning + verify owner/agent ==="
ADMIN_EMAIL="admin_$STAMP@microlinktest.com"
ADMIN_PW="AdminPass123!"
docker compose exec -T user-service python -m app.scripts.create_admin "$ADMIN_EMAIL" "$ADMIN_PW" "Smoke Admin" >/tmp/admin_create.log 2>&1
pass "create/promote admin (see /tmp/admin_create.log)"

req POST /auth/login "" "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PW\"}"
[ "$CODE" = "200" ] && { ADMIN_TOKEN=$(echo "$RESP" | jget "['access_token']"); pass "admin login"; } || fail "admin login" "$CODE $RESP"

req PATCH "/users/$OWNER_ID/verify" "$ADMIN_TOKEN" ""
[ "$CODE" = "200" ] && pass "admin verifies shop_owner" || fail "admin verifies shop_owner" "$CODE $RESP"

req PATCH "/users/$AGENT_ID/verify" "$ADMIN_TOKEN" ""
[ "$CODE" = "200" ] && pass "admin verifies delivery_agent" || fail "admin verifies delivery_agent" "$CODE $RESP"

# re-login so tokens carry the fresh is_verified claim
req POST /auth/login "" "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$PW\"}"
OWNER_TOKEN=$(echo "$RESP" | jget "['access_token']")
req POST /auth/login "" "{\"email\":\"$AGENT_EMAIL\",\"password\":\"$PW\"}"
AGENT_TOKEN=$(echo "$RESP" | jget "['access_token']")

echo "=== 4. Shop owner creates shop + product ==="
req POST /shops "$OWNER_TOKEN" '{"name":"Smoke Test Cafe","category":"restaurant","address":"123 Test Rd, Colombo","latitude":6.9271,"longitude":79.8612}'
[ "$CODE" = "201" ] && { SHOP_ID=$(echo "$RESP" | jget "['id']"); pass "create shop (bare /api/shops, no trailing slash)"; } || fail "create shop" "$CODE $RESP"

req POST "/shops/$SHOP_ID/products" "$OWNER_TOKEN" '{"name":"Test Burger","price":5.5,"description":"smoke test item"}'
[ "$CODE" = "201" ] && pass "add product to shop" || fail "add product to shop" "$CODE $RESP"

echo "=== 5. Customer browses shops + recommendations ==="
req GET "/shops?lat=6.9271&lng=79.8612&radius_km=50" "$CUST_TOKEN" ""
if [ "$CODE" = "200" ] && echo "$RESP" | grep -q "$SHOP_ID"; then pass "list/search shops (finds new shop)"; else fail "list/search shops" "$CODE $RESP"; fi

req GET "/recommendations?lat=6.9271&lng=79.8612" "$CUST_TOKEN" ""
[ "$CODE" = "200" ] && pass "get recommendations" || fail "get recommendations" "$CODE $RESP"

req POST "/recommendations/$SHOP_ID/favorite" "$CUST_TOKEN" ""
[ "$CODE" = "204" ] && pass "favorite a shop" || fail "favorite a shop" "$CODE $RESP"

echo "=== 6. Navigation route ==="
req POST /navigation/route "$CUST_TOKEN" '{"origin":{"lat":6.9271,"lng":79.8612},"destination":{"lat":6.9350,"lng":79.8500}}'
[ "$CODE" = "200" ] && pass "compute route" || fail "compute route" "$CODE $RESP"


echo "=== 7. Order + delivery flow ==="
req POST /delivery/orders "$CUST_TOKEN" "{\"shop_id\":\"$SHOP_ID\",\"items\":[{\"name\":\"Test Burger\",\"qty\":2}],\"delivery_address\":\"456 Home St\",\"delivery_lat\":6.93,\"delivery_lng\":79.855,\"total_amount\":11.0}"
[ "$CODE" = "201" ] && { ORDER_ID=$(echo "$RESP" | jget "['id']"); pass "customer creates order"; } || fail "customer creates order" "$CODE $RESP"

req POST /delivery/agents/profile "$AGENT_TOKEN" '{"vehicle_type":"bike"}'
[ "$CODE" = "200" ] && pass "agent creates profile" || fail "agent creates profile" "$CODE $RESP"

req PATCH /delivery/agents/me/availability "$AGENT_TOKEN" '{"is_available":true}'
[ "$CODE" = "200" ] && pass "agent sets availability" || fail "agent sets availability" "$CODE $RESP"

req GET /delivery/orders/available "$AGENT_TOKEN" ""
[ "$CODE" = "200" ] && pass "agent lists available orders" || fail "agent lists available orders" "$CODE $RESP"

req PATCH "/delivery/orders/$ORDER_ID/accept" "$AGENT_TOKEN" ""
[ "$CODE" = "200" ] && pass "agent accepts order" || fail "agent accepts order" "$CODE $RESP"

req PATCH "/delivery/orders/$ORDER_ID/status" "$AGENT_TOKEN" '{"status":"picked_up"}'
[ "$CODE" = "200" ] && pass "order -> picked_up" || fail "order -> picked_up" "$CODE $RESP"

req PATCH "/delivery/orders/$ORDER_ID/status" "$AGENT_TOKEN" '{"status":"in_transit"}'
[ "$CODE" = "200" ] && pass "order -> in_transit" || fail "order -> in_transit" "$CODE $RESP"

req PATCH "/delivery/orders/$ORDER_ID/status" "$AGENT_TOKEN" '{"status":"delivered"}'
[ "$CODE" = "200" ] && pass "order -> delivered" || fail "order -> delivered" "$CODE $RESP"

echo "=== 8. Crowdsource feedback ==="
req POST /crowdsource/feedback "$CUST_TOKEN" "{\"order_id\":\"$ORDER_ID\",\"rating\":5,\"comment\":\"smoke test feedback\"}"
[ "$CODE" = "201" ] && pass "submit order feedback" || fail "submit order feedback" "$CODE $RESP"

echo "=== 9. Admin analytics ==="
req GET /admin/analytics/overview "$ADMIN_TOKEN" ""
[ "$CODE" = "200" ] && pass "admin analytics overview" || fail "admin analytics overview" "$CODE $RESP"

req GET /admin/activity-log "$ADMIN_TOKEN" ""
[ "$CODE" = "200" ] && pass "admin activity log" || fail "admin activity log" "$CODE $RESP"

echo
echo "================================"
echo "RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ]
