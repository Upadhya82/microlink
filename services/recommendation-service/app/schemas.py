from datetime import datetime

from pydantic import BaseModel, ConfigDict

from app.models import InteractionType


class InteractionCreateRequest(BaseModel):
    shop_id: str
    interaction_type: InteractionType


class InteractionResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    shop_id: str
    interaction_type: InteractionType
    created_at: datetime


class FavoriteResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    shop_id: str
    created_at: datetime
