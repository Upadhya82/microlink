"""Predefined product categories and the "Others" review (app/product_categories.py).

    cd services/shop-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_product_categories.py -q
"""

import unittest

from app.product_categories import (
    DEFAULT_CATEGORIES,
    match_category,
    name_key,
    other_categories,
    slugify,
)

KNOWN = [("grocery", "Grocery"), ("first-aid", "First aid"), ("men", "Men's clothing")]


class NameTests(unittest.TestCase):
    def test_name_key_ignores_case_spacing_and_punctuation(self):
        self.assertEqual(name_key("  Pet  Food! "), "pet food")
        self.assertEqual(name_key("First-Aid"), "first aid")

    def test_slugify(self):
        self.assertEqual(slugify("Pet Food & Toys"), "pet-food-toys")
        self.assertEqual(slugify("!!!"), "")


class MatchTests(unittest.TestCase):
    def test_a_slug_or_label_matches_however_it_is_written(self):
        self.assertEqual(match_category("grocery", KNOWN), "grocery")
        self.assertEqual(match_category("First Aid", KNOWN), "first-aid")
        self.assertEqual(match_category("first-aid", KNOWN), "first-aid")
        self.assertEqual(match_category("men's clothing", KNOWN), "men")

    def test_anything_else_is_an_others_category(self):
        self.assertIsNone(match_category("Pet food", KNOWN))
        self.assertIsNone(match_category("", KNOWN))

    def test_the_defaults_cover_every_seeded_category(self):
        seeded = ["accessory", "bakery", "books", "building", "dessert", "drink", "electronics",
                  "first-aid", "general", "grocery", "hardware", "household", "hygiene",
                  "lighting", "main", "medicine", "men", "office", "paint", "paper", "pharmacy",
                  "plumbing", "restaurant", "school", "stationery", "supplement", "tools",
                  "women", "writing"]
        for slug in seeded:
            self.assertEqual(match_category(slug, DEFAULT_CATEGORIES), slug)

    def test_default_slugs_are_unique(self):
        slugs = [slug for slug, _ in DEFAULT_CATEGORIES]
        self.assertEqual(len(slugs), len(set(slugs)))


class OtherCategoriesTests(unittest.TestCase):
    PRODUCTS = [
        ("grocery", "s1", "Rice 5kg"),
        ("Pet food", "s1", "Dog biscuits"),
        ("pet  food", "s2", "Cat food tin"),
        ("Pet food", "s2", "Fish flakes"),
        ("Gift wrap", "s3", "Gift paper"),
        ("", "s3", "No category"),
    ]

    def test_only_unlisted_categories_are_suggested_most_used_first(self):
        result = other_categories(self.PRODUCTS, KNOWN, dismissed=[])
        self.assertEqual([item["name"] for item in result], ["Pet food", "Gift wrap"])
        pet = result[0]
        self.assertEqual(pet["product_count"], 3)
        self.assertEqual(pet["shop_count"], 2)
        self.assertEqual(pet["example_products"], ["Dog biscuits", "Cat food tin", "Fish flakes"])

    def test_a_dismissed_name_is_left_out(self):
        result = other_categories(self.PRODUCTS, KNOWN, dismissed=["PET FOOD"])
        self.assertEqual([item["name"] for item in result], ["Gift wrap"])

    def test_once_added_it_is_no_longer_suggested(self):
        known = KNOWN + [("pet-food", "Pet food")]
        result = other_categories(self.PRODUCTS, known, dismissed=[])
        self.assertEqual([item["name"] for item in result], ["Gift wrap"])


if __name__ == "__main__":
    unittest.main()
