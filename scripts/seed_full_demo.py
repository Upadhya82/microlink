#!/usr/bin/env python3
"""Fill every role's tabs with realistic demo data, through the real API.

After this, logging in as any of the accounts below shows something in every
tab instead of empty screens:

  Admin          shop / suggestion / applicant / correction queues, complaints,
                 road reports, ads, plans, analytics, activity log, users
  Customer       orders (delivered, on the way, waiting, cancelled), favourites,
                 recommendations, nearby shops, user suggestions with comments,
                 notifications
  Shop owner     shop, products (one running low), orders, alerts, reviews with
                 a reply, analytics, a pending ad
  Driver         finished deliveries with ratings, one delivery on the way,
                 requests waiting to be taken, performance

Everything goes through the API gateway exactly as the app does, so every rule
(stock, handover codes, geofence, notifications, trust scores) runs as normal.
No service code or database table is changed.

Before running:
  1. docker compose up --build          (the stack must be running)
  2. create the admin once:
     docker compose exec user-service python -m app.scripts.create_admin admin@microlink.lk "Admin1234" "Admin User"

Run (from the project folder):
  python scripts/seed_full_demo.py
  python scripts/seed_full_demo.py --base http://localhost:8081/api --admin-email admin@microlink.lk --admin-password Admin1234
  python scripts/seed_full_demo.py --lat 6.8213 --lng 79.9627     # put the demo area near you

Safe to re-run: accounts and shops are reused, and the orders, suggestions,
complaints and reports are only created the first time (when the first demo
customer has no orders yet). Pass --again to add another round of activity.

Every demo account's password is  Demo1234  (see DEMO_PASSWORD).
"""

from __future__ import annotations

import argparse
import base64
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Reuse the HTTP helpers and the placeholder document from the shop seed.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from seed_demo_data import PLACEHOLDER_PNG_B64, multipart_body, request  # noqa: E402

DEMO_PASSWORD = "Demo1234"

CUSTOMERS = [
    ("nimali.demo@microlink.lk", "Nimali Perera"),
    ("kasun.demo@microlink.lk", "Kasun Silva"),
    ("tharindu.demo@microlink.lk", "Tharindu Fernando"),
]
OWNERS = [
    ("sunil.demo@microlink.lk", "Sunil Jayasinghe", "Sunil Stores"),
    ("ayesha.demo@microlink.lk", "Ayesha Rahman", "City Care Pharmacy"),
]
DRIVERS = [
    ("ruwan.demo@microlink.lk", "Ruwan Kumara", "bike", "WP BCD-1234"),
    ("dilan.demo@microlink.lk", "Dilan Mendis", "scooter", "WP KX-5678"),
]
# Applied but not approved: these fill the admin's "Applicants" queue.
PENDING_OWNER = ("chamari.demo@microlink.lk", "Chamari Wickramasinghe", "Chamari Textiles")
PENDING_DRIVER = ("pradeep.demo@microlink.lk", "Pradeep Rajapaksha", "car", "WP CAB-4455")

OWNER_DOCS = ("national_id", "business_registration", "profile_photo")
DRIVER_DOCS = (
    "national_id",
    "driving_licence",
    "police_clearance",
    "vehicle_registration",
    "profile_photo",
)

# (key, owner index, name, category, (dlat, dlng) from the centre, address,
#  phone, verify?)  -- the last one stays unverified for the admin's queue.
SHOPS = [
    ("grocery", 0, "Sunil Stores", "grocery", (0.002, 0.001), "45 Temple Road", "0112456789", True),
    ("bakery", 0, "Sunil Bake House", "bakery", (-0.003, 0.004), "12 Station Road", "0112456790", True),
    ("pharmacy", 1, "City Care Pharmacy", "pharmacy", (0.004, -0.002), "88 Main Street", "0112987654", True),
    ("hardware", 1, "Rahman Hardware", "hardware", (-0.005, -0.004), "3 Lake Drive", "0112987655", False),
]

