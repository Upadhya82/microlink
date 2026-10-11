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

    # How far from a pickup an available agent is still told about a new
    # order (REQ-DELIV-4). Generous because Sri Lankan towns are spread out
    # and an agent with no job will happily travel.
    agent_service_radius_km: float = 15.0

    # Ownership of a shop lives in shop-service; this service asks it rather
    # than keeping a copy of the shop table that could drift.
    shop_service_url: str = "http://shop-service:8000"

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
