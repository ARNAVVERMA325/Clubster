"""Event slot suggestion + clash detection.

Implements the scheduling algorithm exactly as specified (function names
and pipeline structure preserved). A few gaps in the original pseudocode
had to be resolved to get runnable code; each is called out with a
"pseudocode fix" comment at the point it's resolved:

  * `generate_gaps` / `apply_venue_turnover` referenced a `date` that
    wasn't in scope — both now take `date` explicitly.
  * `suggest_slot` referenced `college_settings` without ever assigning
    it to a local — it's now fetched once and reused for the gap search
    and the buffer math.
  * `user_timetable_overrides` has an add/remove `type`. Naively unioning
    both into one busy list (as literally written) can't express
    "remove" cancelling out a base timetable block. `get_section_timetable`
    now applies `remove` overrides itself (subtracting them from the base
    timetable slots it fetches); `get_timetable_overrides` returns only
    `add` overrides, so the calling code (`effective_busy`) is untouched.
  * `get_section_timetable` / `get_timetable_overrides` need a concrete
    `date` (not just a weekday) to anchor recurring weekly slots to real
    datetimes — both now take `date` in addition to `day`.
  * `suggest_slot` recursing via `retry_next_day` had no recursion cap in
    the pseudocode; `retry_next_day` now threads through an internal
    `_attempt` counter so the search terminates.

Everything else follows the pseudocode step-for-step.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field
from typing import Optional

from core.config import get_supabase_client

# ============================================================
# Data types
# ============================================================


@dataclass(frozen=True)
class Interval:
    start: dt.datetime
    end: dt.datetime


@dataclass(frozen=True)
class Gap:
    start: dt.datetime
    end: dt.datetime
    date: dt.date

    @property
    def duration(self) -> dt.timedelta:
        return self.end - self.start


@dataclass(frozen=True)
class CalendarEntry:
    date: dt.date
    day_type: str
    is_teaching_day: bool


@dataclass(frozen=True)
class CollegeSettings:
    college_id: str
    day_start: dt.time
    day_end: dt.time
    working_days: list[int]
    default_turnover_minutes: int
    start_buffer_minutes: int
    inform_buffer_minutes: int
    min_viable_turnout: float


@dataclass(frozen=True)
class UserRef:
    id: str
    year: Optional[int] = None


@dataclass(frozen=True)
class KeyMember:
    id: str
    required: bool = True
    year: Optional[int] = None


@dataclass(frozen=True)
class Event:
    id: str
    college_id: str
    club_id: str
    venue_id: Optional[str]
    duration_minutes: int
    event_target_sections: list[str]
    actual_start: Optional[dt.datetime] = None
    actual_end: Optional[dt.datetime] = None

    @property
    def duration(self) -> dt.timedelta:
        return dt.timedelta(minutes=self.duration_minutes)


@dataclass(frozen=True)
class ScheduleResult:
    suggested_start: dt.datetime
    informing_time: dt.datetime
    turnout_score: float
    low_confidence: bool
    alternatives: list[tuple[Gap, float]] = field(default_factory=list)


class NoSlotFound:
    """Sentinel returned (not raised) when no valid slot exists in the
    search window — matches the pseudocode's `return NoSlotFound()`."""

    def __repr__(self) -> str:  # pragma: no cover - cosmetic
        return "NoSlotFound()"

    def __eq__(self, other: object) -> bool:
        return isinstance(other, NoSlotFound)


# ============================================================
# Small pure-logic helpers
# ============================================================


def offset_days(date: dt.date, offset: int) -> dt.date:
    return date + dt.timedelta(days=offset)


def weekday(date: dt.date) -> int:
    """Monday=0 .. Sunday=6, matching the day_of_week columns in schema.sql."""
    return date.weekday()


def overlaps(a: Interval, b: Interval | Gap) -> bool:
    return a.start < b.end and b.start < a.end


