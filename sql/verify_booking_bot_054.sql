-- Closed disposable acceptance for {{CLIENT_CODE_UPPER}} pg-booking 054 (booking bot).
-- Run only after 050-054 are applied. Every fixture is rolled back.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('{{CLIENT_CODE}}_booking.dialog_state') IS NULL
     OR to_regclass('{{CLIENT_CODE}}_booking.appointment_owners') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.bot_context(bigint,text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.bot_create_appointment(bigint,uuid,uuid,uuid,uuid,text,text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.bot_cancel_appointment(bigint,uuid)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.bot_due_reminders(timestamp with time zone,integer)') IS NULL THEN
    RAISE EXCEPTION '054 acceptance preflight failed: bot API is incomplete';
  END IF;
END
$preflight$;

DO $rights$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = '{{CLIENT_CODE}}_booking' AND p.proname LIKE 'bot\_%'
    AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) AS a WHERE a.grantee = 0));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '054 acceptance: functions open to PUBLIC: %', v_bad;
  END IF;
END
$rights$;

DO $bot_flow$
DECLARE
  v_admin bigint := 920000000001;
  v_u1 bigint := 920000000011;
  v_u2 bigint := 920000000012;
  v_day date := current_date + 3;
  v_dow int := EXTRACT(DOW FROM current_date + 3)::int;
  v_service uuid;
  v_staff uuid;
  v_s1 uuid; v_s2 uuid; v_s3 uuid;
  v_a1 uuid := gen_random_uuid();
  v_c1 uuid := gen_random_uuid();
  v_a2 uuid := gen_random_uuid();
  v_a3 uuid := gen_random_uuid();
  v_a4 uuid := gen_random_uuid();
  v_a5 uuid;
  v_r jsonb;
  v_n int;
  v_caught boolean;
