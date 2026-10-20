from pydantic import Field, field_validator
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    service_name: str = "crowdsource-service"

    postgres_user: str = "microlink"
    postgres_password: str = "microlink_dev_pw"
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "crowdsource_db"

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

    # Item 7: only an account an admin has verified, whose crowdsource
    # reports have not been rejected, may confirm a neighbour's shop report.
    # Every customer is created already verified, so the flag alone would let
    # anyone through -- the trust score is what shuts out accounts whose
    # reports admins have thrown out.
    min_confirm_trust: int = 50

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