# Per shop: (name, description, price, stock, product category). The first
# grocery item starts at 6 so the orders below take it to "running low".
PRODUCTS = {
    "grocery": [
        ("Samba Rice 5kg", "Keeri samba, new harvest", 1450, 6, "Rice & Grains"),
        ("Dhal 1kg", "Red lentils", 420, 30, "Rice & Grains"),
        ("Coconut Oil 1L", "Cold pressed", 980, 20, "Oils"),
        ("Full Cream Milk Powder 400g", "Imported", 1480, 18, "Dairy"),
        ("Ceylon Tea 200g", "BOPF, Nuwara Eliya", 650, 25, "Beverages"),
        ("White Sugar 1kg", "Granulated", 320, 40, "Baking"),
    ],
    "bakery": [
        ("Fish Bun", "Spicy fish filling", 90, 40, "Buns"),
        ("Seeni Sambol Bun", "Caramelised onion", 90, 35, "Buns"),
        ("Butter Cake 500g", "Traditional recipe", 1200, 10, "Cakes"),
        ("Chicken Roll", "Spiced chicken and potato", 150, 30, "Short eats"),
        ("Sandwich Bread", "Large loaf, sliced", 260, 20, "Bread"),
    ],
    "pharmacy": [
        ("Paracetamol 500mg (10)", "Fever and pain relief", 60, 100, "Medicines"),
        ("Digital Thermometer", "10 second reading", 1200, 8, "Devices"),
        ("Vitamin C 500mg (30)", "Chewable", 920, 15, "Vitamins"),
        ("Face Masks (50)", "Three-ply", 850, 30, "Personal care"),
        ("Hand Sanitizer 250ml", "70% alcohol", 480, 25, "Personal care"),
    ],
    "hardware": [
        ("LED Bulb 9W", "Warm white, E27", 320, 60, "Electrical"),
        ("Hammer 16oz", "Fibreglass handle", 1450, 12, "Tools"),
        ("Measuring Tape 5m", "Steel blade", 680, 16, "Tools"),
        ("Padlock 40mm", "Brass, two keys", 540, 22, "Security"),
        ("Paint Brush Set (5)", "Synthetic", 890, 20, "Painting"),
    ],
}


class Seeder:
    def __init__(self, base: str, lat: float, lng: float):
        self.base = base.rstrip("/")
        self.lat = lat
        self.lng = lng
        self.ok = 0
        self.problems: list[str] = []

    # ------------------------------------------------------------ helpers
    def call(self, method, path, token=None, body=None, expect=(200, 201, 204)):
        status, data = request(method, f"{self.base}{path}", token, body)
        if status not in expect:
            self.problems.append(f"{method} {path} -> {status} {str(data)[:160]}")
            return None
        self.ok += 1
        return data if data is not None else {}

    def note(self, text):
        print(f"  + {text}")

    def login(self, email, password):
        status, data = request(
            "POST", f"{self.base}/auth/login", body={"email": email, "password": password}
        )
        if status == 200:
            return data["access_token"], data["user"]["id"]
        return None, None

    def customer(self, email, name):
        """Register (or reuse) a customer; returns (token, user id)."""
        status, data = request(
            "POST",
            f"{self.base}/auth/register",
            body={"email": email, "password": DEMO_PASSWORD, "full_name": name, "role": "user"},
        )
        if status == 201:
            return data["access_token"], data["user"]["id"]
        return self.login(email, DEMO_PASSWORD)

    def apply(self, email, name, role, business, docs):
        """Send a shop-owner / driver application with placeholder documents.
        A 409 means it already exists, which is fine."""
        document = base64.b64decode(PLACEHOLDER_PNG_B64)
        fields = [
            ("email", email),
            ("password", DEMO_PASSWORD),
            ("full_name", name),
            ("role", role),
            ("business_name", business),
        ]
        files = []
        for doc_type in docs:
            fields.append(("doc_types", doc_type))
            files.append(("files", f"{doc_type}.png", document))
        content_type, body = multipart_body(fields, files)
        req = urllib.request.Request(
            f"{self.base}/auth/register-application",
            data=body,
            headers={"Content-Type": content_type},
            method="POST",
        )
        try:
            urllib.request.urlopen(req, timeout=30).read()
            self.ok += 1
        except urllib.error.HTTPError as exc:
            if exc.code != 409:
                self.problems.append(f"apply {email} -> {exc.code} {exc.read()[:160]!r}")
        except Exception as exc:  # network
            self.problems.append(f"apply {email} -> {exc}")

    def user_id(self, admin, email):
        rows = self.call("GET", f"/users?q={urllib.parse.quote(email)}&limit=5", admin) or []
        for row in rows:
            if row.get("email", "").lower() == email.lower():
                return row["id"], row.get("is_verified", False)
        return None, False

    def approved_account(self, admin, email, name, role, business, docs):
        """Apply, have the admin approve, and log in with a fresh token."""
        self.apply(email, name, role, business, docs)
        uid, verified = self.user_id(admin, email)
        if uid and not verified:
            self.call("PATCH", f"/users/{uid}/verify", admin)
        return self.login(email, DEMO_PASSWORD)

    def at(self, offset):
        return round(self.lat + offset[0], 6), round(self.lng + offset[1], 6)


