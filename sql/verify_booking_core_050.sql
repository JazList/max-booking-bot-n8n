-- Closed disposable acceptance for {{CLIENT_CODE_UPPER}} pg-booking 050.
-- Run only after 050 is applied. Every fixture is rolled back; nothing here
-- is meant to survive in the target database.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('{{CLIENT_CODE}}_booking.booking_settings') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.services') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.staff') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.staff_services') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.work_schedule') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.schedule_exceptions') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.slots') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.customers') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.appointments') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.reminders') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.setting_text(text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.setting_int(text)') IS NULL THEN
    RAISE EXCEPTION '050 acceptance preflight failed: booking core schema is incomplete';
  END IF;
END
$preflight$;

-- ---------- Settings seeded from the client's own values ----------

DO $settings$
BEGIN
  IF {{CLIENT_CODE}}_booking.setting_int('slot_step_minutes') <> {{BOOKING_SLOT_STEP_MINUTES}}
     OR {{CLIENT_CODE}}_booking.setting_int('horizon_days') <> {{BOOKING_HORIZON_DAYS}}
     OR {{CLIENT_CODE}}_booking.setting_int('lead_time_hours') <> {{BOOKING_LEAD_TIME_HOURS}}
     OR {{CLIENT_CODE}}_booking.setting_int('cancel_hours') <> {{BOOKING_CANCEL_HOURS}}
     OR {{CLIENT_CODE}}_booking.setting_text('reminder_hours') <> '{{BOOKING_REMINDER_HOURS}}'
     OR {{CLIENT_CODE}}_booking.setting_text('confirm_mode') <> '{{BOOKING_CONFIRM_MODE}}'
     OR {{CLIENT_CODE}}_booking.setting_int('customer_retention_months') <> {{BOOKING_CUSTOMER_RETENTION_MONTHS}} THEN
    RAISE EXCEPTION '050 acceptance: booking_settings does not match the client values';
  END IF;
END
$settings$;

-- ---------- Shared consent journal was widened, not replaced ----------

DO $consent_wording$
DECLARE
  v_row {{CLIENT_CODE}}_privacy.consent_text_versions%ROWTYPE;
BEGIN
  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_privacy.consent_text_versions
  WHERE version = 'booking-1.0';

  IF NOT FOUND
     OR v_row.scope <> 'booking_form'
     OR v_row.effective_from <> TIMESTAMPTZ '2026-09-25 00:00:00+03'
     OR v_row.text_sha256 <> public.digest(convert_to(v_row.display_text, 'UTF8'), 'sha256') THEN
    RAISE EXCEPTION '050 acceptance: booking-1.0 consent wording row is missing or wrong';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = '{{CLIENT_CODE}}_privacy'
      AND rel.relname = 'consent_events'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%booking_form%'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = '{{CLIENT_CODE}}_privacy'
      AND rel.relname = 'consent_events'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%booking_widget%'
  ) THEN
    RAISE EXCEPTION '050 acceptance: consent_events scope/ui_surface was not widened for booking';
  END IF;

  -- The original pg-privacy purposes must still be accepted; the widening
  -- must be additive, never a replacement of the existing enum values.
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = '{{CLIENT_CODE}}_privacy'
      AND rel.relname = 'consent_events'
      AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ILIKE '%contact_form%'
      AND pg_get_constraintdef(con.oid) ILIKE '%chat_max%'
  ) THEN
    RAISE EXCEPTION '050 acceptance: widening the scope check dropped an existing purpose';
  END IF;
END
$consent_wording$;

-- ---------- CHECK constraints reject bad rows ----------