def sections_overlap(sections_a: list[str], sections_b: list[str]) -> bool:
    return bool(set(sections_a) & set(sections_b))


def merge_intervals(intervals: list[Interval]) -> list[Interval]:
    """Sweep-line merge of overlapping/touching intervals, O(n log n)."""
    if not intervals:
        return []
    ordered = sorted(intervals, key=lambda iv: iv.start)
    merged = [ordered[0]]
    for iv in ordered[1:]:
        last = merged[-1]
        if iv.start <= last.end:
            if iv.end > last.end:
                merged[-1] = Interval(last.start, iv.end)
        else:
            merged.append(iv)
    return merged


def subtract_interval(piece: Interval, block: Interval) -> list[Interval]:
    """`piece` minus `block`, as 0-2 remaining pieces."""
    if block.end <= piece.start or block.start >= piece.end:
        return [piece]
    pieces = []
    if block.start > piece.start:
        pieces.append(Interval(piece.start, block.start))
    if block.end < piece.end:
        pieces.append(Interval(block.end, piece.end))
    return pieces


def subtract_intervals(base: list[Interval], removals: list[Interval]) -> list[Interval]:
    pieces = list(base)
    for removal in removals:
        next_pieces: list[Interval] = []
        for p in pieces:
            next_pieces += subtract_interval(p, removal)
        pieces = next_pieces
    return merge_intervals(pieces)


# ============================================================
# STEP 0 — Validate / advance date
# ============================================================


def find_valid_date(
    college_id: str, requested_date: dt.date, max_days_forward: int = 5
) -> Optional[dt.date]:
    for offset in range(max_days_forward + 1):
        candidate = offset_days(requested_date, offset)
        calendar_entry = get_academic_calendar(college_id, candidate)
        if calendar_entry.is_teaching_day:
            return candidate
    return None  # nothing found in window -> tell admin manually


# ============================================================
# STEP 1 — Effective busy calendar (the single source of truth)
# ============================================================


def effective_busy(user_id: str, date: dt.date) -> list[Interval]:
    day = weekday(date)
    intervals: list[Interval] = []
    intervals += get_section_timetable(user_id, day, date)  # base class schedule
    intervals += get_timetable_overrides(user_id, day, date)  # electives (add only; removes are netted into get_section_timetable)
    intervals += get_mandatory_event_blocks(user_id, date)  # club_only events targeting them
    intervals += get_rsvped_event_blocks(user_id, date)  # opted-into open events
    return merge_intervals(intervals)  # sweep-line merge, O(n log n)


# ============================================================
# STEP 2 — Combined busy timeline for all invited students
# ============================================================


def combined_busy(event: Event, date: dt.date) -> tuple[list[Interval], list[UserRef]]:
    invited_users = get_users_in_target_sections(event.event_target_sections)
    all_intervals: list[Interval] = []
    for user in invited_users:
        all_intervals += effective_busy(user.id, date)
    return merge_intervals(all_intervals), invited_users


# ============================================================
# STEP 3 — Generate candidate gaps
# ============================================================


def complement(
    busy: list[Interval], day_start: dt.time, day_end: dt.time, date: dt.date
) -> list[Gap]:
    """Invert the merged busy set within [day_start, day_end] on `date`."""
    window_start = dt.datetime.combine(date, day_start)
    window_end = dt.datetime.combine(date, day_end)

    clipped = []
    for iv in busy:
        s, e = max(iv.start, window_start), min(iv.end, window_end)
        if s < e:
            clipped.append(Interval(s, e))
    clipped = merge_intervals(clipped)

    gaps: list[Gap] = []
    cursor = window_start
    for iv in clipped:
        if iv.start > cursor:
            gaps.append(Gap(cursor, iv.start, date))
        cursor = max(cursor, iv.end)
    if cursor < window_end:
        gaps.append(Gap(cursor, window_end, date))
    return gaps


