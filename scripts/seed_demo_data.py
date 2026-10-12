#!/usr/bin/env python3
"""Seed realistic demo shops and products across Sri Lanka.

Every category gets at least three shops in different parts of the country,
so the map, category filters and landmark search all have something to show
wherever the grader happens to be standing.

Safe to re-run: shops are matched by name and skipped if they already exist,
so this will not pile up duplicates.

    python scripts/seed_demo_data.py                  # against localhost:8080
    python scripts/seed_demo_data.py --base http://host:8080/api
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

OWNER_EMAIL = "demo.owner@microlink.lk"
OWNER_PASSWORD = "Passw0rd1"
OWNER_NAME = "Demo Shop Owner"

# (name, category, address, lat, lng, open, close, phone, delivery)
SHOPS: list[tuple] = [
    # ---------------- grocery
    ("Kamal Super", "grocery", "42 Galle Road, Colombo 03", 6.9100, 79.8530, "07:00", "21:00", "0112345678", True),
    ("Kandy Fresh Market", "grocery", "Peradeniya Road, Kandy", 7.2930, 80.6350, "06:00", "19:00", "0812233445", True),
    ("Jaffna Grocers", "grocery", "Hospital Road, Jaffna", 9.6615, 80.0255, "07:00", "20:00", "0212221133", False),
    ("Galle Fort Provisions", "grocery", "Church Street, Galle Fort", 6.0270, 80.2170, "08:00", "20:00", "0912234567", True),
    # ---------------- restaurant
    ("Ceylon Spice Kitchen", "restaurant", "3 Galle Face, Colombo 01", 6.9270, 79.8430, "11:00", "23:00", "0114567890", True),
    ("Hill Country Rice & Curry", "restaurant", "Temple Street, Nuwara Eliya", 6.9700, 80.7829, "10:00", "22:00", "0522234455", False),
    ("Negombo Seafood Hut", "restaurant", "Lewis Place, Negombo", 7.2080, 79.8380, "11:00", "23:30", "0312233445", True),
    ("Batti Lagoon Cafe", "restaurant", "Bar Road, Batticaloa", 7.7170, 81.7000, "09:00", "21:00", "0652222334", False),
    # ---------------- pharmacy
    ("Nimal Pharmacy", "pharmacy", "8 Duplication Road, Colombo 04", 6.8950, 79.8570, "08:00", "22:00", "0112223344", True),
    ("Kandy City Pharmacy", "pharmacy", "Dalada Veediya, Kandy", 7.2955, 80.6360, "08:00", "21:00", "0812211334", True),
    ("Matara Medicare", "pharmacy", "Anagarika Dharmapala Mw, Matara", 5.9480, 80.5350, "08:00", "20:00", "0412233445", False),
    ("Anuradhapura Health Mart", "pharmacy", "Main Street, Anuradhapura", 8.3114, 80.4037, "07:30", "21:00", "0252222110", True),
    # ---------------- electronics
    ("TechPoint Electronics", "electronics", "88 Union Place, Colombo 02", 6.9230, 79.8620, "09:00", "19:00", "0117654321", True),
    ("Kurunegala Gadget House", "electronics", "Colombo Road, Kurunegala", 7.4860, 80.3640, "09:00", "19:00", "0372233445", False),
    ("Galle Digital Centre", "electronics", "Main Street, Galle", 6.0535, 80.2210, "09:30", "18:30", "0912244556", True),
    # ---------------- clothing
    ("Silk Route Clothing", "clothing", "14 Flower Road, Colombo 07", 6.9105, 79.8660, "10:00", "20:00", "0112244668", False),
    ("Kandy Textile House", "clothing", "Yatinuwara Veediya, Kandy", 7.2920, 80.6320, "09:00", "19:00", "0812255667", True),
    ("Jaffna Saree Palace", "clothing", "KKS Road, Jaffna", 9.6690, 80.0180, "09:00", "19:30", "0212233447", False),
    # ---------------- hardware
    ("Lanka Hardware", "hardware", "61 Baseline Road, Colombo 09", 6.9330, 79.8750, "08:00", "17:00", "0112299887", False),
    ("Ratnapura Tool Store", "hardware", "Main Street, Ratnapura", 6.6828, 80.4017, "08:00", "18:00", "0452233445", True),
    ("Trinco Builders Supply", "hardware", "Dockyard Road, Trincomalee", 8.5874, 81.2152, "08:00", "17:30", "0262222118", False),
    # ---------------- stationery
    ("BookNest Stationery", "stationery", "29 Ward Place, Colombo 07", 6.9160, 79.8700, "08:30", "18:30", "0112255779", True),
    ("Kandy Book Centre", "stationery", "Kotugodella Veediya, Kandy", 7.2940, 80.6380, "08:30", "18:00", "0812266778", False),
    ("Badulla School Supplies", "stationery", "Bazaar Street, Badulla", 6.9890, 81.0550, "08:00", "18:00", "0552233447", True),
    # ---------------- bakery
    ("Colombo Bakers", "bakery", "5 Marine Drive, Colombo 03", 6.9180, 79.8480, "06:00", "18:00", "0112277889", True),
    ("Kandy Hill Bakery", "bakery", "Peradeniya Road, Kandy", 7.2900, 80.6300, "06:00", "19:00", "0812277889", True),
    ("Matara Bake House", "bakery", "Beach Road, Matara", 5.9430, 80.5450, "06:30", "18:30", "0412244556", False),
    # ---------------- other
    ("Pettah General Store", "other", "Main Street, Pettah, Colombo 11", 6.9390, 79.8580, "08:00", "19:00", "0112288990", False),
    ("Dambulla Roadside Stall", "other", "Kandy Road, Dambulla", 7.8600, 80.6510, "07:00", "20:00", "0662233445", False),
    ("Ella Travellers Shop", "other", "Passara Road, Ella", 6.8667, 81.0466, "08:00", "21:00", "0572233445", True),
]

# Per-category product catalogue: (name, description, price, stock)
PRODUCTS: dict[str, list[tuple]] = {
    "grocery": [
        ("Rice 5kg (Nadu)", "Locally milled white nadu rice", 1250, 40),
        ("Red Lentils 1kg", "Imported masoor dhal", 420, 25),
        ("Coconut Oil 1L", "Cold pressed, unrefined", 980, 4),
        ("Milk Powder 400g", "Full cream", 1480, 0),
    ],
    "restaurant": [
        ("Rice & Curry (Chicken)", "Five vegetable curries with chicken", 650, 30),
        ("Kottu Roti", "Chicken kottu with cheese", 850, 20),
        ("Fresh Lime Juice", "No added sugar", 250, 50),
    ],
    "pharmacy": [
        ("Paracetamol 500mg (10)", "Fever and pain relief", 60, 100),
        ("Digital Thermometer", "Fast read, 10 seconds", 1200, 8),
        ("Antiseptic Liquid 250ml", "For cuts and grazes", 540, 3),
    ],
    "electronics": [
        ("USB-C Charger 25W", "Fast charge, 1 year warranty", 2400, 15),
        ("Bluetooth Earbuds", "6 hour battery, charging case", 4900, 6),
        ("Power Bank 10000mAh", "Dual output", 3800, 2),
    ],
    "clothing": [
        ("Cotton Sarong", "Handloom, assorted colours", 1500, 18),
        ("School Shirt (White)", "Poly-cotton, sizes 8-16", 1100, 24),
        ("Batik Shawl", "Hand-dyed", 2600, 5),
    ],
    "hardware": [
        ("Hammer 16oz", "Fibreglass handle", 1450, 12),
        ("Paint Brush Set (5)", "Synthetic bristle", 890, 20),
        ("LED Bulb 9W", "Warm white, E27", 320, 60),
    ],
    "stationery": [
        ("Exercise Book (80 pages)", "Ruled, pack of 5", 450, 80),
        ("Ballpoint Pens (10)", "Blue ink", 300, 45),
        ("Geometry Box", "Compass, ruler, protractor", 750, 10),
    ],
    "bakery": [
        ("Fish Bun", "Freshly baked, spicy", 90, 40),
        ("Seeni Sambol Bun", "Caramelised onion filling", 90, 35),
        ("Butter Cake (500g)", "Traditional recipe", 1200, 6),
    ],
    "other": [
        ("Bottled Water 1L", "Chilled", 120, 100),
        ("Phone Top-up Card", "Any network", 500, 50),
        ("Umbrella", "Compact, wind resistant", 1350, 9),
    ],
}


def request(method: str, url: str, token: str | None = None, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode()
            return response.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        try:
            return exc.code, json.loads(raw)
        except ValueError:
            return exc.code, raw
    except Exception as exc:  # network down, wrong port, ...
        return 0, str(exc)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://localhost:8080/api")
    args = parser.parse_args()
    base = args.base.rstrip("/")

    status, _ = request("GET", f"{base.replace('/api', '')}/health")
    if status != 200:
        print(f"Gateway not reachable at {base} -- is the stack up? (docker compose up -d)")
        return 1

    # The demo owner must exist and be verified before it can create shops.
    request(
        "POST",
        f"{base}/auth/register",
        body={
            "email": OWNER_EMAIL,
            "password": OWNER_PASSWORD,
            "full_name": OWNER_NAME,
            "role": "shop_owner",
        },
    )
    status, payload = request(
        "POST", f"{base}/auth/login", body={"email": OWNER_EMAIL, "password": OWNER_PASSWORD}
    )
    if status != 200:
        print("Could not log in as the demo owner. It likely needs admin verification:")
        print("  docker compose exec -T postgres psql -U microlink -d user_db \\")
        print(f"    -c \"UPDATE users SET is_verified=true WHERE email='{OWNER_EMAIL}';\"")
        print(f"  (server said: {payload})")
        return 1
    token = payload["access_token"]

    status, existing = request("GET", f"{base}/shops?limit=200")
    known = {s["name"] for s in existing} if status == 200 and isinstance(existing, list) else set()

    created_shops = 0
    created_products = 0
    for name, category, address, lat, lng, opens, closes, phone, delivery in SHOPS:
        if name in known:
            continue
        status, shop = request(
            "POST",
            f"{base}/shops",
            token,
            {
                "name": name,
                "description": f"{category.title()} in {address.split(',')[-1].strip()}",
                "category": category,
                "address": address,
                "latitude": lat,
                "longitude": lng,
                "phone": phone,
                "opening_time": opens,
                "closing_time": closes,
                "delivery_available": delivery,
            },
        )
        if status != 201:
            print(f"  ! {name}: {status} {shop}")
            continue
        created_shops += 1
        for pname, pdesc, price, stock in PRODUCTS.get(category, []):
            pstatus, _ = request(
                "POST",
                f"{base}/shops/{shop['id']}/products",
                token,
                {
                    "name": pname,
                    "description": pdesc,
                    "price": price,
                    "stock_quantity": stock,
                    "category": category,
                },
            )
            if pstatus == 201:
                created_products += 1
        print(f"  + {name} ({category}) @ {address}")

    print()
    print(f"Created {created_shops} shops and {created_products} products.")
    print(f"Skipped {len(known & {s[0] for s in SHOPS})} that already existed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
