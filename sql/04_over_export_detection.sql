-- ============================================================================
-- OVER-EXPORT VIOLATION DETECTION (FIXED FOR SYNTHETIC NMIs)
-- ============================================================================
-- Purpose: Detect solar installations exceeding approved export limits
-- Data Source: fact_solar_generation (Ausgrid half-hourly readings)
-- Fixed: Handles synthetic NMIs, ROUND() type casting
-- ============================================================================

SET search_path TO compliance, reference, public;

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'OVER-EXPORT VIOLATION DETECTION - AUSGRID DATA';
    RAISE NOTICE '============================================================';
END $$;

-- ============================================================================
-- STEP 0: Add Synthetic Installations to fact_solar_installation (If Needed)
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Step 0: Ensuring synthetic Ausgrid installations exist...';
END $$;

-- Insert synthetic installations for Ausgrid customers that don't exist
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
SELECT DISTINCT
    g.nmi,
    g.postcode,
    g.capacity_kw,
    MIN(DATE(g.reading_timestamp)) as installation_date,  -- First reading date
    MIN(DATE(g.reading_timestamp)) as connection_date,
    MIN(DATE(g.reading_timestamp)) - INTERVAL '30 days' as application_date,
    'APPROVED' as application_status,
    -- Set approved export limit as 1.2x capacity (industry standard)
    CAST(g.capacity_kw * 1.2 AS DECIMAL(10,2)) as approved_export_limit_kw,
    'TRF001' as tariff_code,  -- Default tariff
    1 as installer_id,  -- Default installer
    FALSE as has_battery,
    NULL as battery_capacity_kwh,
    FALSE as is_multi_meter,
    FALSE as is_meter_consolidated
FROM (
    SELECT DISTINCT
        nmi,
        postcode,
        capacity_kw,
        reading_timestamp
    FROM compliance.fact_solar_generation
    WHERE data_source = 'AUSGRID_2012_2013'
) g
WHERE NOT EXISTS (
    SELECT 1 
    FROM compliance.fact_solar_installation i
    WHERE i.nmi = g.nmi
)
GROUP BY g.nmi, g.postcode, g.capacity_kw;

DO $$
DECLARE
    inserted_count INTEGER;
BEGIN
    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RAISE NOTICE '   ✓ Ensured % Ausgrid installations exist in fact_solar_installation', inserted_count;
END $$;

-- ============================================================================
-- STEP 1: Calculate Daily Peak Export for Each Installation
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Step 1: Calculating daily peak export values...';
END $$;

-- Create temporary table with daily max export
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

-- Create index for faster joining
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

-- Insert violations
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
    d.nmi::TEXT,
    'OVER_EXPORT',
    'NETWORK',
    CURRENT_DATE,
    CASE 
        -- Severity based on extent of over-export
        WHEN d.max_export_kw > i.approved_export_limit_kw * 1.5 THEN 'CRITICAL'
        WHEN d.max_export_kw > i.approved_export_limit_kw * 1.2 THEN 'MAJOR'
        ELSE 'MINOR'
    END,
    CONCAT(
        'Installation at postcode ', i.postcode,
        ' (capacity: ', i.capacity_kw, 'kW) ',
        'exceeded approved export limit of ', i.approved_export_limit_kw, 'kW. ',
        'Peak export recorded: ', CAST(d.max_export_kw AS DECIMAL(10,2)), 'kW on ', d.export_date, '. ',
        'Overage: ', CAST((d.max_export_kw - i.approved_export_limit_kw) AS DECIMAL(10,2)), 'kW ',
        '(', CAST(((d.max_export_kw / i.approved_export_limit_kw - 1) * 100) AS DECIMAL(10,1)), '% over limit). ',
        'Total daily export: ', CAST(d.total_export_kwh AS DECIMAL(10,2)), 'kWh'
    ),
    CAST(d.max_export_kw AS DECIMAL(10,2)),
    CAST(i.approved_export_limit_kw AS DECIMAL(10,2)),
    1,  -- Days in violation (per occurrence)
    -- FIX: Add explicit CAST for financial impact calculation
    -- Base penalty: $50 per kW over limit per day
    -- Network stress surcharge: Additional $100 if >150% of limit
    CAST(
        (d.max_export_kw - i.approved_export_limit_kw) * 50 +
        CASE WHEN d.max_export_kw > i.approved_export_limit_kw * 1.5 THEN 100 ELSE 0 END
        AS DECIMAL(12,2)
    ),
    'NEW'
FROM temp_daily_max_export d
JOIN compliance.fact_solar_installation i ON d.nmi::TEXT = i.nmi::TEXT
WHERE 1=1
  -- Only flag if over the approved limit
  AND d.max_export_kw > i.approved_export_limit_kw
  -- Must have an approved limit on file
  AND i.approved_export_limit_kw IS NOT NULL
  AND i.approved_export_limit_kw > 0
  -- Don't create duplicate violations for same NMI
  AND NOT EXISTS (
      SELECT 1 
      FROM compliance.fact_violation v
      WHERE v.nmi::TEXT = d.nmi::TEXT
        AND v.violation_type = 'OVER_EXPORT'
        AND v.status IN ('NEW', 'INVESTIGATING')
        -- Only avoid duplicates if they're for the same date
        AND v.detected_date = d.export_date
  );

