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

app.include_router(auth.router)
app.include_router(clubs.router)
app.include_router(events.router)
app.include_router(timetables.router)
app.include_router(attendance.router)
app.include_router(budgets.router)


@app.get("/health")
def health_check():
    return {"status": "ok"}
