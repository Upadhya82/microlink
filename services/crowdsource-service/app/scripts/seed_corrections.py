import json
import uuid
from datetime import datetime, timezone

from app.database import SessionLocal
from app.models import (
    NewShopReport,
    ShopCorrectionReport,
    ShopReportConfirmation,
    ShopReportStatus,
    SuggestionCommentReply,
    SuggestionGeneralComment,
)


def seed_corrections_and_suggestions():
    db = SessionLocal()
    try:
        # 1. Clear existing demo reports to avoid duplication
        # Replies point at confirmations, so they go first.
        db.query(SuggestionCommentReply).delete()
        db.query(SuggestionGeneralComment).delete()
        db.query(ShopReportConfirmation).delete()
        db.query(NewShopReport).delete()
        db.query(ShopCorrectionReport).delete()
        db.commit()

        # Dummy user IDs
        u1 = "5f924cd7-0727-49e4-88a1-b16986c47f14"
        u2 = "d7efd286-ddd5-402f-b4c8-bc6dd3b0eb7a"
        u3 = "ac332006-2da9-4ae6-accc-74fc5d22c0f2"
        u4 = "4e09f36f-a41b-4b0c-9450-1968ec1159d1"

        # 2. Seed realistic shop corrections
        corrections = [
            ShopCorrectionReport(
                id=str(uuid.uuid4()),
                reporter_id=u2,
                shop_id="ae2ab7f9-3dba-4e83-8f6a-8b16b820d34a",
                shop_name="Kamal Super",
                changes=json.dumps({"phone": "0112349999", "closing_time": "22:00"}),
                note="Shop now stays open an hour later until 10:00 PM on weekdays and has a new customer hotline.",
                status=ShopReportStatus.pending,
            ),
            ShopCorrectionReport(
                id=str(uuid.uuid4()),
                reporter_id=u3,
                shop_id="0e676c08-b6df-404d-ba99-3601f3ee4f24",
                shop_name="Ceylon Spice Kitchen",
                changes=json.dumps({"address": "5 Galle Face Green, Colombo 01"}),
                note="Moved two doors down to the renovated seafront building.",
                status=ShopReportStatus.pending,
            ),
            ShopCorrectionReport(
                id=str(uuid.uuid4()),
                reporter_id=u4,
                shop_id="ec6be6f2-c48f-47a8-bb46-4cdfa9083bae",
                shop_name="Kandy Fresh Market",
                changes=json.dumps({"opening_time": "06:30", "phone": "0812239988"}),
                note="Morning opening time shifted to 6:30 AM for wholesale deliveries.",
                status=ShopReportStatus.pending,
            ),
            ShopCorrectionReport(
                id=str(uuid.uuid4()),
                reporter_id=u2,
                shop_id="e9b1e997-9e9b-4c49-b53e-bb4ca50eb2b2",
                shop_name="Galle Fort Provisions",
                changes=json.dumps({"name": "Galle Fort Heritage Provisions", "closing_time": "21:00"}),
                note="Storefront signboard was updated with the heritage branding.",
                status=ShopReportStatus.pending,
            ),
        ]
        db.add_all(corrections)

        # 3. Seed New Shop Reports (Requirement 4)
        # Shop A: >= 75% verified (100%), has owner phone number
        r1_id = str(uuid.uuid4())
        r1 = NewShopReport(
            id=r1_id,
            reporter_id=u2,
            shop_name="Samanala Bakers & Sweets",
            category="bakery",
            address="15 High Level Road, Maharagama",
            latitude=6.8480,
            longitude=79.9265,
            phone="0771234567",
            opening_time="06:00",
            closing_time="21:30",
            description="Popular newly opened bakery with fresh pastries and Sri Lankan tea.",
            status=ShopReportStatus.pending,
            has_photo=False,
        )

        # Shop B: >= 75% verified (75%), NO phone number (to test request phone from neighbours)
        r2_id = str(uuid.uuid4())
        r2 = NewShopReport(
            id=r2_id,
            reporter_id=u3,
            shop_name="City Organic Green Market",
            category="grocery",
            address="72 Baseline Road, Dematagoda",
            latitude=6.9320,
            longitude=79.8780,
            phone=None,
            opening_time=None,
            closing_time=None,
            description="Organic vegetables, fresh coconut, and traditional heirloom rice varieties.",
            status=ShopReportStatus.pending,
            has_photo=False,
        )

        # Shop C: < 75% verified (25% - RED highlight), has phone number
        r3_id = str(uuid.uuid4())
        r3 = NewShopReport(
            id=r3_id,
            reporter_id=u4,
            shop_name="QuickFix Mobile & Laptop Repair",
            category="electronics",
            address="12 Station Road, Nugegoda",
            latitude=6.8720,
            longitude=79.8970,
            phone="0718899001",
            opening_time="09:00",
            closing_time="19:00",
            description="Small repair shop claiming 30-minute display replacement.",
            status=ShopReportStatus.pending,
            has_photo=False,
        )

        db.add_all([r1, r2, r3])
        db.commit()

        # Confirmations & Comments for Shop A (100% verified - 4 yes)
        db.add_all([
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r1_id,
                user_id=u1,
                confirms=True,
                comment="Yes, opened last month right opposite the bus stand!",
            ),
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r1_id,
                user_id=u3,
                confirms=True,
                comment="Really good fresh bakery items. Owner is Mr. Saman.",
            ),
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r1_id,
                user_id=u4,
                confirms=True,
                comment="Confirmed, highly recommended for commuters.",
            ),
        ])

        # Confirmations & Comments for Shop B (75% verified - 3 yes, 1 no)
        db.add_all([
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r2_id,
                user_id=u1,
                confirms=True,
                comment="Yes, the shop is definitely there, opened next to the pharmacy.",
            ),
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r2_id,
                user_id=u2,
                confirms=True,
                comment="Fresh organic produce available every morning.",
            ),
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r2_id,
                user_id=u4,
                confirms=True,
                comment="Great place for local vegetables.",
            ),
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r2_id,
                user_id="f858e1ca-85a5-4e98-ad51-8f4ef0817c3a",
                confirms=False,
                comment="Signboard is small, hard to spot from the main road.",
            ),
        ])

        # Confirmations & Comments for Shop C (25% verified - 1 yes, 3 no)
        db.add_all([
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r3_id,
                user_id=u1,
                confirms=True,
                comment="Saw the board, but shop was closed when I visited.",
            ),
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r3_id,
                user_id=u2,
                confirms=False,
                comment="I checked yesterday and the unit is still under renovation, not open yet.",
            ),
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r3_id,
                user_id=u3,
                confirms=False,
                comment="Not operational yet.",
            ),
            ShopReportConfirmation(
                id=str(uuid.uuid4()),
                report_id=r3_id,
                user_id="f858e1ca-85a5-4e98-ad51-8f4ef0817c3a",
                confirms=False,
                comment="No staff there, seems fake or delayed opening.",
            ),
        ])

        db.commit()
        print("Successfully seeded realistic Corrections and Suggested Shops with community ratings and comments!")
    finally:
        db.close()


if __name__ == "__main__":
    seed_corrections_and_suggestions()
