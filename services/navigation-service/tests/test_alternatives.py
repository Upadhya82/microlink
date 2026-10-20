"""Item 2: the alternative routes OSRM offers are kept, not thrown away.

    cd services/navigation-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_alternatives.py -q
"""

import asyncio
import math
import unittest

from app import routing
from app.instructions import describe_alternative, pick_route


def _osrm_route(distance_m: float, duration_s: float, points: int = 3) -> dict:
    """An OSRM route with enough shape to be usable."""
    return {
        "distance": distance_m,
        "duration": duration_s,
        "geometry": {
            "coordinates": [[79.86 + i * 0.01, 6.92 + i * 0.01] for i in range(points)]
        },
        "legs": [
            {
                "steps": [
                    {
                        "maneuver": {
                            "type": "turn",
                            "modifier": "left",
                            "location": [79.86, 6.92],
                        },
                        "name": "Galle Road",
                        "distance": 300,
                    }
                ]
            }
        ],
    }


class DescribeAlternativeTests(unittest.TestCase):
    def test_a_shorter_route_is_described_by_distance(self):
        self.assertEqual(describe_alternative(10.0, 20.0, 7.5, 20.0), "2.5 km shorter")

    def test_a_slower_route_is_described_by_time(self):
        self.assertEqual(describe_alternative(10.0, 20.0, 10.0, 26.0), "6 min slower")

    def test_both_differences_are_mentioned(self):
        self.assertEqual(
            describe_alternative(10.0, 20.0, 8.0, 25.0),
            "2.0 km shorter, 5 min slower",
        )

    def test_a_longer_but_faster_route_says_so(self):
        self.assertEqual(
            describe_alternative(10.0, 30.0, 12.0, 24.0),
            "2.0 km longer, 6 min faster",
        )

    def test_a_near_identical_route_is_not_given_a_fake_difference(self):
        # "0 min slower" would be worse than saying nothing useful.
        self.assertEqual(describe_alternative(10.0, 20.0, 10.02, 20.4), "About the same")


class RoadRouteAlternativeTests(unittest.TestCase):
    """What road_route does with OSRM's answer, with OSRM stubbed out."""

    def setUp(self):
        self.original_client = routing.httpx.AsyncClient

    def tearDown(self):
        routing.httpx.AsyncClient = self.original_client

    def _stub_osrm(self, payload):
        import httpx

        class _Transport(httpx.AsyncBaseTransport):
            async def handle_async_request(self, request):
                return httpx.Response(200, json=payload)

        original = self.original_client

        def factory(*args, **kwargs):
            kwargs["transport"] = _Transport()
            return original(*args, **kwargs)

        routing.httpx.AsyncClient = factory

    def _route(self, preference="fastest"):
        points = [
            routing.Coordinate(lat=6.92, lng=79.86),
            routing.Coordinate(lat=6.95, lng=79.89),
        ]
        return asyncio.run(routing.road_route(points, "driving", preference, "en"))

    def test_the_other_routes_are_returned_alongside_the_chosen_one(self):
        self._stub_osrm(
            {
                "code": "Ok",
                "routes": [
                    _osrm_route(10_000, 1_200),
                    _osrm_route(8_000, 1_500),
                    _osrm_route(12_000, 1_100),
                ],
            }
        )
        result = self._route()
        self.assertIsNotNone(result)
        _polyline, distance_km, duration_minutes, _steps, alternatives = result
        # "fastest" picks the 1100 s route...
        self.assertAlmostEqual(duration_minutes, 1_100 / 60.0, places=3)
        self.assertAlmostEqual(distance_km, 12.0, places=3)
        # ... and the other two are offered rather than discarded.
        self.assertEqual(len(alternatives), 2)

    def test_each_alternative_carries_its_own_steps(self):
        self._stub_osrm(
            {"code": "Ok", "routes": [_osrm_route(10_000, 1_200), _osrm_route(8_000, 1_500)]}
        )
        _p, _d, _m, _s, alternatives = self._route()
        self.assertEqual(len(alternatives), 1)
        _alt_polyline, alt_distance, alt_duration, alt_steps = alternatives[0]
        self.assertAlmostEqual(alt_distance, 8.0, places=3)
        self.assertAlmostEqual(alt_duration, 1_500 / 60.0, places=3)
        self.assertEqual(len(alt_steps), 1)
        self.assertTrue(alt_steps[0]["instruction"])

    def test_the_chosen_route_is_not_repeated_as_an_alternative(self):
        self._stub_osrm({"code": "Ok", "routes": [_osrm_route(10_000, 1_200)]})
        _p, _d, _m, _s, alternatives = self._route()
        self.assertEqual(alternatives, [])

    def test_a_shortest_preference_changes_which_one_is_the_alternative(self):
        self._stub_osrm(
            {"code": "Ok", "routes": [_osrm_route(10_000, 1_200), _osrm_route(8_000, 1_500)]}
        )
        _p, distance_km, _m, _s, alternatives = self._route(preference="shortest")
        self.assertAlmostEqual(distance_km, 8.0, places=3)
        self.assertAlmostEqual(alternatives[0][1], 10.0, places=3)

    def test_an_unusable_alternative_is_dropped_rather_than_breaking_the_route(self):
        broken = {"distance": 9_000, "duration": 2_000, "geometry": {"coordinates": []}}
        self._stub_osrm(
            {"code": "Ok", "routes": [_osrm_route(10_000, 1_200), broken]}
        )
        result = self._route()
        self.assertIsNotNone(result)
        self.assertEqual(result[4], [])

    def test_pick_route_still_chooses_as_before(self):
        routes = [_osrm_route(10_000, 1_200), _osrm_route(8_000, 1_500)]
        self.assertEqual(pick_route(routes, "fastest")["duration"], 1_200)
        self.assertEqual(pick_route(routes, "shortest")["distance"], 8_000)


