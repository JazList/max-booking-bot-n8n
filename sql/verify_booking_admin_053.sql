-- Closed disposable acceptance for {{CLIENT_CODE_UPPER}} pg-booking 053.
-- Run only after 050-053 are applied. Every fixture is rolled back; nothing
-- here is meant to survive in the target database.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('{{CLIENT_CODE}}_booking.admins') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.is_admin(bigint)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_list_services(bigint)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_add_service(bigint,text,integer,bigint,text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_update_service(bigint,uuid,text,integer,bigint,boolean)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_set_service_active(bigint,uuid,boolean)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_list_staff(bigint)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_link_staff_service(bigint,uuid,uuid)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_unlink_staff_service(bigint,uuid,uuid)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_set_work_hours(bigint,uuid,integer,time without time zone,time without time zone)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_set_exception(bigint,uuid,date,boolean,time without time zone,time without time zone,text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_remove_exception(bigint,uuid,date)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_create_appointment(bigint,uuid,uuid,uuid,text,text,text)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_list_appointments(bigint,date,boolean)') IS NULL
     OR to_regprocedure('{{CLIENT_CODE}}_booking.admin_cancel_appointment(bigint,uuid,text)') IS NULL THEN
    RAISE EXCEPTION '053 acceptance preflight failed: admin API is incomplete';
  END IF;
END
$preflight$;

-- Rights: no function of the admin API is open to PUBLIC (KB-02#6, checked on proacl).
DO $rights$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_bad
  FROM pg_proc AS p
  JOIN pg_namespace AS n ON n.oid = p.pronamespace
  WHERE n.nspname = '{{CLIENT_CODE}}_booking'
    AND (p.proname LIKE 'admin\_%' OR p.proname IN ('is_admin', 'require_admin', 'resync_staff_slots'))
    AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) AS a WHERE a.grantee = 0));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION '053 acceptance: functions open to PUBLIC: %', v_bad;
  END IF;
END
$rights$;

DO $admin_flow$
DECLARE
  v_admin bigint := 910000000001;
  v_stranger bigint := 910000000002;
  v_inactive bigint := 910000000003;
  v_day date := current_date + 3;
  v_dow int := EXTRACT(DOW FROM current_date + 3)::int;
  v_service_id uuid;
  v_service2_id uuid;
  v_staff_id uuid;
  v_slot_a uuid;
  v_slot_b uuid;
  v_ok boolean;
  v_row record;
  v_price bigint;
  v_title text;
  v_appt uuid := gen_random_uuid();
  v_appt2 uuid := gen_random_uuid();
  v_appt3 uuid := gen_random_uuid();
  v_appt4 uuid := gen_random_uuid();
  v_n int;
  v_caught boolean;
