-- ============================================================================
-- FINAL FIX: Convert fact_solar_installation.nmi to VARCHAR
-- ============================================================================
-- Problem: fact_solar_installation.nmi is BIGINT but should be VARCHAR
-- Solution: Convert the column type to match fact_solar_generation
-- ============================================================================

SET search_path TO compliance, reference, public;

\echo '============================================================'
\echo 'FIXING NMI DATA TYPE MISMATCH'
\echo '============================================================'
\echo ''

-- Step 1: Drop foreign key constraints if they exist
DO $$
BEGIN
    -- Drop constraint from fact_violation if it exists
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'fact_violation_nmi_fkey'
        AND table_name = 'fact_violation'
    ) THEN
        ALTER TABLE compliance.fact_violation 
        DROP CONSTRAINT fact_violation_nmi_fkey;
        RAISE NOTICE '✓ Dropped foreign key constraint';
    END IF;
END $$;

-- Step 2: Convert NMI column from BIGINT to VARCHAR
\echo 'Converting fact_solar_installation.nmi from BIGINT to VARCHAR...'

ALTER TABLE compliance.fact_solar_installation 
ALTER COLUMN nmi TYPE VARCHAR(11) USING nmi::TEXT;

\echo '✓ Converted NMI to VARCHAR(11)'
\echo ''

-- Step 3: Verify the change
DO $$
DECLARE
    gen_type TEXT;
    install_type TEXT;
BEGIN
    SELECT data_type INTO gen_type
    FROM information_schema.columns
    WHERE table_schema = 'compliance'
      AND table_name = 'fact_solar_generation'
      AND column_name = 'nmi';
    
    SELECT data_type INTO install_type
    FROM information_schema.columns
    WHERE table_schema = 'compliance'
      AND table_name = 'fact_solar_installation'
      AND column_name = 'nmi';
    
    RAISE NOTICE 'Verification:';
    RAISE NOTICE '  fact_solar_generation.nmi   = %', gen_type;
    RAISE NOTICE '  fact_solar_installation.nmi = %', install_type;
    
    IF gen_type = install_type THEN
        RAISE NOTICE '✓ Types now match!';
    ELSE
        RAISE EXCEPTION 'Types still do not match!';
    END IF;
END $$;

\echo ''
\echo '============================================================'
\echo 'NOW RUNNING OVER-EXPORT DETECTION'
\echo '============================================================'
\echo ''

-- ============================================================================
-- OVER-EXPORT VIOLATION DETECTION
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Step 0: Creating synthetic installations for Ausgrid data...';
END $$;

-- Create synthetic installations for Ausgrid customers
INSERT INTO compliance.fact_solar_installation (
    nmi,
    postcode,
    capacity_kw,
    installation_date,
    connection_date,
    application_date,
    application_status,
    approved_export_limit_kw,
    tariff_code,
    installer_id,
    has_battery,
    battery_capacity_kwh,
    is_multi_meter,
    is_meter_consolidated
)
SELECT 
    g.nmi,  -- Both VARCHAR now
    g.postcode,
    g.capacity_kw,
    MIN(DATE(g.reading_timestamp)) as installation_date,
    MIN(DATE(g.reading_timestamp)) as connection_date,
    MIN(DATE(g.reading_timestamp)) - INTERVAL '30 days' as application_date,
    'APPROVED' as application_status,
    ROUND((g.capacity_kw * 1.2)::numeric, 2) as approved_export_limit_kw,
    'TRF001' as tariff_code,
    1 as installer_id,
    FALSE as has_battery,
    NULL as battery_capacity_kwh,
    FALSE as is_multi_meter,
    FALSE as is_meter_consolidated
FROM compliance.fact_solar_generation g
WHERE g.data_source = 'AUSGRID_2012_2013'
  AND NOT EXISTS (
      SELECT 1 
      FROM compliance.fact_solar_installation i
      WHERE i.nmi = g.nmi  -- Both VARCHAR - no cast needed!
  )