def _line(start_lng: float, start_lat: float, d_lng: float, d_lat: float, points: int = 6) -> list:
    return [[start_lng + i * d_lng, start_lat + i * d_lat] for i in range(points)]


def _via_route(coordinates: list, distance_m: float, duration_s: float) -> dict:
    """What OSRM returns for origin -> via -> destination: two legs, with an
    arrive/depart pair at the via point."""

    def step(kind, lng, lat):
        return {"maneuver": {"type": kind, "location": [lng, lat]}, "name": "Side Road", "distance": 100}

    return {
        "distance": distance_m,
        "duration": duration_s,
        "geometry": {"coordinates": coordinates},
        "legs": [
            {"steps": [step("depart", *coordinates[0]), step("arrive", *coordinates[2])]},
            {"steps": [step("depart", *coordinates[2]), step("arrive", *coordinates[-1])]},
        ],
    }


# The main route runs straight north-east; the detours bend off it.
_MAIN = {"code": "Ok", "routes": [{**_osrm_route(5_000, 600), "geometry": {"coordinates": _line(79.99, 6.80, 0.01, 0.01)}}]}
_LEFT = _via_route(_line(79.99, 6.80, 0.004, 0.012), 6_000, 700)
_RIGHT = _via_route(_line(79.99, 6.80, 0.012, 0.004), 6_500, 760)


