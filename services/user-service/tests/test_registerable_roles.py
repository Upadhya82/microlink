"""Item 16: who may use /auth/register, and who has to apply.

A shop owner or delivery agent could self-register with no documents at
all. That left an account nobody could approve (no documents to review)
and nobody could use (unverified), which is the worst of both. Those roles
now have to come through /auth/register-application, which takes the
documents in the same request.

    cd services/user-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_registerable_roles.py -q
"""

import ast
import os
import unittest

from app.models import UserRole
from app.routers.auth_router import REQUIRED_DOCUMENTS
from app.schemas import REGISTERABLE_ROLES, ROLES_NEEDING_APPLICATION

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUTH_ROUTER = os.path.join(ROOT, "app", "routers", "auth_router.py")


class RoleSetTests(unittest.TestCase):
    def test_a_customer_can_still_self_register(self):
        self.assertIn(UserRole.user, REGISTERABLE_ROLES)

    def test_a_shop_owner_cannot(self):
        self.assertNotIn(UserRole.shop_owner, REGISTERABLE_ROLES)

    def test_a_delivery_agent_cannot(self):
        self.assertNotIn(UserRole.delivery_agent, REGISTERABLE_ROLES)

    def test_an_admin_was_never_self_registerable(self):
        self.assertNotIn(UserRole.admin, REGISTERABLE_ROLES)

    def test_the_two_sets_do_not_overlap(self):
        # A role in both would mean two ways in, one of which skips the
        # documents.
        self.assertEqual(REGISTERABLE_ROLES & ROLES_NEEDING_APPLICATION, set())

    def test_every_applying_role_has_documents_defined(self):
        # A role sent to the application endpoint with no required documents
        # would be refused there as well, leaving no way in at all.
        self.assertEqual(ROLES_NEEDING_APPLICATION, set(REQUIRED_DOCUMENTS))

    def test_a_shop_owner_must_supply_its_documents(self):
        self.assertIn("business_registration", REQUIRED_DOCUMENTS[UserRole.shop_owner])

    def test_a_delivery_agent_must_supply_its_documents(self):
        for doc_type in ("driving_licence", "police_clearance", "vehicle_registration"):
            self.assertIn(doc_type, REQUIRED_DOCUMENTS[UserRole.delivery_agent])


class RegisterEndpointWiringTests(unittest.TestCase):
    """The checks are in the code, in the order that gives the better error.

    Read from the source rather than exercised over HTTP, in the same style
    as shop-service's contract tests: this file needs no database.
    """

    def setUp(self):
        with open(AUTH_ROUTER, encoding="utf-8") as handle:
            self.source = handle.read()
        self.tree = ast.parse(self.source)

    def _function(self, name: str) -> ast.AsyncFunctionDef:
        for node in ast.walk(self.tree):
            if isinstance(node, ast.AsyncFunctionDef) and node.name == name:
                return node
        raise AssertionError(f"{name} not found")

    def test_register_refuses_the_applying_roles(self):
        body = ast.unparse(self._function("register"))
        self.assertIn("ROLES_NEEDING_APPLICATION", body)
        self.assertIn("register-application", body)

    def test_register_points_the_applicant_somewhere_useful(self):
        # "Contact an administrator" is a dead end for a role that has a
        # perfectly good way in.
        body = ast.unparse(self._function("register"))
        refusal = body.index("ROLES_NEEDING_APPLICATION")
        generic = body.index("Contact an administrator")
        self.assertLess(
            refusal,
            generic,
            "the specific refusal must come before the generic one",
        )

    def test_the_application_endpoint_does_not_use_the_register_set(self):
        # It did, and that silently refused every application the moment
        # REGISTERABLE_ROLES stopped listing these roles.
        body = ast.unparse(self._function("register_application"))
        self.assertIn("ROLES_NEEDING_APPLICATION", body)
        self.assertNotIn("REGISTERABLE_ROLES", body)


if __name__ == "__main__":
    unittest.main()