GROUP BY g.nmi, g.postcode, g.capacity_kw;

DO $$
DECLARE
    inserted_count INTEGER;
BEGIN
    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RAISE NOTICE '   ✓ Created % Ausgrid installations in fact_solar_installation', inserted_count;
END $$;

-- ============================================================================
-- STEP 1: Calculate Daily Peak Export
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Step 1: Calculating daily peak export values...';
END $$;

DROP TABLE IF EXISTS temp_daily_max_export;

CREATE TEMP TABLE temp_daily_max_export AS
SELECT 
    g.nmi,
    DATE(g.reading_timestamp) as export_date,
    MAX(g.max_export_kw) as max_export_kw,
    MAX(g.max_generation_kw) as max_generation_kw,
    COUNT(*) as reading_count,
    AVG(g.export_kwh) as avg_export_kwh,
    SUM(g.export_kwh) as total_export_kwh
FROM compliance.fact_solar_generation g
WHERE g.max_export_kw IS NOT NULL
  AND g.max_export_kw > 0
GROUP BY g.nmi, DATE(g.reading_timestamp);

CREATE INDEX idx_temp_daily_nmi ON temp_daily_max_export(nmi);

DO $$
DECLARE
    record_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO record_count FROM temp_daily_max_export;
    RAISE NOTICE '   ✓ Calculated peak export for % daily records', record_count;
END $$;

-- ============================================================================
-- STEP 2: Identify Over-Export Violations
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Step 2: Identifying over-export violations...';
END $$;

INSERT INTO compliance.fact_violation (
    nmi,
    violation_type,
    violation_category,
    detected_date,
    severity,
    description,
    max_export_recorded_kw,
    approved_limit_kw,
    days_in_violation,
    financial_impact,
    status
)
SELECT 
    d.nmi,
    'OVER_EXPORT',
    'NETWORK',
    CURRENT_DATE,
    CASE 
        WHEN d.max_export_kw > i.approved_export_limit_kw * 1.5 THEN 'CRITICAL'
        WHEN d.max_export_kw > i.approved_export_limit_kw * 1.2 THEN 'MAJOR'
        ELSE 'MINOR'
    END,
    CONCAT(
        'Installation at postcode ', i.postcode,
        ' (capacity: ', i.capacity_kw, 'kW) ',
        'exceeded approved export limit of ', i.approved_export_limit_kw, 'kW. ',
        'Peak export recorded: ', ROUND(d.max_export_kw::numeric, 2), 'kW on ', d.export_date, '. ',
        'Overage: ', ROUND((d.max_export_kw - i.approved_export_limit_kw)::numeric, 2), 'kW ',
        '(', ROUND(((d.max_export_kw / i.approved_export_limit_kw - 1) * 100)::numeric, 1), '% over limit). ',
        'Total daily export: ', ROUND(d.total_export_kwh::numeric, 2), 'kWh'
    ),
    ROUND(d.max_export_kw::numeric, 2),
    ROUND(i.approved_export_limit_kw::numeric, 2),
    1,
    ROUND(
        ((d.max_export_kw - i.approved_export_limit_kw) * 50 +
        CASE WHEN d.max_export_kw > i.approved_export_limit_kw * 1.5 THEN 100 ELSE 0 END)::numeric,
        2
    ),
    'NEW'
FROM temp_daily_max_export d
JOIN compliance.fact_solar_installation i ON d.nmi = i.nmi  -- Both VARCHAR!
WHERE d.max_export_kw > i.approved_export_limit_kw
  AND i.approved_export_limit_kw IS NOT NULL
  AND i.approved_export_limit_kw > 0
  AND NOT EXISTS (
      SELECT 1 
      FROM compliance.fact_violation v
      WHERE v.nmi = d.nmi
        AND v.violation_type = 'OVER_EXPORT'
        AND v.status IN ('NEW', 'INVESTIGATING')
        AND v.detected_date = d.export_date
  );

