"""Timetable routes.

`/section/{section_id}` and `/overrides` are still stubs — TODO: implement
against timetable_slots and user_timetable_overrides.

`/upload` sends an uploaded timetable (image, PDF, or pasted text) to
Claude and validates the structured result. With `dry_run=true` it
returns the parsed slots for admin review without writing to the
database; otherwise it inserts immediately via
core.timetable_inserter.insert_timetable_into_db. `/confirm` takes JSON
previously returned by a dry_run call and inserts it — no second Claude
call.
"""

from __future__ import annotations

import base64
import re
import uuid
from typing import Optional

import anthropic
from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from pydantic import BaseModel, Field, ValidationError, field_validator, model_validator

from core.config import get_anthropic_client
from core.timetable_inserter import insert_timetable_into_db

MAX_UPLOAD_BYTES = 5 * 1024 * 1024

router = APIRouter(prefix="/timetables", tags=["timetables"])


@router.get("/section/{section_id}", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def get_section_timetable(section_id: str):
    return {"detail": "not implemented"}


@router.post("/overrides", status_code=status.HTTP_501_NOT_IMPLEMENTED)
def create_override():
    return {"detail": "not implemented"}


# ============================================================
# POST /timetables/upload
# ============================================================

CUSTOM_TIMETABLE_PROMPT = """You are a timetable parser for Delhi University colleges. Your job is to
extract class schedules from messy, handwritten, or formatted timetables
and return structured JSON.

Input: A timetable for one section (e.g., "Physics Hons, Section B, Year 1")

Output: A JSON object with this exact structure:
{
  "course": "Physics Hons",
  "year": 1,
  "section": "B",
  "slots": [
    {
      "day_of_week": 1,
      "start_time": "09:00",
      "end_time": "10:00",
      "subject": "Mechanics" or null if unlabeled
    },
    ...
  ]
}

Rules:
- day_of_week: 0=Sunday, 1=Monday, ..., 6=Saturday
- Times in 24-hour format (HH:MM)
- Ignore lunch breaks, assembly, holidays
- If a time slot is empty/free, do NOT include it
- If subject is unclear, use null
- Return ONLY valid JSON, no other text

Example input: "Mon 9-10 Mechanics, Tue 9-11 Practicals Lab, Wed 2-3 Tutorial"
Example output: {"course": "Physics Hons", "year": 1, "section": "B",
"slots": [{"day_of_week": 1, "start_time": "09:00", "end_time": "10:00",
"subject": "Mechanics"}, ...]}"""

_TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


class ParsedSlot(BaseModel):
    day_of_week: int = Field(ge=0, le=6)  # Claude's convention: 0=Sunday .. 6=Saturday
    start_time: str
    end_time: str
    subject: Optional[str] = None

    @field_validator("start_time", "end_time")
    @classmethod
    def _valid_time(cls, v: str) -> str:
        if not _TIME_RE.match(v):
            raise ValueError(f"'{v}' is not a valid 24-hour HH:MM time")
        return v

    @model_validator(mode="after")
    def _end_after_start(self) -> "ParsedSlot":
        if self.end_time <= self.start_time:
            raise ValueError(f"end_time ({self.end_time}) must be after start_time ({self.start_time})")
        return self


class ParsedTimetable(BaseModel):
    course: str = Field(min_length=1)
    year: int
    section: str = Field(min_length=1)
    slots: list[ParsedSlot]

    @field_validator("course", "section")
    @classmethod
    def _non_empty(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("must not be empty")
        return v


def get_current_user_id() -> Optional[str]:
    """TODO: replace with real auth (verify the Supabase JWT from the
    Authorization header). Returns None until auth is implemented, so
    uploads are currently recorded as unattributed."""
    return None


def _build_content_blocks(file: Optional[UploadFile], text: Optional[str]) -> list[dict]:
    if file is not None:
        contents = file.file.read()
        if len(contents) > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=400, detail="File too large. Max 5MB.")

        content_type = file.content_type or ""
        filename = (file.filename or "").lower()

        if content_type.startswith("image/"):
            return [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": content_type,
                        "data": base64.standard_b64encode(contents).decode("utf-8"),
                    },
                },
                {"type": "text", "text": "Extract the class timetable from this image."},
            ]

        if content_type == "application/pdf" or filename.endswith(".pdf"):
            return [
                {
                    "type": "document",
                    "source": {
                        "type": "base64",
                        "media_type": "application/pdf",
                        "data": base64.standard_b64encode(contents).decode("utf-8"),
                    },
                },
                {"type": "text", "text": "Extract the class timetable from this document."},
            ]

        if content_type.startswith("text/") or filename.endswith(".txt"):
            return [{"type": "text", "text": contents.decode("utf-8", errors="replace")}]

        raise HTTPException(
            status_code=400,
            detail=f"unsupported file type '{content_type or file.filename}' — upload an image, a PDF, or a .txt file",
        )

    return [{"type": "text", "text": text}]


