from pydantic import Field, field_validator
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    service_name: str = "delivery-service"

    postgres_user: str = "microlink"
    postgres_password: str = "microlink_dev_pw"
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "delivery_db"

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

    # ---- Delivery rules that come from the SRS. All of them can be changed
    # ---- from the .env file without touching the code.

    # SRS "View Available Orders": only show orders inside the agent's radius.
    agent_service_radius_km: float = 15.0

    # SRS "Update Order Status": the agent must be near the shop to confirm
    # pickup and near the customer to confirm delivery. Set GEOFENCE_ENABLED=false
    # for demos on an emulator whose GPS is not at the real shop/customer.
    geofence_enabled: bool = True
    geofence_radius_m: float = 300.0

    # Used to estimate the ETA and the "promised by" time of an order.
    average_speed_kmh: float = 25.0
    eta_buffer_minutes: int = 15
    default_trip_minutes: int = 45

    # SRS "Accept / Reject Order": a timed-out offer is hidden from that agent
    # for this many minutes, then shows up again.
    reject_timeout_hide_minutes: int = 5

    # How long an order may wait for a delivery agent before it is cancelled
    # and its reserved stock (item 12) goes back on the shelf.
    #
    # A setting, and no longer five minutes: at five, nearly every order
    # placed while no agent happened to be online died unaccepted, and the
    # shop's stock sprang back a few minutes after the customer ordered --
    # so a second customer saw the full quantity again. An hour is long
    # enough for a driver to come online, and short enough that an order
    # nobody ever takes does not hold stock for a whole day.
    unclaimed_timeout_minutes: int = 60

    # Item 8: how many cancellations by one shop, inside how many days, before
    # admins are told. The alert fires on exactly the Nth, not on every one
    # after it.
    # Item 4: when a shop counts as "often delayed". Thresholds rather than
    # constants because the right numbers are a product decision, not a
    # technical one.
    # How far back to look.
    timeliness_window_days: int = 30
    # Fewer orders than this in the window is not a pattern worth marking.
    min_orders_for_timeliness: int = 5
    # A median accept-to-pickup wait above this many minutes is slow.
    slow_pickup_minutes: float = 15.0
    # ... or this share of orders arriving after the promised time (0.4 = 40%).
    late_order_ratio: float = 0.4

    shop_cancellation_alert_count: int = 3
    shop_cancellation_window_days: int = 7
    user_service_url: str = "http://user-service:8000"

    # SRS 6.2 safety: stop customers who cancel again and again.
    max_cancellations_per_day: int = 5

    # docker-compose passes a full DATABASE_URL (same pattern as user-service).
    # Without this the service used its own default password and could not log in
    # to the compose Postgres.
    database_url_override: str | None = Field(default=None, alias="DATABASE_URL")
    redis_url: str | None = Field(default=None, alias="REDIS_URL")

    # Ownership of a shop lives in shop-service; this service asks it rather
    # than keeping a copy of the shop table that could drift.
    shop_service_url: str = "http://shop-service:8000"

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
