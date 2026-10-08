"""Settings for shop-service, read from environment variables.

The variable names (POSTGRES_*, REDIS_*, JWT_*) are the ones docker-compose.yml
already passes to this service, so nothing in the shared compose file has to
change. Everything added for Member 2's extra features has a safe default.
"""

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

    jwt_secret: str = "change_this_dev_secret_key_before_any_real_deployment"
    jwt_algorithm: str = "HS256"

    # --- Shop discovery rules (SRS section 5.3 / 5.7) ---
    # A product with this many items (or fewer) left is "Low Stock".
    low_stock_threshold: int = 5
    # SRS REQ-SHOP-1: at most 10 photos per shop.
    max_shop_photos: int = 10
    # SRS REQ-CROWD-3: trust score = average of ratings from the last 90 days.
    rating_window_days: int = 90
    # SRS REQ-SEARCH-3: default landmark search radius is 2 km.
    default_landmark_radius_km: float = 2.0
    # Used to group "peak hours" in analytics. Sri Lanka is UTC+05:30.
    local_utc_offset_minutes: int = 330

    # Free OpenStreetMap geocoder used for landmark search (no API key).
    nominatim_url: str = "https://nominatim.openstreetmap.org/search"
    geocode_timeout_seconds: float = 6.0

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg2://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    class Config:
        env_file = ".env"
        extra = "ignore"


settings = Settings()
