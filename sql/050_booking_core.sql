-- {{CLIENT_CODE_UPPER}}: booking core schema for U5 "online appointment booking".
-- Production rule: signatures created here are consumed by n8n scenarios and the
-- booking widget; do not change table/column names or 051's function signatures
-- without a coordinated release on every consumer.
--
-- This migration depends on the shared consent journal (pg-privacy 001+). It
-- never edits that migration's file; instead it widens two of its CHECK
-- constraints (scope, ui_surface) in place, the same way any later migration
-- in this repository is expected to extend a shared enum without breaking the
-- existing rows or the hash-chain evidence already recorded under it.

\set ON_ERROR_STOP on

BEGIN;

-- ---------- Preflight: the shared consent journal must already be applied ----------

DO $preflight$
BEGIN
  IF to_regnamespace('{{CLIENT_CODE}}_privacy') IS NULL THEN
    RAISE EXCEPTION '050 preflight: schema {{CLIENT_CODE}}_privacy is missing; apply pg-privacy migrations first';
  END IF;
  IF to_regclass('{{CLIENT_CODE}}_privacy.consent_events') IS NULL THEN
    RAISE EXCEPTION '050 preflight: {{CLIENT_CODE}}_privacy.consent_events is missing; apply pg-privacy migrations first';
  END IF;
  IF to_regclass('{{CLIENT_CODE}}_privacy.consent_text_versions') IS NULL THEN
    RAISE EXCEPTION '050 preflight: {{CLIENT_CODE}}_privacy.consent_text_versions is missing; apply pg-privacy migrations first';
  END IF;
  IF to_regprocedure('{{CLIENT_CODE}}_privacy.record_consent(uuid,text,text,text,text,text,timestamptz,text,inet,text,uuid)') IS NULL THEN
    RAISE EXCEPTION '050 preflight: {{CLIENT_CODE}}_privacy.record_consent(...) is missing; apply pg-privacy migrations first';
  END IF;
END
$preflight$;

-- ---------- Widen the shared consent enums to accept the booking purpose ----------
-- consent_text_versions.scope and consent_events.scope/ui_surface each carry a
-- fixed CHECK list from pg-privacy 001, and other parts of the warehouse add
-- their own values to it (handoff_max comes from the handoff package). The new
-- value is therefore appended to the definition the database actually holds --
-- never to a list hardcoded here, which would silently drop somebody else's
-- value. Re-running the migration is a no-op: the value is already present.

DO $extend_consent_enums$
DECLARE
  t record;
  v_con text;
  v_def text;
BEGIN
  FOR t IN
    SELECT *
    FROM (VALUES
      ('consent_text_versions', 'scope', 'booking_form'),
      ('consent_events', 'scope', 'booking_form'),
      ('consent_events', 'ui_surface', 'booking_widget')
    ) AS v(rel_name, col_name, new_value)
  LOOP
    SELECT con.conname, pg_get_constraintdef(con.oid)
    INTO v_con, v_def
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = '{{CLIENT_CODE}}_privacy'
      AND rel.relname = t.rel_name
      AND con.contype = 'c'
      AND con.conkey = ARRAY[(
        SELECT att.attnum
        FROM pg_attribute att
        WHERE att.attrelid = rel.oid
          AND att.attname = t.col_name
      )]::smallint[]
      AND pg_get_constraintdef(con.oid) ILIKE '%contact_form%';

    IF v_con IS NULL THEN
      RAISE EXCEPTION '050 preflight: single-column CHECK on %.% not found', t.rel_name, t.col_name;
    END IF;

    CONTINUE WHEN v_def ILIKE '%' || t.new_value || '%';

    EXECUTE format(
      'ALTER TABLE {{CLIENT_CODE}}_privacy.%I DROP CONSTRAINT %I',
      t.rel_name, v_con
    );
    EXECUTE format(
      'ALTER TABLE {{CLIENT_CODE}}_privacy.%I ADD CONSTRAINT %I CHECK (%s OR %I = %L)',
      t.rel_name, v_con,
      regexp_replace(v_def, '^CHECK\s*', ''),
      t.col_name, t.new_value
    );
  END LOOP;
END
$extend_consent_enums$;

-- ---------- Legal-document mapping for the booking consent scope ----------
-- record_consent (pg-privacy 016+) links every event to the legal document
-- revisions required for its scope and fails without a mapping row. Booking
-- collects personal data through a form, so it reuses the same document
-- types contact_form already requires; this only adds rows, it never
-- changes an existing scope's mapping.

