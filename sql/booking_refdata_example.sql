-- {{CLIENT_CODE_UPPER}}: example reference data for pg-booking (postgres/tools).
-- Run manually during commissioning to exercise the booking flow end to end
-- against a real database. Every row here is a neutral placeholder; replace
-- the whole file with the client's real service list, staff and working
-- hours before going live.

\set ON_ERROR_STOP on

BEGIN;

INSERT INTO {{CLIENT_CODE}}_booking.services (code, title, duration_minutes, price_minor, sort_order)
VALUES
  ('service-a', 'Услуга А', 30, 100000, 1),
  ('service-b', 'Услуга Б', 60, 200000, 2)
ON CONFLICT (code) DO NOTHING;

INSERT INTO {{CLIENT_CODE}}_booking.staff (code, display_name, sort_order)
VALUES
  ('staff-1', 'Мастер 1', 1),
  ('staff-2', 'Мастер 2', 2)
ON CONFLICT (code) DO NOTHING;

INSERT INTO {{CLIENT_CODE}}_booking.staff_services (staff_id, service_id)
SELECT st.staff_id, sv.service_id
FROM {{CLIENT_CODE}}_booking.staff AS st
CROSS JOIN {{CLIENT_CODE}}_booking.services AS sv
WHERE (st.code, sv.code) IN (
  ('staff-1', 'service-a'),
  ('staff-1', 'service-b'),
  ('staff-2', 'service-a')
)
ON CONFLICT DO NOTHING;

-- Monday through Friday, 10:00-19:00, for every staff member above.
INSERT INTO {{CLIENT_CODE}}_booking.work_schedule (staff_id, weekday, starts_time, ends_time)
SELECT st.staff_id, wd.weekday, TIME '10:00', TIME '19:00'
FROM {{CLIENT_CODE}}_booking.staff AS st
CROSS JOIN (VALUES (1), (2), (3), (4), (5)) AS wd(weekday)
WHERE st.code IN ('staff-1', 'staff-2');

-- Build slots for the next `horizon_days` days so free_slots() has something
-- to return right after commissioning.
SELECT {{CLIENT_CODE}}_booking.generate_slots(
  current_date,
  current_date + {{CLIENT_CODE}}_booking.setting_int('horizon_days')
);

COMMIT;
