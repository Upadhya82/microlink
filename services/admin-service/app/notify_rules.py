"""Turns an event-bus envelope into the notification rows it should produce.

Deliberately pure: no database, no Redis, no FastAPI. The subscriber in
app/activity.py calls notifications_from_event() and inserts whatever comes
back, so the interesting logic here stays unit-testable without a running
stack (see tests/test_notify_rules.py).
"""

import json

# Mirrors event_bus.NOTIFICATION_KINDS; anything unrecognised falls back to
# "general" so a typo in a publishing service can't break the insert.
VALID_KINDS = (
    "order",
    "shop_alert",
    "review",
    "account",
    "report",
    "delivery_request",
    "general",
)

MAX_TITLE = 200


def _clean_kind(kind: object) -> str:
    return kind if isinstance(kind, str) and kind in VALID_KINDS else "general"


def _clean_link(link: object) -> str:
    """Store the link hint as compact JSON text; anything odd becomes "{}"."""
    if not isinstance(link, dict):
        return "{}"
    try:
        return json.dumps({str(k): v for k, v in link.items()})
    except (TypeError, ValueError):
        return "{}"


def _unique_user_ids(raw: object) -> list[str]:
    if not isinstance(raw, list):
        return []
    return sorted({u for u in raw if isinstance(u, str) and u})


def _row(user_id: str, title: str, body: str, kind: str, link: object) -> dict:
    return {
        "user_id": user_id,
        "title": title[:MAX_TITLE],
        "body": body,
        "kind": _clean_kind(kind),
        "link": _clean_link(link),
    }


# What a newly approved account can now do, by role. An unapproved owner or
# agent cannot sign in at all, so this is read on their first login after
# approval -- with a fresh token that already carries the verified claim.
_VERIFIED_BODY = {
    "shop_owner": (
        "An admin reviewed your documents and approved your shop owner account. "
        "You can now create your shop and add your products."
    ),
    "delivery_agent": (
        "An admin reviewed your documents and approved your delivery agent account. "
        "Go online to start receiving delivery requests."
    ),
    None: "An admin reviewed your documents and approved your account.",
}


def notifications_from_event(envelope: dict) -> list[dict]:
    """Return one dict per notification row this envelope should create.

    Handles three event types:

    * `notify.users` -- the generic channel every service publishes through
      event_bus.notify_users(). One row per unique user id.
    * `user.verified` -- user-service approving a shop owner or delivery
      agent. They could not sign in before, so the "Congratulations, you
      are verified" row is what greets them on their first login.
    * `shop.cancellation_threshold` -- a shop has cancelled too many orders
      in too few days (item 8). One row per admin, so somebody looks at it.

    Any other event (the vast majority) produces no notifications.
    """
    if not isinstance(envelope, dict):
        return []

    event = envelope.get("event")
    data = envelope.get("data")
    if not isinstance(data, dict):
        data = {}

    if event == "notify.users":
        title = data.get("title")
        if not isinstance(title, str) or not title.strip():
            return []
        body = data.get("body")
        body = body if isinstance(body, str) else ""
        return [
            _row(user_id, title.strip(), body, data.get("kind", "general"), data.get("link"))
            for user_id in _unique_user_ids(data.get("user_ids"))
        ]

    if event == "user.verified":
        user_id = data.get("user_id") or data.get("id")
        if not isinstance(user_id, str) or not user_id:
            return []
        return [
            _row(
                user_id,
                "Congratulations! You are verified",
                _VERIFIED_BODY.get(data.get("role"), _VERIFIED_BODY[None]),
                "account",
                # "verified" is what the app looks for after login, to greet
                # the user with this message the first time they sign in.
                {"route": "verified"},
            )
        ]

    if event == "shop.cancellation_threshold":
        shop_id = data.get("shop_id")
        if not isinstance(shop_id, str) or not shop_id:
            return []
        count = data.get("count")
        count = count if isinstance(count, int) and count > 0 else 0
        days = data.get("window_days")
        days = days if isinstance(days, int) and days > 0 else 0
        body = (
            f"A shop has cancelled {count} orders in the last {days} days. "
            "Check whether it is still able to fulfil orders."
        )
        return [
            _row(
                user_id,
                "A shop is cancelling too many orders",
                body,
                "report",
                {"route": "shop", "id": shop_id},
            )
            for user_id in _unique_user_ids(data.get("admin_ids"))
        ]

    return []


def superseded_by_event(envelope: dict) -> tuple[str, frozenset[str]] | None:
    """Which of a user's unread notifications an event makes out of date.

    Returns (user_id, link routes) for the rows to mark read, or None.

    * `user.verified` -- an applicant who was turned down, fixed it, and has
      now been approved should not open their notifications to find "Your
      application was not approved" still unread beside "Congratulations".
      The rejection notice links to the documents screen, which is how it is
      recognised.
    """
    if not isinstance(envelope, dict) or envelope.get("event") != "user.verified":
        return None
    data = envelope.get("data")
    if not isinstance(data, dict):
        return None
    user_id = data.get("user_id") or data.get("id")
    if not isinstance(user_id, str) or not user_id:
        return None
    return user_id, frozenset({"documents"})


def link_route(link_text: object) -> str | None:
    """The `route` of a stored link (JSON text), or None if it has none."""
    if not isinstance(link_text, str):
        return None
    try:
        value = json.loads(link_text)
    except (TypeError, ValueError):
        return None
    route = value.get("route") if isinstance(value, dict) else None
    return route if isinstance(route, str) else None
