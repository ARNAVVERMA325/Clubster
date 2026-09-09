"""App settings and Supabase client setup."""

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict
from supabase import Client, create_client


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    environment: str = "development"
    api_port: int = 8000
    cors_origins: str = "http://localhost:3000,http://localhost:8080"

    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_service_role_key: str = ""

    database_url: str = ""

    @property
    def cors_origin_list(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()


@lru_cache
def get_supabase_client() -> Client:
    """Service-role Supabase client for backend use.

    TODO: swap to a per-request client scoped to the caller's JWT once
    auth is implemented, so RLS policies apply instead of the service role.
    """
    settings = get_settings()
    return create_client(settings.supabase_url, settings.supabase_service_role_key)
