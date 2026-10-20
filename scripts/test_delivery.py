"""MicroLink - delivery agent test. Checks the SRS rules of the delivery part.

It talks to user-service and delivery-service directly, so it needs NO shop-service,
NO gateway port and NO Python on your laptop. It runs INSIDE the delivery-service
container. From the folder that holds docker-compose.yml:

  1) one time: make an admin (safe to repeat)
     docker compose exec -T user-service python -m app.scripts.create_admin tester-admin@microlinktest.com "AdminPass123!" "Test Admin"

  2) run the test
     docker compose exec -T delivery-service python - < scripts\\test_delivery.py

Every line says PASS or FAIL. It creates fresh test users each run.
"""

import base64
import json
import sys
import threading
import time
import urllib.error
import urllib.request

USER = "http://user-service:8000"
DELIVERY = "http://delivery-service:8000"
ADMIN_EMAIL = "tester-admin@microlinktest.com"
ADMIN_PASSWORD = "AdminPass123!"
PASSWORD = "TestPass123!"
STAMP = int(time.time())

PICKUP = (6.9271, 79.8612)
DROP = (6.9350, 79.8500)
FAR_AWAY = (7.5000, 80.5000)

DOCS = {
    "vehicle_type": "bike",
    "phone": "0771234567",
    "id_document_url": "https://example.com/id.jpg",
    "license_photo_url": "https://example.com/licence.jpg",
    "police_report_url": "https://example.com/police.pdf",
}

passed = 0
failed = 0


def parse(raw):
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return raw


def call(method, url, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, parse(response.read().decode())
    except urllib.error.HTTPError as error:
        return error.code, parse(error.read().decode())
    except Exception as error:  # connection problems
        return 0, str(error)


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("  PASS: " + name)
    else:
        failed += 1
        print("  FAIL: " + name + ((" -- " + str(detail)[:300]) if detail else ""))
    return ok


def section(title):
    print("")
    print("=== " + title + " ===")


def stop(message):
    print("")
    print("STOPPED: " + message)
    print("Result so far: %d passed, %d failed" % (passed, failed))
    sys.exit(1)


# A tiny valid PNG, used as the placeholder for every document a delivery
# agent has to supply. Inline so this script still needs nothing but the
# standard library (it runs inside the delivery-service container).
PLACEHOLDER_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAPAAAACgCAIAAAC9uXYyAAABRElEQVR42u3SQREAMAjAsDFBSEIaWlHBh0sk9BpZ"
    "/eCKLwGGBkODocHQGBoMDYYGQ4OhMTQYGgwNhgZDY2gwNBgaDA2GxtBgaDA0GBoMjaHB0GBoMDQYGkODocHQYGgwNIYG"
    "Q4OhwdAYGgwNhgZDg6ExNBgaDA2GBkNjaDA0GBoMDYbG0GBoMDQYGgyNocHQYGgwNBgaQ4OhwdBgaDA0hgZDg6HB0GBo"
    "DA2GBkODoTE0GBoMDYYGQ2NoMDQYGgwNhsbQYGgwNBgaDI2hwdBgaDA0GBpDg6HB0GBoMDSGBkODocHQYGgMDYYGQ4Oh"
    "MTQYGgwNhgZDY2gwNBgaDA2GxtBgaDA0GBoMjaHB0GBoMDQYGkODocHQYGgwNIYGQ4OhwdBgaAwNhgZDg6HB0BgaDA2G"
    "BkNjaDA0GBoMDYbG0GBoMDTsGCF0Amq+qgrFAAAAAElFTkSuQmCC"
)

# Mirrors REQUIRED_DOCUMENTS in user-service: item 16 means a delivery agent
# can no longer be created through /auth/register at all, so every one of
# these must travel in the same request as the account.
AGENT_DOCUMENT_TYPES = (
    "national_id",
    "driving_licence",
    "police_clearance",
    "vehicle_registration",
    "profile_photo",
)


