"""App settings and Supabase / Anthropic client setup."""

from functools import lru_cache

from anthropic import Anthropic
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

    anthropic_api_key: str = ""

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


@lru_cache
def get_anthropic_client() -> Anthropic:
    """Anthropic API client.

    If ANTHROPIC_API_KEY isn't set via Settings, falls back to the SDK's
    normal credential resolution (ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN
    env vars, or an `ant auth login` profile).
    """
    settings = get_settings()
    if settings.anthropic_api_key:
        return Anthropic(api_key=settings.anthropic_api_key)
    return Anthropic()
