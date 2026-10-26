-- {{CLIENT_CODE_UPPER}}: pg-booking 053 -- administrator functions (services, staff links,
-- schedule, exceptions, phone bookings, day view).
-- 050-052 are not rewritten: this file only adds. Everything here is
-- SECURITY DEFINER in the same style as 051; n8n_runtime gets EXECUTE on the
-- public functions and no table access.
--
-- Access model. The list of administrators is the table admins(max_user_id).
-- is_admin(user_id) answers "is this MAX user an administrator". Every admin_*
-- function takes the caller's MAX user id as its first argument and refuses
-- with 'not an administrator' when it is not in admins. The database cannot
-- tell who really sent the message: the id comes from n8n, so the protection
-- holds only while n8n takes the sender id from the MAX event itself and never
-- from text typed by the user.
-- Administrators are added by the operator with psql (see 00_ШАПКА.md); there
-- is deliberately no function that adds an administrator.
--
-- Update convention (KB-01#33): a NULL argument means "keep the current value".
--
-- Phone bookings. admin_create_appointment reuses the same protection against a
-- double booking as create_appointment (FOR UPDATE on the slot run, status
-- check, partial unique index appointments_active_slot_uidx). The customer gave
-- no consent through the bot, so nothing is written to the consent journal and
-- appointments.consent_event_uuid becomes nullable for such rows; no reminders
-- are planned for them (the customer has no MAX channel).

\set ON_ERROR_STOP on

BEGIN;

-- ---------- Preflight (full signatures, KB-02#10) ----------

DO $preflight$
BEGIN
  IF to_regclass('{{CLIENT_CODE}}_booking.appointments') IS NULL THEN
    RAISE EXCEPTION '053 preflight: {{CLIENT_CODE}}_booking core schema (050) is missing';
  END IF;
  IF to_regprocedure('{{CLIENT_CODE}}_booking.generate_slots(date,date)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.free_slots(uuid,uuid,date,date)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.list_services()') IS NULL THEN
    RAISE EXCEPTION '053 preflight: booking API (051) is missing';
  END IF;
END
$preflight$;

-- ---------- Administrators ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.admins (
  max_user_id bigint PRIMARY KEY,
  display_name text,
  is_active boolean NOT NULL DEFAULT true,
  added_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (display_name IS NULL OR char_length(display_name) <= 160)
);

ALTER TABLE {{CLIENT_CODE}}_booking.admins OWNER TO {{CLIENT_CODE}};
REVOKE ALL ON TABLE {{CLIENT_CODE}}_booking.admins FROM PUBLIC;

-- A booking made by an administrator on behalf of a customer has no consent
-- event in the journal (see the header).
ALTER TABLE {{CLIENT_CODE}}_booking.appointments
  ALTER COLUMN consent_event_uuid DROP NOT NULL;

-- ---------- Access checks ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.is_admin(p_user_id bigint)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM {{CLIENT_CODE}}_booking.admins AS ad
    WHERE ad.max_user_id = p_user_id AND ad.is_active = true
  );
$fn$;

-- Internal: not granted to anyone, called only from the functions below.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.require_admin(p_user_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
BEGIN
  IF p_user_id IS NULL OR NOT {{CLIENT_CODE}}_booking.is_admin(p_user_id) THEN
    RAISE EXCEPTION 'not an administrator';
  END IF;
END
$fn$;

-- Internal: does the window [p_starts, p_ends) fit the staff member's working
-- hours on that date? Same rules as generate_slots (051): an exception for the
-- date wins (day off = no, otherwise its own hours), else the work_schedule row
-- for the weekday with the latest valid_from; only active staff.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.slot_in_schedule(
  p_staff_id uuid,
  p_starts timestamptz,
  p_ends timestamptz
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_day date := p_starts::date;
  v_is_working boolean;
  v_start time;
  v_end time;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.staff AS st
    WHERE st.staff_id = p_staff_id AND st.is_active = true
  ) THEN
    RETURN false;
  END IF;

  SELECT e.is_working, e.starts_time, e.ends_time
  INTO v_is_working, v_start, v_end
  FROM {{CLIENT_CODE}}_booking.schedule_exceptions AS e
  WHERE e.staff_id = p_staff_id AND e.exception_date = v_day;
  IF FOUND THEN
    IF NOT v_is_working THEN
      RETURN false;
    END IF;
  ELSE
    SELECT w.starts_time, w.ends_time
    INTO v_start, v_end
    FROM {{CLIENT_CODE}}_booking.work_schedule AS w
    WHERE w.staff_id = p_staff_id
      AND w.weekday = EXTRACT(DOW FROM v_day)::smallint
      AND w.valid_from <= v_day
      AND (w.valid_to IS NULL OR w.valid_to >= v_day)
    ORDER BY w.valid_from DESC
    LIMIT 1;
  END IF;

  IF v_start IS NULL OR v_end IS NULL THEN
    RETURN false;
  END IF;
  RETURN p_starts >= v_day::timestamp + v_start
     AND p_ends <= v_day::timestamp + v_end;
END
$fn$;

-- Internal: give the slots of a cancelled appointment back. A slot becomes
-- 'free' only when it still fits the staff member's current schedule for its
-- date and does not overlap another slot of the staff member (a leftover of an
-- old grid next to a new one); otherwise it is 'closed' (a day off or shifted hours must not
-- reappear in free_slots just because a booking was cancelled).
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.release_appointment_slots(p_appointment_uuid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
BEGIN
  UPDATE {{CLIENT_CODE}}_booking.slots AS sl
  SET status = CASE
        WHEN {{CLIENT_CODE}}_booking.slot_in_schedule(sl.staff_id, sl.starts_at, sl.ends_at)
             AND NOT EXISTS (
               SELECT 1 FROM {{CLIENT_CODE}}_booking.slots AS ot
               WHERE ot.staff_id = sl.staff_id AND ot.slot_id <> sl.slot_id
                 AND ot.starts_at < sl.ends_at AND ot.ends_at > sl.starts_at
             )
          THEN 'free' ELSE 'closed' END,
      appointment_uuid = NULL
  WHERE sl.appointment_uuid = p_appointment_uuid;
END
$fn$;

-- Internal: rebuild the free slots of one staff member for a date range after a
-- schedule change. Booked/held slots are never touched. A free/closed slot that
-- an appointment row still points to (a cancelled booking; appointments.slot_id
-- has no ON DELETE) cannot be deleted: it is kept and set to 'free' or 'closed'
-- by the new schedule. A regenerated free slot that would overlap a booked or
-- held one is closed. removed_slots = deleted rows; created_slots = rows of
-- this staff member added by the regeneration.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.resync_staff_slots(
  p_staff_id uuid,
  p_from date,
  p_to date
)
RETURNS TABLE(removed_slots int, created_slots int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_from date := GREATEST(p_from, current_date);
  v_removed int := 0;
  v_before bigint;
  v_after bigint;
BEGIN
  IF p_to < v_from THEN
    RETURN QUERY SELECT 0, 0;
    RETURN;
  END IF;

  DELETE FROM {{CLIENT_CODE}}_booking.slots AS sl
  WHERE sl.staff_id = p_staff_id
    AND sl.status IN ('free', 'closed')
    AND sl.starts_at >= v_from::timestamptz
    AND sl.starts_at < (p_to + 1)::timestamptz
    AND NOT EXISTS (
      SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments AS ap WHERE ap.slot_id = sl.slot_id
    );
  GET DIAGNOSTICS v_removed = ROW_COUNT;

  SELECT count(*) INTO v_before
  FROM {{CLIENT_CODE}}_booking.slots AS sl
  WHERE sl.staff_id = p_staff_id
    AND sl.starts_at >= v_from::timestamptz
    AND sl.starts_at < (p_to + 1)::timestamptz;

  PERFORM {{CLIENT_CODE}}_booking.generate_slots(v_from, p_to);

  SELECT count(*) INTO v_after
  FROM {{CLIENT_CODE}}_booking.slots AS sl
  WHERE sl.staff_id = p_staff_id
    AND sl.starts_at >= v_from::timestamptz
    AND sl.starts_at < (p_to + 1)::timestamptz;

  -- kept slots of cancelled bookings follow the new schedule
  UPDATE {{CLIENT_CODE}}_booking.slots AS kp
  SET status = CASE
        WHEN {{CLIENT_CODE}}_booking.slot_in_schedule(kp.staff_id, kp.starts_at, kp.ends_at)
             AND NOT EXISTS (
               SELECT 1 FROM {{CLIENT_CODE}}_booking.slots AS ot
               WHERE ot.staff_id = kp.staff_id AND ot.slot_id <> kp.slot_id
                 AND ot.starts_at < kp.ends_at AND ot.ends_at > kp.starts_at
             )
          THEN 'free' ELSE 'closed' END
  WHERE kp.staff_id = p_staff_id
    AND kp.status IN ('free', 'closed')
    AND kp.appointment_uuid IS NULL
    AND kp.starts_at >= v_from::timestamptz
    AND kp.starts_at < (p_to + 1)::timestamptz
    AND EXISTS (
      SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments AS ap WHERE ap.slot_id = kp.slot_id
    );

  UPDATE {{CLIENT_CODE}}_booking.slots AS fr
  SET status = 'closed'
  WHERE fr.staff_id = p_staff_id
    AND fr.status = 'free'
    AND fr.starts_at >= v_from::timestamptz
    AND fr.starts_at < (p_to + 1)::timestamptz
    AND EXISTS (
      SELECT 1 FROM {{CLIENT_CODE}}_booking.slots AS bk
      WHERE bk.staff_id = fr.staff_id
        AND bk.status IN ('booked', 'held')
        AND bk.starts_at < fr.ends_at
        AND bk.ends_at > fr.starts_at
    );

  RETURN QUERY SELECT v_removed, (v_after - v_before)::int;
END
$fn$;

-- ---------- Services ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_list_services(p_admin_user_id bigint)
RETURNS TABLE(
  service_id uuid,
  code text,
  title text,
  duration_minutes int,
  price_minor bigint,
  is_active boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  RETURN QUERY
    SELECT sv.service_id, sv.code, sv.title, sv.duration_minutes, sv.price_minor, sv.is_active
    FROM {{CLIENT_CODE}}_booking.services AS sv
    ORDER BY sv.sort_order, sv.title;
END
$fn$;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_add_service(
  p_admin_user_id bigint,
  p_title text,
  p_duration_minutes int,
  p_price_minor bigint,
  p_code text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_title text := NULLIF(btrim(COALESCE(p_title, '')), '');
  v_code text := NULLIF(btrim(COALESCE(p_code, '')), '');
  v_service_id uuid;
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF v_title IS NULL OR char_length(v_title) > 160 THEN
    RAISE EXCEPTION 'invalid service title';
  END IF;
  IF p_duration_minutes IS NULL OR p_duration_minutes NOT BETWEEN 5 AND 480 THEN
    RAISE EXCEPTION 'invalid service duration';
  END IF;
  IF p_price_minor IS NOT NULL AND p_price_minor < 0 THEN
    RAISE EXCEPTION 'invalid service price';
  END IF;
  IF v_code IS NULL THEN
    v_code := 'svc-' || substr(encode(public.gen_random_bytes(6), 'hex'), 1, 10);
  END IF;
  IF char_length(v_code) > 60 THEN
    RAISE EXCEPTION 'invalid service code';
  END IF;

  INSERT INTO {{CLIENT_CODE}}_booking.services (code, title, duration_minutes, price_minor, sort_order)
  VALUES (
    v_code, v_title, p_duration_minutes, p_price_minor,
    COALESCE((SELECT max(s0.sort_order) FROM {{CLIENT_CODE}}_booking.services AS s0), 0) + 10
  )
  RETURNING services.service_id INTO v_service_id;

  RETURN v_service_id;
END
$fn$;

-- NULL keeps the current value; p_clear_price = true removes the price.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_update_service(
  p_admin_user_id bigint,
  p_service_id uuid,
  p_title text DEFAULT NULL,
  p_duration_minutes int DEFAULT NULL,
  p_price_minor bigint DEFAULT NULL,
  p_clear_price boolean DEFAULT false
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_title text := NULLIF(btrim(COALESCE(p_title, '')), '');
  v_rows int;
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF v_title IS NOT NULL AND char_length(v_title) > 160 THEN
    RAISE EXCEPTION 'invalid service title';
  END IF;
  IF p_duration_minutes IS NOT NULL AND p_duration_minutes NOT BETWEEN 5 AND 480 THEN
    RAISE EXCEPTION 'invalid service duration';
  END IF;
  IF p_price_minor IS NOT NULL AND p_price_minor < 0 THEN
    RAISE EXCEPTION 'invalid service price';
  END IF;

  UPDATE {{CLIENT_CODE}}_booking.services AS sv
  SET title = COALESCE(v_title, sv.title),
      duration_minutes = COALESCE(p_duration_minutes, sv.duration_minutes),
      price_minor = CASE
                      WHEN p_clear_price THEN NULL
                      ELSE COALESCE(p_price_minor, sv.price_minor)
                    END
  WHERE sv.service_id = p_service_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows > 0;
END
$fn$;

-- Hide (false) or return (true) a service. A hidden service disappears from
-- list_services / free_slots; existing appointments are not touched.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_set_service_active(
  p_admin_user_id bigint,
  p_service_id uuid,
  p_active boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_rows int;
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF p_active IS NULL THEN
    RAISE EXCEPTION 'active flag is required';
  END IF;

  UPDATE {{CLIENT_CODE}}_booking.services AS sv
  SET is_active = p_active
  WHERE sv.service_id = p_service_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows > 0;
END
$fn$;

-- ---------- Staff ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_list_staff(p_admin_user_id bigint)
RETURNS TABLE(
  staff_id uuid,
  code text,
  display_name text,
  is_active boolean,
  service_ids uuid[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  RETURN QUERY
    SELECT
      st.staff_id, st.code, st.display_name, st.is_active,
      COALESCE(
        (SELECT array_agg(ss.service_id ORDER BY ss.service_id)
         FROM {{CLIENT_CODE}}_booking.staff_services AS ss
         WHERE ss.staff_id = st.staff_id),
        ARRAY[]::uuid[]
      )
    FROM {{CLIENT_CODE}}_booking.staff AS st
    ORDER BY st.sort_order, st.display_name;
END
$fn$;

-- Returns true when the link was created / removed, false when nothing changed.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_link_staff_service(
  p_admin_user_id bigint,
  p_staff_id uuid,
  p_service_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_rows int;
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.staff AS st WHERE st.staff_id = p_staff_id) THEN
    RAISE EXCEPTION 'unknown staff';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.services AS sv WHERE sv.service_id = p_service_id) THEN
    RAISE EXCEPTION 'unknown service';
  END IF;

  INSERT INTO {{CLIENT_CODE}}_booking.staff_services (staff_id, service_id)
  VALUES (p_staff_id, p_service_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows > 0;
END
$fn$;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_unlink_staff_service(
  p_admin_user_id bigint,
  p_staff_id uuid,
  p_service_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_rows int;
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);

  DELETE FROM {{CLIENT_CODE}}_booking.staff_services AS ss
  WHERE ss.staff_id = p_staff_id AND ss.service_id = p_service_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows > 0;
END
$fn$;

-- ---------- Working hours and exceptions ----------

-- Set the regular working hours for a weekday (0 = Sunday .. 6 = Saturday) from
-- today on. Both times NULL = the weekday becomes a regular day off. Free slots
-- of the staff member are rebuilt over the booking horizon.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_set_work_hours(
  p_admin_user_id bigint,
  p_staff_id uuid,
  p_weekday int,
  p_starts_time time,
  p_ends_time time
)
RETURNS TABLE(removed_slots int, created_slots int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_horizon int := COALESCE({{CLIENT_CODE}}_booking.setting_int('horizon_days'), 0);
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.staff AS st WHERE st.staff_id = p_staff_id) THEN
    RAISE EXCEPTION 'unknown staff';
  END IF;
  IF p_weekday IS NULL OR p_weekday NOT BETWEEN 0 AND 6 THEN
    RAISE EXCEPTION 'invalid weekday';
  END IF;
  IF (p_starts_time IS NULL) <> (p_ends_time IS NULL) THEN
    RAISE EXCEPTION 'both start and end time are required (or neither for a day off)';
  END IF;
  IF p_starts_time IS NOT NULL AND p_ends_time <= p_starts_time THEN
    RAISE EXCEPTION 'end time must be after start time';
  END IF;

  -- Rows that start today or later are replaced; older open rows end yesterday.
  DELETE FROM {{CLIENT_CODE}}_booking.work_schedule AS w
  WHERE w.staff_id = p_staff_id AND w.weekday = p_weekday AND w.valid_from >= current_date;

  UPDATE {{CLIENT_CODE}}_booking.work_schedule AS w
  SET valid_to = current_date - 1
  WHERE w.staff_id = p_staff_id AND w.weekday = p_weekday
    AND (w.valid_to IS NULL OR w.valid_to >= current_date);

  IF p_starts_time IS NOT NULL THEN
    INSERT INTO {{CLIENT_CODE}}_booking.work_schedule (staff_id, weekday, starts_time, ends_time, valid_from)
    VALUES (p_staff_id, p_weekday, p_starts_time, p_ends_time, current_date);
  END IF;

  RETURN QUERY
    SELECT r.removed_slots, r.created_slots
    FROM {{CLIENT_CODE}}_booking.resync_staff_slots(p_staff_id, current_date, current_date + v_horizon) AS r;
END
$fn$;

-- Day off (p_is_working = false) or special hours (p_is_working = true with
-- both times) for one date. Free slots of that date are rebuilt. Existing
-- appointments are NOT cancelled: their count is returned so the administrator
-- can call the customers.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_set_exception(
  p_admin_user_id bigint,
  p_staff_id uuid,
  p_date date,
  p_is_working boolean,
  p_starts_time time DEFAULT NULL,
  p_ends_time time DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS TABLE(removed_slots int, created_slots int, active_appointments int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_removed int;
  v_created int;
  v_active int;
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.staff AS st WHERE st.staff_id = p_staff_id) THEN
    RAISE EXCEPTION 'unknown staff';
  END IF;
  IF p_date IS NULL OR p_date < current_date THEN
    RAISE EXCEPTION 'date must be today or later';
  END IF;
  IF p_is_working IS NULL THEN
    RAISE EXCEPTION 'working flag is required';
  END IF;
  IF p_is_working AND (p_starts_time IS NULL OR p_ends_time IS NULL OR p_ends_time <= p_starts_time) THEN
    RAISE EXCEPTION 'working exception needs start and end time (end after start)';
  END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 300 THEN
    RAISE EXCEPTION 'note too long';
  END IF;

  INSERT INTO {{CLIENT_CODE}}_booking.schedule_exceptions AS ex
    (staff_id, exception_date, is_working, starts_time, ends_time, note)
  VALUES (
    p_staff_id, p_date, p_is_working,
    CASE WHEN p_is_working THEN p_starts_time END,
    CASE WHEN p_is_working THEN p_ends_time END,
    v_note
  )
  ON CONFLICT (staff_id, exception_date) DO UPDATE
  SET is_working = EXCLUDED.is_working,
      starts_time = EXCLUDED.starts_time,
      ends_time = EXCLUDED.ends_time,
      note = EXCLUDED.note;

  SELECT r.removed_slots, r.created_slots INTO v_removed, v_created
  FROM {{CLIENT_CODE}}_booking.resync_staff_slots(p_staff_id, p_date, p_date) AS r;

  SELECT count(*)::int INTO v_active
  FROM {{CLIENT_CODE}}_booking.appointments AS a
  WHERE a.staff_id = p_staff_id
    AND a.status IN ('planned', 'confirmed')
    AND a.starts_at >= p_date::timestamptz
    AND a.starts_at < (p_date + 1)::timestamptz;

  RETURN QUERY SELECT v_removed, v_created, v_active;
END
$fn$;

-- Cancel the exception: the regular weekday schedule applies again.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_remove_exception(
  p_admin_user_id bigint,
  p_staff_id uuid,
  p_date date
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_rows int;
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'date is required';
  END IF;

  DELETE FROM {{CLIENT_CODE}}_booking.schedule_exceptions AS ex
  WHERE ex.staff_id = p_staff_id AND ex.exception_date = p_date;
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows > 0 AND p_date >= current_date THEN
    PERFORM r.removed_slots
    FROM {{CLIENT_CODE}}_booking.resync_staff_slots(p_staff_id, p_date, p_date) AS r;
  END IF;

  RETURN v_rows > 0;
END
$fn$;

-- ---------- Appointments ----------

-- A booking taken by phone: name and phone only, no MAX. Same slot locking and
-- double-booking protection as create_appointment. Repeating the call with the
-- same p_appointment_uuid for the same slot returns the existing booking.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_create_appointment(
  p_admin_user_id bigint,
  p_appointment_uuid uuid,
  p_service_id uuid,
  p_slot_id uuid,
  p_name text,
  p_phone text,
  p_comment text DEFAULT NULL
)
RETURNS TABLE(
  appointment_id uuid,
  starts_at timestamptz,
  ends_at timestamptz,
  status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_phone_raw text := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_phone text;
  v_comment text := NULLIF(btrim(COALESCE(p_comment, '')), '');
  v_existing {{CLIENT_CODE}}_booking.appointments%ROWTYPE;
  v_service {{CLIENT_CODE}}_booking.services%ROWTYPE;
  v_first_slot {{CLIENT_CODE}}_booking.slots%ROWTYPE;
  v_step int;
  v_needed int;
  v_slot_ids uuid[];
  v_slot_count int;
  v_expected_end timestamptz;
  v_customer_id uuid;
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF p_appointment_uuid IS NULL OR p_service_id IS NULL OR p_slot_id IS NULL THEN
    RAISE EXCEPTION 'missing appointment identifiers';
  END IF;
  IF v_phone_raw IS NULL THEN
    RAISE EXCEPTION 'phone is required';
  END IF;
  v_phone := regexp_replace(v_phone_raw, '\D', '', 'g');
  IF v_phone !~ '^\d{10,15}$' THEN
    RAISE EXCEPTION 'invalid phone';
  END IF;
  IF v_name IS NOT NULL AND char_length(v_name) > 160 THEN
    RAISE EXCEPTION 'name too long';
  END IF;
  IF v_comment IS NOT NULL AND char_length(v_comment) > 1000 THEN
    RAISE EXCEPTION 'comment too long';
  END IF;

  SELECT * INTO v_existing
  FROM {{CLIENT_CODE}}_booking.appointments AS ap
  WHERE ap.appointment_uuid = p_appointment_uuid;
  IF FOUND THEN
    IF v_existing.service_id IS DISTINCT FROM p_service_id
       OR v_existing.slot_id IS DISTINCT FROM p_slot_id THEN
      RAISE EXCEPTION 'appointment UUID conflicts with an existing booking';
    END IF;
    RETURN QUERY
      SELECT v_existing.appointment_uuid, v_existing.starts_at, v_existing.ends_at, v_existing.status;
    RETURN;
  END IF;

  SELECT * INTO v_service
  FROM {{CLIENT_CODE}}_booking.services AS sv
  WHERE sv.service_id = p_service_id AND sv.is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown or inactive service';
  END IF;

  SELECT * INTO v_first_slot
  FROM {{CLIENT_CODE}}_booking.slots AS sl
  WHERE sl.slot_id = p_slot_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown slot';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.staff AS st
    WHERE st.staff_id = v_first_slot.staff_id AND st.is_active = true
  ) THEN
    RAISE EXCEPTION 'staff is not active';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.staff_services AS ss
    WHERE ss.staff_id = v_first_slot.staff_id AND ss.service_id = p_service_id
  ) THEN
    RAISE EXCEPTION 'staff does not provide this service';
  END IF;

  v_step := {{CLIENT_CODE}}_booking.setting_int('slot_step_minutes');
  IF v_step IS NULL OR v_step < 1 THEN
    RAISE EXCEPTION 'slot_step_minutes setting is not configured';
  END IF;
  v_needed := ceil(v_service.duration_minutes::numeric / v_step)::int;

  IF v_first_slot.starts_at < clock_timestamp() THEN
    RAISE EXCEPTION 'slot is in the past';
  END IF;

  SELECT array_agg(cand.slot_id ORDER BY cand.starts_at), count(*), max(cand.ends_at)
  INTO v_slot_ids, v_slot_count, v_expected_end
  FROM (
    SELECT sl.slot_id, sl.starts_at, sl.ends_at, sl.status
    FROM {{CLIENT_CODE}}_booking.slots AS sl
    WHERE sl.staff_id = v_first_slot.staff_id
      AND sl.starts_at >= v_first_slot.starts_at
      AND sl.starts_at < v_first_slot.starts_at + make_interval(mins => v_step * v_needed)
    ORDER BY sl.starts_at
    FOR UPDATE
  ) AS cand;

  IF v_slot_count IS DISTINCT FROM v_needed THEN
    RAISE EXCEPTION 'slot is no longer available';
  END IF;

  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.slots AS sl
    WHERE sl.slot_id = ANY(v_slot_ids) AND sl.status <> 'free'
  ) THEN
    RAISE EXCEPTION 'slot is no longer available';
  END IF;

  SELECT cu.customer_id INTO v_customer_id
  FROM {{CLIENT_CODE}}_booking.customers AS cu
  WHERE cu.phone_e164 = v_phone;

  IF NOT FOUND THEN
    INSERT INTO {{CLIENT_CODE}}_booking.customers (customer_id, phone_e164, display_name)
    VALUES (gen_random_uuid(), v_phone, v_name)
    RETURNING customers.customer_id INTO v_customer_id;
  ELSE
    UPDATE {{CLIENT_CODE}}_booking.customers AS cu
    SET display_name = COALESCE(cu.display_name, v_name)
    WHERE cu.customer_id = v_customer_id;
  END IF;

  -- The cancellation code is random and thrown away: the customer has no
  -- channel to use it, the administrator cancels through admin_cancel_appointment.
  INSERT INTO {{CLIENT_CODE}}_booking.appointments (
    appointment_uuid, consent_event_uuid, customer_id, service_id, staff_id,
    slot_id, starts_at, ends_at, status, source, confirm_code_sha256, comment
  ) VALUES (
    p_appointment_uuid, NULL, v_customer_id, p_service_id, v_first_slot.staff_id,
    p_slot_id, v_first_slot.starts_at, v_expected_end, 'confirmed', 'manual',
    public.digest(public.gen_random_bytes(16), 'sha256'), v_comment
  );

  UPDATE {{CLIENT_CODE}}_booking.slots AS sl
  SET status = 'booked', appointment_uuid = p_appointment_uuid
  WHERE sl.slot_id = ANY(v_slot_ids);

  RETURN QUERY
    SELECT p_appointment_uuid, v_first_slot.starts_at, v_expected_end, 'confirmed'::text;
END
$fn$;

-- Appointments that start on a date (server time zone), oldest first.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_list_appointments(
  p_admin_user_id bigint,
  p_date date,
  p_include_cancelled boolean DEFAULT false
)
RETURNS TABLE(
  appointment_uuid uuid,
  starts_at timestamptz,
  ends_at timestamptz,
  status text,
  source text,
  service_title text,
  staff_name text,
  customer_name text,
  customer_phone text,
  comment text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'date is required';
  END IF;

  RETURN QUERY
    SELECT
      a.appointment_uuid, a.starts_at, a.ends_at, a.status, a.source,
      sv.title, st.display_name, cu.display_name, cu.phone_e164, a.comment
    FROM {{CLIENT_CODE}}_booking.appointments AS a
    JOIN {{CLIENT_CODE}}_booking.services AS sv ON sv.service_id = a.service_id
    JOIN {{CLIENT_CODE}}_booking.staff AS st ON st.staff_id = a.staff_id
    JOIN {{CLIENT_CODE}}_booking.customers AS cu ON cu.customer_id = a.customer_id
    WHERE a.starts_at >= p_date::timestamptz
      AND a.starts_at < (p_date + 1)::timestamptz
      AND (p_include_cancelled OR a.status <> 'cancelled')
    ORDER BY a.starts_at, st.display_name;
END
$fn$;

-- Administrator cancels any appointment (no code, no cancel_hours limit);
-- slots are released and pending reminders skipped.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.admin_cancel_appointment(
  p_admin_user_id bigint,
  p_appointment_uuid uuid,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_appt {{CLIENT_CODE}}_booking.appointments%ROWTYPE;
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  PERFORM {{CLIENT_CODE}}_booking.require_admin(p_admin_user_id);

  SELECT * INTO v_appt
  FROM {{CLIENT_CODE}}_booking.appointments AS ap
  WHERE ap.appointment_uuid = p_appointment_uuid
  FOR UPDATE;
  IF NOT FOUND OR v_appt.status NOT IN ('planned', 'confirmed') THEN
    RETURN false;
  END IF;

  UPDATE {{CLIENT_CODE}}_booking.appointments AS ap
  SET status = 'cancelled',
      cancelled_at = clock_timestamp(),
      cancel_reason = left(v_reason, 300),
      updated_at = clock_timestamp()
  WHERE ap.appointment_uuid = p_appointment_uuid;

  PERFORM {{CLIENT_CODE}}_booking.release_appointment_slots(p_appointment_uuid);

  UPDATE {{CLIENT_CODE}}_booking.reminders AS rm
  SET status = 'skipped'
  WHERE rm.appointment_uuid = p_appointment_uuid AND rm.status = 'pending';

  RETURN true;
END
$fn$;

-- ---------- cancel_appointment (replaces the 051 body) ----------
-- Same signature and result as in 051. The only change: the slots are released
-- through release_appointment_slots, so a slot outside the current schedule
-- (day off, shifted hours) is closed instead of becoming free again.
-- 053 must therefore be applied after 051 (re-running 051 restores the old body).
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.cancel_appointment(
  p_appointment_uuid uuid,
  p_confirm_code text,
  p_reason text
)
RETURNS TABLE(
  cancelled boolean,
  status text,
  reason_code text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_appt {{CLIENT_CODE}}_booking.appointments%ROWTYPE;
  v_cancel_hours int;
  v_now timestamptz := clock_timestamp();
  v_reason text := NULLIF(btrim(COALESCE(p_reason, '')), '');
BEGIN
  SELECT * INTO v_appt
  FROM {{CLIENT_CODE}}_booking.appointments
  WHERE appointment_uuid = p_appointment_uuid
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::text, 'not_found'::text;
    RETURN;
  END IF;

  IF v_appt.confirm_code_sha256 IS DISTINCT FROM
     public.digest(convert_to(COALESCE(p_confirm_code, ''), 'UTF8'), 'sha256') THEN
    RETURN QUERY SELECT false, v_appt.status, 'bad_code'::text;
    RETURN;
  END IF;

  IF v_appt.status IN ('cancelled', 'done', 'no_show') THEN
    RETURN QUERY SELECT false, v_appt.status, 'already_cancelled'::text;
    RETURN;
  END IF;

  v_cancel_hours := COALESCE({{CLIENT_CODE}}_booking.setting_int('cancel_hours'), 0);
  IF v_appt.starts_at < v_now + make_interval(hours => v_cancel_hours) THEN
    RETURN QUERY SELECT false, v_appt.status, 'too_late'::text;
    RETURN;
  END IF;

  UPDATE {{CLIENT_CODE}}_booking.appointments
  SET status = 'cancelled',
      cancelled_at = v_now,
      cancel_reason = v_reason,
      updated_at = clock_timestamp()
  WHERE appointment_uuid = p_appointment_uuid;

  PERFORM {{CLIENT_CODE}}_booking.release_appointment_slots(p_appointment_uuid);

  UPDATE {{CLIENT_CODE}}_booking.reminders AS rm
  SET status = 'skipped'
  WHERE rm.appointment_uuid = p_appointment_uuid
    AND rm.status = 'pending';

  RETURN QUERY SELECT true, 'cancelled'::text, 'ok'::text;
END
$fn$;

-- ---------- Ownership and rights (KB-02#5, KB-02#6) ----------
-- Default privileges add to the built-in ones, so PUBLIC is revoked explicitly
-- per function and again for the whole schema at the end.

ALTER FUNCTION {{CLIENT_CODE}}_booking.is_admin(bigint) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.require_admin(bigint) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.slot_in_schedule(uuid, timestamptz, timestamptz) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.release_appointment_slots(uuid) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.cancel_appointment(uuid, text, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.resync_staff_slots(uuid, date, date) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_list_services(bigint) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_add_service(bigint, text, int, bigint, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_update_service(bigint, uuid, text, int, bigint, boolean) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_set_service_active(bigint, uuid, boolean) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_list_staff(bigint) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_link_staff_service(bigint, uuid, uuid) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_unlink_staff_service(bigint, uuid, uuid) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_set_work_hours(bigint, uuid, int, time, time) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_set_exception(bigint, uuid, date, boolean, time, time, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_remove_exception(bigint, uuid, date) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_create_appointment(bigint, uuid, uuid, uuid, text, text, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_list_appointments(bigint, date, boolean) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.admin_cancel_appointment(bigint, uuid, text) OWNER TO {{CLIENT_CODE}};

REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.is_admin(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.require_admin(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.slot_in_schedule(uuid, timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.release_appointment_slots(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.cancel_appointment(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.resync_staff_slots(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_list_services(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_add_service(bigint, text, int, bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_update_service(bigint, uuid, text, int, bigint, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_set_service_active(bigint, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_list_staff(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_link_staff_service(bigint, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_unlink_staff_service(bigint, uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_set_work_hours(bigint, uuid, int, time, time) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_set_exception(bigint, uuid, date, boolean, time, time, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_remove_exception(bigint, uuid, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_create_appointment(bigint, uuid, uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_list_appointments(bigint, date, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.admin_cancel_appointment(bigint, uuid, text) FROM PUBLIC;

REVOKE ALL ON ALL ROUTINES IN SCHEMA {{CLIENT_CODE}}_booking FROM PUBLIC;

DO $grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_runtime') THEN
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.is_admin(bigint) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.cancel_appointment(uuid, text, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_list_services(bigint) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_add_service(bigint, text, int, bigint, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_update_service(bigint, uuid, text, int, bigint, boolean) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_set_service_active(bigint, uuid, boolean) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_list_staff(bigint) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_link_staff_service(bigint, uuid, uuid) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_unlink_staff_service(bigint, uuid, uuid) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_set_work_hours(bigint, uuid, int, time, time) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_set_exception(bigint, uuid, date, boolean, time, time, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_remove_exception(bigint, uuid, date) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_create_appointment(bigint, uuid, uuid, uuid, text, text, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_list_appointments(bigint, date, boolean) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.admin_cancel_appointment(bigint, uuid, text) TO n8n_runtime;
  END IF;
END
$grant$;

COMMIT;
