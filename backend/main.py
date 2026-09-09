"""Clubster FastAPI app entrypoint."""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from core.config import get_settings
from routers import attendance, auth, budgets, clubs, events, timetables

settings = get_settings()

app = FastAPI(title="Clubster API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mounted under /api so route paths match the ones referenced elsewhere
# (e.g. POST /api/timetables/upload); /health is deliberately left outside.
app.include_router(auth.router, prefix="/api")
app.include_router(clubs.router, prefix="/api")
app.include_router(events.router, prefix="/api")
app.include_router(timetables.router, prefix="/api")
app.include_router(attendance.router, prefix="/api")
app.include_router(budgets.router, prefix="/api")


@app.get("/health")
def health_check():
    return {"status": "ok"}
