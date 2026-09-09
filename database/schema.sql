-- ============================================================
-- Clubster database schema
-- Target: Supabase (Postgres)
--
-- Apply via the Supabase SQL editor, or:
--   supabase db push
-- or
--   psql "$DATABASE_URL" -f database/schema.sql
-- ============================================================

create extension if not exists "pgcrypto";

-- ============================================================
-- Enums
-- ============================================================

create type membership_role as enum (
  'president',
  'vice_president',
  'secretary',
  'treasurer',
  'event_coordinator',
  'member'
);

create type event_type as enum (
  'meeting',
  'workshop',
  'fest',
  'trip',
  'planning',
  'other'
);

create type event_visibility as enum (
  'club_only',
  'college_open',
  'all_colleges_open'
);

create type attendance_method as enum (
  'qr',
  'roll_number_entry'
);

create type budget_entry_type as enum (
  'income',
  'expense'
);

create type notification_type as enum (
  'reminder',
  'event_created',
  'clash_warning',
  'general'
);

create type override_type as enum (
  'add',
  'remove'
);

create type rsvp_status as enum (
  'going',
  'maybe',
  'not_going'
);

create type calendar_day_type as enum (
  'holiday',
  'exam',
  'fest',
  'normal'
);

create type clash_type as enum (
  'venue',
  'audience'
);

create type clash_status as enum (
  'open',
  'acknowledged',
  'resolved'
);

-- ============================================================
-- Core identity / org structure
-- ============================================================

create table colleges (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  domain text unique,
  created_at timestamptz not null default now()
);

create table sections (
  id uuid primary key default gen_random_uuid(),
  college_id uuid not null references colleges(id) on delete cascade,
  name text not null,
  year int,
  created_at timestamptz not null default now()
);

-- id is expected to match auth.users.id when created via Supabase Auth.
create table users (
  id uuid primary key default gen_random_uuid(),
  college_id uuid not null references colleges(id) on delete cascade,
  section_id uuid references sections(id) on delete set null,
  full_name text not null,
  email text not null unique,
  roll_number text,
  year int,
  created_at timestamptz not null default now()
);

create table clubs (
  id uuid primary key default gen_random_uuid(),
  college_id uuid not null references colleges(id) on delete cascade,
  name text not null,
  description text,
  logo_url text,
  created_at timestamptz not null default now()
);

create table club_memberships (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  role membership_role not null default 'member',
  created_at timestamptz not null default now(),
  unique (club_id, user_id)
);

-- ============================================================
-- Timetables / venues
-- ============================================================

create table timetable_slots (
  id uuid primary key default gen_random_uuid(),
  section_id uuid not null references sections(id) on delete cascade,
  day_of_week int not null check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  subject text,
  room text,
  created_at timestamptz not null default now(),
  check (end_time > start_time)
);

create table venues (
  id uuid primary key default gen_random_uuid(),
  college_id uuid not null references colleges(id) on delete cascade,
  name text not null,
  capacity int,
  location text,
  created_at timestamptz not null default now()
);

-- ============================================================
-- Events
-- ============================================================

create table events (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  college_id uuid not null references colleges(id) on delete cascade,
  venue_id uuid references venues(id) on delete set null,
  title text not null,
  description text,
  event_type event_type not null default 'other',
  visibility event_visibility not null default 'club_only',
  status text not null default 'draft',
  -- planned/suggested window
  start_time timestamptz,
  end_time timestamptz,
  duration_minutes int,
  -- confirmed window, set once a slot is locked in (used by clash detection)
  actual_start timestamptz,
  actual_end timestamptz,
  created_by uuid references users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table event_target_sections (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  section_id uuid not null references sections(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (event_id, section_id)
);

create table event_attendance (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  method attendance_method not null,
  checked_in_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (event_id, user_id)
);

-- ============================================================
-- Sponsors / budgets
-- ============================================================

create table sponsors (
  id uuid primary key default gen_random_uuid(),
  college_id uuid not null references colleges(id) on delete cascade,
  club_id uuid references clubs(id) on delete set null,
  name text not null,
  contact_name text,
  contact_email text,
  contact_phone text,
  created_at timestamptz not null default now()
);

create table budgets (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references clubs(id) on delete cascade,
  event_id uuid references events(id) on delete set null,
  title text not null,
  allocated_amount numeric(12, 2),
  created_at timestamptz not null default now()
);

create table budget_entries (
  id uuid primary key default gen_random_uuid(),
  budget_id uuid not null references budgets(id) on delete cascade,
  type budget_entry_type not null,
  amount numeric(12, 2) not null,
  description text,
  entry_date date not null default current_date,
  created_by uuid references users(id) on delete set null,
  created_at timestamptz not null default now()
);

-- ============================================================
-- Notifications
-- ============================================================

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  type notification_type not null default 'general',
  title text not null,
  body text,
  related_event_id uuid references events(id) on delete set null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

-- ============================================================
-- Scheduling support tables
-- ============================================================

-- Per-user, per-weekday additions/removals layered on top of the
-- section's base timetable_slots (e.g. an elective that isn't shared by
-- the whole section).
create table user_timetable_overrides (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  day_of_week int not null check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  type override_type not null,
  created_at timestamptz not null default now(),
  check (end_time > start_time)
);

create table event_rsvps (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  status rsvp_status not null default 'maybe',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, user_id)
);

