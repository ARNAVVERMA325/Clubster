"""Timetable routes — stubs only. TODO: implement against timetable_slots
and user_timetable_overrides."""

from fastapi import APIRouter, status

router = APIRouter(prefix="/timetables", tags=["timetables"])


@router.get("/section/{section_id}", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def get_section_timetable(section_id: str):
    return {"detail": "not implemented"}


@router.post("/overrides", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def create_override():
    return {"detail": "not implemented"}