BEGIN
  INSERT INTO {{CLIENT_CODE}}_booking.admins (max_user_id, display_name) VALUES (v_admin, 'verify-053');
  INSERT INTO {{CLIENT_CODE}}_booking.admins (max_user_id, display_name, is_active) VALUES (v_inactive, 'verify-053-off', false);

  -- ---- is_admin ----
  IF NOT {{CLIENT_CODE}}_booking.is_admin(v_admin) THEN
    RAISE EXCEPTION '053 acceptance: registered administrator is not recognised';
  END IF;
  IF {{CLIENT_CODE}}_booking.is_admin(v_stranger) THEN
    RAISE EXCEPTION '053 acceptance: is_admin is true for a foreign id';
  END IF;
  IF {{CLIENT_CODE}}_booking.is_admin(v_inactive) OR {{CLIENT_CODE}}_booking.is_admin(NULL) THEN
    RAISE EXCEPTION '053 acceptance: is_admin is true for an inactive or NULL id';
  END IF;

  -- ---- a foreign id is refused by every kind of admin function ----
  v_caught := false;
  BEGIN
    PERFORM {{CLIENT_CODE}}_booking.admin_add_service(v_stranger, 'X', 30, NULL);
  EXCEPTION WHEN raise_exception THEN
    v_caught := SQLERRM = 'not an administrator';
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION '053 acceptance: admin_add_service accepted a foreign id';
  END IF;
  v_caught := false;
  BEGIN
    PERFORM * FROM {{CLIENT_CODE}}_booking.admin_list_appointments(v_stranger, v_day);
  EXCEPTION WHEN raise_exception THEN
    v_caught := SQLERRM = 'not an administrator';
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION '053 acceptance: admin_list_appointments accepted a foreign id';
  END IF;

  -- ---- services: add, update (NULL keeps), hide / return ----
  v_service_id := {{CLIENT_CODE}}_booking.admin_add_service(v_admin, 'Проверка 053', 60, 150000, 'verify-053-service');
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.list_services() AS ls WHERE ls.service_id = v_service_id) THEN
    RAISE EXCEPTION '053 acceptance: added service is not visible in list_services';
  END IF;
  v_service2_id := {{CLIENT_CODE}}_booking.admin_add_service(v_admin, 'Без кода', 30, NULL);
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.services AS sv WHERE sv.service_id = v_service2_id AND sv.code LIKE 'svc-%') THEN
    RAISE EXCEPTION '053 acceptance: service without code did not get a generated code';
  END IF;

  v_ok := {{CLIENT_CODE}}_booking.admin_update_service(v_admin, v_service_id, 'Проверка 053 (новая)', 90, NULL);
  SELECT sv.title, sv.price_minor, sv.duration_minutes INTO v_title, v_price, v_n
  FROM {{CLIENT_CODE}}_booking.services AS sv WHERE sv.service_id = v_service_id;
  IF NOT v_ok OR v_title <> 'Проверка 053 (новая)' OR v_n <> 90 OR v_price IS DISTINCT FROM 150000 THEN
    RAISE EXCEPTION '053 acceptance: admin_update_service did not keep the price on NULL (title %, duration %, price %)', v_title, v_n, v_price;
  END IF;
  PERFORM {{CLIENT_CODE}}_booking.admin_update_service(v_admin, v_service_id, NULL, 60, 170000);
  PERFORM {{CLIENT_CODE}}_booking.admin_update_service(v_admin, v_service_id, p_clear_price => true, p_title => NULL);
  SELECT sv.price_minor INTO v_price FROM {{CLIENT_CODE}}_booking.services AS sv WHERE sv.service_id = v_service_id;
  IF v_price IS NOT NULL THEN
    RAISE EXCEPTION '053 acceptance: p_clear_price did not clear the price';
  END IF;
  PERFORM {{CLIENT_CODE}}_booking.admin_update_service(v_admin, v_service_id, NULL, NULL, 150000);

  PERFORM {{CLIENT_CODE}}_booking.admin_set_service_active(v_admin, v_service2_id, false);
  IF EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.list_services() AS ls WHERE ls.service_id = v_service2_id) THEN
    RAISE EXCEPTION '053 acceptance: hidden service is still visible in list_services';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.admin_list_services(v_admin) AS al
    WHERE al.service_id = v_service2_id AND al.is_active = false
  ) THEN
    RAISE EXCEPTION '053 acceptance: admin_list_services does not show the hidden service';
  END IF;
  PERFORM {{CLIENT_CODE}}_booking.admin_set_service_active(v_admin, v_service2_id, true);
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.list_services() AS ls WHERE ls.service_id = v_service2_id) THEN
    RAISE EXCEPTION '053 acceptance: returned service is not visible again';
  END IF;

  -- ---- staff link / unlink ----
  INSERT INTO {{CLIENT_CODE}}_booking.staff (code, display_name)
  VALUES ('verify-053-staff', 'Проверка мастера 053')
  RETURNING staff_id INTO v_staff_id;

  IF EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.list_staff(v_service_id) AS ls WHERE ls.staff_id = v_staff_id) THEN
    RAISE EXCEPTION '053 acceptance: staff is listed for a service before the link';
  END IF;
  IF NOT {{CLIENT_CODE}}_booking.admin_link_staff_service(v_admin, v_staff_id, v_service_id)
     OR {{CLIENT_CODE}}_booking.admin_link_staff_service(v_admin, v_staff_id, v_service_id) THEN
    RAISE EXCEPTION '053 acceptance: link must report true once and false on repeat';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.list_staff(v_service_id) AS ls WHERE ls.staff_id = v_staff_id)
     OR NOT EXISTS (
       SELECT 1 FROM {{CLIENT_CODE}}_booking.admin_list_staff(v_admin) AS al
       WHERE al.staff_id = v_staff_id AND v_service_id = ANY (al.service_ids)
     ) THEN
    RAISE EXCEPTION '053 acceptance: link is not visible in list_staff / admin_list_staff';
  END IF;
  IF NOT {{CLIENT_CODE}}_booking.admin_unlink_staff_service(v_admin, v_staff_id, v_service2_id) IS FALSE THEN
    RAISE EXCEPTION '053 acceptance: unlink of a missing link must return false';
  END IF;

  -- ---- work hours: the weekday of v_day becomes 10:00-12:00 ----
  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff_id, v_dow, TIME '10:00', TIME '12:00');
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs
  ) THEN
    RAISE EXCEPTION '053 acceptance: no free slots after setting work hours';
  END IF;
  SELECT count(*) INTO v_n FROM {{CLIENT_CODE}}_booking.slots AS sl
  WHERE sl.staff_id = v_staff_id AND sl.starts_at >= v_day::timestamptz AND sl.starts_at < (v_day + 1)::timestamptz;
  IF v_n <> 4 THEN
    RAISE EXCEPTION '053 acceptance: expected 4 slots for 10:00-12:00 at 30-minute step, got %', v_n;
  END IF;

  -- ---- day off removes the windows; removing the exception brings them back ----
  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_booking.admin_set_exception(v_admin, v_staff_id, v_day, false, NULL, NULL, 'verify');
  IF EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs) THEN
    RAISE EXCEPTION '053 acceptance: a day off did not remove the windows from free_slots';
  END IF;
  v_ok := {{CLIENT_CODE}}_booking.admin_remove_exception(v_admin, v_staff_id, v_day);
  IF NOT v_ok THEN
    RAISE EXCEPTION '053 acceptance: admin_remove_exception returned false for an existing exception';
  END IF;
  -- separate statement: a query in the same expression would keep the snapshot from before the removal
  IF NOT EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs) THEN
    RAISE EXCEPTION '053 acceptance: removing the exception did not restore the windows';
  END IF;
  IF {{CLIENT_CODE}}_booking.admin_remove_exception(v_admin, v_staff_id, v_day) THEN
    RAISE EXCEPTION '053 acceptance: removing a missing exception must return false';
  END IF;

  -- special hours 10:00-11:00 -> a 60-minute service fits exactly once
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_exception(v_admin, v_staff_id, v_day, true, TIME '10:00', TIME '11:00', NULL);
  SELECT count(*) INTO v_n FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs;
  IF v_n <> 1 THEN
    RAISE EXCEPTION '053 acceptance: special hours should leave 1 window, got %', v_n;
  END IF;
  PERFORM {{CLIENT_CODE}}_booking.admin_remove_exception(v_admin, v_staff_id, v_day);

  -- ---- phone booking takes the window and a second one is refused ----
  SELECT fs.slot_id INTO v_slot_a
  FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs
  ORDER BY fs.starts_at LIMIT 1;
  SELECT sl.slot_id INTO v_slot_b
  FROM {{CLIENT_CODE}}_booking.slots AS sl
  WHERE sl.staff_id = v_staff_id AND sl.starts_at >= v_day::timestamptz
  ORDER BY sl.starts_at OFFSET 1 LIMIT 1;

  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_booking.admin_create_appointment(v_admin, v_appt, v_service_id, v_slot_a, 'Клиент по телефону', '+7 999 000-05-30', 'verify');
  IF v_row.status <> 'confirmed' THEN
    RAISE EXCEPTION '053 acceptance: phone booking status is %', v_row.status;
  END IF;
  -- repeat with the same uuid is idempotent
  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_booking.admin_create_appointment(v_admin, v_appt, v_service_id, v_slot_a, 'Клиент по телефону', '+7 999 000-05-30', 'verify');
  IF v_row.appointment_id <> v_appt THEN
    RAISE EXCEPTION '053 acceptance: repeated phone booking did not return the same appointment';
  END IF;

  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs
    WHERE fs.slot_id = v_slot_a
  ) THEN
    RAISE EXCEPTION '053 acceptance: the booked window is still offered by free_slots';
  END IF;

  -- same time again (new uuid) -> refused
  v_caught := false;
  BEGIN
    PERFORM * FROM {{CLIENT_CODE}}_booking.admin_create_appointment(v_admin, v_appt2, v_service_id, v_slot_a, 'Второй', '+7 999 000-05-31', NULL);
  EXCEPTION WHEN raise_exception THEN
    v_caught := SQLERRM = 'slot is no longer available';
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION '053 acceptance: second phone booking on the same time was not refused';
  END IF;
  -- a slot inside the booked 60 minutes -> refused too
  v_caught := false;
  BEGIN
    PERFORM * FROM {{CLIENT_CODE}}_booking.admin_create_appointment(v_admin, v_appt2, v_service_id, v_slot_b, 'Второй', '+7 999 000-05-31', NULL);
  EXCEPTION WHEN raise_exception THEN
    v_caught := SQLERRM = 'slot is no longer available';
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION '053 acceptance: overlapping phone booking was not refused';
  END IF;
  -- the customer route (create_appointment, 051) is refused by the same slots
  v_caught := false;
  BEGIN
    PERFORM * FROM {{CLIENT_CODE}}_booking.create_appointment(
      gen_random_uuid(), gen_random_uuid(), 'booking-1.0', clock_timestamp(), '/booking',
      v_service_id, v_slot_a, 'Клиент сайта', '+7 999 000-05-32', NULL, NULL, 'bot', NULL, 'verify-053');
  EXCEPTION WHEN raise_exception THEN
    v_caught := SQLERRM = 'slot is no longer available';
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION '053 acceptance: create_appointment was not refused on a phone-booked window';
  END IF;

  -- ---- day list ----
  SELECT count(*) INTO v_n FROM {{CLIENT_CODE}}_booking.admin_list_appointments(v_admin, v_day) AS la
  WHERE la.appointment_uuid = v_appt AND la.source = 'manual' AND la.customer_phone = '79990000530';
  IF v_n <> 1 THEN
    RAISE EXCEPTION '053 acceptance: admin_list_appointments did not return the phone booking';
  END IF;

  -- day off after a booking keeps the appointment and reports it
  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_booking.admin_set_exception(v_admin, v_staff_id, v_day, false, NULL, NULL, NULL);
  IF v_row.active_appointments <> 1 THEN
    RAISE EXCEPTION '053 acceptance: day off must report 1 active appointment, got %', v_row.active_appointments;
  END IF;
  PERFORM {{CLIENT_CODE}}_booking.admin_remove_exception(v_admin, v_staff_id, v_day);
  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs
    WHERE fs.slot_id = v_slot_a
  ) THEN
    RAISE EXCEPTION '053 acceptance: a resync offered a window over the booked time';
  END IF;

  -- ---- admin cancel frees the window ----
  IF NOT {{CLIENT_CODE}}_booking.admin_cancel_appointment(v_admin, v_appt, 'verify')
     OR {{CLIENT_CODE}}_booking.admin_cancel_appointment(v_admin, v_appt, 'verify') THEN
    RAISE EXCEPTION '053 acceptance: admin_cancel_appointment must succeed once';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.slots AS sl WHERE sl.slot_id = v_slot_a AND sl.status = 'free'
  ) THEN
    RAISE EXCEPTION '053 acceptance: cancelled phone booking did not free the slot';
  END IF;

  -- ---- after a cancellation the schedule can still be changed (FK slots <- appointments) ----
  -- v_appt is cancelled and still points to v_slot_a, which must not be deleted.
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_exception(v_admin, v_staff_id, v_day, false, NULL, NULL, NULL);
  PERFORM {{CLIENT_CODE}}_booking.admin_remove_exception(v_admin, v_staff_id, v_day);
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff_id, v_dow, TIME '10:00', TIME '12:00');
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs WHERE fs.slot_id = v_slot_a
  ) THEN
    RAISE EXCEPTION '053 acceptance: the slot of a cancelled booking did not come back after a schedule change';
  END IF;

  -- ---- day off + booking -> cancel: the day must stay empty ----
  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_booking.admin_create_appointment(v_admin, v_appt3, v_service_id, v_slot_a, 'Клиент по телефону', '+7 999 000-05-31', 'verify');
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_exception(v_admin, v_staff_id, v_day, false, NULL, NULL, NULL);
  IF NOT {{CLIENT_CODE}}_booking.admin_cancel_appointment(v_admin, v_appt3, 'verify') THEN
    RAISE EXCEPTION '053 acceptance: cancel on a day off failed';
  END IF;
  IF EXISTS (SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs) THEN
    RAISE EXCEPTION '053 acceptance: cancelling a booking on a day off re-opened windows';
  END IF;
  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.slots AS sl
    WHERE sl.staff_id = v_staff_id AND sl.starts_at >= v_day::timestamptz
      AND sl.starts_at < (v_day + 1)::timestamptz AND sl.status = 'free'
  ) THEN
    RAISE EXCEPTION '053 acceptance: a free slot remained on a day off after cancelling';
  END IF;
  PERFORM {{CLIENT_CODE}}_booking.admin_remove_exception(v_admin, v_staff_id, v_day);
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs WHERE fs.slot_id = v_slot_a
  ) THEN
    RAISE EXCEPTION '053 acceptance: removing the day off did not reopen the cancelled slot';
  END IF;

  -- ---- shifted hours + client cancel: a slot outside the new hours stays closed ----
  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_booking.admin_create_appointment(v_admin, v_appt4, v_service_id, v_slot_a, 'Клиент по телефону', '+7 999 000-05-32', 'verify');
  UPDATE {{CLIENT_CODE}}_booking.appointments
  SET confirm_code_sha256 = public.digest(convert_to('verify-code', 'UTF8'), 'sha256')
  WHERE appointment_uuid = v_appt4;
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff_id, v_dow, TIME '11:00', TIME '12:00');
  SELECT * INTO v_row FROM {{CLIENT_CODE}}_booking.cancel_appointment(v_appt4, 'verify-code', 'verify');
  IF v_row.cancelled IS DISTINCT FROM true THEN
    RAISE EXCEPTION '053 acceptance: client cancel_appointment failed (%)', v_row.reason_code;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.slots AS sl WHERE sl.slot_id = v_slot_a AND sl.status = 'closed' AND sl.appointment_uuid IS NULL
  ) THEN
    RAISE EXCEPTION '053 acceptance: a slot outside the new hours was not closed after cancelling';
  END IF;
  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs WHERE fs.slot_id = v_slot_a
  ) THEN
    RAISE EXCEPTION '053 acceptance: a slot outside the new hours is offered after cancelling';
  END IF;
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff_id, v_dow, TIME '10:00', TIME '12:00');
  IF NOT EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs WHERE fs.slot_id = v_slot_a
  ) THEN
    RAISE EXCEPTION '053 acceptance: restoring the hours did not reopen the slot';
  END IF;

  -- ---- two grids: a kept slot of the old grid that overlaps the new grid stays closed ----
  -- v_slot_a (10:00) is free now. Hours 10:15-12:15 generate 10:15, 10:45, ...;
  -- the old-grid slots 10:00 and 10:30 overlap them and must not be offered.
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff_id, v_dow, TIME '10:15', TIME '12:15');
  SELECT count(*) INTO v_n
  FROM {{CLIENT_CODE}}_booking.slots AS a
  JOIN {{CLIENT_CODE}}_booking.slots AS b ON b.staff_id = a.staff_id AND b.slot_id <> a.slot_id
   AND b.starts_at < a.ends_at AND b.ends_at > a.starts_at
  WHERE a.staff_id = v_staff_id AND a.status = 'free' AND b.status = 'free'
    AND a.starts_at >= v_day::timestamptz AND a.starts_at < (v_day + 1)::timestamptz;
  IF v_n <> 0 THEN
    RAISE EXCEPTION '053 acceptance: overlapping free slots offered after a grid change (% pairs)', v_n;
  END IF;
  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs WHERE fs.slot_id = v_slot_a
  ) THEN
    RAISE EXCEPTION '053 acceptance: an old-grid slot overlapping the new grid is offered';
  END IF;
  -- cancelling a booking on the old grid must not open it either
  SELECT sl.slot_id INTO v_slot_b FROM {{CLIENT_CODE}}_booking.slots AS sl
  WHERE sl.staff_id = v_staff_id AND sl.starts_at = v_day::timestamptz + INTERVAL '10 hours 45 minutes';
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff_id, v_dow, TIME '10:00', TIME '12:00');
  v_appt2 := gen_random_uuid();
  SELECT * INTO v_row
  FROM {{CLIENT_CODE}}_booking.admin_create_appointment(v_admin, v_appt2, v_service_id, v_slot_a, 'Клиент по телефону', '+7 999 000-05-34', NULL);
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff_id, v_dow, TIME '10:15', TIME '12:15');
  PERFORM {{CLIENT_CODE}}_booking.admin_cancel_appointment(v_admin, v_appt2, 'verify');
  IF EXISTS (
    SELECT 1 FROM {{CLIENT_CODE}}_booking.free_slots(v_service_id, v_staff_id, v_day, v_day) AS fs WHERE fs.slot_id = v_slot_a
  ) THEN
    RAISE EXCEPTION '053 acceptance: cancel re-opened an old-grid slot overlapping the new grid';
  END IF;
  PERFORM * FROM {{CLIENT_CODE}}_booking.admin_set_work_hours(v_admin, v_staff_id, v_dow, TIME '10:00', TIME '12:00');

  -- ---- a phone booking on an inactive staff member is refused ----
  UPDATE {{CLIENT_CODE}}_booking.staff SET is_active = false WHERE staff_id = v_staff_id;
  v_caught := false;
  BEGIN
    PERFORM * FROM {{CLIENT_CODE}}_booking.admin_create_appointment(v_admin, gen_random_uuid(), v_service_id, v_slot_a, 'Клиент по телефону', '+7 999 000-05-33', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_caught := true;
  END;
  UPDATE {{CLIENT_CODE}}_booking.staff SET is_active = true WHERE staff_id = v_staff_id;
  IF NOT v_caught THEN
    RAISE EXCEPTION '053 acceptance: a phone booking on an inactive staff member was accepted';
  END IF;

  -- ---- n8n_runtime: only functions, no tables (KB-01#35) ----
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_runtime') THEN
    SET LOCAL ROLE n8n_runtime;
    IF {{CLIENT_CODE}}_booking.is_admin(v_stranger) THEN
      RAISE EXCEPTION '053 acceptance: is_admin(foreign) is true under n8n_runtime';
    END IF;
    IF NOT {{CLIENT_CODE}}_booking.is_admin(v_admin) THEN
      RAISE EXCEPTION '053 acceptance: is_admin(admin) is false under n8n_runtime';
    END IF;
    PERFORM count(*) FROM {{CLIENT_CODE}}_booking.admin_list_appointments(v_admin, v_day);
    v_caught := false;
    BEGIN
      PERFORM count(*) FROM {{CLIENT_CODE}}_booking.admins;
    EXCEPTION WHEN insufficient_privilege THEN
      v_caught := true;
    END;
    IF NOT v_caught THEN
      RAISE EXCEPTION '053 acceptance: n8n_runtime can read the admins table directly';
    END IF;
    v_caught := false;
    BEGIN
      PERFORM {{CLIENT_CODE}}_booking.require_admin(v_admin);
    EXCEPTION WHEN insufficient_privilege THEN
      v_caught := true;
    END;
    IF NOT v_caught THEN
      RAISE EXCEPTION '053 acceptance: n8n_runtime can call the internal require_admin';
    END IF;
    RESET ROLE;
  END IF;
END
$admin_flow$;

ROLLBACK;

\echo 'booking_admin_053_acceptance=OK'
