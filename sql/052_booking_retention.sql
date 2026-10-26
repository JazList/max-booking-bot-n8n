-- {{CLIENT_CODE_UPPER}}: booking retention policy registration and cleanup.
-- Production rule: this migration only registers the booking retention rules
-- in the shared policy table and adds this component's OWN preview/cleanup
-- functions. It never redefines {{CLIENT_CODE}}_privacy.retention_preview or
-- {{CLIENT_CODE}}_privacy.run_retention_cleanup (pg-retention 018/pg-leads 020
-- own those); doing so would break that unrelated component.
--
-- Consent evidence in {{CLIENT_CODE}}_privacy.consent_events is never deleted
-- by the functions below: the append-only hash chain belongs to the separate
-- legal contour and follows its own retention_until under pg-privacy/pg-retention.

\set ON_ERROR_STOP on

BEGIN;

DO $preflight$
BEGIN
  IF to_regclass('{{CLIENT_CODE}}_privacy.retention_policy') IS NULL THEN
    RAISE EXCEPTION '052 preflight: {{CLIENT_CODE}}_privacy.retention_policy from pg-retention 018 is missing';
  END IF;
  IF to_regclass('{{CLIENT_CODE}}_booking.appointments') IS NULL THEN
    RAISE EXCEPTION '052 preflight: {{CLIENT_CODE}}_booking.appointments is missing; apply 050 first';
  END IF;
  IF to_regclass('{{CLIENT_CODE}}_booking.customers') IS NULL THEN
    RAISE EXCEPTION '052 preflight: {{CLIENT_CODE}}_booking.customers is missing; apply 050 first';
  END IF;
END
$preflight$;

-- ---------- Policy registry ----------
-- automatic_cleanup is false on purpose. The timer that runs retention on the
-- server (pg-retention: run_retention_production.sh under
-- {{CLIENT_CODE}}-retention.timer) calls the {{CLIENT_CODE}}_privacy functions
-- only; it knows nothing about booking, and that part is not modified from here.
-- Declaring true would put a promise in the registry that nothing keeps.
-- Until the shared runner learns about booking, the cleanup below is run by
-- hand -- the order is written down in this node's 00_ШАПКА.md.

INSERT INTO {{CLIENT_CODE}}_privacy.retention_policy (
  data_class, retention_rule, automatic_cleanup, notes
)
VALUES
  (
    'booking_appointments',
    'customer_retention_months months after the visit (appointment ends_at)',
    false,
    'Appointment/booking records are removed after the configured retention window measured from the visit end time. Cleanup is run manually for now: {{CLIENT_CODE}}_booking.run_retention_cleanup(false) -- the shared retention timer does not call it. Linked consent evidence in {{CLIENT_CODE}}_privacy.consent_events is not touched here; it follows its own retention_until under the shared consent hash chain.'
  ),
  (
    'booking_customers',
    'customer card is deleted when there has been no visit for customer_retention_months months and no remaining appointment references it',
    false,
    'Removed only after every appointment referencing the customer has already been cleaned up, so an active or recent booking always keeps its customer card.'
  )
ON CONFLICT (data_class) DO UPDATE
SET retention_rule = EXCLUDED.retention_rule,
    automatic_cleanup = EXCLUDED.automatic_cleanup,
    notes = EXCLUDED.notes,
    updated_at = clock_timestamp();