DO $$
DECLARE
    violation_count INTEGER;
    critical_count INTEGER;
    major_count INTEGER;
    total_impact NUMERIC;
BEGIN
    SELECT COUNT(*) INTO violation_count
    FROM compliance.fact_violation
    WHERE violation_type = 'OVER_EXPORT';
    
    SELECT COUNT(*) INTO critical_count
    FROM compliance.fact_violation
    WHERE violation_type = 'OVER_EXPORT' AND severity = 'CRITICAL';
    
    SELECT COUNT(*) INTO major_count
    FROM compliance.fact_violation
    WHERE violation_type = 'OVER_EXPORT' AND severity = 'MAJOR';
    
    SELECT COALESCE(SUM(financial_impact), 0) INTO total_impact
    FROM compliance.fact_violation
    WHERE violation_type = 'OVER_EXPORT';
    
    RAISE NOTICE '';
    RAISE NOTICE '   ✓ Detected % over-export violations', violation_count;
    RAISE NOTICE '      - Critical: %', critical_count;
    RAISE NOTICE '      - Major: %', major_count;
    RAISE NOTICE '      - Total Financial Impact: $%', total_impact;
END $$;

-- ============================================================================
-- STEP 3: Create Operational Analytics Views
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Step 3: Creating operational analytics views...';
END $$;

-- View 1: Daily Export Summary
DROP VIEW IF EXISTS compliance.vw_daily_export_summary CASCADE;

CREATE VIEW compliance.vw_daily_export_summary AS
SELECT 
    g.nmi,
    i.postcode,
    i.capacity_kw,
    i.approved_export_limit_kw,
    DATE(g.reading_timestamp) as export_date,
    MAX(g.max_export_kw) as peak_export_kw,
    AVG(g.max_export_kw) as avg_export_kw,
    SUM(g.export_kwh) as total_export_kwh,
    COUNT(*) as reading_count,
    CASE 
        WHEN MAX(g.max_export_kw) > i.approved_export_limit_kw THEN TRUE 
        ELSE FALSE 
    END as exceeded_limit,
    CASE 
        WHEN i.approved_export_limit_kw > 0 THEN
            ROUND(((MAX(g.max_export_kw) / i.approved_export_limit_kw - 1) * 100)::numeric, 2)
        ELSE NULL
    END as pct_over_limit
FROM compliance.fact_solar_generation g
JOIN compliance.fact_solar_installation i ON g.nmi = i.nmi  -- Both VARCHAR!
WHERE g.export_kwh IS NOT NULL
GROUP BY g.nmi, i.postcode, i.capacity_kw, i.approved_export_limit_kw, DATE(g.reading_timestamp);

-- View 2: Hourly Export Patterns
DROP VIEW IF EXISTS compliance.vw_hourly_export_patterns CASCADE;

CREATE VIEW compliance.vw_hourly_export_patterns AS
SELECT 
    g.nmi,
    EXTRACT(HOUR FROM g.reading_timestamp) as hour_of_day,
    EXTRACT(DOW FROM g.reading_timestamp) as day_of_week,
    AVG(g.max_export_kw) as avg_export_kw,
    MAX(g.max_export_kw) as peak_export_kw,
    AVG(g.max_generation_kw) as avg_generation_kw,
    COUNT(*) as reading_count
FROM compliance.fact_solar_generation g
WHERE g.export_kwh IS NOT NULL
GROUP BY g.nmi, EXTRACT(HOUR FROM g.reading_timestamp), EXTRACT(DOW FROM g.reading_timestamp);

-- View 3: Network Load Analysis
DROP VIEW IF EXISTS compliance.vw_network_load_analysis CASCADE;

