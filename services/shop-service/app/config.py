"""Settings for shop-service, read from environment variables.

The variable names (POSTGRES_*, REDIS_*, JWT_*) are the ones docker-compose.yml
already passes to this service, so nothing in the shared compose file has to
change. Everything added for Member 2's extra features has a safe default.
"""

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    service_name: str = "shop-service"

    postgres_user: str = "microlink"
    postgres_password: str = "microlink_dev_pw"
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "shop_db"

    redis_host: str = "redis"
    redis_port: int = 6379

    # Required: there is deliberately no default, so a service can never start
    # with a guessable signing secret. Set JWT_SECRET in .env (same value for
    # every service) -- generate one with: openssl rand -hex 32
    jwt_secret: str

    @field_validator("jwt_secret")
    @classmethod
    def _jwt_secret_must_be_strong(cls, value: str) -> str:
        if len(value) < 32 or "change" in value.lower():
            raise ValueError(
                "JWT_SECRET must be at least 32 characters and not a placeholder. "
                "Generate one with: openssl rand -hex 32"
            )
        return value
    jwt_algorithm: str = "HS256"

    # --- Shop discovery rules (SRS section 5.3 / 5.7) ---
    # A product with this many items (or fewer) left is "Low Stock". A sale
    # that takes a product down to this number also tells the owner it is
    # running low (see app/stock_alerts.py).
    low_stock_threshold: int = 5
    # A product needs this many units before customers may see it. 1 means
    # customers can order right down to the last item. Selling that last item
    # hides the product until the owner unhides it (Product.is_hidden).
    # Owners and admins always see every product.
    min_listable_stock: int = 1
    # A shop needs this many listable products before an admin can verify it
    # (item 10). A shop already verified that drops below stays visible: it
    # would otherwise appear and disappear as stock moves.
    min_products_to_verify: int = 5
    # --- Community verification of a newly registered shop ---
    # A shop registered by its owner starts unverified, which means nobody
    # has stood behind the claim that it exists. An admin can verify it, but
    # in a town the admin has never been to, the people who walk past the
    # shop every day know better. This many DISTINCT nearby customers
    # confirming it is treated as the same evidence as an admin's approval.
    community_confirmations_to_verify: int = 3
    # How close a customer must be to the shop for their confirmation to
    # count. Someone in Colombo cannot vouch for a shop in Homagama.
    confirm_radius_km: float = 5.0
    # Minimum crowdsourcing trust score a confirmer needs, on the same 0-100
    # scale crowdsource-service keeps. 50 is what a new account starts with,
    # so this excludes only accounts whose reports admins have rejected.
    min_confirm_trust: int = 50
    # Asked for the confirmer's trust score. Unreachable means the score is
    # treated as the starting 50 -- the verified-account, proximity and
    # distinct-user rules still apply, so a crowdsource-service outage slows
    # nothing down but cannot let a rejected reporter through either.
    crowdsource_service_url: str = "http://crowdsource-service:8000"

    # SRS REQ-SHOP-1: at most 10 photos per shop.
    max_shop_photos: int = 10
    # SRS REQ-CROWD-3: trust score = average of ratings from the last 90 days.
    rating_window_days: int = 90
    # SRS REQ-SEARCH-3: default landmark search radius is 2 km.
    default_landmark_radius_km: float = 2.0
    # Used to group "peak hours" in analytics. Sri Lanka is UTC+05:30.
    local_utc_offset_minutes: int = 330

    # Free OpenStreetMap geocoder used for landmark search (no API key).
    # Used only to ask who saved a shop, when following up on a dormant one.
    recommendation_service_url: str = "http://recommendation-service:8000"

    nominatim_url: str = "https://nominatim.openstreetmap.org/search"
    # Same service, the other direction: a dropped map pin -> an address.
    nominatim_reverse_url: str = "https://nominatim.openstreetmap.org/reverse"
    geocode_timeout_seconds: float = 6.0

    # docker-compose passes a full DATABASE_URL; when set it wins over the parts above.
    database_url_override: str | None = Field(default=None, alias="DATABASE_URL")
    redis_url: str | None = Field(default=None, alias="REDIS_URL")

    @property
    def database_url(self) -> str:
        if self.database_url_override:
            return self.database_url_override
        return (
            f"postgresql+psycopg2://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()


def _apply_redis_url(current: Settings) -> None:
    """docker-compose passes one REDIS_URL; split it into the host/port event_bus.py reads."""
    if not current.redis_url:
        return
    from urllib.parse import urlparse

    parsed = urlparse(current.redis_url)
    current.redis_host = parsed.hostname or current.redis_host
    current.redis_port = parsed.port or current.redis_port


_apply_redis_url(settings)