-- ---------- Preview (read-only) ----------

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.retention_preview(
  p_at date DEFAULT current_date
)
RETURNS TABLE(
  data_class text,
  total_rows bigint,
  eligible_rows bigint,
  note text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
  WITH cutoff AS (
    SELECT p_at::timestamptz
           - (COALESCE({{CLIENT_CODE}}_booking.setting_int('customer_retention_months'), 0) || ' months')::interval
           AS at
  )
  SELECT
    'booking_appointments'::text,
    (SELECT count(*)::bigint FROM {{CLIENT_CODE}}_booking.appointments),
    (
      SELECT count(*)::bigint
      FROM {{CLIENT_CODE}}_booking.appointments AS a, cutoff
      WHERE a.ends_at < cutoff.at
    ),
    (
      'kept ' || COALESCE({{CLIENT_CODE}}_booking.setting_text('customer_retention_months'), '?')
      || ' months after the visit; consent evidence is not deleted by this function'
    )::text
  UNION ALL
  SELECT
    'booking_customers'::text,
    (SELECT count(*)::bigint FROM {{CLIENT_CODE}}_booking.customers),
    (
      SELECT count(*)::bigint
      FROM {{CLIENT_CODE}}_booking.customers AS c, cutoff
      WHERE COALESCE(c.last_visit_at, c.first_seen_at) < cutoff.at
        AND NOT EXISTS (
          SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments AS a
          WHERE a.customer_id = c.customer_id
        )
    ),
    (
      'deleted only when no visit for ' || COALESCE({{CLIENT_CODE}}_booking.setting_text('customer_retention_months'), '?')
      || ' months and no remaining appointment references the customer'
    )::text;
$fn$;

-- ---------- Cleanup ----------
-- Defaults to dry-run; destructive cleanup requires an explicit p_dry_run=false
-- call. Appointment reminders cascade with their appointment; the customer's
-- linked consent_event evidence is left untouched in every case.

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.run_retention_cleanup(
  p_dry_run boolean DEFAULT true,
  p_at date DEFAULT current_date
)
RETURNS TABLE(
  dry_run boolean,
  deleted_appointments bigint,
  deleted_customers bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, {{CLIENT_CODE}}_privacy, pg_temp
AS $fn$
DECLARE
  v_months int := COALESCE({{CLIENT_CODE}}_booking.setting_int('customer_retention_months'), 0);
  v_cutoff timestamptz := p_at::timestamptz - (v_months || ' months')::interval;
  v_deleted_appt bigint := 0;
  v_deleted_cust bigint := 0;
BEGIN
  IF p_dry_run THEN
    RETURN QUERY
    SELECT
      true,
      (SELECT count(*)::bigint FROM {{CLIENT_CODE}}_booking.appointments WHERE ends_at < v_cutoff),
      (
        SELECT count(*)::bigint
        FROM {{CLIENT_CODE}}_booking.customers AS c
        WHERE COALESCE(c.last_visit_at, c.first_seen_at) < v_cutoff
          AND NOT EXISTS (
            SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments AS a
            WHERE a.customer_id = c.customer_id
          )
      );
    RETURN;
  END IF;

  -- Old appointments first; this also cascades their reminders and frees the
  -- FK from customers, without touching {{CLIENT_CODE}}_privacy.consent_events.
  DELETE FROM {{CLIENT_CODE}}_booking.appointments
  WHERE ends_at < v_cutoff;
  GET DIAGNOSTICS v_deleted_appt = ROW_COUNT;

  DELETE FROM {{CLIENT_CODE}}_booking.customers AS c
  WHERE COALESCE(c.last_visit_at, c.first_seen_at) < v_cutoff
    AND NOT EXISTS (
      SELECT 1 FROM {{CLIENT_CODE}}_booking.appointments AS a
      WHERE a.customer_id = c.customer_id
    );
  GET DIAGNOSTICS v_deleted_cust = ROW_COUNT;

  RETURN QUERY SELECT false, v_deleted_appt, v_deleted_cust;
END
$fn$;

ALTER FUNCTION {{CLIENT_CODE}}_booking.retention_preview(date) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.run_retention_cleanup(boolean, date) OWNER TO {{CLIENT_CODE}};

REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.retention_preview(date) FROM PUBLIC;
REVOKE ALL ON FUNCTION {{CLIENT_CODE}}_booking.run_retention_cleanup(boolean, date) FROM PUBLIC;

COMMENT ON FUNCTION {{CLIENT_CODE}}_booking.retention_preview(date) IS
  'Read-only booking retention preview. Never counts or deletes {{CLIENT_CODE}}_privacy.consent_events.';
COMMENT ON FUNCTION {{CLIENT_CODE}}_booking.run_retention_cleanup(boolean, date) IS
  'Booking retention executor. Defaults to dry-run; never deletes consent evidence, only appointments/customers.';

COMMIT;