CREATE VIEW compliance.vw_network_load_analysis AS
SELECT 
    i.postcode,
    DATE(g.reading_timestamp) as load_date,
    EXTRACT(HOUR FROM g.reading_timestamp) as hour_of_day,
    COUNT(DISTINCT g.nmi) as installations_count,
    SUM(g.max_export_kw) as total_export_kw,
    AVG(g.max_export_kw) as avg_export_kw,
    MAX(g.max_export_kw) as peak_single_export_kw,
    CASE 
        WHEN COUNT(CASE WHEN g.max_export_kw > 0 THEN 1 END)::FLOAT / 
             NULLIF(COUNT(DISTINCT g.nmi), 0) > 0.7
        THEN TRUE 
        ELSE FALSE 
    END as network_stress
FROM compliance.fact_solar_generation g
JOIN compliance.fact_solar_installation i ON g.nmi = i.nmi  -- Both VARCHAR!
GROUP BY i.postcode, DATE(g.reading_timestamp), EXTRACT(HOUR FROM g.reading_timestamp);

-- View 4: Top Over-Exporters
DROP VIEW IF EXISTS compliance.vw_top_over_exporters CASCADE;

CREATE VIEW compliance.vw_top_over_exporters AS
SELECT 
    v.nmi,
    i.postcode,
    i.capacity_kw,
    i.approved_export_limit_kw,
    COUNT(*) as violation_count,
    MAX(v.max_export_recorded_kw) as peak_violation_kw,
    AVG(v.max_export_recorded_kw) as avg_violation_kw,
    SUM(v.financial_impact) as total_penalties,
    MAX(v.detected_date) as last_violation_date,
    i.installer_id,
    i.installation_date
FROM compliance.fact_violation v
JOIN compliance.fact_solar_installation i ON v.nmi = i.nmi  -- Both VARCHAR!
WHERE v.violation_type = 'OVER_EXPORT'
  AND v.status IN ('NEW', 'INVESTIGATING')
GROUP BY v.nmi, i.postcode, i.capacity_kw, i.approved_export_limit_kw, 
         i.installer_id, i.installation_date
ORDER BY total_penalties DESC;

DO $$
BEGIN
    RAISE NOTICE '   ✓ Created 4 operational analytics views';
END $$;

-- ============================================================================
-- STEP 4: Summary Statistics
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'OVER-EXPORT DETECTION SUMMARY';
    RAISE NOTICE '============================================================';
END $$;

SELECT 
    'Over-Export Violations Detected' as metric,
    COUNT(*) as count,
    ROUND(COALESCE(SUM(financial_impact), 0)::numeric, 2) as total_financial_impact,
    ROUND(COALESCE(AVG(max_export_recorded_kw - approved_limit_kw), 0)::numeric, 2) as avg_overage_kw,
    ROUND(COALESCE(MAX(max_export_recorded_kw - approved_limit_kw), 0)::numeric, 2) as max_overage_kw
FROM compliance.fact_violation
WHERE violation_type = 'OVER_EXPORT';

SELECT 
    severity,
    COUNT(*) as violation_count,
    ROUND(AVG(max_export_recorded_kw - approved_limit_kw)::numeric, 2) as avg_overage_kw,
    ROUND(SUM(financial_impact)::numeric, 2) as total_penalties
FROM compliance.fact_violation
WHERE violation_type = 'OVER_EXPORT'
GROUP BY severity
ORDER BY 
    CASE severity
        WHEN 'CRITICAL' THEN 1
        WHEN 'MAJOR' THEN 2
        WHEN 'MINOR' THEN 3
    END;

DROP TABLE IF EXISTS temp_daily_max_export;

\echo ''
\echo '============================================================'
\echo '✓ COMPLETE!'
\echo '============================================================'
\echo 'Results stored in: compliance.fact_violation'
\echo 'Analytics views created:'
\echo '  - vw_daily_export_summary'
\echo '  - vw_hourly_export_patterns'
\echo '  - vw_network_load_analysis'
\echo '  - vw_top_over_exporters'
\echo ''
\echo 'Next: Build your Power BI dashboard!'
\echo '============================================================'