def run(args) -> int:
    s = Seeder(args.base, args.lat, args.lng)

    status, _ = request("GET", f"{s.base.replace('/api', '')}/health")
    if status != 200:
        print(f"The gateway is not answering at {s.base}. Start it first: docker compose up --build")
        return 1

    admin, _ = s.login(args.admin_email, args.admin_password)
    if not admin:
        print(f"Could not log in as the admin {args.admin_email}. Create it first:")
        print(
            "  docker compose exec user-service python -m app.scripts.create_admin "
            f'{args.admin_email} "{args.admin_password}" "Admin User"'
        )
        return 1

    # ----------------------------------------------------------- accounts
    print("1. Accounts")
    customers = []
    for email, name in CUSTOMERS:
        token, uid = s.customer(email, name)
        if token:
            customers.append({"email": email, "name": name, "token": token, "id": uid})
            s.note(f"customer {name} <{email}>")
    owners = []
    for email, name, business in OWNERS:
        token, uid = s.approved_account(admin, email, name, "shop_owner", business, OWNER_DOCS)
        if token:
            owners.append({"email": email, "name": name, "token": token, "id": uid})
            s.note(f"shop owner {name} <{email}> (approved)")
    drivers = []
    for email, name, vehicle, plate in DRIVERS:
        token, uid = s.approved_account(admin, email, name, "delivery_agent", name, DRIVER_DOCS)
        if token:
            drivers.append({"email": email, "name": name, "token": token, "id": uid})
            s.call(
                "POST",
                "/delivery/agents/profile",
                token,
                {"vehicle_type": vehicle, "license_plate": plate, "phone": "0771112233"},
            )
            s.note(f"driver {name} <{email}> (approved, {vehicle})")
    s.apply(PENDING_OWNER[0], PENDING_OWNER[1], "shop_owner", PENDING_OWNER[2], OWNER_DOCS)
    s.apply(PENDING_DRIVER[0], PENDING_DRIVER[1], "delivery_agent", PENDING_DRIVER[1], DRIVER_DOCS)
    s.note("2 applications left waiting for the admin (Applicants tab)")

    if len(customers) < 3 or len(owners) < 2 or len(drivers) < 2:
        print("\nSome demo accounts could not be created or logged in:")
        for p in s.problems:
            print("  !", p)
        return 1

    # -------------------------------------------------------------- shops
    print("2. Shops and products")
    shops: dict[str, dict] = {}
    for owner in owners:
        for row in s.call("GET", "/shops/owner/me", owner["token"]) or []:
            shops.setdefault(row["name"], row)
    for key, owner_ix, name, category, offset, address, phone, verify in SHOPS:
        owner = owners[owner_ix]
        shop = shops.get(name)
        if shop is None:
            lat, lng = s.at(offset)
            shop = s.call(
                "POST",
                "/shops",
                owner["token"],
                {
                    "name": name,
                    "description": f"Your neighbourhood {category} shop.",
                    "category": category,
                    "address": address,
                    "latitude": lat,
                    "longitude": lng,
                    "phone": phone,
                    "opening_time": "06:00",
                    "closing_time": "22:30",
                    "delivery_available": True,
                },
            )
            if not shop:
                continue
            for pname, pdesc, price, stock, pcat in PRODUCTS[key]:
                s.call(
                    "POST",
                    f"/shops/{shop['id']}/products",
                    owner["token"],
                    {
                        "name": pname,
                        "description": pdesc,
                        "price": price,
                        "stock_quantity": stock,
                        "category": pcat,
                    },
                )
            s.note(f"{name} ({category}) with {len(PRODUCTS[key])} products")
        shop["_key"] = key
        shop["_owner"] = owner
        shops[name] = shop
        if verify and not shop.get("is_verified"):
            s.call("PATCH", f"/shops/{shop['id']}/verify", admin, {"is_verified": True})
    by_key = {shop["_key"]: shop for shop in shops.values() if "_key" in shop}
    grocery, bakery, pharmacy = by_key.get("grocery"), by_key.get("bakery"), by_key.get("pharmacy")
    if not (grocery and bakery and pharmacy):
        print("\nThe demo shops could not be created:")
        for p in s.problems:
            print("  !", p)
        return 1

    def products(shop):
        return s.call("GET", f"/shops/{shop['id']}/products", shop["_owner"]["token"]) or []

    # --------------------------------------- was the activity done before?
    already = s.call("GET", "/delivery/orders/me", customers[0]["token"]) or []
    if already and not args.again:
        print("\nActivity was already seeded (the first demo customer has orders).")
        print("Run again with --again to add another round.")
        return summary(s)

    nimali, kasun, tharindu = customers
    ruwan, dilan = drivers
    sunil, ayesha = owners

    # -------------------------------------------- browsing and preferences
    print("3. Customers browse, favourite and review")
    prefs = {
        nimali["id"]: "grocery,bakery",
        kasun["id"]: "pharmacy,electronics",
        tharindu["id"]: "restaurant,bakery,grocery",
    }
    for c in customers:
        s.call("PUT", "/users/me/preferences", c["token"], {"preferred_categories": prefs[c["id"]]})
        for shop in (grocery, bakery, pharmacy):
            s.call("POST", "/recommendations/interactions", c["token"],
                   {"shop_id": shop["id"], "interaction_type": "view"})
    s.call("POST", f"/recommendations/{grocery['id']}/favorite", nimali["token"], expect=(204, 200, 409))
    s.call("POST", f"/recommendations/{bakery['id']}/favorite", nimali["token"], expect=(204, 200, 409))
    s.call("POST", f"/recommendations/{pharmacy['id']}/favorite", kasun["token"], expect=(204, 200, 409))
    s.call("POST", f"/recommendations/{bakery['id']}/favorite", tharindu["token"], expect=(204, 200, 409))
    reviews = [
        (nimali, grocery, 5, "Always fresh and the owner is very helpful."),
        (kasun, grocery, 4, "Good prices. A bit crowded in the evening."),
        (tharindu, bakery, 5, "Best fish buns in the area!"),
        (kasun, pharmacy, 4, "Quick service, had everything I needed."),
    ]
    for c, shop, rating, text in reviews:
        s.call("POST", f"/shops/{shop['id']}/rating", c["token"], {"rating": rating, "comment": text})
    rows = s.call("GET", f"/shops/{grocery['id']}/reviews", sunil["token"]) or []
    if rows:
        s.call("POST", f"/shops/{grocery['id']}/reviews/{rows[0]['id']}/reply", sunil["token"],
               {"reply": "Thank you! See you again soon."})
    s.note("preferences, views, 4 favourites, 4 reviews and an owner reply")

    # --------------------------------------------------------- deliveries
    print("4. Orders and deliveries")
    g_items, b_items, p_items = products(grocery), products(bakery), products(pharmacy)

    def item(rows, index, qty):
        p = rows[index % len(rows)]
        return {"product_id": p["id"], "name": p["name"], "quantity": qty, "price": p["price"]}

    def order(c, shop, items, offset, address, fee=250):
        lat, lng = s.at(offset)
        return s.call(
            "POST",
            "/delivery/orders",
            c["token"],
            {
                "shop_id": shop["id"],
                "items": items,
                "delivery_address": address,
                "delivery_lat": lat,
                "delivery_lng": lng,
                "total_amount": fee,
                "item_description": "Please call when you arrive",
            },
        )

    def codes(o, shop, c):
        pick = next((r.get("pickup_code") for r in
                     s.call("GET", f"/delivery/orders/shop/{shop['id']}", shop["_owner"]["token"]) or []
                     if r["id"] == o["id"]), None)
        drop = next((r.get("delivery_code") for r in
                     s.call("GET", "/delivery/orders/me", c["token"]) or [] if r["id"] == o["id"]), None)
        return pick, drop

    def deliver(driver, o, shop, c, finish=True):
        """Take the order through accept -> picked up -> (delivered)."""
        if not o:
            return False
        if s.call("PATCH", f"/delivery/orders/{o['id']}/accept", driver["token"]) is None:
            return False
        pick, drop = codes(o, shop, c)
        s.call("PATCH", "/delivery/agents/me/location", driver["token"],
               {"lat": shop["latitude"], "lng": shop["longitude"]})
        s.call("PATCH", f"/delivery/orders/{o['id']}/status", driver["token"],
               {"status": "picked_up", "code": pick, "lat": shop["latitude"], "lng": shop["longitude"]})
        if not finish:
            return True
        s.call("PATCH", "/delivery/agents/me/location", driver["token"],
               {"lat": o["delivery_lat"], "lng": o["delivery_lng"]})
        done = s.call("PATCH", f"/delivery/orders/{o['id']}/status", driver["token"],
                      {"status": "delivered", "code": drop,
                       "lat": o["delivery_lat"], "lng": o["delivery_lng"]})
        return done is not None

    for d in drivers:
        s.call("PATCH", "/delivery/agents/me/availability", d["token"], {"is_available": True})
        s.call("PATCH", "/delivery/agents/me/location", d["token"], {"lat": s.lat, "lng": s.lng})

    finished = [
        (nimali, grocery, [item(g_items, 0, 2), item(g_items, 4, 1)], (0.006, 0.003), "21 Flower Road", ruwan, 5,
         "Very polite and quick. Thank you!"),
        (kasun, pharmacy, [item(p_items, 0, 2), item(p_items, 2, 1)], (-0.004, 0.006), "7 Park Avenue", ruwan, 4,
         "Arrived on time."),
        (tharindu, bakery, [item(b_items, 0, 6), item(b_items, 3, 4)], (0.007, -0.005), "60 Hill Street", dilan, 5,
         "Buns were still warm!"),
    ]
    for c, shop, items, offset, address, driver, stars, text in finished:
        o = order(c, shop, items, offset, address)
        if deliver(driver, o, shop, c):
            s.call("POST", f"/delivery/orders/{o['id']}/rate", c["token"], {"rating": stars, "comment": text})
            s.call("POST", "/crowdsource/feedback", c["token"],
                   {"order_id": o["id"], "shop_id": shop["id"], "rating": stars, "comment": text})
    s.note("3 delivered orders, rated by the customers")

    # One on the way (Dilan), two waiting for a driver, one cancelled.
    o = order(nimali, bakery, [item(b_items, 2, 1), item(b_items, 1, 4)], (0.006, 0.003), "21 Flower Road")
    deliver(dilan, o, bakery, nimali, finish=False)
    order(kasun, grocery, [item(g_items, 0, 1), item(g_items, 1, 2)], (-0.004, 0.006), "7 Park Avenue", fee=300)
    order(tharindu, pharmacy, [item(p_items, 3, 1)], (0.007, -0.005), "60 Hill Street", fee=200)
    o = order(tharindu, grocery, [item(g_items, 2, 1)], (0.007, -0.005), "60 Hill Street")
    if o:
        s.call("PATCH", f"/delivery/orders/{o['id']}/cancel", tharindu["token"],
               {"reason": "Ordered by mistake"})
    s.note("1 order on the way, 2 waiting for a driver, 1 cancelled")

    # ----------------------------------------------------- owner extras
    print("5. Shop alerts and ads")
    s.call("POST", f"/shops/{grocery['id']}/alerts", sunil["token"],
           {"message": "10% off all rice this weekend!", "alert_type": "special_offer"})
    s.call("POST", f"/shops/{bakery['id']}/alerts", sunil["token"],
           {"message": "Fresh buns every day from 6.30 am.", "alert_type": "general"})
    s.call("POST", f"/shops/{pharmacy['id']}/alerts", ayesha["token"],
           {"message": "Open on Poya days from 8 am to 1 pm.", "alert_type": "general"})
    ad = s.call("POST", "/ads", sunil["token"],
                {"advertiser_name": "Sunil Stores", "title": "Weekend rice sale",
                 "subtitle": "10% off every bag of rice", "shop_id": grocery["id"]})
    if ad:
        s.call("PATCH", f"/ads/{ad['id']}/status", admin, {"status": "approved"})
    s.call("POST", "/ads", ayesha["token"],
           {"advertiser_name": "City Care Pharmacy", "title": "Free blood pressure check",
            "subtitle": "Every Saturday morning", "shop_id": pharmacy["id"]})
    s.note("3 alerts, 1 approved ad, 1 ad waiting for the admin")

    # ------------------------------------------------- community reports
    print("6. Shop suggestions, comments, road reports, corrections")

    def suggest(c, name, category, offset, address, description, phone=None, hours=("08:00", "20:00")):
        lat, lng = s.at(offset)
        return s.call("POST", "/crowdsource/shop-reports", c["token"], {
            "shop_name": name, "category": category, "address": address,
            "latitude": lat, "longitude": lng, "description": description,
            "phone": phone, "opening_time": hours[0], "closing_time": hours[1],
        })

    approved = suggest(nimali, "Amma's Kitchen", "restaurant", (0.003, -0.003), "14 Lotus Lane",
                       "Home-cooked rice and curry, lunch packets from 11 am.", phone="0779876543",
                       hours=("10:30", "21:00"))
    waiting_phone = suggest(kasun, "Lucky Phone Repairs", "electronics", (-0.002, 0.005), "Near the bus stand",
                            "Small shop that fixes phones and sells chargers.")
    waiting = suggest(tharindu, "Green Leaf Vegetables", "grocery", (0.005, 0.002), "Market Junction",
                      "Fresh vegetables straight from Nuwara Eliya every morning.", phone="0761234987",
                      hours=("05:30", "19:00"))
    if approved:
        s.call("POST", f"/crowdsource/shop-reports/{approved['id']}/confirm", kasun["token"],
               {"confirms": True, "comment": "Yes, it is there. The fish curry is great!"})
        s.call("POST", f"/crowdsource/shop-reports/{approved['id']}/confirm", tharindu["token"],
               {"confirms": True, "comment": "I eat lunch there every Friday."})
        first = s.call("POST", f"/crowdsource/shop-reports/{approved['id']}/comments", sunil["token"],
                       {"text": "Good to see a new place on our road."})
        if first:
            s.call("POST", f"/crowdsource/shop-reports/{approved['id']}/comments/{first['id']}/replies",
                   nimali["token"], {"text": "Thanks! Try the jackfruit curry too."})
        s.call("PATCH", f"/crowdsource/shop-reports/{approved['id']}/status", admin, {"status": "approved"})
    if waiting_phone:
        s.call("POST", f"/crowdsource/shop-reports/{waiting_phone['id']}/confirm", nimali["token"],
               {"confirms": True, "comment": "It's next to the bakery, small blue board."})
    if waiting:
        s.call("POST", f"/crowdsource/shop-reports/{waiting['id']}/confirm", nimali["token"],
               {"confirms": True, "comment": "Opens very early, good prices."})
        s.call("POST", f"/crowdsource/shop-reports/{waiting['id']}/confirm", kasun["token"],
               {"confirms": False, "comment": "I could not find it last week."})
    s.note("3 suggestions (1 approved with comments, 2 waiting -- one without a phone number)")

    for c, kind, sev, offset, text in [
        (kasun, "pothole", "high", (0.001, 0.002), "Large pothole near the junction, dangerous for bikes."),
        (tharindu, "flooding", "medium", (-0.002, -0.001), "Road floods after heavy rain."),
        (nimali, "construction", "low", (0.004, 0.004), "One lane closed for pipe work."),
    ]:
        lat, lng = s.at(offset)
        r = s.call("POST", "/crowdsource/road-reports", c["token"], {
            "latitude": lat, "longitude": lng, "condition_type": kind,
            "description": text, "severity": sev})
        if r and kind == "pothole":
            s.call("PATCH", f"/crowdsource/road-reports/{r['id']}/status", admin, {"status": "verified"})
    s.call("POST", "/crowdsource/shop-corrections", tharindu["token"], {
        "shop_id": bakery["id"], "shop_name": bakery["name"], "closing_time": "23:00",
        "note": "They stay open until 11 pm now."})
    s.call("POST", "/crowdsource/shop-corrections", kasun["token"], {
        "shop_id": pharmacy["id"], "shop_name": pharmacy["name"], "phone": "0112987600",
        "note": "The number on the board changed."})
    s.note("3 road reports (1 verified), 2 shop corrections waiting")

    # ------------------------------------------------------ admin extras
    print("7. Complaints and subscription plans")
    c1 = s.call("POST", "/admin/complaints", kasun["token"], {
        "subject": "Driver could not find my house",
        "description": "The driver called three times. Please ask drivers to use the map pin.",
        "category": "delivery"})
    s.call("POST", "/admin/complaints", tharindu["token"], {
        "subject": "Wrong price shown",
        "description": "The app showed Rs. 90 for a bun but the shop charged Rs. 100.",
        "category": "shop"})
    s.call("POST", "/admin/complaints", nimali["token"], {
        "subject": "App feedback",
        "description": "Please add a dark mode schedule option.",
        "category": "other"})
    if c1:
        s.call("PATCH", f"/admin/complaints/{c1['id']}", admin, {
            "status": "in_review", "admin_response": "Thank you. We are checking with the driver."})
    plans = s.call("GET", "/admin/subscription-plans", admin) or []
    if not plans:
        for name, price, desc, features in [
            ("Basic", 0, "Get listed on MicroLink", ["Shop listing", "Up to 20 products"]),
            ("Standard", 1500, "For growing shops", ["Unlimited products", "Shop alerts", "Sales analytics"]),
            ("Premium", 3500, "Be seen first", ["Everything in Standard", "Home screen ad every month",
                                                "Priority support"]),
        ]:
            s.call("POST", "/admin/subscription-plans", admin, {
                "name": name, "price_monthly": price, "description": desc, "features": features})
    s.note("3 complaints (1 in review), subscription plans")

    if args.with_nationwide:
        print("8. Nationwide demo shops (scripts/seed_demo_data.py)")
        nationwide(s, admin)

    return summary(s)