@router.post("/upload")
def upload_timetable(
    college_id: str = Form(...),
    file: Optional[UploadFile] = File(default=None),
    text: Optional[str] = Form(default=None),
    dry_run: bool = Form(default=False),
    current_user: Optional[str] = Depends(get_current_user_id),
):
    if file is None and not (text and text.strip()):
        raise HTTPException(status_code=400, detail="provide either a file upload or a text paste")

    content_blocks = _build_content_blocks(file, text)

    client = get_anthropic_client()
    try:
        response = client.messages.parse(
            model="claude-opus-5",
            max_tokens=4096,
            thinking={"type": "adaptive"},
            system=CUSTOM_TIMETABLE_PROMPT,
            messages=[{"role": "user", "content": content_blocks}],
            output_format=ParsedTimetable,
        )
    except anthropic.RateLimitError as e:
        raise HTTPException(status_code=429, detail="Claude API rate limited, try again shortly") from e
    except anthropic.APIStatusError as e:
        raise HTTPException(status_code=502, detail=f"Claude API error: {e.message}") from e
    except anthropic.APIConnectionError as e:
        raise HTTPException(status_code=502, detail="could not reach the Claude API") from e
    except ValidationError as e:
        raise HTTPException(
            status_code=400, detail={"error": "invalid timetable JSON", "reason": e.errors()}
        ) from e

    if response.stop_reason == "refusal":
        raise HTTPException(status_code=400, detail="Claude declined to process this timetable")

    parsed = response.parsed_output
    if parsed is None:
        raise HTTPException(
            status_code=400,
            detail={"error": "invalid timetable JSON", "reason": "model did not return structured output"},
        )

    # Generated at parse time (not insert time) so a dry_run preview and
    # the confirm call that follows it can be tied together — the admin
    # reviews slots tagged with this id, then POSTs it back to /confirm.
    source_json_id = str(uuid.uuid4())

    if dry_run:
        return {
            "status": "preview",
            "course": parsed.course,
            "year": parsed.year,
            "section": parsed.section,
            "parsed_slots": [slot.model_dump() for slot in parsed.slots],
            "source_json_id": source_json_id,
        }

    result = insert_timetable_into_db(
        parsed_json=parsed.model_dump(),
        college_id=college_id,
        uploaded_by_user_id=current_user,
        source_json_id=source_json_id,
    )

    return {
        "status": "success",
        "sections_created": result["sections_created"],
        "slots_inserted": result["slots_inserted"],
        "course": parsed.course,
        "year": parsed.year,
        "section": parsed.section,
        "parsed_slots": [slot.model_dump() for slot in parsed.slots],
        "source_json_id": result["source_json_id"],
    }


# ============================================================
# POST /timetables/confirm
#
# Takes the JSON an admin already previewed (via /upload?dry_run=true)
# and inserts it — no Claude call here, so confirming can't produce a
# different result than what was shown, and doesn't cost a second
# generation.
# ============================================================


class ConfirmTimetableRequest(ParsedTimetable):
    college_id: str = Field(min_length=1)
    source_json_id: Optional[str] = None


@router.post("/confirm")
def confirm_timetable(
    payload: ConfirmTimetableRequest,
    current_user: Optional[str] = Depends(get_current_user_id),
):
    result = insert_timetable_into_db(
        parsed_json=payload.model_dump(exclude={"college_id", "source_json_id"}),
        college_id=payload.college_id,
        uploaded_by_user_id=current_user,
        source_json_id=payload.source_json_id,
    )

    return {
        "status": "success",
        "sections_created": result["sections_created"],
        "slots_inserted": result["slots_inserted"],
        "section_id": result["section_id"],
        "source_json_id": result["source_json_id"],
    }
