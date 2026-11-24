-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- PostgreSQL. Run the whole file in one go (psql -f, or the pgAdmin Query Tool).

DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path = q8_fleet, public;

------------------------------------------------------------------
-- (a) Database
------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT  NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT  NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT  NOT NULL CHECK (end_odometer   >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT  NOT NULL,
    flagged_on       DATE NOT NULL
);

------------------------------------------------------------------
-- (b) Function: fn_service_due (5,000 km rule)
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = q8_fleet, public
AS $$
DECLARE
    v_current INT;
    v_service INT;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_service
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_service) >= 5000;
END;
$$;

------------------------------------------------------------------
-- (c) Procedure: pr_record_trip (does NOT touch the vehicle odometer)
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql
SET search_path = q8_fleet, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer readings are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    -- The BEFORE INSERT trigger validates the start value and moves the odometer
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

------------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT on trips
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q8_fleet, public
AS $$
DECLARE
    v_current INT;
BEGIN
    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end % (end must exceed start)',
                        NEW.start_odometer, NEW.end_odometer;
    END IF;

    -- Lock the vehicle row so two trips cannot start from the same odometer value
    SELECT current_odometer INTO v_current
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer (%), got %',
                        v_current, NEW.start_odometer;
    END IF;

    -- Exactly once per inserted trip; rolls back with the trip if the insert fails
    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

------------------------------------------------------------------
-- (a, continued) Seed data: vehicles, then six trips through the procedure
------------------------------------------------------------------
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('BAF 1234', 12000, 11000),   -- 1,000 km since service
 ('BAG 5678', 20000, 14000),   -- already 6,000 km: due
 ('BAH 9012',  8000,  4200);   -- 3,800 km: becomes due after its trips

CALL pr_record_trip(1, CURRENT_DATE - 6, 12000, 12300);
CALL pr_record_trip(1, CURRENT_DATE - 4, 12300, 12800);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20400);
CALL pr_record_trip(2, CURRENT_DATE - 3, 20400, 21000);
CALL pr_record_trip(3, CURRENT_DATE - 2, 8000,  8600);
CALL pr_record_trip(3, CURRENT_DATE - 1, 8600,  9400);   -- 5,200 km since service

SELECT * FROM vehicles ORDER BY vehicle_id;
SELECT * FROM trips ORDER BY trip_id;

------------------------------------------------------------------
-- (e) View: v_service_due
------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
  FROM vehicles
 WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;

------------------------------------------------------------------
-- (f) Index: one vehicle's trips within a trip_on date range
------------------------------------------------------------------
-- Equality on vehicle_id first, then the range on trip_on: the planner jumps
-- to one vehicle and reads its trips already in date order.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
  FROM trips
 WHERE vehicle_id = 2
   AND trip_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;
RESET enable_seqscan;

------------------------------------------------------------------
-- (g) Scheduled job
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
SET search_path = q8_fleet, public
AS $$
BEGIN
    -- Insert or update one alert for each due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
      FROM vehicles
     WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
       SET km_since_service = EXCLUDED.km_since_service;   -- flagged_on keeps the first date

    -- Remove alerts for vehicles that are no longer due (serviced)
    DELETE FROM service_alerts sa
     USING vehicles v
     WHERE v.vehicle_id = sa.vehicle_id
       AND v.current_odometer - v.last_service_odometer < 5000;
END;
$$;

-- pg_cron: every Monday at 06:00.
--   CREATE EXTENSION IF NOT EXISTS pg_cron;   (one-off, superuser)
SELECT cron.schedule(
    'fleet-service-alerts',
    '0 6 * * 1',
    $$CALL q8_fleet.pr_refresh_service_alerts()$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;

------------------------------------------------------------------
-- Tests
------------------------------------------------------------------
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();   -- rerun: no duplicates
SELECT * FROM service_alerts ORDER BY vehicle_id;   -- vehicles 2 and 3

-- Vehicle 2 is serviced: its alert disappears on the next refresh
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;   -- vehicle 3 only

SELECT fn_service_due(1) AS v1_false, fn_service_due(3) AS v3_true;

DO $$ BEGIN PERFORM fn_service_due(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);        -- unknown vehicle
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12800, 12800);  -- end not greater
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 100, 200);      -- wrong starting value
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
-- Direct SQL goes through the same trigger
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
            VALUES (1, CURRENT_DATE, 12800, 12700);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

-- The procedure did not move the odometer; only the trigger did, exactly once
CALL pr_record_trip(1, CURRENT_DATE, 12800, 13000);
SELECT vehicle_id, current_odometer FROM vehicles WHERE vehicle_id = 1;   -- 13000