def apply_venue_turnover(
    free: list[Gap], venue_id: Optional[str], date: dt.date, turnover_minutes: int
) -> list[Gap]:
    """Pad around existing venue bookings so back-to-back events leave
    room for setup/teardown."""
    if venue_id is None:
        return free

    bookings = get_venue_bookings(venue_id, date)
    pad = dt.timedelta(minutes=turnover_minutes)
    padded = merge_intervals([Interval(b.start - pad, b.end + pad) for b in bookings])

    result: list[Gap] = []
    for gap in free:
        pieces = [Interval(gap.start, gap.end)]
        for block in padded:
            next_pieces: list[Interval] = []
            for p in pieces:
                next_pieces += subtract_interval(p, block)
            pieces = next_pieces
        result += [Gap(p.start, p.end, date) for p in pieces if p.start < p.end]
    return result


def generate_gaps(
    busy_timeline: list[Interval],
    college_settings: CollegeSettings,
    event_duration: dt.timedelta,
    venue: Optional[str],
    date: dt.date,  # pseudocode fix: `date` was referenced but never passed in
) -> list[Gap]:
    day_start, day_end = college_settings.day_start, college_settings.day_end
    free = complement(busy_timeline, day_start, day_end, date)  # invert the merged busy set
    free = apply_venue_turnover(
        free, venue, date, college_settings.default_turnover_minutes
    )  # pad around existing bookings
    return [g for g in free if g.duration >= event_duration]


# ============================================================
# STEP 4 — Hard filter: required/key members must be free
# ============================================================


def is_free(member: UserRef | KeyMember, gap: Gap) -> bool:
    busy = effective_busy(member.id, gap.date)
    return not any(overlaps(iv, gap) for iv in busy)


def filter_by_required_members(gaps: list[Gap], event: Event) -> list[Gap]:
    required = get_event_key_members(event.id, required=True)
    valid_gaps = []
    for gap in gaps:
        if all(is_free(member, gap) for member in required):
            valid_gaps.append(gap)
    return valid_gaps


# ============================================================
# STEP 5 — Score remaining gaps (normalized, weighted, gated)
# ============================================================


def year_weight(year: Optional[int]) -> float:
    # TODO: this is a flat placeholder (every invited student counts
    # equally). Replace with a real per-year weighting policy once the
    # product decides how much to prioritize e.g. graduating batches.
    return 1.0


def score_gap(gap: Gap, invited_users: list[UserRef]) -> float:
    total_weight = sum(year_weight(u.year) for u in invited_users)
    free_weight = sum(year_weight(u.year) for u in invited_users if is_free(u, gap))
    if total_weight == 0:
        return 0.0
    return (free_weight / total_weight) * 100  # normalized %, not raw headcount


def rank_gaps(gaps: list[Gap], invited_users: list[UserRef]) -> list[tuple[Gap, float]]:
    scored = [(gap, score_gap(gap, invited_users)) for gap in gaps]
    # tie-break: score desc -> earlier date -> longer gap duration
    return sorted(scored, key=lambda x: (-x[1], x[0].date, -x[0].duration))


# ============================================================
# STEP 6 — Final suggestion + confidence flag
# ============================================================


def retry_next_day(
    event: Event, date: dt.date, _attempt: int = 1, max_attempts: int = 5
) -> ScheduleResult | NoSlotFound:
    """Recurse forward within the search cap when a day has no valid gaps."""
    if _attempt >= max_attempts:
        return NoSlotFound()
    next_date = find_valid_date(
        event.college_id, offset_days(date, 1), max_days_forward=max_attempts - _attempt
    )
    if next_date is None:
        return NoSlotFound()
    return suggest_slot(event, next_date, _attempt=_attempt + 1)


