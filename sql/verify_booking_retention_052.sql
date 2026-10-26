-- Closed disposable acceptance for {{CLIENT_CODE_UPPER}} pg-booking 052.
-- Run only after 050-052 are applied. Every fixture is rolled back; nothing
-- here is meant to survive in the target database.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
  IF to_regprocedure('{{CLIENT_CODE}}_booking.retention_preview(date)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.run_retention_cleanup(boolean,date)') IS NULL THEN
    RAISE EXCEPTION '052 acceptance preflight failed: booking retention functions are missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_privacy.retention_policy
    WHERE data_class IN ('booking_appointments', 'booking_customers')
  ) THEN
    RAISE EXCEPTION '052 acceptance preflight failed: booking retention policy rows are missing';
  END IF;
END
$preflight$;

DO $retention$
DECLARE
  v_service_id uuid;
  v_staff_id uuid;
  v_old_slot_id uuid;
  v_recent_slot_id uuid;
  v_old_customer_id uuid;
  v_recent_customer_id uuid;
  v_old_event uuid := gen_random_uuid();
  v_recent_event uuid := gen_random_uuid();
  v_old_appt uuid := gen_random_uuid();
  v_recent_appt uuid := gen_random_uuid();
  v_preview_appt bigint;
  v_preview_cust bigint;
  v_dry record;
  v_run record;
