from typing import Dict, List, Optional
from supabase import Client
from datetime import time
import uuid


def _claude_day_to_storage_day(claude_day: int) -> int:
    """Convert the parser's day-of-week (0=Sunday..6=Saturday, per the
    system prompt in routers/timetables.py) to the convention used by
    timetable_slots / backend.core.scheduler.weekday() (0=Monday..6=Sunday,
    i.e. Python's date.weekday()). Without this, every slot lands on the
    wrong weekday once the scheduler reads it."""
    return (claude_day + 6) % 7


def insert_timetable_into_db(
    parsed_json: Dict,
    college_id: str,
    uploaded_by_user_id: str,
    source_json_id: Optional[str] = None
) -> Dict:
    """
    Insert parsed timetable into sections and timetable_slots tables.

    Args:
        parsed_json: {
            "course": "Physics Hons",
            "year": 1,
            "section": "B",
            "slots": [
                {"day_of_week": 1, "start_time": "09:00",
                 "end_time": "10:00", "subject": "Mechanics"},
                ...
            ]
        }
        college_id: UUID of the college
        uploaded_by_user_id: UUID of the admin uploading
        source_json_id: identifier for the parse run this timetable came
            from. Pass the id from a prior preview (dry_run) call so the
            confirmed rows carry the same traceability id the admin
            reviewed; if omitted, a fresh one is generated.

    Returns:
        {
            "sections_created": 0 or 1,
            "slots_inserted": N,
            "section_id": uuid,
            "source_json_id": uuid
        }
    """
    from core.config import get_supabase_client
    supabase: Client = get_supabase_client()

    course = parsed_json["course"]
    year = parsed_json["year"]
    section = parsed_json["section"]
    slots = parsed_json["slots"]

    # Step 1: Find or create sections row
    sections_data = supabase.table("sections").select("id").eq(
        "college_id", college_id
    ).eq("course", course).eq("year", year).eq("section_name", section).execute()

    if sections_data.data:
        section_id = sections_data.data[0]["id"]
        sections_created = 0
    else:
        new_section = {
            "college_id": college_id,
            "course": course,
            "year": year,
            "section_name": section
        }
        result = supabase.table("sections").insert(new_section).execute()
        section_id = result.data[0]["id"]
        sections_created = 1

    # Step 2: Insert timetable_slots
    source_json_id = source_json_id or str(uuid.uuid4())
    slots_to_insert = []

    for slot in slots:
        slots_to_insert.append({
            "section_id": section_id,
            # slot["day_of_week"] is 0=Sunday..6=Saturday (the parser's
            # convention); timetable_slots stores 0=Monday..6=Sunday.
            "day_of_week": _claude_day_to_storage_day(slot["day_of_week"]),
            "start_time": slot["start_time"],
            "end_time": slot["end_time"],
            "subject": slot.get("subject"),
            "uploaded_by": uploaded_by_user_id,
            "source_json_id": source_json_id
        })

    if slots_to_insert:
        insert_result = supabase.table("timetable_slots").insert(
            slots_to_insert
        ).execute()
        slots_inserted = len(insert_result.data)
    else:
        slots_inserted = 0

    return {
        "sections_created": sections_created,
        "slots_inserted": slots_inserted,
        "section_id": section_id,
        "source_json_id": source_json_id
    }
