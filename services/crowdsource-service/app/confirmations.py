"""When a reported shop has enough support to be worth an admin's time.

One person reporting a shop is a claim. Several nearby people agreeing is
evidence. The rule lives here, away from FastAPI and the database, so the
thresholds can be read and tested on their own.
"""

# Share of answers that must be positive before the report is escalated.
CONFIRM_THRESHOLD = 0.75

# Below this many answers the share means very little: one "yes" out of one
# is 100%, which is just the reporter agreeing with themselves.
MIN_RESPONSES = 4


def tally(confirmations) -> tuple[int, int, float]:
    """Return (total answers, positive answers, share positive).

    Share is 0.0 for no answers rather than undefined, so callers do not
    each have to guard against dividing by zero.
    """
    total = len(confirmations)
    positive = sum(1 for c in confirmations if c.confirms)
    return total, positive, (positive / total if total else 0.0)


def is_confirmed(total: int, positive: int) -> bool:
    """Whether the report has cleared both the share and the floor."""
    if total < MIN_RESPONSES:
        return False
    return (positive / total) >= CONFIRM_THRESHOLD


def just_crossed(total: int, positive: int, was_confirming: bool) -> bool:
    """True only on the answer that tips a report over the line.

    Without this the administrator would be notified again on every further
    answer, which is how a useful alert becomes one people ignore.
    """
    return is_confirmed(total, positive) and not was_confirming