DO $extend_document_mapping$
BEGIN
  IF to_regclass('{{CLIENT_CODE}}_privacy.consent_scope_document_types') IS NULL THEN
    RAISE EXCEPTION '050 preflight: {{CLIENT_CODE}}_privacy.consent_scope_document_types is missing; apply pg-privacy migrations first';
  END IF;

  INSERT INTO {{CLIENT_CODE}}_privacy.consent_scope_document_types (scope, document_type)
  VALUES
    ('booking_form', 'privacy_policy'),
    ('booking_form', 'personal_data_consent')
  ON CONFLICT DO NOTHING;
END
$extend_document_mapping$;

-- ---------- Schema ----------

CREATE SCHEMA IF NOT EXISTS {{CLIENT_CODE}}_booking AUTHORIZATION {{CLIENT_CODE}};

-- ---------- Settings ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.booking_settings (
  setting_key text PRIMARY KEY CHECK (setting_key IN (
    'slot_step_minutes', 'horizon_days', 'lead_time_hours', 'cancel_hours',
    'reminder_hours', 'confirm_mode', 'customer_retention_months'
  )),
  setting_value text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (
    setting_key NOT IN ('slot_step_minutes', 'horizon_days', 'lead_time_hours', 'cancel_hours', 'customer_retention_months')
    OR setting_value ~ '^[0-9]+$'
  ),
  CHECK (setting_key <> 'reminder_hours' OR setting_value ~ '^[0-9]+(,[0-9]+)*$'),
  CHECK (setting_key <> 'confirm_mode' OR setting_value IN ('auto', 'manual'))
);

INSERT INTO {{CLIENT_CODE}}_booking.booking_settings (setting_key, setting_value)
VALUES
  ('slot_step_minutes', '{{BOOKING_SLOT_STEP_MINUTES}}'),
  ('horizon_days', '{{BOOKING_HORIZON_DAYS}}'),
  ('lead_time_hours', '{{BOOKING_LEAD_TIME_HOURS}}'),
  ('cancel_hours', '{{BOOKING_CANCEL_HOURS}}'),
  ('reminder_hours', '{{BOOKING_REMINDER_HOURS}}'),
  ('confirm_mode', '{{BOOKING_CONFIRM_MODE}}'),
  ('customer_retention_months', '{{BOOKING_CUSTOMER_RETENTION_MONTHS}}')
