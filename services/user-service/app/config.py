from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    service_name: str = "user-service"

    postgres_user: str = "microlink"
    postgres_password: str = "microlink_dev_pw"
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "user_db"

    redis_host: str = "redis"
    redis_port: int = 6379

    jwt_secret: str = "change_this_dev_secret_key_before_any_real_deployment"
    jwt_algorithm: str = "HS256"
    jwt_expire_minutes: int = 1440

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+psycopg2://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    class Config:
        env_file = ".env"


settings = Settings()