BEGIN
  INSERT INTO {{CLIENT_CODE}}_booking.admins (max_user_id, display_name) VALUES (v_admin, 'verify-054');
  v_service := {{CLIENT_CODE}}_booking.admin_add_service(v_admin, 'Проверка 054', 30, 100000, 'verify-054-service');
  INSERT INTO {{CLIENT_CODE}}_booking.staff (code, display_name) VALUES ('verify-054-staff', 'Проверка мастера 054')
  RETURNING staff_id INTO v_staff;
  PERFORM {{CLIENT_CODE}}_booking.admin_link_staff_service(v_admin, v_staff, v_service);
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff, v_dow, TIME '10:00', TIME '18:00');
  SELECT fs.slot_id INTO v_s1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service, v_staff, v_day, v_day) AS fs ORDER BY fs.starts_at OFFSET 0 LIMIT 1;
  SELECT fs.slot_id INTO v_s2 FROM {{CLIENT_CODE}}_booking.free_slots(v_service, v_staff, v_day, v_day) AS fs ORDER BY fs.starts_at OFFSET 1 LIMIT 1;
  SELECT fs.slot_id INTO v_s3 FROM {{CLIENT_CODE}}_booking.free_slots(v_service, v_staff, v_day, v_day) AS fs ORDER BY fs.starts_at OFFSET 2 LIMIT 1;
  IF v_s3 IS NULL THEN RAISE EXCEPTION '054 acceptance: fixture slots were not built'; END IF;

  -- context: event dedup, roles, state
  v_r := {{CLIENT_CODE}}_booking.bot_context(v_u1, 'verify-054-evt');
  IF (v_r->>'fresh') <> 'true' OR (v_r->>'admin') <> 'false' OR (v_r->>'consent') <> 'false' THEN
    RAISE EXCEPTION '054 acceptance: first context is wrong: %', v_r;
  END IF;
  IF ({{CLIENT_CODE}}_booking.bot_context(v_u1, 'verify-054-evt')->>'fresh') <> 'false' THEN
    RAISE EXCEPTION '054 acceptance: a repeated event is not marked as seen';
  END IF;
  IF ({{CLIENT_CODE}}_booking.bot_context(v_admin, NULL)->>'admin') <> 'true' THEN
    RAISE EXCEPTION '054 acceptance: administrator is not recognised in the context';
  END IF;
  PERFORM {{CLIENT_CODE}}_booking.bot_state_set(v_u1, 'name', '{"svc":"x"}'::jsonb);
  v_r := {{CLIENT_CODE}}_booking.bot_context(v_u1, NULL);
  IF v_r->>'step' <> 'name' OR v_r->'data'->>'svc' <> 'x' THEN
    RAISE EXCEPTION '054 acceptance: state was not stored: %', v_r;
  END IF;
  PERFORM {{CLIENT_CODE}}_booking.bot_state_set(v_u1, NULL, NULL);
  IF ({{CLIENT_CODE}}_booking.bot_context(v_u1, NULL)->>'step') IS NOT NULL THEN
    RAISE EXCEPTION '054 acceptance: state was not cleared';
  END IF;

  -- no consent -> no booking
  v_r := {{CLIENT_CODE}}_booking.bot_create_appointment(v_u1, v_a1, v_c1, v_service, v_s1, 'Тест', '+7 999 000-00-51');
  IF v_r->>'result' <> 'no_consent' THEN RAISE EXCEPTION '054 acceptance: booking without consent: %', v_r; END IF;
  PERFORM {{CLIENT_CODE}}_booking.bot_grant_consent(v_u1);
  PERFORM {{CLIENT_CODE}}_booking.bot_grant_consent(v_u2);

  -- booking, idempotency, owner
  v_r := {{CLIENT_CODE}}_booking.bot_create_appointment(v_u1, v_a1, v_c1, v_service, v_s1, 'Тест', '+7 999 000-00-51');
  IF v_r->>'result' <> 'ok' OR v_r->'card'->>'service_title' <> 'Проверка 054' THEN
    RAISE EXCEPTION '054 acceptance: booking failed: %', v_r;
  END IF;
  v_r := {{CLIENT_CODE}}_booking.bot_create_appointment(v_u1, v_a1, v_c1, v_service, v_s1, 'Тест', '+7 999 000-00-51');
  IF v_r->>'result' <> 'ok' THEN RAISE EXCEPTION '054 acceptance: repeat of the same booking is not idempotent: %', v_r; END IF;
  SELECT count(*) INTO v_n FROM {{CLIENT_CODE}}_booking.appointment_owners WHERE appointment_uuid = v_a1;
  IF v_n <> 1 THEN RAISE EXCEPTION '054 acceptance: owner row count %', v_n; END IF;
  IF jsonb_array_length({{CLIENT_CODE}}_booking.bot_my_appointments(v_u1)) <> 1
     OR jsonb_array_length({{CLIENT_CODE}}_booking.bot_my_appointments(v_u2)) <> 0 THEN
    RAISE EXCEPTION '054 acceptance: my appointments are wrong';
  END IF;

  -- the same slot for another user: taken, with the list of free slots of the day
  v_r := {{CLIENT_CODE}}_booking.bot_create_appointment(v_u2, v_a2, gen_random_uuid(), v_service, v_s1, 'Другой', '+7 999 000-00-52');
  IF v_r->>'result' <> 'taken' OR jsonb_array_length(v_r->'slots') < 1 THEN
    RAISE EXCEPTION '054 acceptance: second booking of the slot was not refused with slots: %', v_r;
  END IF;
  v_r := {{CLIENT_CODE}}_booking.bot_create_appointment(v_u2, v_a2, gen_random_uuid(), v_service, v_s2, 'Другой', '12');
  IF v_r->>'result' <> 'bad_phone' THEN RAISE EXCEPTION '054 acceptance: bad phone: %', v_r; END IF;

  -- reminders by MAX id
  SELECT count(*) INTO v_n FROM {{CLIENT_CODE}}_booking.bot_due_reminders(v_day::timestamptz + interval '10 hours' - interval '30 minutes', 50)
  WHERE max_user_id = v_u1 AND appointment_uuid = v_a1;
  IF v_n <> 2 THEN RAISE EXCEPTION '054 acceptance: expected 2 due reminders, got %', v_n; END IF;

  -- cancel: stranger refused, owner ok, repeat refused, slot free, reminders skipped
  IF ({{CLIENT_CODE}}_booking.bot_cancel_appointment(v_u2, v_a1)->>'result') <> 'not_found' THEN
    RAISE EXCEPTION '054 acceptance: a stranger cancelled the appointment';
  END IF;
  IF ({{CLIENT_CODE}}_booking.bot_cancel_appointment(v_u1, v_a1)->>'result') <> 'ok' THEN
    RAISE EXCEPTION '054 acceptance: owner could not cancel';
  END IF;
  IF ({{CLIENT_CODE}}_booking.bot_cancel_appointment(v_u1, v_a1)->>'result') <> 'already_cancelled' THEN
    RAISE EXCEPTION '054 acceptance: repeated cancel is not refused';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service, v_staff, v_day, v_day) AS fs WHERE fs.slot_id = v_s1) THEN
    RAISE EXCEPTION '054 acceptance: slot did not become free after cancel';
  END IF;
  SELECT count(*) INTO v_n FROM {{CLIENT_CODE}}_booking.bot_due_reminders(v_day::timestamptz + interval '10 hours' - interval '30 minutes', 50)
  WHERE appointment_uuid = v_a1;
  IF v_n <> 0 THEN RAISE EXCEPTION '054 acceptance: reminders of a cancelled appointment are still due'; END IF;

  -- administrator by phone through the bot wrapper
  v_r := {{CLIENT_CODE}}_booking.bot_admin_create_appointment(v_admin, v_a3, v_service, v_s3, 'По телефону', '+7 999 000-00-53');
  IF v_r->>'result' <> 'ok' THEN RAISE EXCEPTION '054 acceptance: admin booking failed: %', v_r; END IF;
  v_r := {{CLIENT_CODE}}_booking.bot_admin_create_appointment(v_u1, v_a4, v_service, v_s2, 'X', '+7 999 000-00-54');
  IF v_r->>'result' <> 'forbidden' THEN RAISE EXCEPTION '054 acceptance: a customer booked as administrator: %', v_r; END IF;

  -- unmapped failure (NULL appointment uuid): the client gets a fixed code and text, never the exception text
  v_r := {{CLIENT_CODE}}_booking.bot_create_appointment(v_u2, NULL, gen_random_uuid(), v_service, v_s2, 'Сбой', '+7 999 000-00-56');
  IF v_r->>'result' <> 'error' OR v_r->>'code' <> 'internal_error' OR v_r->>'message' <> 'internal error' THEN
    RAISE EXCEPTION '054 acceptance: bot_create_appointment leaks or changes the error shape: %', v_r;
  END IF;
  v_r := {{CLIENT_CODE}}_booking.bot_admin_create_appointment(v_admin, NULL, v_service, v_s2, 'Сбой', '+7 999 000-00-57');
  IF v_r->>'result' <> 'error' OR v_r->>'code' <> 'internal_error' OR v_r->>'message' <> 'internal error' THEN
    RAISE EXCEPTION '054 acceptance: bot_admin_create_appointment leaks or changes the error shape: %', v_r;
  END IF;

  -- day off + booking -> cancel through the bot: the day must not get free windows back
  v_a5 := gen_random_uuid();
  v_r := {{CLIENT_CODE}}_booking.bot_create_appointment(v_u2, v_a5, gen_random_uuid(), v_service, v_s2, 'Выходной', '+7 999 000-00-55');
  IF v_r->>'result' <> 'ok' THEN RAISE EXCEPTION '054 acceptance: booking before day off: %', v_r; END IF;
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_exception(v_admin, v_staff, v_day, false, NULL, NULL, 'verify-054');
  IF ({{CLIENT_CODE}}_booking.bot_cancel_appointment(v_u2, v_a5)->>'result') <> 'ok' THEN
    RAISE EXCEPTION '054 acceptance: cancel on a day off failed';
  END IF;
  SELECT count(*) INTO v_n FROM {{CLIENT_CODE}}_booking.free_slots(v_service, v_staff, v_day, v_day);
  IF v_n <> 0 THEN RAISE EXCEPTION '054 acceptance: cancel through the bot reopened % windows on a day off', v_n; END IF;

  -- n8n_runtime: functions yes, tables and helpers no
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_runtime') THEN
    SET LOCAL ROLE n8n_runtime;
    PERFORM {{CLIENT_CODE}}_booking.bot_context(v_u2, NULL);
    v_caught := false;
    BEGIN
      PERFORM count(*) FROM {{CLIENT_CODE}}_booking.dialog_state;
    EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
    END;
    IF NOT v_caught THEN RAISE EXCEPTION '054 acceptance: n8n_runtime reads dialog_state'; END IF;
    v_caught := false;
    BEGIN
      PERFORM {{CLIENT_CODE}}_booking.bot_appt_card(v_a1);
    EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
    END;
    IF NOT v_caught THEN RAISE EXCEPTION '054 acceptance: n8n_runtime calls the helper bot_appt_card'; END IF;
    RESET ROLE;
  END IF;
END
$bot_flow$;

ROLLBACK;

\echo 'booking_bot_054_acceptance=OK'