def suggest_slot(
    event: Event, date: dt.date, _attempt: int = 1
) -> ScheduleResult | NoSlotFound:
    date = find_valid_date(event.college_id, date)
    if not date:
        return NoSlotFound()

    college_settings = get_college_settings(event.college_id)  # pseudocode fix: was referenced but never assigned

    busy, invited = combined_busy(event, date)
    gaps = generate_gaps(busy, college_settings, event.duration, event.venue_id, date)
    gaps = filter_by_required_members(gaps, event)

    if not gaps:
        return retry_next_day(event, date, _attempt=_attempt)  # recurse forward within cap

    ranked = rank_gaps(gaps, invited)
    best_gap, best_score = ranked[0]

    result = ScheduleResult(
        suggested_start=best_gap.start
        + dt.timedelta(minutes=college_settings.start_buffer_minutes),
        informing_time=best_gap.start
        + dt.timedelta(minutes=college_settings.inform_buffer_minutes),
        turnout_score=best_score,
        low_confidence=best_score < college_settings.min_viable_turnout,
        alternatives=ranked[1:4],  # show admin next-best options too
    )
    save_snapshot(event.id, result, inputs_used=busy)  # audit trail
    return result


# ============================================================
# STEP 7 — Clash detection (runs after a slot is confirmed, not suggested)
# ============================================================


def detect_clashes(event: Event) -> None:
    overlapping = get_events_overlapping(event.venue_id, event.actual_start, event.actual_end)
    for other in overlapping:
        record_clash(event.id, other.id, clash_type="venue", status="open")

    same_time_events = get_events_at_time(
        event.college_id, event.actual_start, event.actual_end
    )
    for other in same_time_events:
        if sections_overlap(event.event_target_sections, other.event_target_sections):
            record_clash(event.id, other.id, clash_type="audience", status="open")


# ============================================================
# Data access — Supabase-backed get_* / record_* functions
#
# All tables referenced below exist in database/schema.sql. None of the
# FastAPI routes that will eventually call into this module are wired up
# yet (see backend/routers/*.py) — that's the only thing still stubbed.
# ============================================================


def _parse_date(value: str) -> dt.date:
    return dt.date.fromisoformat(value)


def _parse_time(value: str) -> dt.time:
    return dt.time.fromisoformat(value)


def _parse_datetime(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value)


def get_academic_calendar(college_id: str, date: dt.date) -> CalendarEntry:
    resp = (
        get_supabase_client()
        .table("academic_calendar")
        .select("day_type, is_teaching_day")
        .eq("college_id", college_id)
        .eq("date", date.isoformat())
        .limit(1)
        .execute()
    )
    if resp.data:
        row = resp.data[0]
        return CalendarEntry(date=date, day_type=row["day_type"], is_teaching_day=row["is_teaching_day"])
    # No override row for this date: default to "normal" teaching day on
    # weekdays, non-teaching on weekends.
    return CalendarEntry(date=date, day_type="normal", is_teaching_day=weekday(date) < 5)


def get_college_settings(college_id: str) -> CollegeSettings:
    resp = (
        get_supabase_client()
        .table("college_settings")
        .select("*")
        .eq("college_id", college_id)
        .limit(1)
        .execute()
    )
    if not resp.data:
        raise ValueError(f"no college_settings row for college_id={college_id}")
    row = resp.data[0]
    return CollegeSettings(
        college_id=college_id,
        day_start=_parse_time(row["day_start"]),
        day_end=_parse_time(row["day_end"]),
        working_days=row["working_days"],
        default_turnover_minutes=row["default_turnover_minutes"],
        start_buffer_minutes=row["start_buffer_minutes"],
        inform_buffer_minutes=row["inform_buffer_minutes"],
        min_viable_turnout=row["min_viable_turnout"],
    )


