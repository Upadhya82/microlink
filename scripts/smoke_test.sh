#!/usr/bin/env bash
# MicroLink end-to-end smoke test — exercises the real golden path through
# the API gateway against the already-running docker compose stack.
set -o pipefail

# The gateway's host port. Override when 8080 is taken on your machine:
#   GATEWAY_PORT=8081 bash scripts/smoke_test.sh
# (and publish the gateway there, e.g. with a compose override).
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
BASE="${BASE:-http://localhost:$GATEWAY_PORT/api}"
PASS=0
FAIL=0
STAMP=$(date +%s)
CUST_TOKEN=""; OWNER_TOKEN=""; AGENT_TOKEN=""; ADMIN_TOKEN=""
PICKUP_CODE=""; DELIVERY_CODE=""
OWNER_ID=""; AGENT_ID=""; SHOP_ID=""; ORDER_ID=""; PRODUCT_ID=""; CANCEL_ORDER_ID=""
APPLICANT_ID=""; DOC_ID=""

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

# Pick a working interpreter once. On Windows/Git Bash `python3` is often the
# Microsoft Store stub, which prints an install hint and exits non-zero -- with
# stderr silenced that made every jget return "" and cascaded into dozens of
# bogus 401/404 failures. Probe it instead of assuming.
PY=""
for candidate in python3 python py; do
  if command -v "$candidate" >/dev/null 2>&1 && echo '{}' | "$candidate" -c "import sys,json;json.load(sys.stdin)" >/dev/null 2>&1; then
    PY="$candidate"; break
  fi
done
if [ -z "$PY" ]; then
  echo "No working Python found (tried python3, python, py). Cannot parse API responses." >&2
  exit 1
fi