def nationwide(s: Seeder, admin: str) -> None:
    """Run the existing nationwide shop seed, approving its owner on the way."""
    from seed_demo_data import OWNER_EMAIL, apply_as_owner

    apply_as_owner(s.base)
    uid, verified = s.user_id(admin, OWNER_EMAIL)
    if uid and not verified:
        s.call("PATCH", f"/users/{uid}/verify", admin)
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seed_demo_data.py")
    subprocess.run([sys.executable, script, "--base", s.base], check=False)


def summary(s: Seeder) -> int:
    print()
    print(f"Done: {s.ok} requests succeeded, {len(s.problems)} problems.")
    for p in s.problems[:25]:
        print("  !", p)
    print()
    print(f"Every demo account's password is {DEMO_PASSWORD}")
    print("  customers : " + ", ".join(e for e, _ in CUSTOMERS))
    print("  owners    : " + ", ".join(e for e, _, _ in OWNERS))
    print("  drivers   : " + ", ".join(e for e, *_ in DRIVERS))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--base", default="http://localhost:8081/api")
    parser.add_argument("--admin-email", default="admin@microlink.lk")
    parser.add_argument("--admin-password", default="Admin1234")
    parser.add_argument("--lat", type=float, default=6.9271, help="centre of the demo area")
    parser.add_argument("--lng", type=float, default=79.8612, help="centre of the demo area")
    parser.add_argument("--again", action="store_true", help="add another round of activity")
    parser.add_argument("--with-nationwide", action="store_true",
                        help="also run seed_demo_data.py (27 shops across Sri Lanka)")
    start = time.time()
    code = run(parser.parse_args())
    print(f"({time.time() - start:.0f}s)")
    return code


if __name__ == "__main__":
    sys.exit(main())