def get_section_timetable(user_id: str, day: int, date: dt.date) -> list[Interval]:
    """Base weekly class schedule for `user_id`'s section on `day`,
    anchored to `date`, with `remove`-type user_timetable_overrides for
    that day already netted out (see module docstring)."""
    client = get_supabase_client()

    user_resp = client.table("users").select("section_id").eq("id", user_id).limit(1).execute()
    if not user_resp.data or not user_resp.data[0].get("section_id"):
        return []
    section_id = user_resp.data[0]["section_id"]

    slots_resp = (
        client.table("timetable_slots")
        .select("start_time, end_time")
        .eq("section_id", section_id)
        .eq("day_of_week", day)
        .execute()
    )
    base = [
        Interval(
            dt.datetime.combine(date, _parse_time(row["start_time"])),
            dt.datetime.combine(date, _parse_time(row["end_time"])),
        )
        for row in slots_resp.data
    ]

    removals_resp = (
        client.table("user_timetable_overrides")
        .select("start_time, end_time")
        .eq("user_id", user_id)
        .eq("day_of_week", day)
        .eq("type", "remove")
        .execute()
    )
    removals = [
        Interval(
            dt.datetime.combine(date, _parse_time(row["start_time"])),
            dt.datetime.combine(date, _parse_time(row["end_time"])),
        )
        for row in removals_resp.data
    ]

    return subtract_intervals(base, removals) if removals else base


def get_timetable_overrides(user_id: str, day: int, date: dt.date) -> list[Interval]:
    """`add`-type overrides only — `remove`-type overrides are applied
    inside get_section_timetable (see module docstring)."""
    resp = (
        get_supabase_client()
        .table("user_timetable_overrides")
        .select("start_time, end_time")
        .eq("user_id", user_id)
        .eq("day_of_week", day)
        .eq("type", "add")
        .execute()
    )
    return [
        Interval(
            dt.datetime.combine(date, _parse_time(row["start_time"])),
            dt.datetime.combine(date, _parse_time(row["end_time"])),
        )
        for row in resp.data
    ]


def get_mandatory_event_blocks(user_id: str, date: dt.date) -> list[Interval]:
    """club_only events targeting a section the user belongs to."""
    client = get_supabase_client()
    user_resp = client.table("users").select("section_id").eq("id", user_id).limit(1).execute()
    if not user_resp.data or not user_resp.data[0].get("section_id"):
        return []
    section_id = user_resp.data[0]["section_id"]

    target_resp = (
        client.table("event_target_sections")
        .select("event_id")
        .eq("section_id", section_id)
        .execute()
    )
    event_ids = [row["event_id"] for row in target_resp.data]
    if not event_ids:
        return []

    events_resp = (
        client.table("events")
        .select("start_time, end_time, actual_start, actual_end")
        .in_("id", event_ids)
        .eq("visibility", "club_only")
        .execute()
    )
    intervals = []
    for row in events_resp.data:
        start_raw = row.get("actual_start") or row.get("start_time")
        end_raw = row.get("actual_end") or row.get("end_time")
        if not start_raw or not end_raw:
            continue
        start = _parse_datetime(start_raw)
        if start.date() == date:
            intervals.append(Interval(start, _parse_datetime(end_raw)))
    return intervals


def get_rsvped_event_blocks(user_id: str, date: dt.date) -> list[Interval]:
    """Open events the user has opted into via event_rsvps(status='going')."""
    client = get_supabase_client()
    rsvp_resp = (
        client.table("event_rsvps")
        .select("event_id")
        .eq("user_id", user_id)
        .eq("status", "going")
        .execute()
    )
    event_ids = [row["event_id"] for row in rsvp_resp.data]
    if not event_ids:
        return []

    events_resp = (
        client.table("events")
        .select("start_time, end_time, actual_start, actual_end")
        .in_("id", event_ids)
        .execute()
    )
    intervals = []
    for row in events_resp.data:
        start_raw = row.get("actual_start") or row.get("start_time")
        end_raw = row.get("actual_end") or row.get("end_time")
        if not start_raw or not end_raw:
            continue
        start = _parse_datetime(start_raw)
        if start.date() == date:
            intervals.append(Interval(start, _parse_datetime(end_raw)))
    return intervals