def multipart(fields, files):
    """Encode a multipart/form-data body with the standard library only."""
    boundary = "----MicroLinkDeliveryTest%d" % STAMP
    crlf = "\r\n"
    parts = []
    for name, value in fields:
        parts.append(
            (
                "--%s%s" % (boundary, crlf)
                + 'Content-Disposition: form-data; name="%s"%s%s' % (name, crlf, crlf)
                + "%s%s" % (value, crlf)
            ).encode()
        )
    for name, filename, payload in files:
        parts.append(
            (
                "--%s%s" % (boundary, crlf)
                + 'Content-Disposition: form-data; name="%s"; filename="%s"%s'
                % (name, filename, crlf)
                + "Content-Type: image/png%s%s" % (crlf, crlf)
            ).encode()
            + payload
            + crlf.encode()
        )
    parts.append(("--%s--%s" % (boundary, crlf)).encode())
    return "multipart/form-data; boundary=" + boundary, b"".join(parts)


def apply_with_documents(email, role, label, doc_types):
    """POST /auth/register-application with a placeholder per document."""
    document = base64.b64decode(PLACEHOLDER_PNG_B64)
    fields = [
        ("email", email),
        ("password", PASSWORD),
        ("full_name", "Test " + label),
        ("role", role),
        ("phone", "0771234567"),
    ]
    files = []
    for doc_type in doc_types:
        fields.append(("doc_types", doc_type))
        files.append(("files", doc_type + ".png", document))

    content_type, body = multipart(fields, files)
    request = urllib.request.Request(
        USER + "/auth/register-application",
        data=body,
        headers={"Content-Type": content_type},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, parse(response.read().decode())
    except urllib.error.HTTPError as error:
        return error.code, parse(error.read().decode())
    except Exception as error:
        return 0, str(error)


def register(role, label):
    """Create an account, the way that role is allowed to (item 16).

    A customer self-registers. A delivery agent has to apply with its
    documents, because /auth/register refuses the role outright -- it used
    to hand out accounts that could never be approved or used.
    """
    email = "%s_%d@microlinktest.com" % (label, STAMP)
    if role == "delivery_agent":
        code, data = apply_with_documents(email, role, label, AGENT_DOCUMENT_TYPES)
    else:
        code, data = call(
            "POST",
            USER + "/auth/register",
            body={
                "email": email,
                "password": PASSWORD,
                "full_name": "Test " + label,
                "role": role,
            },
        )
    if not check("register " + label, code == 201, data):
        stop("could not register " + label + ". Is user-service running?")
    return {"email": email, "id": data["user"]["id"], "token": data["access_token"]}


def login(email, password):
    code, data = call("POST", USER + "/auth/login", body={"email": email, "password": password})
    return data["access_token"] if code == 200 else None


def new_order(token, note=None, fee=150):
    body = {
        "shop_id": "00000000-0000-0000-0000-000000000001",
        "pickup_address": "Test Shop, Colombo",
        "pickup_lat": PICKUP[0],
        "pickup_lng": PICKUP[1],
        "delivery_address": "12 Test Road, Colombo",
        "delivery_lat": DROP[0],
        "delivery_lng": DROP[1],
        "total_amount": fee,
    }
    if note is not None:
        body["item_description"] = note
    return call("POST", DELIVERY + "/delivery/orders", token, body)


def main():
    section("1. Services are running")
    code, data = call("GET", DELIVERY + "/health")
    if not check("delivery-service is up", code == 200, data):
        stop("delivery-service is not answering")
    code, data = call("GET", USER + "/docs")
    check("user-service is up", code == 200, data)

    section("2. Accounts")
    customer = register("user", "customer")
    stranger = register("user", "stranger")
    agent1 = register("delivery_agent", "agent1")
    agent2 = register("delivery_agent", "agent2")
    agent3 = register("delivery_agent", "unverified")

    admin_token = login(ADMIN_EMAIL, ADMIN_PASSWORD)
    if not check("admin can log in", admin_token is not None):
        stop(
            "no admin account yet. Run this once, then run the test again:\n"
            '  docker compose exec -T user-service python -m app.scripts.create_admin '
            + ADMIN_EMAIL + ' "' + ADMIN_PASSWORD + '" "Test Admin"'
        )

    section("3. Agent registration and admin review (SRS REQ-AGENT-1, Verify Delivery Agent Identity)")
    code, data = call("POST", DELIVERY + "/delivery/agents/profile", agent1["token"], {"vehicle_type": "bike"})
    check("agent saves vehicle only -> application is incomplete", code == 200 and data.get("documents_complete") is False, data)
    code, data = call("POST", DELIVERY + "/delivery/agents/profile", agent1["token"], DOCS)
    check("agent submits phone and 3 documents -> complete", code == 200 and data.get("documents_complete") is True, data)
    code, data = call("POST", DELIVERY + "/delivery/agents/profile", agent1["token"], dict(DOCS, id_document_url="not-a-link"))
    check("a document that is not a link is refused", code == 422, data)

    code, data = call("GET", DELIVERY + "/delivery/agents", admin_token)
    ids = [p["user_id"] for p in data] if code == 200 and isinstance(data, list) else []
    check("admin sees the application in the agent list", agent1["id"] in ids, data)
    code, data = call("GET", DELIVERY + "/delivery/agents", customer["token"])
    check("a customer cannot list agents", code == 403, data)

    review = DELIVERY + "/delivery/agents/%s/review" % agent1["id"]
    code, data = call("PATCH", review, admin_token, {"decision": "rejected"})
    check("rejecting without a reason is refused", code == 422, data)
    code, data = call("PATCH", review, admin_token, {"decision": "rejected", "reason": "ID photo is blurry"})
    check("admin rejects with a reason", code == 200 and data.get("application_status") == "rejected", data)
    code, data = call("GET", DELIVERY + "/delivery/agents/me", agent1["token"])
    check("agent can read the rejection reason", code == 200 and data.get("review_note") == "ID photo is blurry", data)
    code, data = call("POST", DELIVERY + "/delivery/agents/profile", agent1["token"], DOCS)
    check("sending details again puts the application back to pending", code == 200 and data.get("application_status") == "pending", data)
    code, data = call("PATCH", review, admin_token, {"decision": "approved"})
    check("admin approves", code == 200 and data.get("application_status") == "approved", data)

    section("4. Verified agents only (REQ-AUTH-4)")
    code, data = call("GET", DELIVERY + "/delivery/orders/available", agent3["token"])
    check("an unverified agent cannot see available orders", code == 403, data)
    for agent in (agent1, agent2):
        code, data = call("PATCH", USER + "/users/%s/verify" % agent["id"], admin_token)
        check("admin verifies " + agent["email"].split("_")[0], code == 200, data)
        agent["token"] = login(agent["email"], PASSWORD)
        code, data = call("POST", DELIVERY + "/delivery/agents/profile", agent["token"], DOCS)
        check("profile saved", code == 200, data)
        code, data = call("PATCH", DELIVERY + "/delivery/agents/me/location", agent["token"], {"lat": PICKUP[0], "lng": PICKUP[1]})
        check("location shared", code == 200, data)
        code, data = call("PATCH", DELIVERY + "/delivery/agents/me/availability", agent["token"], {"is_available": True})
        check("agent goes online", code == 200 and data.get("is_available") is True, data)

    section("5. Delivery request (REQ-DELIV-1 to 4: no cart, no payment)")
    code, data = new_order(customer["token"], note="x" * 201)
    check("a note over 200 characters is refused", code == 422, data)
    code, data = new_order(customer["token"], fee=-5)
    check("a negative fee is refused", code == 422, data)
    code, data = new_order(customer["token"], note="2 bags of rice", fee=0)
    check("request with fee 0 and a note is accepted", code == 201 and data.get("status") == "pending", data)
    order_a = data["id"] if code == 201 else stop("could not create order A")
    code, data = new_order(agent1["token"])
    check("an agent cannot create a request", code == 403, data)

    section("6. Available orders (REQ-AGENT-2) - offline agents see nothing")
    code, data = call("GET", DELIVERY + "/delivery/orders/available", agent1["token"])
    check("online agent sees the new order", code == 200 and any(o["id"] == order_a for o in data), data)
    mine = [o for o in data if o["id"] == order_a] if code == 200 else []
    check("order shows distance and trip distance", bool(mine) and mine[0].get("distance_km") is not None and mine[0].get("trip_distance_km") is not None, mine)
    call("PATCH", DELIVERY + "/delivery/agents/me/availability", agent2["token"], {"is_available": False})
    code, data = call("GET", DELIVERY + "/delivery/orders/available", agent2["token"])
    check("an agent who is offline sees no orders", code == 200 and data == [], data)
    call("PATCH", DELIVERY + "/delivery/agents/me/availability", agent2["token"], {"is_available": True})

    section("7. Two agents press Accept at the same time (race condition)")
    results = {}

    def press_accept(name, token):
        results[name] = call("PATCH", DELIVERY + "/delivery/orders/%s/accept" % order_a, token)

    threads = [
        threading.Thread(target=press_accept, args=("agent1", agent1["token"])),
        threading.Thread(target=press_accept, args=("agent2", agent2["token"])),
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    codes = sorted(result[0] for result in results.values())
    check("exactly one agent wins (200) and the other gets 409", codes == [200, 409], results)
    winner_name = "agent1" if results["agent1"][0] == 200 else "agent2"
    winner = agent1 if winner_name == "agent1" else agent2
    loser = agent2 if winner_name == "agent1" else agent1

    section("8. Reject and one active order (REQ-AGENT-3, Accept / Reject use case)")
    code, data = new_order(customer["token"])
    order_b = data["id"] if code == 201 else stop("could not create order B")
    code, data = call("POST", DELIVERY + "/delivery/orders/%s/reject" % order_b, loser["token"], {"reason": "declined"})
    check("agent rejects an order", code == 200, data)
    code, data = call("GET", DELIVERY + "/delivery/orders/available", loser["token"])
    check("the rejected order is hidden from that agent", code == 200 and all(o["id"] != order_b for o in data), data)
    code, data = call("PATCH", DELIVERY + "/delivery/orders/%s/accept" % order_b, winner["token"])
    check("an agent with an active order cannot accept a second one", code == 409, data)
    code, data = call("PATCH", DELIVERY + "/delivery/orders/%s/accept" % order_a, customer["token"])
    check("a customer cannot accept an order", code == 403, data)

    section("9. Status updates, geofence and ETA (Update Order Status, REQ-AGENT-4)")
    status_url = DELIVERY + "/delivery/orders/%s/status" % order_a
    code, data = call("PATCH", status_url, winner["token"], {"status": "delivered"})
    check("cannot skip steps (accepted -> delivered)", code == 400, data)
    code, data = call("PATCH", status_url, loser["token"], {"status": "picked_up"})
    check("an agent who was not assigned cannot update it", code == 403, data)
    code, data = call("PATCH", status_url, customer["token"], {"status": "picked_up"})
    check("a customer cannot update the status", code == 403, data)

    code, data = call("POST", DELIVERY + "/delivery/orders/%s/notify-customer" % order_a, winner["token"], {"lat": PICKUP[0], "lng": PICKUP[1]})
    check("Notify Customer returns an ETA message", code == 200 and "ETA" in str(data.get("message")), data)
    code, data = call("GET", DELIVERY + "/delivery/orders/%s" % order_a, customer["token"])
    check("customer sees the ETA on the order", code == 200 and data.get("agent_eta_minutes") is not None, data)

    # Handover codes: an agent cannot advance these two states alone. The app
    # gets the pickup code from the shop owner and the delivery code from the
    # customer; this script has no shop-service, so it reads both from the
    # admin view of the order, the one role that is shown both.
    code, data = call("GET", DELIVERY + "/delivery/orders/%s" % order_a, admin_token)
    pickup_code = data.get("pickup_code") if code == 200 else None
    delivery_code = data.get("delivery_code") if code == 200 else None
    check("admin can read both handover codes", bool(pickup_code and delivery_code), data)

    already_picked_up = False
    code, data = call("PATCH", status_url, winner["token"], {"status": "picked_up", "lat": FAR_AWAY[0], "lng": FAR_AWAY[1], "code": pickup_code})
    if code == 400:
        check("geofence blocks pickup far from the shop", True)
    elif code == 200:
        already_picked_up = True
        print("  SKIP: geofence is switched OFF (GEOFENCE_ENABLED=false), so the far-away pickup was allowed")
    else:
        check("geofence check gave an unexpected answer", False, data)
    if not already_picked_up:
        code, data = call("PATCH", status_url, winner["token"], {"status": "picked_up", "lat": PICKUP[0], "lng": PICKUP[1], "code": pickup_code})
        check("pickup accepted next to the shop", code == 200 and data.get("status") in ("picked_up", "in_transit"), data)
    code, data = call("PATCH", status_url, winner["token"], {"status": "delivered", "lat": DROP[0], "lng": DROP[1], "code": delivery_code})
    check("delivered accepted next to the customer", code == 200 and data.get("status") == "delivered", data)
    code, data = call("GET", DELIVERY + "/delivery/orders/%s" % order_a, customer["token"])
    events = [event["status"] for event in data.get("events", [])] if code == 200 else []
    check(
        "history has every step",
        events == ["pending", "accepted", "picked_up", "in_transit", "delivered"]
        or events == ["pending", "accepted", "picked_up", "delivered"],
        events,
    )

    section("10. Performance and rating (REQ-AGENT-5)")
    perf_url = DELIVERY + "/delivery/agents/%s/performance" % winner["id"]
    code, data = call("GET", perf_url, winner["token"])
    check(
        "performance shows deliveries, on-time % and score",
        code == 200 and data.get("total_deliveries") == 1 and data.get("on_time_percentage") == 100.0 and data.get("performance_score") is not None,
        data,
    )
    rate_url = DELIVERY + "/delivery/orders/%s/rate" % order_a
    code, data = call("POST", rate_url, customer["token"], {"rating": 6})
    check("a rating of 6 is refused", code == 422, data)
    code, data = call("POST", rate_url, stranger["token"], {"rating": 5})
    check("another customer cannot rate it", code == 403, data)
    code, data = call("POST", rate_url, customer["token"], {"rating": 5, "comment": "fast and polite"})
    check("customer rates the delivery", code == 200 and data.get("rating") == 5, data)
    code, data = call("POST", rate_url, customer["token"], {"rating": 4})
    check("the same order cannot be rated twice", code == 409, data)
    code, data = call("GET", perf_url, winner["token"])
    check("the rating reaches the agent's average", code == 200 and data.get("rating_count") == 1 and data.get("rating_avg") == 5.0, data)
    code, data = call("GET", perf_url, customer["token"])
    check("the customer of that agent can read the rating", code == 200, data)
    code, data = call("GET", perf_url, stranger["token"])
    check("a stranger cannot read it", code == 403, data)

    section("11. Safety and clean-up")
    code, data = call("GET", DELIVERY + "/delivery/orders/not-a-real-id", customer["token"])
    check("a bad order id gives 404 (it used to crash with 500)", code == 404, data)
    code, data = call("GET", DELIVERY + "/delivery/orders/%s" % order_a, stranger["token"])
    check("a stranger cannot open someone else's order", code == 403, data)
    code, data = call("PATCH", DELIVERY + "/delivery/orders/%s/cancel" % order_a, customer["token"])
    check("a delivered order cannot be cancelled", code == 400, data)
    code, data = call("PATCH", DELIVERY + "/delivery/orders/%s/cancel" % order_b, customer["token"])
    check("customer cancels a pending request", code == 200 and data.get("status") == "cancelled", data)
    code, data = call("GET", DELIVERY + "/delivery/orders?limit=5", admin_token)
    check("admin can list all delivery requests", code == 200 and isinstance(data, list), data)
    code, data = call("GET", DELIVERY + "/delivery/orders", customer["token"])
    check("a customer cannot list all requests", code == 403, data)

    print("")
    print("RESULT: %d passed, %d failed" % (passed, failed))
    if failed:
        print("Send me the FAIL lines above and I will fix them.")
    else:
        print("Everything in the delivery part works.")
    sys.exit(1 if failed else 0)


main()
