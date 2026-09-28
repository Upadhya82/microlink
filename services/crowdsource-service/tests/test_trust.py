import unittest

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from app.models import Base, UserTrustScore
from app.trust import get_or_create_trust_score, record_report


class TrustScoreTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine('sqlite:///:memory:')
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine)
        self.session = self.Session()

    def tearDown(self):
        self.session.close()

    def test_new_user_starts_at_50_and_remains_at_50_after_report(self):
        trust = get_or_create_trust_score(self.session, 'user-123')
        self.assertEqual(trust.score, 50.0)
        self.assertEqual(trust.total_reports, 0)
        self.assertEqual(trust.validated_reports, 0)

        updated = record_report(self.session, 'user-123')
        self.assertEqual(updated.score, 50.0)
        self.assertEqual(updated.total_reports, 1)
        self.assertEqual(updated.validated_reports, 0)


if __name__ == '__main__':
    unittest.main()