def get_users_in_target_sections(event_target_sections: list[str]) -> list[UserRef]:
    if not event_target_sections:
        return []
    resp = (
        get_supabase_client()
        .table("users")
        .select("id, year")
        .in_("section_id", event_target_sections)
        .execute()
    )
    return [UserRef(id=row["id"], year=row.get("year")) for row in resp.data]


def get_event_key_members(event_id: str, required: bool = True) -> list[KeyMember]:
    resp = (
        get_supabase_client()
        .table("event_key_members")
        .select("user_id, required, users(year)")
        .eq("event_id", event_id)
        .eq("required", required)
        .execute()
    )
    members = []
    for row in resp.data:
        year = (row.get("users") or {}).get("year") if row.get("users") else None
        members.append(KeyMember(id=row["user_id"], required=row["required"], year=year))
    return members


def get_venue_bookings(venue_id: str, date: dt.date) -> list[Interval]:
    resp = (
        get_supabase_client()
        .table("events")
        .select("actual_start, actual_end")
        .eq("venue_id", venue_id)
        .not_.is_("actual_start", "null")
        .not_.is_("actual_end", "null")
        .execute()
    )
    intervals = []
    for row in resp.data:
        start = _parse_datetime(row["actual_start"])
        if start.date() == date:
            intervals.append(Interval(start, _parse_datetime(row["actual_end"])))
    return intervals


def get_events_overlapping(
    venue_id: Optional[str], start: Optional[dt.datetime], end: Optional[dt.datetime]
) -> list[Event]:
    if venue_id is None or start is None or end is None:
        return []
    resp = (
        get_supabase_client()
        .table("events")
        .select("id, college_id, club_id, venue_id, duration_minutes, actual_start, actual_end, event_target_sections(section_id)")
        .eq("venue_id", venue_id)
        .lt("actual_start", end.isoformat())
        .gt("actual_end", start.isoformat())
        .execute()
    )
    return [_row_to_event(row) for row in resp.data]


def get_events_at_time(
    college_id: str, start: Optional[dt.datetime], end: Optional[dt.datetime]
) -> list[Event]:
    if start is None or end is None:
        return []
    resp = (
        get_supabase_client()
        .table("events")
        .select("id, college_id, club_id, venue_id, duration_minutes, actual_start, actual_end, event_target_sections(section_id)")
        .eq("college_id", college_id)
        .lt("actual_start", end.isoformat())
        .gt("actual_end", start.isoformat())
        .execute()
    )
    return [_row_to_event(row) for row in resp.data]


def _row_to_event(row: dict) -> Event:
    target_sections = [ts["section_id"] for ts in row.get("event_target_sections") or []]
    return Event(
        id=row["id"],
        college_id=row["college_id"],
        club_id=row["club_id"],
        venue_id=row.get("venue_id"),
        duration_minutes=row.get("duration_minutes") or 0,
        event_target_sections=target_sections,
        actual_start=_parse_datetime(row["actual_start"]) if row.get("actual_start") else None,
        actual_end=_parse_datetime(row["actual_end"]) if row.get("actual_end") else None,
    )


def record_clash(event_a_id: str, event_b_id: str, clash_type: str, status: str) -> None:
    get_supabase_client().table("event_clashes").insert(
        {
            "event_a_id": event_a_id,
            "event_b_id": event_b_id,
            "type": clash_type,
            "status": status,
        }
    ).execute()


def save_snapshot(event_id: str, result: ScheduleResult, inputs_used: list[Interval]) -> None:
    inputs_json = [
        {"start": iv.start.isoformat(), "end": iv.end.isoformat()} for iv in inputs_used
    ]
    get_supabase_client().table("event_schedule_snapshots").insert(
        {
            "event_id": event_id,
            "computed_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "inputs_json": inputs_json,
            "suggested_start": result.suggested_start.isoformat(),
            "informing_time": result.informing_time.isoformat(),
        }
    ).execute()
