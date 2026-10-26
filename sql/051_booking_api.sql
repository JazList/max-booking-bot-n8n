-- {{CLIENT_CODE_UPPER}}: booking application API (SECURITY DEFINER functions).
-- Production rule: these signatures are the contract used by n8n scenarios and
-- the booking widget; do not change parameter order/types without a
-- coordinated release on every consumer.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('{{CLIENT_CODE}}_booking.appointments') IS NULL THEN
    RAISE EXCEPTION '051 preflight: {{CLIENT_CODE}}_booking core schema (050) is missing';
  END IF;
END
$preflight$;

-- ---------- generate_slots: build free slots from schedule + exceptions ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.generate_slots(
  p_from date,
  p_to date
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_step int := {{CLIENT_CODE}}_booking.setting_int('slot_step_minutes');
  v_inserted bigint := 0;
  v_rows bigint;
  v_day date;
  v_staff {{CLIENT_CODE}}_booking.staff%ROWTYPE;
  v_has_exception boolean;
  v_is_working boolean;
  v_work_start time;
  v_work_end time;
  v_cursor timestamptz;
  v_day_end timestamptz;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'invalid date range';
  END IF;
  IF v_step IS NULL OR v_step < 1 THEN
    RAISE EXCEPTION 'slot_step_minutes setting is not configured';
  END IF;

  FOR v_staff IN
    SELECT * FROM {{CLIENT_CODE}}_booking.staff WHERE is_active = true
  LOOP
    v_day := p_from;
    WHILE v_day <= p_to LOOP
      v_has_exception := false;
      v_is_working := true;
      v_work_start := NULL;
      v_work_end := NULL;

      SELECT e.is_working, e.starts_time, e.ends_time
      INTO v_is_working, v_work_start, v_work_end
      FROM {{CLIENT_CODE}}_booking.schedule_exceptions AS e
      WHERE e.staff_id = v_staff.staff_id AND e.exception_date = v_day;

      IF FOUND THEN
        v_has_exception := true;
      END IF;

      IF v_has_exception AND NOT v_is_working THEN
        v_day := v_day + 1;
        CONTINUE;
      END IF;

      IF NOT v_has_exception THEN
        SELECT w.starts_time, w.ends_time
        INTO v_work_start, v_work_end
        FROM {{CLIENT_CODE}}_booking.work_schedule AS w
        WHERE w.staff_id = v_staff.staff_id
          AND w.weekday = EXTRACT(DOW FROM v_day)::smallint
          AND w.valid_from <= v_day
          AND (w.valid_to IS NULL OR w.valid_to >= v_day)
        ORDER BY w.valid_from DESC
        LIMIT 1;
      END IF;

      IF v_work_start IS NOT NULL AND v_work_end IS NOT NULL THEN
        v_cursor := v_day::timestamp + v_work_start;
        v_day_end := v_day::timestamp + v_work_end;
        WHILE v_cursor + make_interval(mins => v_step) <= v_day_end LOOP
          INSERT INTO {{CLIENT_CODE}}_booking.slots (staff_id, starts_at, ends_at, status)
          VALUES (v_staff.staff_id, v_cursor, v_cursor + make_interval(mins => v_step), 'free')
          ON CONFLICT (staff_id, starts_at) DO NOTHING;
          GET DIAGNOSTICS v_rows = ROW_COUNT;
          v_inserted := v_inserted + v_rows;
          v_cursor := v_cursor + make_interval(mins => v_step);
        END LOOP;
      END IF;

      v_day := v_day + 1;
    END LOOP;
  END LOOP;

  RETURN v_inserted;
END
$fn$;

-- ---------- Catalog reads ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.list_services()
RETURNS TABLE(
  service_id uuid,
  code text,
  title text,
  duration_minutes int,
  price_minor bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  SELECT service_id, code, title, duration_minutes, price_minor
  FROM {{CLIENT_CODE}}_booking.services
  WHERE is_active = true
  ORDER BY sort_order, title;
$fn$;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.list_staff(p_service_id uuid)
RETURNS TABLE(
  staff_id uuid,
  code text,
  display_name text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  SELECT DISTINCT s.staff_id, s.code, s.display_name
  FROM {{CLIENT_CODE}}_booking.staff AS s
  LEFT JOIN {{CLIENT_CODE}}_booking.staff_services AS ss ON ss.staff_id = s.staff_id
  WHERE s.is_active = true
    AND (p_service_id IS NULL OR ss.service_id = p_service_id)
  ORDER BY s.display_name;
$fn$;

-- ---------- free_slots: consecutive free slots covering the service duration ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.free_slots(
  p_service_id uuid,
  p_staff_id uuid,
  p_from date,
  p_to date
)
RETURNS TABLE(
  slot_id uuid,
  staff_id uuid,
  staff_name text,
  starts_at timestamptz,
  ends_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_step int := {{CLIENT_CODE}}_booking.setting_int('slot_step_minutes');
  v_lead_hours int := COALESCE({{CLIENT_CODE}}_booking.setting_int('lead_time_hours'), 0);
  v_horizon_days int := COALESCE({{CLIENT_CODE}}_booking.setting_int('horizon_days'), 0);
  v_duration int;
  v_needed int;
  v_earliest timestamptz;
  v_cutoff timestamptz;
BEGIN
  IF p_service_id IS NULL OR p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'invalid free_slots arguments';
  END IF;
  IF v_step IS NULL OR v_step < 1 THEN
    RAISE EXCEPTION 'slot_step_minutes setting is not configured';
  END IF;

  SELECT duration_minutes INTO v_duration
  FROM {{CLIENT_CODE}}_booking.services
  WHERE service_id = p_service_id AND is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown or inactive service';
  END IF;

  v_needed := ceil(v_duration::numeric / v_step)::int;
  v_earliest := GREATEST(
    clock_timestamp() + make_interval(hours => v_lead_hours),
    p_from::timestamptz
  );
  v_cutoff := LEAST(
    clock_timestamp() + make_interval(days => v_horizon_days),
    (p_to + 1)::timestamptz
  );

  RETURN QUERY
  WITH candidate_staff AS (
    SELECT s.staff_id, s.display_name
    FROM {{CLIENT_CODE}}_booking.staff AS s
    JOIN {{CLIENT_CODE}}_booking.staff_services AS ss
      ON ss.staff_id = s.staff_id AND ss.service_id = p_service_id
    WHERE s.is_active = true
      AND (p_staff_id IS NULL OR s.staff_id = p_staff_id)
  ),
  ordered_slots AS (
    SELECT
      sl.slot_id, sl.staff_id, sl.starts_at,
      row_number() OVER (PARTITION BY sl.staff_id ORDER BY sl.starts_at) AS rn
    FROM {{CLIENT_CODE}}_booking.slots AS sl
    JOIN candidate_staff AS cs ON cs.staff_id = sl.staff_id
    WHERE sl.status = 'free'
      AND sl.starts_at >= v_earliest
      AND sl.starts_at < v_cutoff
  ),
  runs AS (
    SELECT
      o1.slot_id, o1.staff_id, o1.starts_at,
      o1.starts_at + make_interval(mins => v_step * v_needed) AS run_ends_at
    FROM ordered_slots AS o1
    WHERE (
      SELECT count(*) FROM ordered_slots AS o2
      WHERE o2.staff_id = o1.staff_id AND o2.rn BETWEEN o1.rn AND o1.rn + v_needed - 1
    ) = v_needed
    AND NOT EXISTS (
      SELECT 1 FROM ordered_slots AS o2
      WHERE o2.staff_id = o1.staff_id
        AND o2.rn BETWEEN o1.rn AND o1.rn + v_needed - 1
        AND o2.starts_at <> o1.starts_at + make_interval(mins => (v_step * (o2.rn - o1.rn))::int)
    )
  )
  SELECT r.slot_id, r.staff_id, cs.display_name, r.starts_at, r.run_ends_at
  FROM runs AS r
  JOIN candidate_staff AS cs ON cs.staff_id = r.staff_id
  ORDER BY r.starts_at, r.staff_id;
END
$fn$;

-- ---------- create_appointment ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.create_appointment(
  p_appointment_uuid uuid,
  p_consent_event_uuid uuid,
  p_consent_text_version text,
  p_client_at timestamptz,
  p_page_path text,
  p_service_id uuid,
  p_slot_id uuid,
  p_name text,
  p_phone text,
  p_email text,
  p_comment text,
  p_source text,
  p_ip inet,
  p_ua_family text
)
RETURNS TABLE(
  appointment_id uuid,
  confirm_code text,
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
  v_email text := NULLIF(lower(btrim(COALESCE(p_email, ''))), '');
  v_comment text := NULLIF(btrim(COALESCE(p_comment, '')), '');
  v_existing {{CLIENT_CODE}}_booking.appointments%ROWTYPE;
  v_existing_customer {{CLIENT_CODE}}_booking.customers%ROWTYPE;
  v_service {{CLIENT_CODE}}_booking.services%ROWTYPE;
  v_first_slot {{CLIENT_CODE}}_booking.slots%ROWTYPE;
  v_step int;
  v_lead_hours int;
  v_needed int;
  v_slot_ids uuid[];
  v_slot_count int;
  v_expected_end timestamptz;
  v_customer_id uuid;
  v_event uuid;
  v_event_at timestamptz;
  v_status text;
  v_confirm_code text;
  v_reminder_hours text;
  v_hour text;
BEGIN
  IF p_appointment_uuid IS NULL OR p_consent_event_uuid IS NULL
     OR p_service_id IS NULL OR p_slot_id IS NULL THEN
    RAISE EXCEPTION 'missing appointment identifiers';
  END IF;
  IF p_consent_text_version <> 'booking-1.0' THEN
    RAISE EXCEPTION 'unsupported booking consent version';
  END IF;
  IF p_source NOT IN ('site', 'bot', 'manual') THEN
    RAISE EXCEPTION 'invalid appointment source';
  END IF;
  IF p_page_path IS NULL OR char_length(p_page_path) > 300
     OR p_page_path !~ '^/[^?#]*$' THEN
    RAISE EXCEPTION 'invalid page path';
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
  IF v_email IS NOT NULL AND (
    char_length(v_email) > 160
    OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ) THEN
    RAISE EXCEPTION 'invalid email';
  END IF;
  IF v_comment IS NOT NULL AND char_length(v_comment) > 1000 THEN
    RAISE EXCEPTION 'comment too long';
  END IF;

  -- Idempotency: a repeated call with the same appointment UUID must not
  -- create a second booking or silently move it to different data.
  SELECT * INTO v_existing
  FROM {{CLIENT_CODE}}_booking.appointments
  WHERE appointment_uuid = p_appointment_uuid;

  IF FOUND THEN
    SELECT * INTO v_existing_customer
    FROM {{CLIENT_CODE}}_booking.customers
    WHERE customer_id = v_existing.customer_id;

    IF v_existing.consent_event_uuid IS DISTINCT FROM p_consent_event_uuid
       OR v_existing.service_id IS DISTINCT FROM p_service_id
       OR v_existing.slot_id IS DISTINCT FROM p_slot_id
       OR v_existing.page_path IS DISTINCT FROM p_page_path
       OR v_existing.comment IS DISTINCT FROM v_comment
       OR v_existing_customer.phone_e164 IS DISTINCT FROM v_phone
       OR v_existing_customer.email IS DISTINCT FROM v_email THEN
      RAISE EXCEPTION 'appointment UUID conflicts with an existing booking';
    END IF;

    -- The plain cancellation code exists only in the answer to the very first
    -- call; the table keeps its hash. A repeat therefore returns NULL instead of
    -- re-issuing a code: re-issuing would let a replayed request invalidate the
    -- code the real client is holding.
    RETURN QUERY
      SELECT v_existing.appointment_uuid, NULL::text,
             v_existing.starts_at, v_existing.ends_at, v_existing.status;
    RETURN;
  END IF;

  SELECT * INTO v_service
  FROM {{CLIENT_CODE}}_booking.services
  WHERE service_id = p_service_id AND is_active = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown or inactive service';
  END IF;

  SELECT * INTO v_first_slot
  FROM {{CLIENT_CODE}}_booking.slots
  WHERE slot_id = p_slot_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown slot';
  END IF;

  v_step := {{CLIENT_CODE}}_booking.setting_int('slot_step_minutes');
  v_lead_hours := COALESCE({{CLIENT_CODE}}_booking.setting_int('lead_time_hours'), 0);
  IF v_step IS NULL OR v_step < 1 THEN
    RAISE EXCEPTION 'slot_step_minutes setting is not configured';
  END IF;
  v_needed := ceil(v_service.duration_minutes::numeric / v_step)::int;

  IF v_first_slot.starts_at < clock_timestamp() + make_interval(hours => v_lead_hours) THEN
    RAISE EXCEPTION 'slot no longer satisfies the minimum lead time';
  END IF;

  -- Lock every slot the service needs, in the same staff's timeline, and
  -- require an unbroken run of exactly the needed length starting here.
  -- Every column reference is qualified ("sl."/"cand."): "starts_at" and
  -- "ends_at" are also this function's OUT-parameter names (from
  -- RETURNS TABLE) and a bare reference would be ambiguous in this scope.
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

  -- "status" is also this function's OUT-parameter name; qualify with the
  -- table alias so it cannot be read as that PL/pgSQL variable instead.
  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.slots AS sl
    WHERE sl.slot_id = ANY(v_slot_ids) AND sl.status <> 'free'
  ) THEN
    RAISE EXCEPTION 'slot is no longer available';
  END IF;

  -- Customer card: find-or-create by phone.
  SELECT customer_id INTO v_customer_id
  FROM {{CLIENT_CODE}}_booking.customers
  WHERE phone_e164 = v_phone;

  IF NOT FOUND THEN
    INSERT INTO {{CLIENT_CODE}}_booking.customers (customer_id, phone_e164, display_name, email)
    VALUES (gen_random_uuid(), v_phone, v_name, v_email)
    RETURNING customer_id INTO v_customer_id;
  ELSE
    -- Only fill what is still empty. A later booking made with the same phone
    -- but a different name must not silently rewrite the card that is already
    -- there: correcting a name is an operator's job, not a side effect of a
    -- public form.
    UPDATE {{CLIENT_CODE}}_booking.customers
    SET display_name = COALESCE(display_name, v_name),
        email = COALESCE(email, v_email)
    WHERE customer_id = v_customer_id;
  END IF;

  SELECT event_id, server_recorded_at
  INTO v_event, v_event_at
  FROM {{CLIENT_CODE}}_privacy.record_consent(
    p_consent_event_uuid,
    'booking:' || p_appointment_uuid::text,
    'booking_form',
    'granted',
    p_consent_text_version,
    'booking_widget',
    p_client_at,
    p_page_path,
    p_ip,
    NULLIF(btrim(COALESCE(p_ua_family, '')), ''),
    p_appointment_uuid
  );

  -- appointments.consent_event_uuid carries no foreign key (see migration 050),
  -- so the link to the consent journal is checked here: record_consent must have
  -- returned an event, and that exact id is what gets stored.
  IF v_event IS NULL THEN
    RAISE EXCEPTION 'consent journal did not return an event for this booking';
  END IF;

  v_status := CASE {{CLIENT_CODE}}_booking.setting_text('confirm_mode')
                WHEN 'auto' THEN 'confirmed'
                ELSE 'planned'
              END;
  v_confirm_code := encode(public.gen_random_bytes(6), 'hex');

  INSERT INTO {{CLIENT_CODE}}_booking.appointments (
    appointment_uuid, consent_event_uuid, customer_id, service_id, staff_id,
    slot_id, starts_at, ends_at, status, source, confirm_code_sha256, page_path, comment
  ) VALUES (
    p_appointment_uuid, v_event, v_customer_id, p_service_id, v_first_slot.staff_id,
    p_slot_id, v_first_slot.starts_at, v_expected_end, v_status, p_source,
    public.digest(convert_to(v_confirm_code, 'UTF8'), 'sha256'), p_page_path, v_comment
  );

  UPDATE {{CLIENT_CODE}}_booking.slots
  SET status = 'booked', appointment_uuid = p_appointment_uuid
  WHERE slot_id = ANY(v_slot_ids);

  v_reminder_hours := {{CLIENT_CODE}}_booking.setting_text('reminder_hours');
  IF v_reminder_hours IS NOT NULL THEN
    FOREACH v_hour IN ARRAY string_to_array(v_reminder_hours, ',') LOOP
      INSERT INTO {{CLIENT_CODE}}_booking.reminders (appointment_uuid, kind, planned_at)
      VALUES (
        p_appointment_uuid,
        'before_' || btrim(v_hour) || 'h',
        v_first_slot.starts_at - make_interval(hours => btrim(v_hour)::int)
      )
      ON CONFLICT (appointment_uuid, kind) DO NOTHING;
    END LOOP;
  END IF;

  RETURN QUERY
    SELECT p_appointment_uuid, v_confirm_code, v_first_slot.starts_at, v_expected_end, v_status;
END
$fn$;

-- ---------- cancel_appointment ----------

-- The 4-argument shape that let the caller pass the current time is dropped:
-- p_at decided the cancellation deadline, so a caller could cancel past it.
DROP FUNCTION IF EXISTS {{CLIENT_CODE}}_booking.cancel_appointment(uuid, text, text, timestamptz);

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

  -- Hash comparison: the plain code is never stored, so it is hashed the same
  -- way here and the digests are compared.
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

  UPDATE {{CLIENT_CODE}}_booking.slots
  SET status = 'free', appointment_uuid = NULL
  WHERE appointment_uuid = p_appointment_uuid;

  -- "status" is also this function's OUT-parameter name; qualify the WHERE
  -- condition with the table alias so it reads the row, not that variable.
  UPDATE {{CLIENT_CODE}}_booking.reminders AS rm
  SET status = 'skipped'
  WHERE rm.appointment_uuid = p_appointment_uuid
    AND rm.status = 'pending';

  RETURN QUERY SELECT true, 'cancelled'::text, 'ok'::text;
END
$fn$;

-- ---------- Reminder delivery ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.due_reminders(
  p_now timestamptz DEFAULT clock_timestamp(),
  p_limit int DEFAULT 50
)
RETURNS TABLE(
  reminder_id uuid,
  appointment_uuid uuid,
  kind text,
  starts_at timestamptz,
  service_title text,
  staff_name text,
  customer_name text,
  customer_phone text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  SELECT
    r.reminder_id, r.appointment_uuid, r.kind, a.starts_at,
    sv.title, st.display_name, c.display_name, c.phone_e164
  FROM {{CLIENT_CODE}}_booking.reminders AS r
  JOIN {{CLIENT_CODE}}_booking.appointments AS a ON a.appointment_uuid = r.appointment_uuid
  JOIN {{CLIENT_CODE}}_booking.services AS sv ON sv.service_id = a.service_id
  JOIN {{CLIENT_CODE}}_booking.staff AS st ON st.staff_id = a.staff_id
  JOIN {{CLIENT_CODE}}_booking.customers AS c ON c.customer_id = a.customer_id
  WHERE r.status = 'pending'
    AND r.planned_at <= p_now
    AND a.status IN ('planned', 'confirmed')
  ORDER BY r.planned_at
  LIMIT p_limit;
$fn$;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.mark_reminder(
  p_reminder_id uuid,
  p_status text,
  p_channel text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_rows int;
BEGIN
  IF p_status NOT IN ('sent', 'failed', 'skipped') THEN
    RAISE EXCEPTION 'invalid reminder status';
  END IF;

  UPDATE {{CLIENT_CODE}}_booking.reminders
  SET status = p_status,
      channel = COALESCE(NULLIF(btrim(COALESCE(p_channel, '')), ''), channel),
      sent_at = CASE WHEN p_status = 'sent' THEN clock_timestamp() ELSE sent_at END,
      attempts = attempts + 1
  WHERE reminder_id = p_reminder_id
    AND status = 'pending';
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  RETURN v_rows > 0;
END
$fn$;

-- ---------- Ownership and access control ----------

ALTER FUNCTION {{CLIENT_CODE}}_booking.generate_slots(date, date) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.list_services() OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.list_staff(uuid) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.free_slots(uuid, uuid, date, date) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.create_appointment(uuid, uuid, text, timestamptz, text, uuid, uuid, text, text, text, text, text, inet, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.cancel_appointment(uuid, text, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.due_reminders(timestamptz, int) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.mark_reminder(uuid, text, text) OWNER TO {{CLIENT_CODE}};

REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.generate_slots(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.list_services() FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.list_staff(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.free_slots(uuid, uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.create_appointment(uuid, uuid, text, timestamptz, text, uuid, uuid, text, text, text, text, text, inet, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.cancel_appointment(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.due_reminders(timestamptz, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.mark_reminder(uuid, text, text) FROM PUBLIC;

DO $grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_runtime') THEN
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.list_services() TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.list_staff(uuid) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.free_slots(uuid, uuid, date, date) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.create_appointment(uuid, uuid, text, timestamptz, text, uuid, uuid, text, text, text, text, text, inet, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.cancel_appointment(uuid, text, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.due_reminders(timestamptz, int) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.mark_reminder(uuid, text, text) TO n8n_runtime;
  END IF;
END
$grant$;

COMMIT;
