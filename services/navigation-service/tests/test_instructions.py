import unittest

from app.instructions import (
    format_distance,
    instruction_text,
    pick_route,
    roundabout_instruction,
    steps_from_legs,
)


class DistanceFormattingTests(unittest.TestCase):
    def test_short_distances_round_to_ten_metres(self):
        self.assertEqual(format_distance(37), "40 metres")
        self.assertEqual(format_distance(12), "10 metres")

    def test_medium_distances_round_to_fifty_metres(self):
        self.assertEqual(format_distance(237), "250 metres")

    def test_kilometres_past_a_thousand(self):
        self.assertEqual(format_distance(1500), "1.5 km")

    def test_whole_kilometres_drop_the_decimal(self):
        self.assertEqual(format_distance(2000), "2 km")

    def test_never_rounds_down_to_zero(self):
        self.assertEqual(format_distance(3), "10 metres")

    def test_sinhala_distance_uses_sinhala_units(self):
        self.assertIn("කිලෝමීටර්", format_distance(1500, "si"))


class InstructionTextTests(unittest.TestCase):
    def test_simple_turn_with_road_name(self):
        self.assertEqual(
            instruction_text("turn", "left", "Galle Road"),
            "Turn left onto Galle Road",
        )

    def test_distance_prefix_is_added_when_given(self):
        self.assertEqual(
            instruction_text("turn", "left", "Galle Road", 250),
            "In 250 metres, Turn left onto Galle Road",
        )

    def test_turn_without_distance_has_no_prefix(self):
        self.assertEqual(instruction_text("turn", "right", "Marine Drive"), "Turn right onto Marine Drive")

    def test_unnamed_road_is_not_announced(self):
        # "onto " with nothing after it is worse than no road at all.
        self.assertEqual(instruction_text("turn", "left", None), "Turn left")
        self.assertEqual(instruction_text("turn", "left", "   "), "Turn left")

    def test_depart_and_arrive(self):
        self.assertEqual(instruction_text("depart", None, "Galle Road"), "Head out")
        self.assertEqual(instruction_text("arrive", None, None), "You have arrived")
        self.assertEqual(
            instruction_text("arrive", None, "Peradeniya Road"),
            "You have arrived at Peradeniya Road",
        )

    def test_very_short_distance_is_not_announced(self):
        # Below 20m the instruction is immediate; a distance prefix is noise.
        self.assertEqual(instruction_text("turn", "left", "Ward Place", 5), "Turn left onto Ward Place")

    def test_sharp_and_slight_modifiers(self):
        self.assertEqual(instruction_text("turn", "sharp left", None), "Take a sharp left")
        self.assertEqual(instruction_text("turn", "slight right", None), "Bear right")

    def test_uturn(self):
        self.assertEqual(instruction_text("turn", "uturn", None), "Make a U-turn")

    def test_unknown_maneuver_falls_back_to_going_straight(self):
        self.assertEqual(instruction_text("something-new", None, None), "Continue straight")

    def test_sinhala_turn(self):
        self.assertEqual(instruction_text("turn", "left", None, language="si"), "වමට හැරෙන්න")

    def test_unknown_language_falls_back_to_english(self):
        self.assertEqual(instruction_text("turn", "left", None, language="de"), "Turn left")

    def test_roundabout_names_the_exit(self):
        self.assertEqual(
            roundabout_instruction(3, "Baseline Road"),
            "At the roundabout, take exit 3 onto Baseline Road",
        )


class PickRouteTests(unittest.TestCase):
    routes = [
        {"duration": 600, "distance": 5000, "id": "a"},
        {"duration": 900, "distance": 3000, "id": "b"},
    ]

    def test_fastest_picks_lowest_duration(self):
        self.assertEqual(pick_route(self.routes, "fastest")["id"], "a")

    def test_shortest_picks_lowest_distance(self):
        self.assertEqual(pick_route(self.routes, "shortest")["id"], "b")

    def test_default_is_fastest(self):
        self.assertEqual(pick_route(self.routes)["id"], "a")

    def test_empty_list_gives_none(self):
        self.assertIsNone(pick_route([]))

    def test_route_missing_the_key_sorts_last_instead_of_raising(self):
        routes = [{"id": "no-duration"}, {"duration": 100, "id": "ok"}]
        self.assertEqual(pick_route(routes, "fastest")["id"], "ok")


class StepsFromLegsTests(unittest.TestCase):
    def test_flattens_legs_into_steps(self):
        legs = [
            {
                "steps": [
                    {
                        "name": "Galle Road",
                        "distance": 250,
                        "maneuver": {
                            "type": "turn",
                            "modifier": "left",
                            "location": [79.8612, 6.9271],
                        },
                    },
                    {
                        "name": "",
                        "distance": 0,
                        "maneuver": {"type": "arrive", "location": [79.86, 6.92]},
                    },
                ]
            }
        ]
        steps = steps_from_legs(legs)
        self.assertEqual(len(steps), 2)
        self.assertEqual(steps[0]["instruction"], "In 250 metres, Turn left onto Galle Road")
        # OSRM gives [lng, lat]; the app needs lat/lng the right way round.
        self.assertAlmostEqual(steps[0]["location"]["lat"], 6.9271)
        self.assertAlmostEqual(steps[0]["location"]["lng"], 79.8612)
        self.assertEqual(steps[1]["instruction"], "You have arrived")

    def test_roundabout_step_uses_the_exit_number(self):
        legs = [
            {
                "steps": [
                    {
                        "name": "Baseline Road",
                        "distance": 100,
                        "maneuver": {
                            "type": "roundabout",
                            "exit": 2,
                            "location": [79.87, 6.93],
                        },
                    }
                ]
            }
        ]
        self.assertIn("exit 2", steps_from_legs(legs)[0]["instruction"])

    def test_malformed_steps_are_skipped_not_fatal(self):
        legs = [
            {"steps": [{"maneuver": {}}, "not-a-dict", {"maneuver": {"location": [1]}}]},
            "not-a-leg",
        ]
        self.assertEqual(steps_from_legs(legs), [])

    def test_no_legs_gives_no_steps(self):
        self.assertEqual(steps_from_legs([]), [])


if __name__ == "__main__":
    unittest.main()
