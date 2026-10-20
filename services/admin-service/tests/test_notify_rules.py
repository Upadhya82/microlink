import json
import unittest

from app.notify_rules import notifications_from_event


def envelope(event, data, source="shop-service"):
    return {"event": event, "source": source, "data": data}


class NotifyUsersEventTests(unittest.TestCase):
    def test_one_row_per_user(self):
        rows = notifications_from_event(
            envelope(
                "notify.users",
                {
                    "user_ids": ["u1", "u2"],
                    "title": "Order accepted",
                    "body": "An agent is on the way.",
                    "kind": "order",
                    "link": {"route": "order", "id": "o1"},
                },
            )
        )
        self.assertEqual(len(rows), 2)
        self.assertEqual([r["user_id"] for r in rows], ["u1", "u2"])
        self.assertEqual(rows[0]["title"], "Order accepted")
        self.assertEqual(rows[0]["kind"], "order")
        self.assertEqual(json.loads(rows[0]["link"]), {"route": "order", "id": "o1"})

    def test_duplicate_and_empty_user_ids_are_dropped(self):
        rows = notifications_from_event(
            envelope("notify.users", {"user_ids": ["u1", "u1", "", None, "u2"], "title": "Hi"})
        )
        self.assertEqual([r["user_id"] for r in rows], ["u1", "u2"])

    def test_no_users_means_no_rows(self):
        self.assertEqual(
            notifications_from_event(envelope("notify.users", {"user_ids": [], "title": "Hi"})), []
        )

    def test_missing_or_blank_title_produces_nothing(self):
        self.assertEqual(
            notifications_from_event(envelope("notify.users", {"user_ids": ["u1"]})), []
        )
        self.assertEqual(
            notifications_from_event(
                envelope("notify.users", {"user_ids": ["u1"], "title": "   "})
            ),
            [],
        )

    def test_unknown_kind_falls_back_to_general(self):
        rows = notifications_from_event(
            envelope("notify.users", {"user_ids": ["u1"], "title": "Hi", "kind": "nonsense"})
        )
        self.assertEqual(rows[0]["kind"], "general")

    def test_non_dict_link_becomes_empty_object(self):
        rows = notifications_from_event(
            envelope("notify.users", {"user_ids": ["u1"], "title": "Hi", "link": "shop/1"})
        )
        self.assertEqual(rows[0]["link"], "{}")

    def test_body_defaults_to_empty_string(self):
        rows = notifications_from_event(envelope("notify.users", {"user_ids": ["u1"], "title": "Hi"}))
        self.assertEqual(rows[0]["body"], "")

    def test_long_title_is_truncated_to_column_width(self):
        rows = notifications_from_event(
            envelope("notify.users", {"user_ids": ["u1"], "title": "x" * 500})
        )
        self.assertEqual(len(rows[0]["title"]), 200)


class UserVerifiedEventTests(unittest.TestCase):
    def test_verified_user_is_told_to_sign_in_again(self):
        rows = notifications_from_event(
            envelope("user.verified", {"user_id": "u9", "role": "shop_owner"}, "user-service")
        )
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["user_id"], "u9")
        self.assertEqual(rows[0]["kind"], "account")
        self.assertIn("sign in again", rows[0]["body"])

    def test_verified_without_a_user_id_produces_nothing(self):
        self.assertEqual(notifications_from_event(envelope("user.verified", {})), [])


class IgnoredEventTests(unittest.TestCase):
    def test_unrelated_events_produce_nothing(self):
        self.assertEqual(notifications_from_event(envelope("order.created", {"id": "o1"})), [])

    def test_malformed_envelopes_produce_nothing(self):
        self.assertEqual(notifications_from_event({}), [])
        self.assertEqual(notifications_from_event(None), [])
        self.assertEqual(notifications_from_event(envelope("notify.users", "not-a-dict")), [])
        self.assertEqual(
            notifications_from_event(envelope("notify.users", {"user_ids": "u1", "title": "Hi"})),
            [],
        )


class ShopCancellationThresholdTests(unittest.TestCase):
    """Item 8: a shop that keeps cancelling gets one alert per admin."""

    def _event(self, **overrides):
        data = {
            "shop_id": "shop-1",
            "owner_id": "owner-1",
            "count": 3,
            "window_days": 7,
            "admin_ids": ["admin-1", "admin-2"],
        }
        data.update(overrides)
        return envelope("shop.cancellation_threshold", data, source="delivery-service")

    def test_one_row_per_admin(self):
        rows = notifications_from_event(self._event())
        self.assertEqual([row["user_id"] for row in rows], ["admin-1", "admin-2"])

    def test_the_body_names_the_count_and_the_window(self):
        rows = notifications_from_event(self._event())
        self.assertIn("3 orders", rows[0]["body"])
        self.assertIn("7 days", rows[0]["body"])

    def test_the_link_points_at_the_shop(self):
        rows = notifications_from_event(self._event())
        self.assertEqual(json.loads(rows[0]["link"]), {"route": "shop", "id": "shop-1"})
        self.assertEqual(rows[0]["kind"], "report")

    def test_no_admins_means_no_rows(self):
        self.assertEqual(notifications_from_event(self._event(admin_ids=[])), [])

    def test_a_duplicate_admin_id_produces_one_row(self):
        rows = notifications_from_event(self._event(admin_ids=["admin-1", "admin-1"]))
        self.assertEqual(len(rows), 1)

    def test_an_event_without_a_shop_is_ignored(self):
        self.assertEqual(notifications_from_event(self._event(shop_id=None)), [])

    def test_rubbish_numbers_do_not_break_the_insert(self):
        rows = notifications_from_event(self._event(count="three", window_days=None))
        self.assertEqual(len(rows), 2)
        self.assertIn("0 orders", rows[0]["body"])

    def test_other_events_still_produce_nothing(self):
        self.assertEqual(
            notifications_from_event(envelope("order.cancelled", {"order_id": "o1"})), []
        )


if __name__ == "__main__":
    unittest.main()
