"""Predefined product categories, and the "Others" an admin can promote.

A product still stores its category as plain text, exactly as before: a
predefined category's slug ("grocery", "first-aid"), or -- when the owner
picked "Others" -- whatever they typed. Nothing about existing products
changes until an admin accepts an "Others" category, which turns it into a
predefined one and moves the products that used it onto the new slug.

The matching rules are plain functions so tests/test_product_categories.py
can check them without a database.
"""

from __future__ import annotations

import re
from typing import Iterable

# (slug, label). Covers every category the seed data and the shops already
# use, plus the everyday ones a micro business is likely to need.
DEFAULT_CATEGORIES: tuple[tuple[str, str], ...] = (
    ("grocery", "Grocery"),
    ("vegetables", "Vegetables"),
    ("fruits", "Fruits"),
    ("dairy", "Dairy & eggs"),
    ("meat-fish", "Meat & fish"),
    ("bakery", "Bakery"),
    ("snacks", "Snacks"),
    ("drink", "Drinks"),
    ("dessert", "Desserts"),
    ("main", "Main dishes"),
    ("restaurant", "Restaurant meals"),
    ("household", "Household"),
    ("hygiene", "Personal care & hygiene"),
    ("baby", "Baby care"),
    ("medicine", "Medicine"),
    ("pharmacy", "Pharmacy items"),
    ("first-aid", "First aid"),
    ("supplement", "Supplements"),
    ("stationery", "Stationery"),
    ("books", "Books"),
    ("school", "School supplies"),
    ("office", "Office supplies"),
    ("paper", "Paper products"),
    ("writing", "Writing supplies"),
    ("electronics", "Electronics"),
    ("mobile", "Mobile phones & accessories"),
    ("lighting", "Lighting"),
    ("hardware", "Hardware"),
    ("tools", "Tools"),
    ("paint", "Paint"),
    ("plumbing", "Plumbing"),
    ("building", "Building materials"),
    ("men", "Men's clothing"),
    ("women", "Women's clothing"),
    ("kids", "Kids' clothing"),
    ("accessory", "Accessories"),
    ("toys", "Toys"),
    ("general", "General"),
)


def name_key(text: str | None) -> str:
    """How two category names are compared: case, spacing and punctuation ignored."""
    return re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()


def slugify(text: str) -> str:
    """'Pet Food & Toys' -> 'pet-food-toys'."""
    return re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")[:60]


def match_category(text: str | None, categories: Iterable[tuple[str, str]]) -> str | None:
    """The slug of the predefined category `text` names, or None for an "Others" one.

    Matches the slug ("first-aid"), the label ("First aid") or either written
    differently ("First-Aid", "first aid").
    """
    key = name_key(text)
    if not key:
        return None
    for slug, label in categories:
        if key in (name_key(slug), name_key(label)):
            return slug
    return None


def other_categories(
    products: Iterable[tuple[str | None, str | None, str]],
    categories: Iterable[tuple[str, str]],
    dismissed: Iterable[str],
    examples_per_category: int = 3,
) -> list[dict]:
    """The "Others" categories waiting for an admin, most used first.

    `products` is (category, shop_id, product name) for every product.
    Names that differ only in case or spacing are grouped; the spelling used
    most often is the one shown.
    """
    known = list(categories)
    skipped = {name_key(name) for name in dismissed}
    groups: dict[str, dict] = {}
    for category, shop_id, product_name in products:
        key = name_key(category)
        if not key or key in skipped or match_category(category, known) is not None:
            continue
        group = groups.setdefault(
            key, {"key": key, "spellings": {}, "shops": set(), "products": 0, "examples": []}
        )
        spelling = (category or "").strip()
        group["spellings"][spelling] = group["spellings"].get(spelling, 0) + 1
        group["products"] += 1
        if shop_id:
            group["shops"].add(shop_id)
        if product_name and len(group["examples"]) < examples_per_category:
            group["examples"].append(product_name)

    result = []
    for group in groups.values():
        name = max(group["spellings"].items(), key=lambda item: (item[1], item[0]))[0]
        result.append(
            {
                "name": name,
                "key": group["key"],
                "product_count": group["products"],
                "shop_count": len(group["shops"]),
                "example_products": group["examples"],
            }
        )
    result.sort(key=lambda item: (-item["product_count"], item["name"].lower()))
    return result
