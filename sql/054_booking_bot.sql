-- {{CLIENT_CODE_UPPER}}: pg-booking 054 -- state and functions of the booking bot in MAX
-- (dialog state, consent of the bot user, owner of an appointment, event dedup,
-- bot-side create/cancel, reminders addressed by MAX id).
-- 050-053 are not rewritten: this file only adds. SECURITY DEFINER in the style of
-- 051/053; n8n_runtime gets EXECUTE and no table access (KB-01#35).
--
-- Why this exists. 051 cancels only by a plain confirm code that is never stored,
-- and due_reminders returns a phone, not a MAX id; the bot has neither. So the bot
-- keeps who made an appointment (appointment_owners) and cancels through
-- bot_cancel_appointment, which checks the owner instead of the code and applies
-- the same cancel_hours rule. Reminders are delivered only for appointments made
-- through the bot (the owner is known); other pending reminders are not touched.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('{{CLIENT_CODE}}_booking.admins') IS NULL THEN
    RAISE EXCEPTION '054 preflight: 053 (admins) is missing';
  END IF;
  IF to_regprocedure('{{CLIENT_CODE}}_booking.create_appointment(uuid,uuid,text,timestamp with time zone,text,uuid,uuid,text,text,text,text,text,inet,text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_create_appointment(bigint,uuid,uuid,uuid,text,text,text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.free_slots(uuid,uuid,date,date)') IS NULL THEN
    RAISE EXCEPTION '054 preflight: 051/053 functions are missing';
  END IF;
END
$preflight$;

-- ---------- Tables ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.dialog_state (
  max_user_id bigint PRIMARY KEY,
  step text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (char_length(step) <= 40)
);

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.bot_users (
  max_user_id bigint PRIMARY KEY,
  consent_at timestamptz,
  first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.appointment_owners (
  appointment_uuid uuid PRIMARY KEY
    REFERENCES {{CLIENT_CODE}}_booking.appointments(appointment_uuid) ON DELETE CASCADE,
  max_user_id bigint NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS appointment_owners_user_idx
  ON {{CLIENT_CODE}}_booking.appointment_owners (max_user_id);

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.bot_events (
  event_id text PRIMARY KEY,
  seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (char_length(event_id) <= 200)
);

ALTER TABLE {{CLIENT_CODE}}_booking.dialog_state OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.bot_users OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.appointment_owners OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.bot_events OWNER TO {{CLIENT_CODE}};
REVOKE ALL ON TABLE {{CLIENT_CODE}}_booking.dialog_state, {{CLIENT_CODE}}_booking.bot_users,
  {{CLIENT_CODE}}_booking.appointment_owners, {{CLIENT_CODE}}_booking.bot_events FROM PUBLIC;

-- ---------- Card of an appointment (helper, not granted) ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_appt_card(p_appt uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  SELECT jsonb_build_object(
    'appointment_uuid', a.appointment_uuid,
    'starts_at', a.starts_at,
    'ends_at', a.ends_at,
    'status', a.status,
    'source', a.source,
    'service_title', sv.title,
    'price_minor', sv.price_minor,
    'staff_name', st.display_name,
    'customer_name', cu.display_name,
    'customer_phone', cu.phone_e164)
  FROM {{CLIENT_CODE}}_booking.appointments AS a
  JOIN {{CLIENT_CODE}}_booking.services AS sv ON sv.service_id = a.service_id
  JOIN {{CLIENT_CODE}}_booking.staff AS st ON st.staff_id = a.staff_id
  JOIN {{CLIENT_CODE}}_booking.customers AS cu ON cu.customer_id = a.customer_id
  WHERE a.appointment_uuid = p_appt;
$fn$;

-- ---------- Free slots of the day of a slot (for "the time was just taken") ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_day_slots(p_service uuid, p_slot uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_day date;
  v_res jsonb;
BEGIN
  SELECT (sl.starts_at AT TIME ZONE 'Europe/Moscow')::date INTO v_day
  FROM {{CLIENT_CODE}}_booking.slots AS sl WHERE sl.slot_id = p_slot;
  IF v_day IS NULL THEN
    RETURN jsonb_build_object('day', NULL, 'slots', '[]'::jsonb);
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('slot_id', f.slot_id, 'starts_at', f.starts_at,
           'staff_name', f.staff_name) ORDER BY f.starts_at, f.staff_name), '[]'::jsonb)
  INTO v_res
  FROM {{CLIENT_CODE}}_booking.free_slots(p_service, NULL, v_day, v_day) AS f;
  RETURN jsonb_build_object('day', v_day, 'slots', v_res);
END
$fn$;

-- ---------- Context of an incoming event ----------
-- Delivery semantics (decided, not an oversight): AT-MOST-ONCE for incoming events.
-- bot_context marks the event as seen BEFORE the scenario handles it. If n8n fails after this call,
-- the same MAX event is not processed again (fresh = false) and the user simply repeats the action.
-- Moving the mark after processing needs an acknowledgement function plus an n8n change
-- (build.js of n8n-max-booking calls bot_context(user, event) once per event and has no ack step).
-- Reminders are NOT at-most-once: bot_due_reminders marks nothing; the n8n scenario calls mark_reminder
-- AFTER delivery (sent / failed), so a crash between send and mark may repeat a reminder, never lose it.

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_context(p_user bigint, p_event text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_fresh boolean := true;
  v_rows int;
  v_state {{CLIENT_CODE}}_booking.dialog_state%ROWTYPE;
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'user is required';
  END IF;
  DELETE FROM {{CLIENT_CODE}}_booking.dialog_state WHERE updated_at < clock_timestamp() - interval '24 hours';
  DELETE FROM {{CLIENT_CODE}}_booking.bot_events WHERE seen_at < clock_timestamp() - interval '2 days';
  IF p_event IS NOT NULL THEN
    INSERT INTO {{CLIENT_CODE}}_booking.bot_events (event_id) VALUES (p_event) ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_fresh := v_rows > 0;
  END IF;
  INSERT INTO {{CLIENT_CODE}}_booking.bot_users (max_user_id) VALUES (p_user) ON CONFLICT DO NOTHING;
  SELECT * INTO v_state FROM {{CLIENT_CODE}}_booking.dialog_state WHERE max_user_id = p_user;
  RETURN jsonb_build_object(
    'fresh', v_fresh,
    'admin', {{CLIENT_CODE}}_booking.is_admin(p_user),
    'consent', EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.bot_users AS u
                       WHERE u.max_user_id = p_user AND u.consent_at IS NOT NULL),
    'step', v_state.step,
    'data', COALESCE(v_state.data, '{}'::jsonb),
    'admins', COALESCE((SELECT jsonb_agg(ad.max_user_id) FROM {{CLIENT_CODE}}_booking.admins AS ad
                        WHERE ad.is_active), '[]'::jsonb));
END
$fn$;

-- p_step NULL clears the state.
CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_state_set(p_user bigint, p_step text, p_data jsonb)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
BEGIN
  IF p_user IS NULL THEN
    RAISE EXCEPTION 'user is required';
  END IF;
  IF p_step IS NULL THEN
    DELETE FROM {{CLIENT_CODE}}_booking.dialog_state WHERE max_user_id = p_user;
    RETURN true;
  END IF;
  INSERT INTO {{CLIENT_CODE}}_booking.dialog_state (max_user_id, step, data, updated_at)
  VALUES (p_user, p_step, COALESCE(p_data, '{}'::jsonb), clock_timestamp())
  ON CONFLICT (max_user_id) DO UPDATE
    SET step = EXCLUDED.step, data = EXCLUDED.data, updated_at = EXCLUDED.updated_at;
  RETURN true;
END
$fn$;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_grant_consent(p_user bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
BEGIN
  INSERT INTO {{CLIENT_CODE}}_booking.bot_users (max_user_id, consent_at)
  VALUES (p_user, clock_timestamp())
  ON CONFLICT (max_user_id) DO UPDATE
    SET consent_at = COALESCE({{CLIENT_CODE}}_booking.bot_users.consent_at, EXCLUDED.consent_at);
  RETURN true;
END
$fn$;

-- ---------- Create (customer) ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_create_appointment(
  p_user bigint,
  p_appointment_uuid uuid,
  p_consent_event_uuid uuid,
  p_service uuid,
  p_slot uuid,
  p_name text,
  p_phone text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_row record;
  v_msg text;
  v_state text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.bot_users AS u
                 WHERE u.max_user_id = p_user AND u.consent_at IS NOT NULL) THEN
    RETURN jsonb_build_object('result', 'no_consent');
  END IF;

  SELECT * INTO v_row FROM {{CLIENT_CODE}}_booking.create_appointment(
    p_appointment_uuid, p_consent_event_uuid, 'booking-1.0', clock_timestamp(), '/bot',
    p_service, p_slot, p_name, p_phone, NULL, NULL, 'bot', NULL, 'max-bot');

  INSERT INTO {{CLIENT_CODE}}_booking.appointment_owners (appointment_uuid, max_user_id)
  VALUES (p_appointment_uuid, p_user)
  ON CONFLICT (appointment_uuid) DO NOTHING;

  RETURN jsonb_build_object('result', 'ok', 'card', {{CLIENT_CODE}}_booking.bot_appt_card(p_appointment_uuid));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('result', 'taken') || {{CLIENT_CODE}}_booking.bot_day_slots(p_service, p_slot);
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
    IF v_msg ~ 'no longer available|minimum lead time|unknown slot' THEN
      RETURN jsonb_build_object('result', 'taken') || {{CLIENT_CODE}}_booking.bot_day_slots(p_service, p_slot);
    ELSIF v_msg ~ 'invalid phone|phone is required' THEN
      RETURN jsonb_build_object('result', 'bad_phone');
    ELSIF v_msg ~ 'unknown or inactive service' THEN
      RETURN jsonb_build_object('result', 'no_service');
    END IF;
    RAISE WARNING 'bot_create_appointment failed: sqlstate=%, message=%', v_state, v_msg;
    RETURN jsonb_build_object('result', 'error', 'code', 'internal_error', 'message', 'internal error');
END
$fn$;

-- ---------- Create (administrator, by phone) ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_admin_create_appointment(
  p_admin bigint,
  p_appointment_uuid uuid,
  p_service uuid,
  p_slot uuid,
  p_name text,
  p_phone text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_row record;
  v_msg text;
  v_state text;
BEGIN
  SELECT * INTO v_row FROM {{CLIENT_CODE}}_booking.admin_create_appointment(
    p_admin, p_appointment_uuid, p_service, p_slot, p_name, p_phone, NULL);
  RETURN jsonb_build_object('result', 'ok', 'card', {{CLIENT_CODE}}_booking.bot_appt_card(p_appointment_uuid));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('result', 'taken') || {{CLIENT_CODE}}_booking.bot_day_slots(p_service, p_slot);
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
    v_msg := SQLERRM;
    IF v_msg ~ 'not an administrator' THEN
      RETURN jsonb_build_object('result', 'forbidden');
    ELSIF v_msg ~ 'no longer available|minimum lead time|unknown slot' THEN
      RETURN jsonb_build_object('result', 'taken') || {{CLIENT_CODE}}_booking.bot_day_slots(p_service, p_slot);
    ELSIF v_msg ~ 'invalid phone|phone is required' THEN
      RETURN jsonb_build_object('result', 'bad_phone');
    ELSIF v_msg ~ 'unknown or inactive service' THEN
      RETURN jsonb_build_object('result', 'no_service');
    END IF;
    RAISE WARNING 'bot_admin_create_appointment failed: sqlstate=%, message=%', v_state, v_msg;
    RETURN jsonb_build_object('result', 'error', 'code', 'internal_error', 'message', 'internal error');
END
$fn$;

-- ---------- My appointments / cancel ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_my_appointments(p_user bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  SELECT COALESCE(jsonb_agg(
           {{CLIENT_CODE}}_booking.bot_appt_card(o.appointment_uuid)
           || jsonb_build_object('can_cancel',
                a.starts_at >= clock_timestamp()
                  + make_interval(hours => COALESCE({{CLIENT_CODE}}_booking.setting_int('cancel_hours'), 0)))
           ORDER BY a.starts_at), '[]'::jsonb)
  FROM {{CLIENT_CODE}}_booking.appointment_owners AS o
  JOIN {{CLIENT_CODE}}_booking.appointments AS a ON a.appointment_uuid = o.appointment_uuid
  WHERE o.max_user_id = p_user
    AND a.status IN ('planned', 'confirmed')
    AND a.starts_at > clock_timestamp();
$fn$;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_cancel_appointment(p_user bigint, p_appt uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_appt {{CLIENT_CODE}}_booking.appointments%ROWTYPE;
  v_now timestamptz := clock_timestamp();
  v_hours int;
BEGIN
  SELECT a.* INTO v_appt
  FROM {{CLIENT_CODE}}_booking.appointments AS a
  JOIN {{CLIENT_CODE}}_booking.appointment_owners AS o ON o.appointment_uuid = a.appointment_uuid
  WHERE a.appointment_uuid = p_appt AND o.max_user_id = p_user
  FOR UPDATE OF a;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_found');
  END IF;
  IF v_appt.status IN ('cancelled', 'done', 'no_show') THEN
    RETURN jsonb_build_object('result', 'already_cancelled');
  END IF;
  v_hours := COALESCE({{CLIENT_CODE}}_booking.setting_int('cancel_hours'), 0);
  IF v_appt.starts_at < v_now + make_interval(hours => v_hours) THEN
    RETURN jsonb_build_object('result', 'too_late', 'cancel_hours', v_hours,
             'card', {{CLIENT_CODE}}_booking.bot_appt_card(p_appt));
  END IF;
  UPDATE {{CLIENT_CODE}}_booking.appointments
  SET status = 'cancelled', cancelled_at = v_now, cancel_reason = 'bot', updated_at = clock_timestamp()
  WHERE appointment_uuid = p_appt;
  PERFORM {{CLIENT_CODE}}_booking.release_appointment_slots(p_appt);
  UPDATE {{CLIENT_CODE}}_booking.reminders AS rm
  SET status = 'skipped'
  WHERE rm.appointment_uuid = p_appt AND rm.status = 'pending';
  RETURN jsonb_build_object('result', 'ok', 'card', {{CLIENT_CODE}}_booking.bot_appt_card(p_appt));
END
$fn$;

-- ---------- Reminders addressed by MAX id ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_due_reminders(
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
  max_user_id bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  SELECT r.reminder_id, r.appointment_uuid, r.kind, a.starts_at,
         sv.title, st.display_name, c.display_name, o.max_user_id
  FROM {{CLIENT_CODE}}_booking.reminders AS r
  JOIN {{CLIENT_CODE}}_booking.appointments AS a ON a.appointment_uuid = r.appointment_uuid
  JOIN {{CLIENT_CODE}}_booking.appointment_owners AS o ON o.appointment_uuid = a.appointment_uuid
  JOIN {{CLIENT_CODE}}_booking.services AS sv ON sv.service_id = a.service_id
  JOIN {{CLIENT_CODE}}_booking.staff AS st ON st.staff_id = a.staff_id
  JOIN {{CLIENT_CODE}}_booking.customers AS c ON c.customer_id = a.customer_id
  WHERE r.status = 'pending'
    AND r.planned_at <= p_now
    AND a.starts_at > p_now
    AND a.status IN ('planned', 'confirmed')
  ORDER BY r.planned_at
  LIMIT p_limit;
$fn$;

-- ---------- Summary of a chosen slot for the confirmation screen ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.bot_slot_summary(p_service uuid, p_slot uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  SELECT jsonb_build_object('service_title', sv.title, 'price_minor', sv.price_minor,
           'staff_name', st.display_name, 'starts_at', sl.starts_at)
  FROM {{CLIENT_CODE}}_booking.slots AS sl
  JOIN {{CLIENT_CODE}}_booking.staff AS st ON st.staff_id = sl.staff_id
  CROSS JOIN {{CLIENT_CODE}}_booking.services AS sv
  WHERE sl.slot_id = p_slot AND sv.service_id = p_service;
$fn$;

-- ---------- Ownership and rights ----------

ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_appt_card(uuid) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_day_slots(uuid, uuid) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_context(bigint, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_state_set(bigint, text, jsonb) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_grant_consent(bigint) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_create_appointment(bigint, uuid, uuid, uuid, uuid, text, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_admin_create_appointment(bigint, uuid, uuid, uuid, text, text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_my_appointments(bigint) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_cancel_appointment(bigint, uuid) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_due_reminders(timestamptz, int) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.bot_slot_summary(uuid, uuid) OWNER TO {{CLIENT_CODE}};

REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_appt_card(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_day_slots(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_context(bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_state_set(bigint, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_grant_consent(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_create_appointment(bigint, uuid, uuid, uuid, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_admin_create_appointment(bigint, uuid, uuid, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_my_appointments(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_cancel_appointment(bigint, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_due_reminders(timestamptz, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.bot_slot_summary(uuid, uuid) FROM PUBLIC;

-- bot_appt_card and bot_day_slots are internal helpers: no grant.
DO $grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_runtime') THEN
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_context(bigint, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_state_set(bigint, text, jsonb) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_grant_consent(bigint) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_create_appointment(bigint, uuid, uuid, uuid, uuid, text, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_admin_create_appointment(bigint, uuid, uuid, uuid, text, text) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_my_appointments(bigint) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_cancel_appointment(bigint, uuid) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_due_reminders(timestamptz, int) TO n8n_runtime;
    GRANT EXECUTE ON FUNCTION {{CLIENT_CODE}}_booking.bot_slot_summary(uuid, uuid) TO n8n_runtime;
  END IF;
END
$grant$;

COMMIT;