class DetourAlternativeTests(unittest.TestCase):
    """Item 2 on local trips: OSRM offers one route, so detours are asked for."""

    def setUp(self):
        self.original_client = routing.httpx.AsyncClient
        self.requests = []

    def tearDown(self):
        routing.httpx.AsyncClient = self.original_client

    def _stub(self, main, via_answers):
        """`main` answers the plain A->B request; via requests take the next
        answer from `via_answers` (a dict, an exception, or None for HTTP 500)."""
        import httpx

        requests = self.requests
        answers = list(via_answers)

        class _Transport(httpx.AsyncBaseTransport):
            async def handle_async_request(self, request):
                requests.append(request)
                if request.url.path.count(";") == 1:
                    return httpx.Response(200, json=main)
                answer = answers.pop(0)
                if isinstance(answer, Exception):
                    raise answer
                if answer is None:
                    return httpx.Response(500)
                return httpx.Response(200, json={"code": "Ok", "routes": [answer]})

        original = self.original_client

        def factory(*args, **kwargs):
            kwargs["transport"] = _Transport()
            return original(*args, **kwargs)

        routing.httpx.AsyncClient = factory

    def _route(self, destination=(6.85, 80.04)):
        points = [
            routing.Coordinate(lat=6.80, lng=79.99),
            routing.Coordinate(lat=destination[0], lng=destination[1]),
        ]
        return asyncio.run(routing.road_route(points, "driving", "fastest", "en"))

    def test_both_detours_are_offered_when_they_use_other_roads(self):
        self._stub(_MAIN, [_LEFT, _RIGHT])
        alternatives = self._route()[4]
        self.assertEqual(sorted(round(a[1], 1) for a in alternatives), [6.0, 6.5])

    def test_the_via_point_is_not_announced_as_a_stop(self):
        self._stub(_MAIN, [_LEFT, _RIGHT])
        steps = self._route()[4][0][3]
        kinds = [s["maneuver"] for s in steps]
        self.assertEqual(kinds, ["depart", "arrive"])

    def test_the_detour_requests_carry_on_through_the_via_point(self):
        self._stub(_MAIN, [_LEFT, _RIGHT])
        self._route()
        via_requests = [r for r in self.requests if r.url.path.count(";") == 2]
        self.assertEqual(len(via_requests), 2)
        for request in via_requests:
            self.assertEqual(request.url.params["continue_straight"], "true")
            self.assertEqual(request.url.params["alternatives"], "false")

    def test_a_detour_on_the_same_roads_as_the_main_route_is_dropped(self):
        same = _via_route(_line(79.99, 6.80, 0.01, 0.01), 5_100, 610)
        self._stub(_MAIN, [same, _RIGHT])
        alternatives = self._route()[4]
        self.assertEqual([round(a[1], 1) for a in alternatives], [6.5])

    def test_two_detours_that_found_the_same_road_count_once(self):
        self._stub(_MAIN, [_LEFT, _LEFT])
        self.assertEqual(len(self._route()[4]), 1)

    def test_a_detour_much_longer_than_the_main_route_is_dropped(self):
        long_way = _via_route(_line(79.99, 6.80, 0.012, 0.004), 7_600, 900)  # 52% longer
        self._stub(_MAIN, [_LEFT, long_way])
        self.assertEqual([round(a[1], 1) for a in self._route()[4]], [6.0])

    def test_a_failed_detour_costs_only_that_option(self):
        import httpx

        self._stub(_MAIN, [httpx.ConnectTimeout("slow"), None])
        result = self._route()
        self.assertIsNotNone(result)
        self.assertAlmostEqual(result[1], 5.0, places=3)
        self.assertEqual(result[4], [])

    def test_no_detours_are_asked_for_when_osrm_already_offered_one(self):
        two = {"code": "Ok", "routes": [_osrm_route(10_000, 1_200), _osrm_route(8_000, 1_500)]}
        self._stub(two, [])
        self._route()
        self.assertEqual(len(self.requests), 1)

    def test_no_detours_are_asked_for_on_a_very_short_trip(self):
        self._stub(_MAIN, [])
        self._route(destination=(6.803, 79.993))  # about 500 m
        self.assertEqual(len(self.requests), 1)


class DetourPointTests(unittest.TestCase):
    def test_one_via_point_each_side_of_the_trip(self):
        origin = routing.Coordinate(lat=6.80, lng=79.99)
        destination = routing.Coordinate(lat=6.80, lng=80.03)  # due east, ~4.4 km
        left, right = routing.detour_points(origin, destination)
        # Level with the middle of the trip, one north and one south of it.
        self.assertAlmostEqual(left.lng, 80.01, places=4)
        self.assertAlmostEqual(right.lng, 80.01, places=4)
        self.assertGreater(left.lat, 6.80)
        self.assertLess(right.lat, 6.80)
        # 30% of the trip to the side: about 1.3 km.
        offset_km = (left.lat - 6.80) * 110.574
        self.assertAlmostEqual(offset_km, 4.4 * 0.3, delta=0.1)

    def test_the_offset_is_capped_on_a_long_trip(self):
        origin = routing.Coordinate(lat=6.80, lng=79.99)
        destination = routing.Coordinate(lat=7.30, lng=79.99)  # ~55 km north
        left, _right = routing.detour_points(origin, destination)
        km_per_deg_lng = 111.320 * math.cos(math.radians(7.05))  # at the trip's middle
        self.assertAlmostEqual(abs(left.lng - 79.99) * km_per_deg_lng, 3.0, places=3)

    def test_shared_fraction_measures_length_not_point_count(self):
        c = routing.Coordinate
        main = [c(lat=0, lng=0), c(lat=0, lng=0.01), c(lat=0, lng=0.02)]
        # First half on the main road, second half off it.
        path = [c(lat=0, lng=0), c(lat=0, lng=0.01), c(lat=0.01, lng=0.01)]
        self.assertAlmostEqual(routing.shared_fraction(path, main), 0.5, places=2)


if __name__ == "__main__":
    unittest.main()