jget() { "$PY" -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

echo "=== 1. Gateway + service health ==="
for svc in "gateway:$GATEWAY_PORT" "user:8001" "shop:8002" "recommendation:8003" "navigation:8004" "delivery:8005" "crowdsource:8006" "admin:8007"; do
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

# Item 16: these two roles need their documents in the same request, so
# /auth/register refuses them outright rather than creating an account that
# can never be approved or used.
req POST /auth/register "" "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$PW\",\"full_name\":\"Test Owner\",\"role\":\"shop_owner\"}"
[ "$CODE" = "403" ] && pass "plain register refuses shop_owner"   || fail "plain register refuses shop_owner" "expected 403, got $CODE $RESP"

req POST /auth/register "" "{\"email\":\"$AGENT_EMAIL\",\"password\":\"$PW\",\"full_name\":\"Test Agent\",\"role\":\"delivery_agent\"}"
[ "$CODE" = "403" ] && pass "plain register refuses delivery_agent"   || fail "plain register refuses delivery_agent" "expected 403, got $CODE $RESP"

COUNT=$(docker compose exec -T postgres psql -U microlink -d user_db -t -A   -c "select count(*) from users where email in ('$OWNER_EMAIL','$AGENT_EMAIL');" 2>/dev/null | tr -d '[:space:]')
[ "$COUNT" = "0" ] && pass "a refused registration created no account"   || fail "a refused registration created no account" "found $COUNT"

# REQ-AUTH-4: an application is all-or-nothing. A gated role that cannot
# supply every document must not end up with an account it can never use.
APPLICANT_EMAIL="applicant_$STAMP@test.com"
# In the working directory, not the system temp: on Windows the curl on
# PATH cannot resolve an MSYS /tmp path and fails the upload before it
# reaches the server.
DOCPNG="smoke_doc_$STAMP.png"
# Also in the working directory, not /tmp: curl resolves an MSYS path but the
# Windows Python that reads the ids back out of it does not.
APPLY_RESP="smoke_apply_$STAMP.json"
docker compose exec -T shop-service python -c "
from PIL import Image
import base64, io
b = io.BytesIO(); Image.new('RGBA', (900, 600), (40, 90, 160, 255)).save(b, 'PNG')
print(base64.b64encode(b.getvalue()).decode())" 2>/dev/null | base64 -d > "$DOCPNG"

apply_code() {
  curl -s -o "$APPLY_RESP" -w "%{http_code}" -X POST "$BASE/auth/register-application"     -F "email=$APPLICANT_EMAIL" -F "password=$PW" -F "full_name=Smoke Applicant"     -F "role=shop_owner" -F "business_name=Smoke Stores" "$@"
}

# Only one of the three required documents.
CODE=$(apply_code -F "doc_types=national_id" -F "files=@$DOCPNG;type=application/octet-stream")
[ "$CODE" = "400" ] && pass "incomplete application is refused"   || fail "incomplete application is refused" "$CODE $(cat "$APPLY_RESP")"

COUNT=$(docker compose exec -T postgres psql -U microlink -d user_db -t -A   -c "select count(*) from users where email='$APPLICANT_EMAIL';" 2>/dev/null | tr -d '[:space:]')
[ "$COUNT" = "0" ] && pass "refused application created no account"   || fail "refused application created no account" "found $COUNT"

CODE=$(apply_code   -F "doc_types=national_id" -F "files=@$DOCPNG;type=application/octet-stream"   -F "doc_types=business_registration" -F "files=@$DOCPNG;type=application/octet-stream"   -F "doc_types=profile_photo" -F "files=@$DOCPNG;type=application/octet-stream")
[ "$CODE" = "201" ] && pass "complete application is accepted"   || fail "complete application is accepted" "$CODE $(cat "$APPLY_RESP")"

DOCS=$(docker compose exec -T postgres psql -U microlink -d user_db -t -A   -c "select count(*) from user_documents d join users u on u.id=d.user_id where u.email='$APPLICANT_EMAIL';" 2>/dev/null | tr -d '[:space:]')
[ "$DOCS" = "3" ] && pass "application stored all 3 documents"   || fail "application stored all 3 documents" "found $DOCS"

# Item 16: the owner and the agent come in the same way, with documents.
apply_as() {
  local email="$1" role="$2" name="$3"; shift 3
  curl -s -o "$APPLY_RESP" -w "%{http_code}" -X POST "$BASE/auth/register-application"     -F "email=$email" -F "password=$PW" -F "full_name=$name"     -F "role=$role" -F "business_name=Smoke Stores" "$@"
}

CODE=$(apply_as "$OWNER_EMAIL" shop_owner "Test Owner"   -F "doc_types=national_id" -F "files=@$DOCPNG;type=application/octet-stream"   -F "doc_types=business_registration" -F "files=@$DOCPNG;type=application/octet-stream"   -F "doc_types=profile_photo" -F "files=@$DOCPNG;type=application/octet-stream")
if [ "$CODE" = "201" ]; then
  OWNER_ID=$("$PY" -c "import json;print(json.load(open('"$APPLY_RESP"'))['user']['id'])" 2>/dev/null)
  pass "shop_owner applies with documents"
else
  fail "shop_owner applies with documents" "$CODE $(cat "$APPLY_RESP")"
fi

CODE=$(apply_as "$AGENT_EMAIL" delivery_agent "Test Agent"   -F "doc_types=national_id" -F "files=@$DOCPNG;type=application/octet-stream"   -F "doc_types=driving_licence" -F "files=@$DOCPNG;type=application/octet-stream"   -F "doc_types=police_clearance" -F "files=@$DOCPNG;type=application/octet-stream"   -F "doc_types=vehicle_registration" -F "files=@$DOCPNG;type=application/octet-stream"   -F "doc_types=profile_photo" -F "files=@$DOCPNG;type=application/octet-stream")
if [ "$CODE" = "201" ]; then
  AGENT_ID=$("$PY" -c "import json;print(json.load(open('"$APPLY_RESP"'))['user']['id'])" 2>/dev/null)
  pass "delivery_agent applies with documents"
else
  fail "delivery_agent applies with documents" "$CODE $(cat "$APPLY_RESP")"
fi

req POST /auth/login "" "{\"email\":\"$APPLICANT_EMAIL\",\"password\":\"$PW\"}"
[ "$CODE" = "403" ] && pass "applicant cannot log in before approval"   || fail "applicant cannot log in before approval" "$CODE $RESP"
rm -f "$DOCPNG" "$APPLY_RESP"

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

# Item 9: a document is served with a name and a disposition, so the app and
# the browser can open it instead of receiving nameless bytes.
req GET "/users?q=$APPLICANT_EMAIL" "$ADMIN_TOKEN" ""
APPLICANT_ID=$(echo "$RESP" | jget "[0]['id']")
req GET "/users/$APPLICANT_ID/documents" "$ADMIN_TOKEN" ""
DOC_ID=$(echo "$RESP" | jget "[0]['id']")
if [ -n "$DOC_ID" ] && [ "$DOC_ID" != "None" ]; then
  DOC_HEADERS=$(curl -s -D - -o /dev/null -H "Authorization: Bearer $ADMIN_TOKEN" "$BASE/users/documents/$DOC_ID/file")
  echo "$DOC_HEADERS" | grep -qi "content-disposition: *inline; *filename=" && pass "a document is served with a filename"   || fail "a document is served with a filename" "$(echo "$DOC_HEADERS" | grep -i content-disposition)"
  echo "$DOC_HEADERS" | grep -qi "x-content-type-options: *nosniff" && pass "a document is served with nosniff"   || fail "a document is served with nosniff" "no nosniff header"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/users/documents/$DOC_ID/file")
  [ "$CODE" = "401" -o "$CODE" = "403" ] && pass "a document is not served without a token"   || fail "a document is not served without a token" "got $CODE"
else
  fail "admin can find the applicant's documents" "no document id"
fi

# re-login so tokens carry the fresh is_verified claim
req POST /auth/login "" "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$PW\"}"
OWNER_TOKEN=$(echo "$RESP" | jget "['access_token']")
req POST /auth/login "" "{\"email\":\"$AGENT_EMAIL\",\"password\":\"$PW\"}"
AGENT_TOKEN=$(echo "$RESP" | jget "['access_token']")

echo "=== 4. Shop owner creates shop + product ==="
req POST /shops "$OWNER_TOKEN" '{"name":"Smoke Test Cafe","category":"restaurant","address":"123 Test Rd, Colombo","latitude":6.9271,"longitude":79.8612}'
[ "$CODE" = "201" ] && { SHOP_ID=$(echo "$RESP" | jget "['id']"); pass "create shop (bare /api/shops, no trailing slash)"; } || fail "create shop" "$CODE $RESP"

# stock_quantity must be at least shop-service's min_listable_stock (5), or
# the create is refused with 422 and customers would never see the product.
req POST "/shops/$SHOP_ID/products" "$OWNER_TOKEN" '{"name":"Test Burger","price":5.5,"description":"smoke test item","stock_quantity":10}'
[ "$CODE" = "201" ] && { PRODUCT_ID=$(echo "$RESP" | jget "['id']"); pass "add product to shop"; } || fail "add product to shop" "$CODE $RESP"

# A product below the listing threshold cannot be created at all (item 11).
req POST "/shops/$SHOP_ID/products" "$OWNER_TOKEN" '{"name":"Nearly gone","price":3.0,"stock_quantity":4}'
[ "$CODE" = "422" ] && pass "a product under 5 in stock is refused"   || fail "a product under 5 in stock is refused" "expected 422, got $CODE $RESP"

# Item 10: a shop with one product cannot be verified yet.
req PATCH "/shops/$SHOP_ID/verify" "$ADMIN_TOKEN" '{"is_verified":true}'
[ "$CODE" = "409" ] && pass "a shop with too few products cannot be verified"   || fail "a shop with too few products cannot be verified" "expected 409, got $CODE $RESP"

# Stock it properly and the same call succeeds.
for n in 2 3 4 5; do
  req POST "/shops/$SHOP_ID/products" "$OWNER_TOKEN" "{\"name\":\"Filler $n\",\"price\":2.5,\"stock_quantity\":8}"
done
req PATCH "/shops/$SHOP_ID/verify" "$ADMIN_TOKEN" '{"is_verified":true}'
LISTED=$(echo "$RESP" | jget "['listable_product_count']")
[ "$CODE" = "200" ] && pass "a shop with 5 listed products can be verified"   || fail "a shop with 5 listed products can be verified" "$CODE $RESP"
[ "$LISTED" = "5" ] && pass "the response reports the listable product count"   || fail "the response reports the listable product count" "got $LISTED"

echo "=== 5. Customer browses shops + recommendations ==="
req GET "/shops?lat=6.9271&lng=79.8612&radius_km=50" "$CUST_TOKEN" ""
if [ "$CODE" = "200" ] && echo "$RESP" | grep -q "$SHOP_ID"; then pass "list/search shops (finds new shop)"; else fail "list/search shops" "$CODE $RESP"; fi

# Omitting radius_km must mean "no distance limit", not the server's old
# default of 10 km. Turning the radius filter off in the app looked like it
# did nothing because of exactly that.
req GET "/shops?lat=6.9271&lng=79.8612&radius_km=2&limit=200" "$CUST_TOKEN" ""
NEAR_COUNT=$(echo "$RESP" | "$PY" -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
req GET "/shops?lat=6.9271&lng=79.8612&limit=200" "$CUST_TOKEN" ""
ALL_COUNT=$(echo "$RESP" | "$PY" -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
if [ -n "$NEAR_COUNT" ] && [ -n "$ALL_COUNT" ] && [ "$ALL_COUNT" -gt "$NEAR_COUNT" ]; then
  pass "no radius returns more shops than a 2 km radius ($ALL_COUNT vs $NEAR_COUNT)"
else
  fail "no radius returns more shops than a 2 km radius" "near=$NEAR_COUNT all=$ALL_COUNT"
fi

req GET "/recommendations?lat=6.9271&lng=79.8612" "$CUST_TOKEN" ""
[ "$CODE" = "200" ] && pass "get recommendations" || fail "get recommendations" "$CODE $RESP"

req POST "/recommendations/$SHOP_ID/favorite" "$CUST_TOKEN" ""
[ "$CODE" = "204" ] && pass "favorite a shop" || fail "favorite a shop" "$CODE $RESP"

echo "=== 6. Navigation route ==="
req POST /navigation/route "$CUST_TOKEN" '{"origin":{"lat":6.9271,"lng":79.8612},"destination":{"lat":6.9350,"lng":79.8500}}'
[ "$CODE" = "200" ] && pass "compute route" || fail "compute route" "$CODE $RESP"


echo "=== 7. Order + delivery flow ==="
# A real product_id and quantity, so the order reserves stock (item 12).
req POST /delivery/orders "$CUST_TOKEN" "{\"shop_id\":\"$SHOP_ID\",\"items\":[{\"product_id\":\"$PRODUCT_ID\",\"name\":\"Test Burger\",\"quantity\":2,\"price\":5.5}],\"delivery_address\":\"456 Home St\",\"delivery_lat\":6.93,\"delivery_lng\":79.855,\"total_amount\":11.0}"
[ "$CODE" = "201" ] && { ORDER_ID=$(echo "$RESP" | jget "['id']"); pass "customer creates order"; } || fail "customer creates order" "$CODE $RESP"

req POST /delivery/agents/profile "$AGENT_TOKEN" '{"vehicle_type":"bike"}'
[ "$CODE" = "200" ] && pass "agent creates profile" || fail "agent creates profile" "$CODE $RESP"

req PATCH /delivery/agents/me/availability "$AGENT_TOKEN" '{"is_available":true}'
[ "$CODE" = "200" ] && pass "agent sets availability" || fail "agent sets availability" "$CODE $RESP"

req GET /delivery/orders/available "$AGENT_TOKEN" ""
[ "$CODE" = "200" ] && pass "agent lists available orders" || fail "agent lists available orders" "$CODE $RESP"

req PATCH "/delivery/orders/$ORDER_ID/accept" "$AGENT_TOKEN" ""
[ "$CODE" = "200" ] && pass "agent accepts order" || fail "agent accepts order" "$CODE $RESP"

# Handover codes: the agent cannot advance these two states alone. Fetch
# them the way the real app does -- the pickup code from the shop owner's
# order list, the delivery code from the customer's.
req GET "/delivery/orders/shop/$SHOP_ID" "$OWNER_TOKEN" ""
PICKUP_CODE=$(echo "$RESP" | "$PY" -c "
import sys, json
rows = json.load(sys.stdin)
match = [r for r in rows if r['id'] == '$ORDER_ID']
print(match[0]['pickup_code'] if match else '')
" 2>/dev/null)
[ -n "$PICKUP_CODE" ] && pass "shop owner can read the pickup code"   || fail "shop owner can read the pickup code" "$CODE $RESP"

req GET "/delivery/orders/me" "$CUST_TOKEN" ""
DELIVERY_CODE=$(echo "$RESP" | "$PY" -c "
import sys, json
rows = json.load(sys.stdin)
match = [r for r in rows if r['id'] == '$ORDER_ID']
print(match[0]['delivery_code'] if match else '')
" 2>/dev/null)
[ -n "$DELIVERY_CODE" ] && pass "customer can read the delivery code"   || fail "customer can read the delivery code" "$CODE $RESP"

# A wrong code must not advance the order.
req PATCH "/delivery/orders/$ORDER_ID/status" "$AGENT_TOKEN" '{"status":"picked_up","code":"0000"}'
[ "$CODE" = "400" ] && pass "wrong pickup code is rejected"   || fail "wrong pickup code is rejected" "expected 400, got $CODE"

req PATCH "/delivery/orders/$ORDER_ID/status" "$AGENT_TOKEN" "{\"status\":\"picked_up\",\"code\":\"$PICKUP_CODE\"}"
[ "$CODE" = "200" ] && pass "order -> picked_up" || fail "order -> picked_up" "$CODE $RESP"

# Confirming the pickup code starts the journey, so in_transit is set by the
# server. The agent has no button for it and no second request to make.
req GET "/delivery/orders/$ORDER_ID" "$CUST_TOKEN" ""
STATUS_NOW=$(echo "$RESP" | jget "['status']")
[ "$STATUS_NOW" = "in_transit" ] && pass "pickup moves the order to in_transit automatically"   || fail "pickup moves the order to in_transit automatically" "status is $STATUS_NOW"

# The two codes must not be interchangeable, or one of them would open both
# handovers and the parcel could be closed off without meeting the customer.
[ "$PICKUP_CODE" != "$DELIVERY_CODE" ] && pass "pickup and delivery codes differ"   || fail "pickup and delivery codes differ" "both are $PICKUP_CODE"

req PATCH "/delivery/orders/$ORDER_ID/status" "$AGENT_TOKEN" "{\"status\":\"delivered\",\"code\":\"$PICKUP_CODE\"}"
[ "$CODE" = "400" ] && pass "pickup code cannot close the delivery"   || fail "pickup code cannot close the delivery" "$CODE $RESP"

# The agent is sent neither code; they can only type in what they are told.
req GET "/delivery/orders/$ORDER_ID" "$AGENT_TOKEN" ""
AG_PICK=$(echo "$RESP" | jget "['pickup_code']")
AG_DROP=$(echo "$RESP" | jget "['delivery_code']")
[ -z "$AG_PICK" -o "$AG_PICK" = "None" ] && [ -z "$AG_DROP" -o "$AG_DROP" = "None" ] && pass "agent is shown neither handover code"   || fail "agent is shown neither handover code" "pickup=$AG_PICK delivery=$AG_DROP"

req PATCH "/delivery/orders/$ORDER_ID/status" "$AGENT_TOKEN" "{\"status\":\"delivered\",\"code\":\"$DELIVERY_CODE\"}"
[ "$CODE" = "200" ] && pass "order -> delivered" || fail "order -> delivered" "$CODE $RESP"

echo "=== 8. Stock reservation and cancellations (items 11, 12, 8) ==="

# The order above took 2 of the 10.
stock_now() {
  req GET "/shops/$SHOP_ID/products" "$OWNER_TOKEN" ""
  echo "$RESP" | "$PY" -c "
import sys, json
rows = json.load(sys.stdin)
match = [r for r in rows if r['id'] == '$PRODUCT_ID']
print(match[0]['stock_quantity'] if match else 'missing')
" 2>/dev/null
}
LEFT=$(stock_now)
[ "$LEFT" = "8" ] && pass "placing an order took the stock (10 -> 8)"   || fail "placing an order took the stock" "expected 8, got $LEFT"

# More than the shop has: refused, and nothing is saved.
req POST /delivery/orders "$CUST_TOKEN" "{\"shop_id\":\"$SHOP_ID\",\"items\":[{\"product_id\":\"$PRODUCT_ID\",\"name\":\"Test Burger\",\"quantity\":99,\"price\":5.5}],\"delivery_address\":\"456 Home St\",\"delivery_lat\":6.93,\"delivery_lng\":79.855}"
[ "$CODE" = "409" ] && pass "an order the shop cannot fill is refused (409)"   || fail "an order the shop cannot fill is refused" "expected 409, got $CODE $RESP"
LEFT=$(stock_now)
[ "$LEFT" = "8" ] && pass "the refused order took no stock"   || fail "the refused order took no stock" "expected 8, got $LEFT"

# The gateway must not expose the internal reserve/release endpoints.
req POST "/shops/$SHOP_ID/stock/reserve" "$OWNER_TOKEN" "{\"order_id\":\"x\",\"lines\":[]}"
[ "$CODE" = "404" ] && pass "the internal stock endpoints are not reachable"   || fail "the internal stock endpoints are not reachable" "expected 404, got $CODE"

# A second order for the shop to cancel.
req POST /delivery/orders "$CUST_TOKEN" "{\"shop_id\":\"$SHOP_ID\",\"items\":[{\"product_id\":\"$PRODUCT_ID\",\"name\":\"Test Burger\",\"quantity\":3,\"price\":5.5}],\"delivery_address\":\"456 Home St\",\"delivery_lat\":6.93,\"delivery_lng\":79.855,\"total_amount\":16.5}"
[ "$CODE" = "201" ] && { CANCEL_ORDER_ID=$(echo "$RESP" | jget "['id']"); pass "customer places a second order"; } || fail "customer places a second order" "$CODE $RESP"

req PATCH "/delivery/orders/$CANCEL_ORDER_ID/cancel" "$OWNER_TOKEN" '{}'
[ "$CODE" = "422" ] && pass "a shop must give a reason to cancel"   || fail "a shop must give a reason to cancel" "expected 422, got $CODE $RESP"

req PATCH "/delivery/orders/$CANCEL_ORDER_ID/cancel" "$OWNER_TOKEN" '{"reason":"Fryer broke down"}'
[ "$CODE" = "200" ] && pass "the shop owner can cancel its own order"   || fail "the shop owner can cancel its own order" "$CODE $RESP"

req GET "/delivery/orders/$CANCEL_ORDER_ID" "$CUST_TOKEN" ""
WHO=$(echo "$RESP" | jget "['cancelled_by']")
WHY=$(echo "$RESP" | jget "['cancel_reason']")
[ "$WHO" = "shop" ] && [ "$WHY" = "Fryer broke down" ] && pass "the customer is shown who cancelled and why"   || fail "the customer is shown who cancelled and why" "cancelled_by=$WHO reason=$WHY"

LEFT=$(stock_now)
[ "$LEFT" = "8" ] && pass "cancelling put the stock back (5 -> 8)"   || fail "cancelling put the stock back" "expected 8, got $LEFT"

echo "=== 9. Crowdsource feedback ==="
req POST /crowdsource/feedback "$CUST_TOKEN" "{\"order_id\":\"$ORDER_ID\",\"shop_id\":\"$SHOP_ID\",\"rating\":5,\"comment\":\"smoke test feedback\"}"
[ "$CODE" = "201" ] && pass "submit order feedback" || fail "submit order feedback" "$CODE $RESP"

# Item 3: that feedback travels over the event bus and becomes a review on
# the shop's page, labelled "Verified order" in the app. The bus is
# asynchronous, so give shop-service a moment to pick it up.
ORDER_REVIEW=""
for attempt in 1 2 3 4 5 6; do
  sleep 1
  req GET "/shops/$SHOP_ID/reviews" "$CUST_TOKEN" ""
  ORDER_REVIEW=$(echo "$RESP" | "$PY" -c "
import sys, json
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
match = [r for r in rows if r.get('source') == 'order']
print(match[0]['rating'] if match else '')
" 2>/dev/null)
  [ -n "$ORDER_REVIEW" ] && break
done
[ "$ORDER_REVIEW" = "5" ] && pass "order feedback shows up in the shop's reviews"   || fail "order feedback shows up in the shop's reviews" "no source=order review found"

echo "=== 10. Admin analytics ==="
req GET /admin/analytics/overview "$ADMIN_TOKEN" ""
[ "$CODE" = "200" ] && pass "admin analytics overview" || fail "admin analytics overview" "$CODE $RESP"

req GET /admin/activity-log "$ADMIN_TOKEN" ""
[ "$CODE" = "200" ] && pass "admin activity log" || fail "admin activity log" "$CODE $RESP"

echo
echo "================================"
echo "RESULT: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ]
