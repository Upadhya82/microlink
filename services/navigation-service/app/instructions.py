"""Turn-by-turn instruction text, and route preference selection.

Pure functions: no HTTP, no database, no FastAPI, so `tests/test_instructions.py`
can cover every maneuver without a running stack or a call to OSRM.

Languages: English and Sinhala (REQ-NAV-3). Tamil was dropped from this build
on the team's instruction; adding it back means adding one dict below and the
locale already exists in app/locales.py.
"""

from typing import Any

# OSRM maneuver type -> phrase, per language. The modifier ("left", "sharp
# right", ...) is appended for the types where it carries the meaning.
_TURN_PHRASES: dict[str, dict[str, str]] = {
    "en": {
        "left": "Turn left",
        "right": "Turn right",
        "sharp left": "Take a sharp left",
        "sharp right": "Take a sharp right",
        "slight left": "Bear left",
        "slight right": "Bear right",
        "straight": "Continue straight",
        "uturn": "Make a U-turn",
    },
    "si": {
        "left": "වමට හැරෙන්න",
        "right": "දකුණට හැරෙන්න",
        "sharp left": "තියුණු ලෙස වමට හැරෙන්න",
        "sharp right": "තියුණු ලෙස දකුණට හැරෙන්න",
        "slight left": "සුළුවෙන් වමට හැරෙන්න",
        "slight right": "සුළුවෙන් දකුණට හැරෙන්න",
        "straight": "කෙළින්ම ඉදිරියට යන්න",
        "uturn": "හැරී ආපසු යන්න",
    },
}

_TEMPLATES: dict[str, dict[str, str]] = {
    "en": {
        "depart": "Head out",
        "arrive": "You have arrived",
        "arrive_at": "You have arrived at {road}",
        "roundabout": "At the roundabout, take exit {exit}",
        "roundabout_plain": "Go around the roundabout",
        "merge": "Merge",
        "fork": "Keep {modifier} at the fork",
        "on_ramp": "Take the ramp",
        "off_ramp": "Take the exit",
        "continue": "Continue",
        "onto": "{instruction} onto {road}",
        "in_distance": "In {distance}, {instruction}",
        "metres": "{value} metres",
        "kilometres": "{value} km",
    },
    "si": {
        "depart": "ගමන ආරම්භ කරන්න",
        "arrive": "ඔබ පැමිණ ඇත",
        "arrive_at": "ඔබ {road} වෙත පැමිණ ඇත",
        "roundabout": "වටරවුමේදී, {exit} වන පිටවීම ගන්න",
        "roundabout_plain": "වටරවුම වටා යන්න",
        "merge": "එක් වන්න",
        "fork": "දෙබෑවේදී {modifier} පැත්තට යන්න",
        "on_ramp": "ප්‍රවේශ මාර්ගයට යන්න",
        "off_ramp": "පිටවීම ගන්න",
        "continue": "ඉදිරියට යන්න",
        "onto": "{road} වෙත {instruction}",
        "in_distance": "{distance}කින්, {instruction}",
        "metres": "මීටර් {value}",
        "kilometres": "කිලෝමීටර් {value}",
    },
}

SUPPORTED_LANGUAGES = ("en", "si")


def _lang(language: str) -> str:
    """Fall back to English for anything we have no table for."""
    return language if language in SUPPORTED_LANGUAGES else "en"


def format_distance(metres: float, language: str = "en") -> str:
    """A spoken distance: metres rounded to something sayable, km past 1000."""
    code = _lang(language)
    t = _TEMPLATES[code]
    if metres >= 1000:
        value = round(metres / 1000, 1)
        # "2 km" reads better than "2.0 km".
        text = str(int(value)) if value == int(value) else str(value)
        return t["kilometres"].format(value=text)
    # Round to 10m below 100m and 50m above: nobody navigates by "237 metres".
    step = 10 if metres < 100 else 50
    rounded = max(step, int(round(metres / step)) * step)
    return t["metres"].format(value=rounded)


