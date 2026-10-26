"""Who is told when a suggested shop is approved (app/nearby_people.py).

    cd services/crowdsource-service
    python -m pytest tests/test_nearby_people.py -q
"""

import unittest

from app.nearby_people import users_near

SHOP = (6.8402, 80.0105)  # Diyagama


class UsersNearTests(unittest.TestCase):
    def test_each_kind_of_known_place_counts(self):
        found = users_near(
            *SHOP,
            shops=[{"owner_id": "owner", "latitude": 6.8450, "longitude": 80.0150}],
            agents=[{"user_id": "agent", "current_lat": 6.8380, "current_lng": 80.0050}],
            orders=[{"customer_id": "cust", "delivery_lat": 6.8500, "delivery_lng": 80.0200}],
        )
        self.assertEqual(found, {"owner", "agent", "cust"})

    def test_people_far_away_are_not_told(self):
        found = users_near(
            *SHOP,
            shops=[{"owner_id": "kandy-owner", "latitude": 7.2906, "longitude": 80.6337}],
            agents=[{"user_id": "galle-agent", "current_lat": 6.0329, "current_lng": 80.2170}],
        )
        self.assertEqual(found, set())

    def test_a_customer_counts_by_their_newest_address_only(self):
        found = users_near(
            *SHOP,
            orders=[
                # newest first: they now live in Kandy
                {"customer_id": "moved", "delivery_lat": 7.2906, "delivery_lng": 80.6337},
                {"customer_id": "moved", "delivery_lat": 6.8410, "delivery_lng": 80.0110},
            ],
        )
        self.assertEqual(found, set())

    def test_missing_or_bad_locations_are_skipped(self):
        found = users_near(
            *SHOP,
            agents=[{"user_id": "agent", "current_lat": None, "current_lng": None}],
            orders=[{"customer_id": "cust", "delivery_lat": "x", "delivery_lng": 80.0}],
        )
        self.assertEqual(found, set())

    def test_other_known_places_count_too(self):
        found = users_near(
            *SHOP,
            points=[
                ("road-reporter", 6.8420, 80.0120),   # reported a pothole nearby
                ("kandy-user", 7.2906, 80.6337),
                (None, 6.8402, 80.0105),
            ],
        )
        self.assertEqual(found, {"road-reporter"})

    def test_the_radius_can_be_changed(self):
        shops = [{"owner_id": "owner", "latitude": 6.9271, "longitude": 79.8612}]  # ~19 km
        self.assertEqual(users_near(*SHOP, shops=shops), set())
        self.assertEqual(users_near(*SHOP, shops=shops, radius_km=25), {"owner"})


if __name__ == "__main__":
    unittest.main()
