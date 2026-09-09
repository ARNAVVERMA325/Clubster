import datetime as dt

import core.scheduler as scheduler
from core.scheduler import (
    CalendarEntry,
    CollegeSettings,
    Event,
    Gap,
    Interval,
    KeyMember,
    NoSlotFound,
    UserRef,
    filter_by_required_members,
    find_valid_date,
    generate_gaps,
    rank_gaps,
)


def make_settings(**overrides):
    defaults = dict(
        college_id="college-1",
        day_start=dt.time(9, 0),
        day_end=dt.time(17, 0),
        working_days=[0, 1, 2, 3, 4],
        default_turnover_minutes=10,
        start_buffer_minutes=5,
        inform_buffer_minutes=60,
        min_viable_turnout=50.0,
    )
    defaults.update(overrides)
    return CollegeSettings(**defaults)


# ============================================================
# No free gap exists
# ============================================================


def test_generate_gaps_returns_empty_when_day_fully_busy():
    date = dt.date(2026, 1, 5)  # Monday
    settings = make_settings()
    busy = [
        Interval(
            dt.datetime.combine(date, dt.time(9, 0)),
            dt.datetime.combine(date, dt.time(17, 0)),
        )
    ]

    gaps = generate_gaps(busy, settings, dt.timedelta(minutes=30), venue=None, date=date)

    assert gaps == []


def test_suggest_slot_returns_no_slot_found_when_every_day_is_fully_busy(monkeypatch):
    date = dt.date(2026, 1, 5)
    settings = make_settings()
    event = Event(
        id="event-1",
        college_id="college-1",
        club_id="club-1",
        venue_id=None,
        duration_minutes=30,
        event_target_sections=["section-1"],
    )

    monkeypatch.setattr(
        scheduler, "get_academic_calendar", lambda college_id, d: CalendarEntry(d, "normal", True)
    )
    monkeypatch.setattr(scheduler, "get_college_settings", lambda college_id: settings)

    def always_full_day_busy(ev, d):
        busy = [
            Interval(
                dt.datetime.combine(d, dt.time(9, 0)),
                dt.datetime.combine(d, dt.time(17, 0)),
            )
        ]
        return busy, [UserRef(id="u1", year=1)]

    monkeypatch.setattr(scheduler, "combined_busy", always_full_day_busy)
    monkeypatch.setattr(scheduler, "get_event_key_members", lambda event_id, required=True: [])
    monkeypatch.setattr(scheduler, "save_snapshot", lambda *a, **k: None)

    result = scheduler.suggest_slot(event, date)

    assert result == NoSlotFound()


# ============================================================
# Required member blocks all gaps
# ============================================================


def test_required_member_blocks_all_gaps(monkeypatch):
    date = dt.date(2026, 1, 5)
    gap_morning = Gap(
        dt.datetime(2026, 1, 5, 10, 0), dt.datetime(2026, 1, 5, 11, 0), date
    )
    gap_afternoon = Gap(
        dt.datetime(2026, 1, 5, 13, 0), dt.datetime(2026, 1, 5, 14, 0), date
    )
    event = Event(
        id="event-1",
        college_id="college-1",
        club_id="club-1",
        venue_id=None,
        duration_minutes=60,
        event_target_sections=["section-1"],
    )

    monkeypatch.setattr(
        scheduler,
        "get_event_key_members",
        lambda event_id, required=True: [KeyMember(id="required-user", required=True)],
    )
    # required member is busy across the entire day -> every gap is invalid
    full_day_busy = [
        Interval(
            dt.datetime.combine(date, dt.time(9, 0)),
            dt.datetime.combine(date, dt.time(17, 0)),
        )
    ]
    monkeypatch.setattr(scheduler, "effective_busy", lambda user_id, d: full_day_busy)

    result = filter_by_required_members([gap_morning, gap_afternoon], event)

    assert result == []


def test_required_member_free_gap_survives_filter(monkeypatch):
    date = dt.date(2026, 1, 5)
    gap_free = Gap(dt.datetime(2026, 1, 5, 10, 0), dt.datetime(2026, 1, 5, 11, 0), date)
    event = Event(
        id="event-1",
        college_id="college-1",
        club_id="club-1",
        venue_id=None,
        duration_minutes=60,
        event_target_sections=["section-1"],
    )

    monkeypatch.setattr(
        scheduler,
        "get_event_key_members",
        lambda event_id, required=True: [KeyMember(id="required-user", required=True)],
    )
    monkeypatch.setattr(scheduler, "effective_busy", lambda user_id, d: [])

    result = filter_by_required_members([gap_free], event)

    assert result == [gap_free]


# ============================================================
# Tie-broken scoring
# ============================================================


def test_rank_gaps_tie_break_by_date_then_duration(monkeypatch):
    d1 = dt.date(2026, 1, 5)
    d2 = dt.date(2026, 1, 6)

    gap_later_date = Gap(dt.datetime(2026, 1, 6, 10, 0), dt.datetime(2026, 1, 6, 10, 30), d2)
    gap_earlier_long = Gap(dt.datetime(2026, 1, 5, 10, 0), dt.datetime(2026, 1, 5, 11, 30), d1)
    gap_earlier_short = Gap(dt.datetime(2026, 1, 5, 13, 0), dt.datetime(2026, 1, 5, 13, 30), d1)

    # every gap ties on score, so only the tie-break rule decides order
    monkeypatch.setattr(scheduler, "score_gap", lambda gap, invited: 80.0)

    ranked = rank_gaps([gap_later_date, gap_earlier_short, gap_earlier_long], invited_users=[])

    assert [gap for gap, _ in ranked] == [gap_earlier_long, gap_earlier_short, gap_later_date]


def test_rank_gaps_orders_by_score_when_not_tied(monkeypatch):
    date = dt.date(2026, 1, 5)
    gap_high = Gap(dt.datetime(2026, 1, 5, 9, 0), dt.datetime(2026, 1, 5, 10, 0), date)
    gap_low = Gap(dt.datetime(2026, 1, 5, 11, 0), dt.datetime(2026, 1, 5, 12, 0), date)

    scores = {id(gap_high): 90.0, id(gap_low): 40.0}
    monkeypatch.setattr(scheduler, "score_gap", lambda gap, invited: scores[id(gap)])

    ranked = rank_gaps([gap_low, gap_high], invited_users=[])

    assert [gap for gap, _ in ranked] == [gap_high, gap_low]


# ============================================================
# Date rollover past a holiday in academic_calendar
# ============================================================


def test_find_valid_date_rolls_over_a_holiday(monkeypatch):
    holiday = dt.date(2026, 1, 5)
    next_day = dt.date(2026, 1, 6)
    calendar = {
        holiday: CalendarEntry(holiday, "holiday", False),
        next_day: CalendarEntry(next_day, "normal", True),
    }
    monkeypatch.setattr(scheduler, "get_academic_calendar", lambda college_id, d: calendar[d])

    result = find_valid_date("college-1", holiday, max_days_forward=5)

    assert result == next_day


def test_find_valid_date_returns_none_when_window_is_all_holidays(monkeypatch):
    monkeypatch.setattr(
        scheduler, "get_academic_calendar", lambda college_id, d: CalendarEntry(d, "holiday", False)
    )

    result = find_valid_date("college-1", dt.date(2026, 1, 5), max_days_forward=3)

    assert result is None
