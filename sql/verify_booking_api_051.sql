-- Closed disposable acceptance for {{CLIENT_CODE_UPPER}} pg-booking 051.
-- Run only after 050-051 are applied. Every fixture is rolled back; nothing
-- here is meant to survive in the target database.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
  IF to_regprocedure('{{CLIENT_CODE}}_booking.generate_slots(date,date)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.list_services()') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.list_staff(uuid)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.free_slots(uuid,uuid,date,date)') IS NULL
     OR to_regprocedure(
          '{{CLIENT_CODE}}_booking.create_appointment(uuid,uuid,text,timestamptz,text,uuid,uuid,text,text,text,text,text,inet,text)'
        ) IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.cancel_appointment(uuid,text,text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.due_reminders(timestamptz,int)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.mark_reminder(uuid,text,text)') IS NULL THEN
    RAISE EXCEPTION '051 acceptance preflight failed: booking API is incomplete';
  END IF;
END
$preflight$;

DO $booking_flow$
DECLARE
  v_service_id uuid;
  v_staff_id uuid;
  v_day date := current_date + 2;
  v_generated bigint;
  v_first_slot_id uuid;
  v_second_slot_id uuid;
  v_third_slot_id uuid;
  v_appt_a uuid := gen_random_uuid();
  v_appt_a_consent uuid := gen_random_uuid();
  v_appt_b uuid := gen_random_uuid();
  v_appt_conflict uuid := gen_random_uuid();
  v_appt_too_soon uuid := gen_random_uuid();
  v_result record;
  v_cancel record;
  v_code text;
  v_cancel_hours_before text;
  v_soon_slot_id uuid;
  v_reminder_id uuid;
  v_marked boolean;
  v_due_count int;
BEGIN
  INSERT INTO {{CLIENT_CODE}}_booking.services (code, title, duration_minutes)
  VALUES ('verify-051-service', 'Проверка услуги', 60)
  RETURNING service_id INTO v_service_id;

  INSERT INTO {{CLIENT_CODE}}_booking.staff (code, display_name)
  VALUES ('verify-051-staff', 'Проверка мастера')
  RETURNING staff_id INTO v_staff_id;

  INSERT INTO {{CLIENT_CODE}}_booking.staff_services (staff_id, service_id)
  VALUES (v_staff_id, v_service_id);

  INSERT INTO {{CLIENT_CODE}}_booking.schedule_exceptions (staff_id, exception_date, is_working, starts_time, ends_time)
  VALUES (v_staff_id, v_day, true, TIME '09:00', TIME '11:00');

  -- ---- generate_slots ----
  v_generated := {{CLIENT_CODE}}_booking.generate_slots(v_day, v_day);
  IF v_generated <> 4 THEN
    RAISE EXCEPTION '051 acceptance: expected 4 generated slots for a 2-hour window at 30-minute step, got %', v_generated;
  END IF;

  -- Re-running generate_slots must be idempotent.
  IF {{CLIENT_CODE}}_booking.generate_slots(v_day, v_day) <> 0 THEN
    RAISE EXCEPTION '051 acceptance: generate_slots is not idempotent';
  END IF;

  -- ---- catalog reads ----
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.list_services() WHERE service_id = v_service_id
  ) THEN
    RAISE EXCEPTION '051 acceptance: list_services did not return the test service';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.list_staff(v_service_id) WHERE staff_id = v_staff_id
  ) THEN
    RAISE EXCEPTION '051 acceptance: list_staff did not return the test staff for the test service';
  END IF;

  -- ---- free_slots: a 60-minute service needs two consecutive 30-minute slots ----
  SELECT slot_id INTO v_first_slot_id
  FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day)
  ORDER BY starts_at
  LIMIT 1;
  IF v_first_slot_id IS NULL THEN
    RAISE EXCEPTION '051 acceptance: free_slots returned nothing for the test window';
  END IF;

  SELECT slot_id INTO v_second_slot_id
  FROM {{CLIENT_CODE}}_booking.slots
  WHERE staff_id = v_staff_id
  ORDER BY starts_at
  OFFSET 1 LIMIT 1;
  SELECT slot_id INTO v_third_slot_id
  FROM {{CLIENT_CODE}}_booking.slots
  WHERE staff_id = v_staff_id
  ORDER BY starts_at
  OFFSET 2 LIMIT 1;

  -- ---- create_appointment: success ----
  SELECT * INTO v_result
  FROM {{CLIENT_CODE}}_booking.create_appointment(
    v_appt_a, v_appt_a_consent, 'booking-1.0', clock_timestamp(), '/booking',
    v_service_id, v_first_slot_id, 'Тест Клиент', '+7 999 000-00-61', NULL,
    NULL, 'site', NULL, 'verify-051'
  );
  v_code := v_result.confirm_code;
  IF v_code IS NULL OR char_length(v_code) < 8 THEN
    RAISE EXCEPTION '051 acceptance: create_appointment did not return a cancellation code';
  END IF;
  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments AS ap
    WHERE ap.appointment_uuid = v_appt_a
      AND ap.confirm_code_sha256 IS DISTINCT FROM public.digest(convert_to(v_code, 'UTF8'), 'sha256')
  ) THEN
    RAISE EXCEPTION '051 acceptance: stored cancellation code hash does not match the issued code';
  END IF;

  IF v_result.appointment_id <> v_appt_a
     OR v_result.status <> 'confirmed'
     OR v_result.ends_at <> v_result.starts_at + INTERVAL '60 minutes' THEN
    RAISE EXCEPTION '051 acceptance: create_appointment did not book the expected 60-minute run, status=%', v_result.status;
  END IF;

  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.slots
    WHERE slot_id IN (v_first_slot_id, v_second_slot_id) AND status <> 'booked'
  ) THEN
    RAISE EXCEPTION '051 acceptance: both slots the service needs were not marked booked';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.slots WHERE slot_id = v_third_slot_id AND status = 'free'
  ) THEN
    RAISE EXCEPTION '051 acceptance: a slot beyond the booked run was consumed unexpectedly';
  END IF;

  -- ---- idempotent repeat with the same UUID and the same data ----
  SELECT * INTO v_result
  FROM {{CLIENT_CODE}}_booking.create_appointment(
    v_appt_a, v_appt_a_consent, 'booking-1.0', clock_timestamp(), '/booking',
    v_service_id, v_first_slot_id, 'Тест Клиент', '+7 999 000-00-61', NULL,
    NULL, 'site', NULL, 'verify-051'
  );
  IF v_result.appointment_id <> v_appt_a OR v_result.status <> 'confirmed' THEN
    RAISE EXCEPTION '051 acceptance: repeated create_appointment call was not idempotent';
  END IF;
  -- A repeat must not hand out a cancellation code again: only the hash is kept.
  IF v_result.confirm_code IS NOT NULL THEN
    RAISE EXCEPTION '051 acceptance: repeated create_appointment call re-issued a cancellation code';
  END IF;

  -- ---- same UUID, different data: must be refused, not silently changed ----
  BEGIN
    PERFORM * FROM {{CLIENT_CODE}}_booking.create_appointment(
      v_appt_a, gen_random_uuid(), 'booking-1.0', clock_timestamp(), '/booking',
      v_service_id, v_first_slot_id, 'Тест Клиент', '+7 999 000-00-99', NULL,
      NULL, 'site', NULL, 'verify-051'
    );
    RAISE EXCEPTION '051 acceptance: create_appointment accepted conflicting data for an existing UUID';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'appointment UUID conflicts with an existing booking' THEN
        RAISE;
      END IF;
  END;

  -- ---- a different UUID for an already-booked slot must be refused ----
  BEGIN
    PERFORM * FROM {{CLIENT_CODE}}_booking.create_appointment(
      v_appt_conflict, gen_random_uuid(), 'booking-1.0', clock_timestamp(), '/booking',
      v_service_id, v_first_slot_id, 'Другой Клиент', '+7 999 000-00-62', NULL,
      NULL, 'site', NULL, 'verify-051'
    );
    RAISE EXCEPTION '051 acceptance: booking an already-booked slot was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'slot is no longer available' THEN
        RAISE;
      END IF;
  END;

  -- ---- a slot inside the configured lead time must be refused ----
  INSERT INTO {{CLIENT_CODE}}_booking.slots (staff_id, starts_at, ends_at, status)
  VALUES (v_staff_id, clock_timestamp() + INTERVAL '10 minutes', clock_timestamp() + INTERVAL '40 minutes', 'free')
  RETURNING slot_id INTO v_soon_slot_id;

  BEGIN
    PERFORM * FROM {{CLIENT_CODE}}_booking.create_appointment(
      v_appt_too_soon, gen_random_uuid(), 'booking-1.0', clock_timestamp(), '/booking',
      v_service_id, v_soon_slot_id, 'Слишком Быстро', '+7 999 000-00-63', NULL,
      NULL, 'site', NULL, 'verify-051'
    );
    RAISE EXCEPTION '051 acceptance: a slot inside lead_time_hours was accepted';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'slot no longer satisfies the minimum lead time' THEN
        RAISE;
      END IF;
  END;

  -- ---- reminders were scheduled and are reachable from the future ----
  SELECT count(*) INTO v_due_count
  FROM {{CLIENT_CODE}}_booking.due_reminders(
    (SELECT starts_at FROM {{CLIENT_CODE}}_booking.appointments WHERE appointment_uuid = v_appt_a),
    100
  )
  WHERE appointment_uuid = v_appt_a;
  IF v_due_count <> 2 THEN
    RAISE EXCEPTION '051 acceptance: expected 2 due reminders (24h and 2h) for the booked appointment, got %', v_due_count;
  END IF;

  SELECT reminder_id INTO v_reminder_id
  FROM {{CLIENT_CODE}}_booking.reminders
  WHERE appointment_uuid = v_appt_a AND kind = 'before_2h';

  v_marked := {{CLIENT_CODE}}_booking.mark_reminder(v_reminder_id, 'sent', 'sms');
  IF NOT v_marked THEN
    RAISE EXCEPTION '051 acceptance: mark_reminder did not mark a pending reminder as sent';
  END IF;

  SELECT count(*) INTO v_due_count
  FROM {{CLIENT_CODE}}_booking.due_reminders(
    (SELECT starts_at FROM {{CLIENT_CODE}}_booking.appointments WHERE appointment_uuid = v_appt_a),
    100
  )
  WHERE appointment_uuid = v_appt_a;
  IF v_due_count <> 1 THEN
    RAISE EXCEPTION '051 acceptance: due_reminders still counts a reminder already marked sent';
  END IF;

  IF {{CLIENT_CODE}}_booking.mark_reminder(v_reminder_id, 'sent', 'sms') THEN
    RAISE EXCEPTION '051 acceptance: mark_reminder re-marked an already-sent reminder';
  END IF;

  -- ---- cancel_appointment: wrong code ----
  SELECT * INTO v_cancel
  FROM {{CLIENT_CODE}}_booking.cancel_appointment(v_appt_a, 'wrong-code', NULL);
  IF v_cancel.cancelled OR v_cancel.reason_code <> 'bad_code' THEN
    RAISE EXCEPTION '051 acceptance: cancel_appointment accepted a wrong confirm code';
  END IF;

  -- ---- cancel_appointment: too late (inside cancel_hours) ----
  -- The function now takes its own clock, so the deadline is moved instead of
  -- the time: that is exactly the abuse the removed p_at argument allowed.
  SELECT setting_value INTO v_cancel_hours_before
  FROM {{CLIENT_CODE}}_booking.booking_settings WHERE setting_key = 'cancel_hours';
  UPDATE {{CLIENT_CODE}}_booking.booking_settings
  SET setting_value = '100000' WHERE setting_key = 'cancel_hours';

  SELECT * INTO v_cancel
  FROM {{CLIENT_CODE}}_booking.cancel_appointment(v_appt_a, v_code, NULL);
  IF v_cancel.cancelled OR v_cancel.reason_code <> 'too_late' THEN
    RAISE EXCEPTION '051 acceptance: cancel_appointment allowed a cancellation inside cancel_hours';
  END IF;

  UPDATE {{CLIENT_CODE}}_booking.booking_settings
  SET setting_value = v_cancel_hours_before WHERE setting_key = 'cancel_hours';

  -- ---- cancel_appointment: ok ----
  SELECT * INTO v_cancel
  FROM {{CLIENT_CODE}}_booking.cancel_appointment(v_appt_a, v_code, 'verify-051 cleanup');
  IF NOT v_cancel.cancelled OR v_cancel.reason_code <> 'ok' OR v_cancel.status <> 'cancelled' THEN
    RAISE EXCEPTION '051 acceptance: a timely cancel_appointment call was refused';
  END IF;

  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.slots
    WHERE slot_id IN (v_first_slot_id, v_second_slot_id) AND status <> 'free'
  ) THEN
    RAISE EXCEPTION '051 acceptance: cancellation did not free the held slots';
  END IF;
  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.reminders
    WHERE appointment_uuid = v_appt_a AND status = 'pending'
  ) THEN
    RAISE EXCEPTION '051 acceptance: cancellation left a pending reminder behind';
  END IF;

  -- ---- cancel_appointment: already cancelled ----
  SELECT * INTO v_cancel
  FROM {{CLIENT_CODE}}_booking.cancel_appointment(v_appt_a, v_code, NULL);
  IF v_cancel.cancelled OR v_cancel.reason_code <> 'already_cancelled' THEN
    RAISE EXCEPTION '051 acceptance: cancel_appointment did not report an already-cancelled booking';
  END IF;

  -- ---- cancel_appointment: not found ----
  SELECT * INTO v_cancel
  FROM {{CLIENT_CODE}}_booking.cancel_appointment(gen_random_uuid(), 'anything', NULL);
  IF v_cancel.cancelled OR v_cancel.reason_code <> 'not_found' THEN
    RAISE EXCEPTION '051 acceptance: cancel_appointment did not report a missing appointment';
  END IF;

  -- ---- booking the now-freed slot again must succeed ----
  SELECT * INTO v_result
  FROM {{CLIENT_CODE}}_booking.create_appointment(
    v_appt_b, gen_random_uuid(), 'booking-1.0', clock_timestamp(), '/booking',
    v_service_id, v_first_slot_id, 'Второй Клиент', '+7 999 000-00-64', NULL,
    NULL, 'bot', NULL, 'verify-051'
  );
  IF v_result.status <> 'confirmed' THEN
    RAISE EXCEPTION '051 acceptance: rebooking a freed slot after cancellation was refused';
  END IF;
END
$booking_flow$;

ROLLBACK;

\echo 'booking_api_051_acceptance=OK'