DO $checks$
BEGIN
  BEGIN
    INSERT INTO {{CLIENT_CODE}}_booking.services (code, title, duration_minutes)
    VALUES ('verify-050-bad-duration', 'Проверка', 1);
    RAISE EXCEPTION '050 acceptance: duration_minutes CHECK did not reject 1 minute';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO {{CLIENT_CODE}}_booking.slots (staff_id, starts_at, ends_at)
    VALUES (gen_random_uuid(), clock_timestamp(), clock_timestamp());
    RAISE EXCEPTION '050 acceptance: slots CHECK did not reject ends_at <= starts_at';
  EXCEPTION
    WHEN check_violation THEN NULL;
    WHEN foreign_key_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO {{CLIENT_CODE}}_booking.customers (phone_e164)
    VALUES ('123');
    RAISE EXCEPTION '050 acceptance: customers CHECK did not reject a too-short phone';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO {{CLIENT_CODE}}_booking.booking_settings (setting_key, setting_value)
    VALUES ('confirm_mode', 'sometimes')
    ON CONFLICT (setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;
    RAISE EXCEPTION '050 acceptance: confirm_mode CHECK accepted an invalid value';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;
END
$checks$;

-- ---------- Appointment identity is immutable ----------

DO $identity$
DECLARE
  v_service_id uuid;
  v_staff_id uuid;
  v_slot_id uuid;
  v_customer_id uuid;
  v_event uuid := gen_random_uuid();
  v_appt uuid := gen_random_uuid();
BEGIN
  INSERT INTO {{CLIENT_CODE}}_booking.services (code, title, duration_minutes)
  VALUES ('verify-050-service', 'Проверка услуги', 30)
  RETURNING service_id INTO v_service_id;

  INSERT INTO {{CLIENT_CODE}}_booking.staff (code, display_name)
  VALUES ('verify-050-staff', 'Проверка мастера')
  RETURNING staff_id INTO v_staff_id;

  INSERT INTO {{CLIENT_CODE}}_booking.slots (staff_id, starts_at, ends_at, status)
  VALUES (v_staff_id, clock_timestamp() + INTERVAL '1 day', clock_timestamp() + INTERVAL '1 day 30 minutes', 'booked')
  RETURNING slot_id INTO v_slot_id;

  INSERT INTO {{CLIENT_CODE}}_booking.customers (phone_e164)
  VALUES ('79990000050')
  RETURNING customer_id INTO v_customer_id;

  PERFORM {{CLIENT_CODE}}_privacy.record_consent(
    v_event, 'verify-050:' || v_appt::text, 'booking_form', 'granted',
    'booking-1.0', 'booking_widget', clock_timestamp(), '/booking',
    NULL, 'verify-050', v_appt
  );

  INSERT INTO {{CLIENT_CODE}}_booking.appointments (
    appointment_uuid, consent_event_uuid, customer_id, service_id, staff_id,
    slot_id, starts_at, ends_at, source, confirm_code_sha256, page_path
  ) VALUES (
    v_appt, v_event, v_customer_id, v_service_id, v_staff_id,
    v_slot_id, clock_timestamp() + INTERVAL '1 day', clock_timestamp() + INTERVAL '1 day 30 minutes',
    'manual', public.digest(convert_to('verify0050', 'UTF8'), 'sha256'), '/booking'
  );

  BEGIN
    UPDATE {{CLIENT_CODE}}_booking.appointments
    SET appointment_uuid = gen_random_uuid()
    WHERE appointment_uuid = v_appt;
    RAISE EXCEPTION '050 acceptance: appointment identity trigger did not block appointment_uuid mutation';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'appointment identity/evidence linkage is immutable' THEN
        RAISE;
      END IF;
  END;

  UPDATE {{CLIENT_CODE}}_booking.appointments
  SET comment = 'ordinary field may still change'
  WHERE appointment_uuid = v_appt;
END
$identity$;

-- ---------- Ownership and PUBLIC access ----------

DO $access$
BEGIN
  IF (SELECT pg_get_userbyid(relowner) FROM pg_class
      WHERE oid = '{{CLIENT_CODE}}_booking.appointments'::regclass) <> '{{CLIENT_CODE}}' THEN
    RAISE EXCEPTION '050 acceptance: {{CLIENT_CODE}}_booking.appointments is not owned by {{CLIENT_CODE}}';
  END IF;

  -- The PUBLIC pseudo-role has no pg_roles entry, so it cannot be passed as
  -- a role name to has_schema_privilege(); grantee 0 in the ACL means PUBLIC.
  IF EXISTS (
    SELECT 1
    FROM pg_namespace AS n,
         LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) AS a
    WHERE n.nspname = '{{CLIENT_CODE}}_booking'
      AND a.grantee = 0
      AND a.privilege_type = 'USAGE'
  ) THEN
    RAISE EXCEPTION '050 acceptance: PUBLIC still has USAGE on {{CLIENT_CODE}}_booking';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_runtime')
     AND NOT has_schema_privilege('n8n_runtime', '{{CLIENT_CODE}}_booking', 'USAGE') THEN
    RAISE EXCEPTION '050 acceptance: n8n_runtime lacks USAGE on {{CLIENT_CODE}}_booking';
  END IF;
END
$access$;

ROLLBACK;

\echo 'booking_core_050_acceptance=OK'