ON CONFLICT (setting_key) DO NOTHING;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.setting_text(p_key text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, pg_temp
AS $fn$
  SELECT setting_value
  FROM {{CLIENT_CODE}}_booking.booking_settings
  WHERE setting_key = p_key;
$fn$;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.setting_int(p_key text)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, pg_temp
AS $fn$
  SELECT setting_value::integer
  FROM {{CLIENT_CODE}}_booking.booking_settings
  WHERE setting_key = p_key;
$fn$;

-- ---------- Catalog: services and staff ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.services (
  service_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  title text NOT NULL,
  duration_minutes int NOT NULL CHECK (duration_minutes BETWEEN 5 AND 480),
  price_minor bigint CHECK (price_minor IS NULL OR price_minor >= 0),
  is_active boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (char_length(code) BETWEEN 1 AND 60),
  CHECK (char_length(title) BETWEEN 1 AND 160)
);

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.staff (
  staff_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  display_name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (char_length(code) BETWEEN 1 AND 60),
  CHECK (char_length(display_name) BETWEEN 1 AND 160)
);

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.staff_services (
  staff_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.staff(staff_id) ON DELETE CASCADE,
  service_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.services(service_id) ON DELETE CASCADE,
  PRIMARY KEY (staff_id, service_id)
);

-- ---------- Working hours ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.work_schedule (
  schedule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.staff(staff_id) ON DELETE CASCADE,
  -- weekday follows PostgreSQL EXTRACT(DOW ...): 0 = Sunday .. 6 = Saturday.
  weekday smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  starts_time time NOT NULL,
  ends_time time NOT NULL,
  valid_from date NOT NULL DEFAULT current_date,
  valid_to date,
  CHECK (ends_time > starts_time),
  CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE INDEX IF NOT EXISTS work_schedule_staff_weekday_idx
  ON {{CLIENT_CODE}}_booking.work_schedule (staff_id, weekday);

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.schedule_exceptions (
  exception_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.staff(staff_id) ON DELETE CASCADE,
  exception_date date NOT NULL,
  is_working boolean NOT NULL,
  starts_time time,
  ends_time time,
  note text,
  UNIQUE (staff_id, exception_date),
  CHECK (
    is_working = false
    OR (starts_time IS NOT NULL AND ends_time IS NOT NULL AND ends_time > starts_time)
  ),
  CHECK (note IS NULL OR char_length(note) <= 300)
);

-- ---------- Slots ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.slots (
  slot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.staff(staff_id) ON DELETE CASCADE,
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'free' CHECK (status IN ('free', 'held', 'booked', 'closed')),
  appointment_uuid uuid,
  UNIQUE (staff_id, starts_at),
  CHECK (ends_at > starts_at)
);

CREATE INDEX IF NOT EXISTS slots_free_starts_idx
  ON {{CLIENT_CODE}}_booking.slots (starts_at) WHERE status = 'free';

-- ---------- Customers (personal data) ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.customers (
  customer_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone_e164 text NOT NULL UNIQUE,
  display_name text,
  email text,
  first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_visit_at timestamptz,
  visits_count int NOT NULL DEFAULT 0 CHECK (visits_count >= 0),
  CHECK (char_length(phone_e164) BETWEEN 10 AND 16),
  CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 160),
  CHECK (email IS NULL OR char_length(email) BETWEEN 3 AND 160)
);

COMMENT ON TABLE {{CLIENT_CODE}}_booking.customers IS
  'Customer card for booking (phone, name, email); personal data covered by its own retention rule, see 052.';

-- ---------- Consent wording for the booking form ----------
-- text_sha256 is also recomputed by the shared protect_consent_text_version
-- trigger on INSERT; it is written out explicitly here to match the pattern
-- used by every other consent text insert in this repository.

INSERT INTO {{CLIENT_CODE}}_privacy.consent_text_versions (
  version, scope, display_text, text_sha256, effective_from
)
VALUES (
  'booking-1.0',
  'booking_form',
  'Я даю согласие на обработку персональных данных для записи на услугу, подтверждения и напоминания о визите и ознакомлен(а) с Политикой обработки персональных данных.',
  public.digest(convert_to('Я даю согласие на обработку персональных данных для записи на услугу, подтверждения и напоминания о визите и ознакомлен(а) с Политикой обработки персональных данных.', 'UTF8'), 'sha256'),
  TIMESTAMPTZ '2026-09-25 00:00:00+03'
)
ON CONFLICT (version) DO NOTHING;

-- ---------- Appointments ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.appointments (
  appointment_uuid uuid PRIMARY KEY,
  -- Deliberately NOT a foreign key to {{CLIENT_CODE}}_privacy.consent_events.
  -- pg-retention/018 refuses to install destructive cleanup while any table
  -- outside its known list references the consent journal, and such a key would
  -- also block pruning the hash chain. The link is guaranteed on the write path
  -- instead: create_appointment stores the event_uuid that record_consent itself
  -- returned, and raises if the journal did not return one.
  consent_event_uuid uuid NOT NULL UNIQUE,
  customer_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.customers(customer_id),
  service_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.services(service_id),
  staff_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.staff(staff_id),
  slot_id uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.slots(slot_id),
  starts_at timestamptz NOT NULL,
  ends_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'planned'
    CHECK (status IN ('planned', 'confirmed', 'cancelled', 'done', 'no_show')),
  source text NOT NULL CHECK (source IN ('site', 'bot', 'manual')),
  -- Only the hash of the cancellation code is kept. The plain code is returned
  -- to the caller once, at booking time, and is never stored: a database dump
  -- must not let anyone cancel other people's bookings.
  confirm_code_sha256 bytea NOT NULL
    CHECK (octet_length(confirm_code_sha256) = 32),
  page_path text CHECK (page_path IS NULL OR (char_length(page_path) <= 300 AND page_path ~ '^/[^?#]*$')),
  comment text CHECK (comment IS NULL OR char_length(comment) <= 1000),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  cancelled_at timestamptz,
  cancel_reason text CHECK (cancel_reason IS NULL OR char_length(cancel_reason) <= 300),
  CHECK (ends_at > starts_at),
  CHECK (status <> 'cancelled' OR cancelled_at IS NOT NULL),
  CHECK (status = 'cancelled' OR cancelled_at IS NULL)
);

-- One live booking per slot, enforced by the database and not only by the
-- FOR UPDATE lock inside create_appointment: any other write path (a manual
-- INSERT during commissioning, a future admin screen) is covered too.
-- An EXCLUDE over (staff_id, tstzrange(starts_at, ends_at)) would additionally
-- catch an overlap that starts from a different slot, but it needs the
-- btree_gist extension, which the platform does not install today.
CREATE UNIQUE INDEX IF NOT EXISTS appointments_active_slot_uidx
  ON {{CLIENT_CODE}}_booking.appointments (slot_id)
  WHERE status <> 'cancelled';

CREATE INDEX IF NOT EXISTS appointments_starts_idx
  ON {{CLIENT_CODE}}_booking.appointments (starts_at);
CREATE INDEX IF NOT EXISTS appointments_customer_idx
  ON {{CLIENT_CODE}}_booking.appointments (customer_id);

-- Added only now that the appointments table exists; a booked/held slot points
-- back at the appointment that holds it.
DO $slots_appointment_fkey$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'slots_appointment_fkey'
      AND conrelid = '{{CLIENT_CODE}}_booking.slots'::regclass
  ) THEN
    ALTER TABLE {{CLIENT_CODE}}_booking.slots
      ADD CONSTRAINT slots_appointment_fkey
      FOREIGN KEY (appointment_uuid) REFERENCES {{CLIENT_CODE}}_booking.appointments(appointment_uuid)
      ON DELETE SET NULL;
  END IF;
