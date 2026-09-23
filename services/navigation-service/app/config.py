from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    service_name: str = "navigation-service"

    postgres_user: str = "microlink"
    postgres_password: str = "microlink_dev_pw"
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "navigation_db"

    redis_host: str = "redis"
    redis_port: int = 6379

    jwt_secret: str = "change_this_dev_secret_key_before_any_real_deployment"
    jwt_algorithm: str = "HS256"

    # Public OSRM demo server -- real road routing over OpenStreetMap data,
    # no API key. Swap for a self-hosted OSRM/Valhalla URL in production.
    osrm_base_url: str = "https://router.project-osrm.org"

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg2://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    class Config:
        env_file = ".env"


settings = Settings()