def instruction_text(
    maneuver_type: str,
    modifier: str | None,
    road: str | None,
    distance_before_m: float | None = None,
    language: str = "en",
) -> str:
    """One spoken sentence for an OSRM maneuver.

    `maneuver_type` and `modifier` come straight from OSRM's step.maneuver;
    `road` is the name of the street being turned onto, which is skipped when
    OSRM has no name for it rather than saying "onto ".
    """
    code = _lang(language)
    t = _TEMPLATES[code]
    turns = _TURN_PHRASES[code]
    maneuver_type = (maneuver_type or "").strip().lower()
    modifier = (modifier or "").strip().lower() or None
    road = (road or "").strip() or None

    if maneuver_type == "depart":
        base = t["depart"]
    elif maneuver_type == "arrive":
        return t["arrive_at"].format(road=road) if road else t["arrive"]
    elif maneuver_type in ("roundabout", "rotary"):
        base = t["roundabout_plain"]
    elif maneuver_type == "merge":
        base = t["merge"]
    elif maneuver_type == "fork":
        base = t["fork"].format(modifier=turns.get(modifier or "straight", ""))
    elif maneuver_type == "on ramp":
        base = t["on_ramp"]
    elif maneuver_type == "off ramp":
        base = t["off_ramp"]
    elif maneuver_type in ("turn", "end of road", "new name", "continue"):
        base = turns.get(modifier or "straight", t["continue"])
    else:
        base = turns.get(modifier or "straight", t["continue"])

    if road and maneuver_type not in ("depart",):
        base = t["onto"].format(instruction=base, road=road)

    if distance_before_m is not None and distance_before_m >= 20:
        base = t["in_distance"].format(
            distance=format_distance(distance_before_m, code),
            instruction=base,
        )
    return base


def roundabout_instruction(exit_number: int, road: str | None, language: str = "en") -> str:
    """Roundabouts read better with the exit number than with a modifier."""
    code = _lang(language)
    t = _TEMPLATES[code]
    base = t["roundabout"].format(exit=exit_number)
    if road:
        base = t["onto"].format(instruction=base, road=road)
    return base


def pick_route(routes: list[dict[str, Any]], preference: str = "fastest") -> dict | None:
    """Choose between OSRM's alternatives (REQ-NAV-2: user-selectable).

    "fastest" takes the shortest duration, "shortest" the shortest distance.
    OSRM already returns its alternatives best-first for duration, but the
    shortest route is frequently not first, which is the whole reason this
    choice is offered.
    """
    usable = [r for r in routes if isinstance(r, dict)]
    if not usable:
        return None
    key = "distance" if preference == "shortest" else "duration"
    # A route missing the key sorts last rather than raising.
    return min(usable, key=lambda r: r.get(key) if isinstance(r.get(key), (int, float)) else float("inf"))


def steps_from_legs(legs: list[dict[str, Any]], language: str = "en") -> list[dict[str, Any]]:
    """Flatten OSRM legs into the app's RouteStep shape.

    Each step carries the sentence to speak, how far before it the driver
    should hear it, and where it happens so the app can decide when to say it.
    """
    steps: list[dict[str, Any]] = []
    for leg in legs:
        if not isinstance(leg, dict):
            continue
        for step in leg.get("steps") or []:
            if not isinstance(step, dict):
                continue
            maneuver = step.get("maneuver") or {}
            location = maneuver.get("location") or []
            if len(location) < 2:
                continue
            maneuver_type = maneuver.get("type") or ""
            modifier = maneuver.get("modifier")
            road = step.get("name") or None
            distance = step.get("distance")
            distance_m = float(distance) if isinstance(distance, (int, float)) else 0.0

            if maneuver_type in ("roundabout", "rotary") and maneuver.get("exit"):
                text = roundabout_instruction(int(maneuver["exit"]), road, language)
            else:
                text = instruction_text(maneuver_type, modifier, road, distance_m, language)

            steps.append(
                {
                    "instruction": text,
                    "distance_m": distance_m,
                    # OSRM gives [lng, lat].
                    "location": {"lat": float(location[1]), "lng": float(location[0])},
                    "maneuver": maneuver_type,
                    "modifier": modifier,
                }
            )
    return steps
