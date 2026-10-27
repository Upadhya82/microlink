"""The admin "User Insights" tab: counts by role, and district / province.

    cd services/admin-service
    python -m pytest tests/test_user_insights.py -q
"""

import unittest
from datetime import datetime, timedelta, timezone

from app.user_insights import (
    DISTRICTS,
    PROVINCES,
    build_insights,
    districts_by_province,
    locate,
    user_points,
)

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)


def _user(user_id, role, name="Someone", days_ago=30):
    return {
        "id": user_id,
        "full_name": name,
        "email": f"{user_id}@example.com",
        "role": role,
        "is_active": True,
        "is_verified": True,
        "created_at": (NOW - timedelta(days=days_ago)).isoformat(),
    }


class LocateTests(unittest.TestCase):
    def test_well_known_places_land_in_the_right_district(self):
        self.assertEqual(locate(6.9271, 79.8612), ("Colombo", "Western"))      # Colombo city
        self.assertEqual(locate(6.8441, 80.0020), ("Colombo", "Western"))      # Homagama
        self.assertEqual(locate(7.2906, 80.6337), ("Kandy", "Central"))        # Kandy town
        self.assertEqual(locate(6.0329, 80.2170), ("Galle", "Southern"))       # Galle fort
        self.assertEqual(locate(9.6615, 80.0255), ("Jaffna", "Northern"))      # Jaffna town
        self.assertEqual(locate(8.3114, 80.4037), ("Anuradhapura", "North Central"))
        self.assertEqual(locate(6.9934, 81.0550), ("Badulla", "Uva"))

    def test_a_point_outside_sri_lanka_is_not_known(self):
        self.assertEqual(locate(0.0, 0.0), (None, None))
        self.assertEqual(locate(51.5, -0.12), (None, None))

    def test_a_missing_point_is_not_known(self):
        self.assertEqual(locate(None, 80.0), (None, None))
        self.assertEqual(locate("not a number", 80.0), (None, None))

    def test_all_25_districts_and_9_provinces_are_listed(self):
        self.assertEqual(len(DISTRICTS), 25)
        self.assertEqual(len(PROVINCES), 9)
        grouped = districts_by_province()
        self.assertEqual(sum(len(v) for v in grouped.values()), 25)
        self.assertIn("Gampaha", grouped["Western"])


class UserPointsTests(unittest.TestCase):
    def test_each_role_is_placed_from_its_own_data(self):
        points = user_points(
            shops=[{"owner_id": "owner", "latitude": 7.29, "longitude": 80.63}],
            agents=[{"user_id": "agent", "current_lat": 6.03, "current_lng": 80.21}],
            orders=[{"customer_id": "cust", "delivery_lat": 9.66, "delivery_lng": 80.02}],
        )
        self.assertEqual(points["owner"][2], "shop")
        self.assertEqual(points["agent"][2], "live location")
        self.assertEqual(points["cust"][2], "last delivery address")

    def test_a_customer_is_placed_at_the_newest_order(self):
        points = user_points(
            shops=[],
            agents=[],
            orders=[
                {"customer_id": "cust", "delivery_lat": 7.29, "delivery_lng": 80.63},  # newest
                {"customer_id": "cust", "delivery_lat": 6.92, "delivery_lng": 79.86},
            ],
        )
        self.assertEqual(points["cust"][:2], (7.29, 80.63))

    def test_an_agent_without_a_live_location_is_left_out(self):
        points = user_points([], [{"user_id": "agent", "current_lat": None}], [])
        self.assertNotIn("agent", points)


class BuildInsightsTests(unittest.TestCase):
    def setUp(self):
        self.users = [
            # "user" is what user-service calls a plain shopper; this tab
            # reports them as "customer". Feeding it "customer" here, as this
            # test used to, tested a row user-service never sends.
            _user("c1", "user", "Kamal Perera", days_ago=2),
            _user("c2", "user", "Nimali Silva"),
            _user("o1", "shop_owner", "Sunil Stores"),
            _user("a1", "delivery_agent", "Ruwan Rider", days_ago=1),
            _user("admin", "admin", "The Admin"),
        ]
        self.points = {
            "c1": (6.9271, 79.8612, "last delivery address"),
            "o1": (7.2906, 80.6337, "shop"),
        }

    def test_totals_count_each_role_and_leave_admins_out(self):
        result = build_insights(self.users, self.points, now=NOW)
        self.assertEqual(
            result["totals"],
            {"customer": 2, "shop_owner": 1, "delivery_agent": 1, "total": 4},
        )
        self.assertNotIn("admin", [row["id"] for row in result["users"]])

    def test_new_this_week_counts_recent_sign_ups(self):
        result = build_insights(self.users, self.points, now=NOW)
        self.assertEqual(
            result["new_this_week"], {"customer": 1, "shop_owner": 0, "delivery_agent": 1}
        )

    def test_a_shoppers_role_is_reported_as_customer(self):
        """The row says "user"; the tab, and the app reading it, say
        "customer". Mixing the two up is what made this tab 502."""
        result = build_insights(self.users, self.points, now=NOW)
        kamal = next(r for r in result["users"] if r["id"] == "c1")
        self.assertEqual(kamal["role"], "customer")

    def test_an_unknown_role_is_not_counted(self):
        result = build_insights([_user("x", "wizard", "Nobody")], {}, now=NOW)
        self.assertEqual(result["totals"]["total"], 0)
        self.assertEqual(result["users"], [])

    def test_each_user_gets_a_district_or_none(self):
        rows = {row["id"]: row for row in build_insights(self.users, self.points, now=NOW)["users"]}
        self.assertEqual((rows["c1"]["district"], rows["c1"]["province"]), ("Colombo", "Western"))
        self.assertEqual((rows["o1"]["district"], rows["o1"]["province"]), ("Kandy", "Central"))
        self.assertIsNone(rows["c2"]["district"])
        self.assertIsNone(rows["c2"]["location_source"])

    def test_exact_coordinates_are_never_returned(self):
        row = build_insights(self.users, self.points, now=NOW)["users"][0]
        self.assertFalse({"latitude", "longitude", "lat", "lng"} & set(row))

    def test_newest_users_come_first(self):
        ids = [row["id"] for row in build_insights(self.users, self.points, now=NOW)["users"]]
        self.assertEqual(ids[0], "a1")

    def test_the_filter_lists_come_with_the_data(self):
        result = build_insights(self.users, self.points, now=NOW)
        self.assertEqual(result["provinces"][0], "Western")
        self.assertIn("Kandy", result["districts"]["Central"])
        self.assertEqual(result["located_users"], 2)


if __name__ == "__main__":
    unittest.main()