BEGIN
  INSERT INTO {{CLIENT_CODE}}_booking.services (code, title, duration_minutes)
  VALUES ('verify-052-service', 'Проверка услуги', 30)
  RETURNING service_id INTO v_service_id;

  INSERT INTO {{CLIENT_CODE}}_booking.staff (code, display_name)
  VALUES ('verify-052-staff', 'Проверка мастера')
  RETURNING staff_id INTO v_staff_id;

  INSERT INTO {{CLIENT_CODE}}_booking.slots (staff_id, starts_at, ends_at, status)
  VALUES (v_staff_id, current_date - INTERVAL '3 years', current_date - INTERVAL '3 years' + INTERVAL '30 minutes', 'closed')
  RETURNING slot_id INTO v_old_slot_id;

  INSERT INTO {{CLIENT_CODE}}_booking.slots (staff_id, starts_at, ends_at, status)
  VALUES (v_staff_id, current_date - INTERVAL '1 month', current_date - INTERVAL '1 month' + INTERVAL '30 minutes', 'closed')
  RETURNING slot_id INTO v_recent_slot_id;

  INSERT INTO {{CLIENT_CODE}}_booking.customers (customer_id, phone_e164, first_seen_at, last_visit_at)
  VALUES (gen_random_uuid(), '79990000521', current_date - INTERVAL '3 years', NULL)
  RETURNING customer_id INTO v_old_customer_id;

  INSERT INTO {{CLIENT_CODE}}_booking.customers (customer_id, phone_e164, first_seen_at, last_visit_at)
  VALUES (gen_random_uuid(), '79990000522', current_date - INTERVAL '2 months', current_date - INTERVAL '1 month')
  RETURNING customer_id INTO v_recent_customer_id;

  -- record_consent requires client_at close to server time; the fixture's
  -- age lives in the appointment/slot/customer timestamps below, not here.
  PERFORM {{CLIENT_CODE}}_privacy.record_consent(
    v_old_event, 'verify-052-old:' || v_old_appt::text, 'booking_form', 'granted',
    'booking-1.0', 'booking_widget', clock_timestamp(), '/booking',
    NULL, 'verify-052', v_old_appt
  );
  PERFORM {{CLIENT_CODE}}_privacy.record_consent(
    v_recent_event, 'verify-052-recent:' || v_recent_appt::text, 'booking_form', 'granted',
    'booking-1.0', 'booking_widget', clock_timestamp(), '/booking',
    NULL, 'verify-052', v_recent_appt
  );

  INSERT INTO {{CLIENT_CODE}}_booking.appointments (
    appointment_uuid, consent_event_uuid, customer_id, service_id, staff_id,
    slot_id, starts_at, ends_at, status, source, confirm_code_sha256, page_path
  ) VALUES (
    v_old_appt, v_old_event, v_old_customer_id, v_service_id, v_staff_id,
    v_old_slot_id, current_date - INTERVAL '3 years', current_date - INTERVAL '3 years' + INTERVAL '30 minutes',
    'done', 'manual', public.digest(convert_to('verifyold052', 'UTF8'), 'sha256'), '/booking'
  );

  INSERT INTO {{CLIENT_CODE}}_booking.appointments (
    appointment_uuid, consent_event_uuid, customer_id, service_id, staff_id,
    slot_id, starts_at, ends_at, status, source, confirm_code_sha256, page_path
  ) VALUES (
    v_recent_appt, v_recent_event, v_recent_customer_id, v_service_id, v_staff_id,
    v_recent_slot_id, current_date - INTERVAL '1 month', current_date - INTERVAL '1 month' + INTERVAL '30 minutes',
    'done', 'manual', public.digest(convert_to('verifynew052', 'UTF8'), 'sha256'), '/booking'
  );

  -- ---- preview: old appointment eligible, its customer not yet (still referenced) ----
  SELECT eligible_rows INTO v_preview_appt
  FROM {{CLIENT_CODE}}_booking.retention_preview(current_date)
  WHERE data_class = 'booking_appointments';
  SELECT eligible_rows INTO v_preview_cust
  FROM {{CLIENT_CODE}}_booking.retention_preview(current_date)
  WHERE data_class = 'booking_customers';

  IF v_preview_appt < 1 THEN
    RAISE EXCEPTION '052 acceptance: retention_preview did not count the old appointment as eligible';
  END IF;
  -- The old customer still has an appointment row at this point, so it must
  -- not be reported as eligible until that appointment has been cleaned up.
  IF v_preview_cust <> 0 THEN
    RAISE EXCEPTION '052 acceptance: a customer with a surviving appointment was reported eligible for deletion';
  END IF;

  -- ---- dry run must not delete anything ----
  SELECT * INTO v_dry
  FROM {{CLIENT_CODE}}_booking.run_retention_cleanup(true, current_date);
  IF NOT v_dry.dry_run OR v_dry.deleted_appointments < 1 THEN
    RAISE EXCEPTION '052 acceptance: dry-run cleanup did not report the old appointment';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments WHERE appointment_uuid = v_old_appt) THEN
    RAISE EXCEPTION '052 acceptance: a dry run deleted data';
  END IF;

  -- ---- real cleanup: old appointment, then its now-unreferenced customer ----
  SELECT * INTO v_run
  FROM {{CLIENT_CODE}}_booking.run_retention_cleanup(false, current_date);
  IF v_run.dry_run OR v_run.deleted_appointments < 1 OR v_run.deleted_customers < 1 THEN
    RAISE EXCEPTION '052 acceptance: cleanup did not delete the expected old appointment and customer';
  END IF;

  IF EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments WHERE appointment_uuid = v_old_appt) THEN
    RAISE EXCEPTION '052 acceptance: old appointment survived cleanup';
  END IF;
  IF EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.customers WHERE customer_id = v_old_customer_id) THEN
    RAISE EXCEPTION '052 acceptance: old customer survived cleanup';
  END IF;

  -- ---- recent appointment/customer must survive ----
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments WHERE appointment_uuid = v_recent_appt) THEN
    RAISE EXCEPTION '052 acceptance: cleanup deleted a recent appointment that is still within retention';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.customers WHERE customer_id = v_recent_customer_id) THEN
    RAISE EXCEPTION '052 acceptance: cleanup deleted a recent customer that is still within retention';
  END IF;

  -- ---- consent evidence is a separate legal contour and must never be touched ----
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_privacy.consent_events WHERE event_uuid = v_old_event) THEN
    RAISE EXCEPTION '052 acceptance: booking retention cleanup deleted consent evidence; it must not';
  END IF;
END
$retention$;

ROLLBACK;

\echo 'booking_retention_052_acceptance=OK'
