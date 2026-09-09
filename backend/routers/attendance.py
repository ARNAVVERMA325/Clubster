"""Attendance routes — stubs only. TODO: implement against event_attendance
(QR check-in and roll-number entry)."""

from fastapi import APIRouter, status

router = APIRouter(prefix="/attendance", tags=["attendance"])


@router.post("/{event_id}/check-in", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def check_in(event_id: str):
    return {"detail": "not implemented"}


@router.get("/{event_id}", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def list_attendance(event_id: str):
    return {"detail": "not implemented"}