END
$slots_appointment_fkey$;

CREATE OR REPLACE FUNCTION {{CLIENT_CODE}}_booking.block_appointment_identity_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, {{CLIENT_CODE}}_booking, pg_temp
AS $fn$
BEGIN
  IF NEW.appointment_uuid IS DISTINCT FROM OLD.appointment_uuid
     OR NEW.consent_event_uuid IS DISTINCT FROM OLD.consent_event_uuid
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.source IS DISTINCT FROM OLD.source THEN
    RAISE EXCEPTION 'appointment identity/evidence linkage is immutable';
  END IF;
  RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS appointments_identity_protection
  ON {{CLIENT_CODE}}_booking.appointments;
CREATE TRIGGER appointments_identity_protection
BEFORE UPDATE ON {{CLIENT_CODE}}_booking.appointments
FOR EACH ROW EXECUTE FUNCTION {{CLIENT_CODE}}_booking.block_appointment_identity_mutation();

-- ---------- Reminders ----------

CREATE TABLE IF NOT EXISTS {{CLIENT_CODE}}_booking.reminders (
  reminder_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  appointment_uuid uuid NOT NULL REFERENCES {{CLIENT_CODE}}_booking.appointments(appointment_uuid) ON DELETE CASCADE,
  kind text NOT NULL CHECK (char_length(kind) BETWEEN 1 AND 40),
  planned_at timestamptz NOT NULL,
  sent_at timestamptz,
  channel text CHECK (channel IS NULL OR char_length(channel) <= 40),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed', 'skipped')),
  attempts int NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  UNIQUE (appointment_uuid, kind)
);

CREATE INDEX IF NOT EXISTS reminders_due_idx
  ON {{CLIENT_CODE}}_booking.reminders (planned_at) WHERE status = 'pending';

-- ---------- Ownership ----------

ALTER TABLE {{CLIENT_CODE}}_booking.booking_settings OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.services OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.staff OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.staff_services OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.work_schedule OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.schedule_exceptions OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.slots OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.customers OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.appointments OWNER TO {{CLIENT_CODE}};
ALTER TABLE {{CLIENT_CODE}}_booking.reminders OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.setting_text(text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.setting_int(text) OWNER TO {{CLIENT_CODE}};
ALTER FUNCTION {{CLIENT_CODE}}_booking.block_appointment_identity_mutation() OWNER TO {{CLIENT_CODE}};

-- ---------- Access control ----------

REVOKE ALL ON SCHEMA {{CLIENT_CODE}}_booking FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA {{CLIENT_CODE}}_booking FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA {{CLIENT_CODE}}_booking FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA {{CLIENT_CODE}}_booking FROM PUBLIC;

DO $grant$
BEGIN
  -- n8n_runtime only ever calls the SECURITY DEFINER API in 051; it needs
  -- schema USAGE to resolve those functions but no direct table access.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_runtime') THEN
    GRANT USAGE ON SCHEMA {{CLIENT_CODE}}_booking TO n8n_runtime;
  END IF;

  -- consent_api never writes booking data directly either; USAGE only keeps
  -- future read-only tooling from needing another migration to add it.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'consent_api') THEN
    GRANT USAGE ON SCHEMA {{CLIENT_CODE}}_booking TO consent_api;
  END IF;
END
$grant$;

COMMIT;
