from pydantic import Field
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

    jwt_secret: str = "change_this_dev_secret_key_before_any_real_deployment"
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

    # SRS 6.2 safety: stop customers who cancel again and again.
    max_cancellations_per_day: int = 5

    # docker-compose passes a full DATABASE_URL (same pattern as user-service).
    # Without this the service used its own default password and could not log in
    # to the compose Postgres.
    database_url_override: str | None = Field(default=None, alias="DATABASE_URL")

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