-- Report results
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

-- View 1: Daily Export Summary by Installation
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
    -- Over-limit indicator
    CASE 
        WHEN MAX(g.max_export_kw) > i.approved_export_limit_kw THEN TRUE 
        ELSE FALSE 
    END as exceeded_limit,
    -- Percentage over limit (FIX: Add explicit CAST)
    CASE 
        WHEN i.approved_export_limit_kw > 0 THEN
            CAST(((MAX(g.max_export_kw) / i.approved_export_limit_kw - 1) * 100) AS DECIMAL(10,2))
        ELSE NULL
    END as pct_over_limit
FROM compliance.fact_solar_generation g
JOIN compliance.fact_solar_installation i ON g.nmi::TEXT = i.nmi::TEXT
WHERE g.export_kwh IS NOT NULL
GROUP BY g.nmi, i.postcode, i.capacity_kw, i.approved_export_limit_kw, DATE(g.reading_timestamp);

COMMENT ON VIEW compliance.vw_daily_export_summary IS 
'Daily export summary with over-limit detection for operational monitoring';

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

COMMENT ON VIEW compliance.vw_hourly_export_patterns IS 
'Hourly export patterns for identifying peak export times';

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
    -- Network stress indicator (>70% of installations exporting simultaneously)
    CASE 
        WHEN COUNT(CASE WHEN g.max_export_kw > 0 THEN 1 END)::FLOAT / 
             NULLIF(COUNT(DISTINCT g.nmi), 0) > 0.7 
        THEN TRUE 
        ELSE FALSE 
    END as network_stress
FROM compliance.fact_solar_generation g
JOIN compliance.fact_solar_installation i ON g.nmi::TEXT = i.nmi::TEXT
GROUP BY i.postcode, DATE(g.reading_timestamp), EXTRACT(HOUR FROM g.reading_timestamp);

COMMENT ON VIEW compliance.vw_network_load_analysis IS 
'Network-level load analysis showing aggregate export by postcode and time';

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
JOIN compliance.fact_solar_installation i ON v.nmi::TEXT = i.nmi::TEXT
WHERE v.violation_type = 'OVER_EXPORT'
  AND v.status IN ('NEW', 'INVESTIGATING')
GROUP BY v.nmi, i.postcode, i.capacity_kw, i.approved_export_limit_kw, 
         i.installer_id, i.installation_date
ORDER BY total_penalties DESC;

COMMENT ON VIEW compliance.vw_top_over_exporters IS 
'Ranked list of installations with most frequent/severe over-export violations';

DO $$
BEGIN
    RAISE NOTICE '   ✓ Created 4 operational analytics views';
END $$;

-- ============================================================================
-- STEP 4: Create Summary Statistics
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'OVER-EXPORT DETECTION SUMMARY';
    RAISE NOTICE '============================================================';
END $$;

-- Display summary table
SELECT 
    'Over-Export Violations Detected' as metric,
    COUNT(*) as count,
    CAST(SUM(financial_impact) AS DECIMAL(15,2)) as total_financial_impact,
    CAST(AVG(max_export_recorded_kw - approved_limit_kw) AS DECIMAL(10,2)) as avg_overage_kw,
    CAST(MAX(max_export_recorded_kw - approved_limit_kw) AS DECIMAL(10,2)) as max_overage_kw
FROM compliance.fact_violation
WHERE violation_type = 'OVER_EXPORT';

-- Severity breakdown
SELECT 
    severity,
    COUNT(*) as violation_count,
    CAST(AVG(max_export_recorded_kw - approved_limit_kw) AS DECIMAL(10,2)) as avg_overage_kw,
    CAST(SUM(financial_impact) AS DECIMAL(15,2)) as total_penalties
FROM compliance.fact_violation
WHERE violation_type = 'OVER_EXPORT'
GROUP BY severity
ORDER BY 
    CASE severity
        WHEN 'CRITICAL' THEN 1
        WHEN 'MAJOR' THEN 2
        WHEN 'MINOR' THEN 3
    END;

-- Clean up temp table
DROP TABLE IF EXISTS temp_daily_max_export;

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE '✓ OVER-EXPORT DETECTION COMPLETE!';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'Results stored in: compliance.fact_violation';
    RAISE NOTICE 'Analytics views created:';
    RAISE NOTICE '  - vw_daily_export_summary';
    RAISE NOTICE '  - vw_hourly_export_patterns';
    RAISE NOTICE '  - vw_network_load_analysis';
    RAISE NOTICE '  - vw_top_over_exporters';
    RAISE NOTICE '';
    RAISE NOTICE 'Next Step: Build operational monitoring dashboard';
    RAISE NOTICE '============================================================';
END $$;