-- One row per college; tunable parameters for the scheduling algorithm.
create table college_settings (
  id uuid primary key default gen_random_uuid(),
  college_id uuid not null unique references colleges(id) on delete cascade,
  day_start time not null default '09:00',
  day_end time not null default '17:00',
  working_days int[] not null default '{1,2,3,4,5}',
  default_turnover_minutes int not null default 10,
  start_buffer_minutes int not null default 5,
  inform_buffer_minutes int not null default 60,
  min_viable_turnout numeric(5, 2) not null default 50.0,
  created_at timestamptz not null default now()
);

create table academic_calendar (
  id uuid primary key default gen_random_uuid(),
  college_id uuid not null references colleges(id) on delete cascade,
  date date not null,
  day_type calendar_day_type not null default 'normal',
  is_teaching_day boolean not null default true,
  created_at timestamptz not null default now(),
  unique (college_id, date)
);

create table event_key_members (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  required boolean not null default true,
  created_at timestamptz not null default now(),
  unique (event_id, user_id)
);

create table event_clashes (
  id uuid primary key default gen_random_uuid(),
  event_a_id uuid not null references events(id) on delete cascade,
  event_b_id uuid not null references events(id) on delete cascade,
  type clash_type not null,
  status clash_status not null default 'open',
  resolution_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (event_a_id <> event_b_id)
);

create table event_schedule_snapshots (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references events(id) on delete cascade,
  computed_at timestamptz not null default now(),
  inputs_json jsonb,
  suggested_start timestamptz,
  informing_time timestamptz,
  created_at timestamptz not null default now()
);

-- ============================================================
-- Indexes
-- ============================================================

create index idx_users_college_id on users (college_id);
create index idx_users_section_id on users (section_id);
create index idx_club_memberships_user_id on club_memberships (user_id);
create index idx_club_memberships_club_id on club_memberships (club_id);
create index idx_sections_college_id on sections (college_id);
create index idx_timetable_slots_section_id on timetable_slots (section_id);
create index idx_venues_college_id on venues (college_id);
create index idx_events_club_id on events (club_id);
create index idx_events_college_id on events (college_id);
create index idx_events_venue_id on events (venue_id);
create index idx_event_target_sections_event_id on event_target_sections (event_id);
create index idx_event_target_sections_section_id on event_target_sections (section_id);
create index idx_event_attendance_event_id on event_attendance (event_id);
create index idx_budgets_club_id on budgets (club_id);
create index idx_budget_entries_budget_id on budget_entries (budget_id);
create index idx_notifications_user_id on notifications (user_id);
create index idx_user_timetable_overrides_user_id on user_timetable_overrides (user_id);
create index idx_event_rsvps_event_id on event_rsvps (event_id);
create index idx_event_rsvps_user_id on event_rsvps (user_id);
create index idx_academic_calendar_college_date on academic_calendar (college_id, date);
create index idx_event_key_members_event_id on event_key_members (event_id);
create index idx_event_clashes_event_a_id on event_clashes (event_a_id);
create index idx_event_clashes_event_b_id on event_clashes (event_b_id);
create index idx_event_schedule_snapshots_event_id on event_schedule_snapshots (event_id);
