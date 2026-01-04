-- ============================================================================
-- AUSNET SOLAR COMPLIANCE DATABASE SCHEMA
-- ============================================================================
-- Purpose: Create database schema for solar installation compliance monitoring
-- Database: PostgreSQL 12+
-- Author: Data Analytics Team
-- Date: 2026-01-03
-- ============================================================================

-- Drop existing database if needed (BE CAREFUL IN PRODUCTION!)
-- DROP DATABASE IF EXISTS ausnet_solar_compliance;

-- Create database
CREATE DATABASE ausnet_solar_compliance
    WITH 
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.UTF-8'
    LC_CTYPE = 'en_US.UTF-8'
    TEMPLATE = template0;

-- Connect to the database
\c ausnet_solar_compliance;

-- ============================================================================
-- EXTENSIONS
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";      -- UUID generation
CREATE EXTENSION IF NOT EXISTS "pg_trgm";        -- Text search optimization
CREATE EXTENSION IF NOT EXISTS "btree_gist";     -- Index optimization

-- ============================================================================
-- SCHEMA CREATION
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS compliance;
CREATE SCHEMA IF NOT EXISTS reference;
CREATE SCHEMA IF NOT EXISTS staging;

-- Set search path
SET search_path TO compliance, reference, staging, public;

-- ============================================================================
-- DIMENSION TABLES (Reference Data)
-- ============================================================================

-- ----------------------------
-- Installer Dimension
-- ----------------------------
DROP TABLE IF EXISTS reference.dim_installer CASCADE;
CREATE TABLE reference.dim_installer (
    installer_id INTEGER PRIMARY KEY,
    installer_name VARCHAR(200) NOT NULL,
    abn VARCHAR(11),
    cec_accredited BOOLEAN DEFAULT TRUE,
    quality_score DECIMAL(3,1) CHECK (quality_score >= 0 AND quality_score <= 10),
    total_installations INTEGER DEFAULT 0,
    compliance_rate DECIMAL(5,2),
    license_status VARCHAR(20) DEFAULT 'ACTIVE',
    created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE reference.dim_installer IS 'CEC accredited solar installers operating in AusNet territory';
COMMENT ON COLUMN reference.dim_installer.quality_score IS 'Quality score 0-10 based on compliance history';
COMMENT ON COLUMN reference.dim_installer.compliance_rate IS 'Percentage of compliant installations';

-- ----------------------------
-- Tariff Dimension
-- ----------------------------
DROP TABLE IF EXISTS reference.dim_tariff CASCADE;
CREATE TABLE reference.dim_tariff (
    tariff_id SERIAL PRIMARY KEY,
    tariff_code VARCHAR(30) UNIQUE NOT NULL,
    tariff_type VARCHAR(20) NOT NULL CHECK (tariff_type IN ('SOLAR', 'NON_SOLAR')),
    tariff_description TEXT,
    fit_rate_c_kwh DECIMAL(6,2),  -- Feed-in Tariff rate in cents/kWh
    is_active BOOLEAN DEFAULT TRUE,
    effective_from DATE,
    effective_to DATE,
    created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE reference.dim_tariff IS 'Electricity tariff codes and rates';
COMMENT ON COLUMN reference.dim_tariff.fit_rate_c_kwh IS 'Feed-in Tariff rate in cents per kWh';

-- ----------------------------
-- Postcode Reference
-- ----------------------------
DROP TABLE IF EXISTS reference.dim_postcode CASCADE;
CREATE TABLE reference.dim_postcode (
    postcode INTEGER PRIMARY KEY,
    suburb VARCHAR(100),
    state VARCHAR(3) DEFAULT 'VIC',
    region VARCHAR(50),
    is_metro BOOLEAN,
    is_ausnet_territory BOOLEAN DEFAULT TRUE,
    network_zone VARCHAR(50),
    is_constrained_area BOOLEAN DEFAULT FALSE,
    export_limit_kw DECIMAL(6,2) DEFAULT 5.0,
    created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE reference.dim_postcode IS 'Victorian postcode reference with AusNet network zones';
COMMENT ON COLUMN reference.dim_postcode.is_constrained_area IS 'Network areas with reduced export limits';
COMMENT ON COLUMN reference.dim_postcode.export_limit_kw IS 'Default export limit for postcode (kW)';

-- ----------------------------
-- Date Dimension (for time-series analysis)
-- ----------------------------
DROP TABLE IF EXISTS reference.dim_date CASCADE;
CREATE TABLE reference.dim_date (
    date_id INTEGER PRIMARY KEY,
    full_date DATE NOT NULL UNIQUE,
    year INTEGER NOT NULL,
    quarter INTEGER NOT NULL,
    month INTEGER NOT NULL,
    month_name VARCHAR(20),
    week INTEGER NOT NULL,
    day_of_month INTEGER NOT NULL,
    day_of_week INTEGER NOT NULL,
    day_name VARCHAR(20),
    is_weekend BOOLEAN,
    is_public_holiday BOOLEAN DEFAULT FALSE,
    financial_year INTEGER,
    financial_quarter INTEGER
);

COMMENT ON TABLE reference.dim_date IS 'Date dimension for time-series analysis';

-- ============================================================================
-- FACT TABLES (Transaction Data)
-- ============================================================================

-- ----------------------------
-- Solar Installation Master (Main Fact Table)
-- ----------------------------
DROP TABLE IF EXISTS compliance.fact_solar_installation CASCADE;
CREATE TABLE compliance.fact_solar_installation (
    installation_id SERIAL PRIMARY KEY,
    nmi VARCHAR(11) UNIQUE NOT NULL,
    postcode INTEGER NOT NULL,
    installer_id INTEGER REFERENCES reference.dim_installer(installer_id),
    tariff_code VARCHAR(30) REFERENCES reference.dim_tariff(tariff_code),
    
    -- Installation details
    capacity_kw DECIMAL(8,2) NOT NULL CHECK (capacity_kw > 0),
    approved_export_limit_kw DECIMAL(6,2),
    inverter_capacity_kw DECIMAL(8,2),
    panel_count INTEGER,
    
    -- Application tracking
    application_status VARCHAR(20) NOT NULL 
        CHECK (application_status IN ('APPROVED', 'PENDING', 'REJECTED', 'NO_APPLICATION')),
    application_date DATE,
    approval_date DATE,
    installation_date DATE NOT NULL,
    connection_date DATE,
    
    -- Meter configuration
    meter_type VARCHAR(20) DEFAULT 'SINGLE' 
        CHECK (meter_type IN ('SINGLE', 'DUAL', 'MULTI')),
    is_multi_meter BOOLEAN DEFAULT FALSE,
    is_meter_consolidated BOOLEAN DEFAULT TRUE,
    
    -- Battery information
    has_battery BOOLEAN DEFAULT FALSE,
    battery_capacity_kwh DECIMAL(8,2),
    battery_type VARCHAR(30),
    
    -- Compliance flags
    is_compliant BOOLEAN DEFAULT TRUE,
    compliance_issues TEXT[],  -- Array of issue codes
    risk_level VARCHAR(20) DEFAULT 'LOW' 
        CHECK (risk_level IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    
    -- Audit trail
    created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_verified_date TIMESTAMP,
    
    -- Constraints
    CONSTRAINT chk_application_approval CHECK (
        (application_status = 'APPROVED' AND approval_date IS NOT NULL) OR
        (application_status != 'APPROVED')
    ),
    CONSTRAINT chk_capacity_limit CHECK (capacity_kw <= 999.99),
    CONSTRAINT chk_battery_capacity CHECK (
        (has_battery = TRUE AND battery_capacity_kwh IS NOT NULL) OR
        (has_battery = FALSE)
    )
);

COMMENT ON TABLE compliance.fact_solar_installation IS 'Master table of all solar installations in AusNet territory';
COMMENT ON COLUMN compliance.fact_solar_installation.nmi IS 'National Meter Identifier (11 digits)';
COMMENT ON COLUMN compliance.fact_solar_installation.compliance_issues IS 'Array of issue codes (e.g., UNAUTHORIZED, OVER_EXPORT)';

-- Indexes for fact_solar_installation
CREATE INDEX idx_installation_nmi ON compliance.fact_solar_installation(nmi);
CREATE INDEX idx_installation_postcode ON compliance.fact_solar_installation(postcode);
CREATE INDEX idx_installation_installer ON compliance.fact_solar_installation(installer_id);
CREATE INDEX idx_installation_status ON compliance.fact_solar_installation(application_status);
CREATE INDEX idx_installation_date ON compliance.fact_solar_installation(installation_date);
CREATE INDEX idx_installation_compliant ON compliance.fact_solar_installation(is_compliant);
CREATE INDEX idx_installation_risk ON compliance.fact_solar_installation(risk_level);

-- ----------------------------
-- Solar Generation Facts (Time-series data)
-- ----------------------------
DROP TABLE IF EXISTS compliance.fact_solar_generation CASCADE;
CREATE TABLE compliance.fact_solar_generation (
    generation_id BIGSERIAL PRIMARY KEY,
    nmi VARCHAR(11) NOT NULL REFERENCES compliance.fact_solar_installation(nmi),
    reading_timestamp TIMESTAMP NOT NULL,
    
    -- Energy readings (kWh)
    generation_kwh DECIMAL(10,4),
    consumption_kwh DECIMAL(10,4),
    export_kwh DECIMAL(10,4),
    import_kwh DECIMAL(10,4),
    
    -- Power readings (kW)
    max_export_kw DECIMAL(8,2),
    max_generation_kw DECIMAL(8,2),
    
    -- Data quality
    reading_quality VARCHAR(20) DEFAULT 'ACTUAL' 
        CHECK (reading_quality IN ('ACTUAL', 'ESTIMATED', 'SUBSTITUTED')),
    data_source VARCHAR(50),
    
    created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    -- Constraints
    CONSTRAINT chk_export_calc CHECK (
        export_kwh IS NULL OR 
        (export_kwh >= 0 AND export_kwh <= generation_kwh)
    ),
    CONSTRAINT unique_nmi_timestamp UNIQUE (nmi, reading_timestamp)
);

COMMENT ON TABLE compliance.fact_solar_generation IS 'Half-hourly solar generation and export readings';

-- Partitioning by month for performance
CREATE INDEX idx_generation_nmi ON compliance.fact_solar_generation(nmi);
CREATE INDEX idx_generation_timestamp ON compliance.fact_solar_generation(reading_timestamp);
CREATE INDEX idx_generation_nmi_timestamp ON compliance.fact_solar_generation(nmi, reading_timestamp);

-- ----------------------------
-- Compliance Violations
-- ----------------------------
DROP TABLE IF EXISTS compliance.fact_violation CASCADE;
CREATE TABLE compliance.fact_violation (
    violation_id SERIAL PRIMARY KEY,
    nmi VARCHAR(11) NOT NULL REFERENCES compliance.fact_solar_installation(nmi),
    
    -- Violation details
    violation_type VARCHAR(50) NOT NULL,
    violation_category VARCHAR(30) NOT NULL,
    detected_date DATE NOT NULL,
    severity VARCHAR(20) NOT NULL 
        CHECK (severity IN ('MINOR', 'MAJOR', 'CRITICAL')),
    
    -- Metrics
    description TEXT,
    max_export_recorded_kw DECIMAL(8,2),
    approved_limit_kw DECIMAL(6,2),
    days_in_violation INTEGER,
    financial_impact DECIMAL(12,2),
    
    -- Resolution tracking
    status VARCHAR(20) DEFAULT 'NEW' 
        CHECK (status IN ('NEW', 'INVESTIGATING', 'RESOLVED', 'CLOSED', 'DISMISSED')),
    assigned_to VARCHAR(100),
    resolution_notes TEXT,
    resolution_date DATE,
    
    -- Audit
    created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT chk_violation_dates CHECK (
        resolution_date IS NULL OR resolution_date >= detected_date
    )
);

COMMENT ON TABLE compliance.fact_violation IS 'Compliance violations detected through automated rules';
COMMENT ON COLUMN compliance.fact_violation.violation_type IS 'Type: UNAUTHORIZED, OVER_EXPORT, TARIFF_MISMATCH, etc.';

-- Indexes
CREATE INDEX idx_violation_nmi ON compliance.fact_violation(nmi);
CREATE INDEX idx_violation_type ON compliance.fact_violation(violation_type);
CREATE INDEX idx_violation_status ON compliance.fact_violation(status);
CREATE INDEX idx_violation_severity ON compliance.fact_violation(severity);
CREATE INDEX idx_violation_detected_date ON compliance.fact_violation(detected_date);

-- ----------------------------
-- AEMO Submission Log
-- ----------------------------
DROP TABLE IF EXISTS compliance.fact_aemo_submission CASCADE;
CREATE TABLE compliance.fact_aemo_submission (
    submission_id SERIAL PRIMARY KEY,
    nmi VARCHAR(11) REFERENCES compliance.fact_solar_installation(nmi),
    
    -- Submission details
    submission_date TIMESTAMP NOT NULL,
    submission_type VARCHAR(50) DEFAULT 'CONNECTION',
    submission_batch_id VARCHAR(50),
    
    -- Outcome
    submission_status VARCHAR(20) NOT NULL 
        CHECK (submission_status IN ('SUCCESS', 'FAILED', 'PENDING', 'PARTIAL')),
    error_code VARCHAR(100),
    error_message TEXT,
    retry_count INTEGER DEFAULT 0,
    
    -- Data submitted
    submitted_capacity_kw DECIMAL(8,2),
    submitted_connection_date DATE,
    
    created_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    CONSTRAINT chk_failed_has_error CHECK (
        (submission_status = 'FAILED' AND error_code IS NOT NULL) OR
        (submission_status != 'FAILED')
    )
);

COMMENT ON TABLE compliance.fact_aemo_submission IS 'AEMO DER Register submission tracking';

-- Indexes
CREATE INDEX idx_aemo_submission_nmi ON compliance.fact_aemo_submission(nmi);
CREATE INDEX idx_aemo_submission_status ON compliance.fact_aemo_submission(submission_status);
CREATE INDEX idx_aemo_submission_date ON compliance.fact_aemo_submission(submission_date);

-- ============================================================================
-- STAGING TABLES (For data loading)
-- ============================================================================

DROP TABLE IF EXISTS staging.stg_solar_installation CASCADE;
CREATE TABLE staging.stg_solar_installation (
    nmi VARCHAR(11),
    postcode INTEGER,
    installer_id INTEGER,
    tariff_code VARCHAR(30),
    capacity_kw DECIMAL(8,2),
    approved_export_limit_kw DECIMAL(6,2),
    application_status VARCHAR(20),
    application_date DATE,
    approval_date DATE,
    installation_date DATE,
    connection_date DATE,
    meter_type VARCHAR(20),
    is_multi_meter BOOLEAN,
    is_meter_consolidated BOOLEAN,
    has_battery BOOLEAN,
    battery_capacity_kwh DECIMAL(8,2),
    battery_type VARCHAR(30),
    load_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE staging.stg_solar_installation IS 'Staging table for bulk data loads';

-- ============================================================================
-- VIEWS FOR ANALYSIS
-- ============================================================================

-- ----------------------------
-- Active Installations View
-- ----------------------------
CREATE OR REPLACE VIEW compliance.vw_active_installations AS
SELECT 
    i.installation_id,
    i.nmi,
    i.postcode,
    p.suburb,
    p.region,
    i.capacity_kw,
    i.approved_export_limit_kw,
    i.application_status,
    i.installation_date,
    inst.installer_name,
    t.tariff_code,
    t.tariff_type,
    i.has_battery,
    i.is_compliant,
    i.risk_level,
    i.compliance_issues
FROM compliance.fact_solar_installation i
LEFT JOIN reference.dim_postcode p ON i.postcode = p.postcode
LEFT JOIN reference.dim_installer inst ON i.installer_id = inst.installer_id
LEFT JOIN reference.dim_tariff t ON i.tariff_code = t.tariff_code
WHERE i.application_status IN ('APPROVED', 'PENDING')
ORDER BY i.installation_date DESC;

COMMENT ON VIEW compliance.vw_active_installations IS 'Currently active solar installations';

-- ----------------------------
-- Compliance Summary View
-- ----------------------------
CREATE OR REPLACE VIEW compliance.vw_compliance_summary AS
SELECT 
    COUNT(*) AS total_installations,
    COUNT(*) FILTER (WHERE application_status = 'APPROVED') AS approved_count,
    COUNT(*) FILTER (WHERE application_status = 'NO_APPLICATION') AS unauthorized_count,
    COUNT(*) FILTER (WHERE application_status = 'PENDING') AS pending_count,
    COUNT(*) FILTER (WHERE is_compliant = FALSE) AS non_compliant_count,
    ROUND(AVG(capacity_kw), 2) AS avg_capacity_kw,
    SUM(capacity_kw) AS total_capacity_kw,
    COUNT(*) FILTER (WHERE has_battery = TRUE) AS battery_count,
    COUNT(*) FILTER (WHERE is_multi_meter = TRUE AND is_meter_consolidated = FALSE) AS meter_issue_count
FROM compliance.fact_solar_installation;

COMMENT ON VIEW compliance.vw_compliance_summary IS 'High-level compliance metrics';

-- ----------------------------
-- Violations Dashboard View
-- ----------------------------
CREATE OR REPLACE VIEW compliance.vw_violations_dashboard AS
SELECT 
    v.violation_id,
    v.nmi,
    i.postcode,
    p.suburb,
    v.violation_type,
    v.violation_category,
    v.severity,
    v.detected_date,
    v.status,
    v.financial_impact,
    inst.installer_name,
    i.capacity_kw,
    i.approved_export_limit_kw,
    v.max_export_recorded_kw,
    v.days_in_violation,
    EXTRACT(DAY FROM CURRENT_DATE - v.detected_date) AS days_open
FROM compliance.fact_violation v
JOIN compliance.fact_solar_installation i ON v.nmi = i.nmi
LEFT JOIN reference.dim_postcode p ON i.postcode = p.postcode
LEFT JOIN reference.dim_installer inst ON i.installer_id = inst.installer_id
WHERE v.status IN ('NEW', 'INVESTIGATING')
ORDER BY v.severity DESC, v.detected_date;

COMMENT ON VIEW compliance.vw_violations_dashboard IS 'Active compliance violations for monitoring';

-- ============================================================================
-- FUNCTIONS & TRIGGERS
-- ============================================================================

-- ----------------------------
-- Function: Update timestamp on record change
-- ----------------------------
CREATE OR REPLACE FUNCTION update_updated_date()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_date = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply trigger to relevant tables
CREATE TRIGGER trg_installation_updated
    BEFORE UPDATE ON compliance.fact_solar_installation
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_date();

CREATE TRIGGER trg_violation_updated
    BEFORE UPDATE ON compliance.fact_violation
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_date();

-- ----------------------------
-- Function: Calculate NMI checksum
-- ----------------------------
CREATE OR REPLACE FUNCTION calculate_nmi_checksum(nmi_base VARCHAR)
RETURNS VARCHAR AS $$
DECLARE
    weights INTEGER[] := ARRAY[2,1,2,1,2,1,2,1,2,1];
    total INTEGER := 0;
    i INTEGER;
    digit INTEGER;
BEGIN
    FOR i IN 1..10 LOOP
        digit := CAST(substring(nmi_base from i for 1) AS INTEGER);
        total := total + (digit * weights[i]);
    END LOOP;
    
    RETURN ((10 - (total % 10)) % 10)::VARCHAR;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION calculate_nmi_checksum IS 'Calculate checksum digit for NMI validation';

-- ----------------------------
-- Function: Validate NMI format
-- ----------------------------
CREATE OR REPLACE FUNCTION validate_nmi(nmi VARCHAR)
RETURNS BOOLEAN AS $$
BEGIN
    -- Check length
    IF LENGTH(nmi) != 11 THEN
        RETURN FALSE;
    END IF;
    
    -- Check all numeric
    IF nmi !~ '^[0-9]{11}$' THEN
        RETURN FALSE;
    END IF;
    
    -- Check Victorian jurisdiction codes (62 or 63)
    IF substring(nmi from 2 for 2) NOT IN ('62', '63') THEN
        RETURN FALSE;
    END IF;
    
    -- Validate checksum
    IF substring(nmi from 1 for 1) != calculate_nmi_checksum(substring(nmi from 2)) THEN
        RETURN FALSE;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION validate_nmi IS 'Validate NMI format and checksum';

-- ============================================================================
-- REFERENCE DATA POPULATION
-- ============================================================================

-- Populate Date Dimension (2015-2030)
INSERT INTO reference.dim_date (
    date_id, full_date, year, quarter, month, month_name, 
    week, day_of_month, day_of_week, day_name, is_weekend,
    financial_year, financial_quarter
)
SELECT 
    TO_CHAR(date_series, 'YYYYMMDD')::INTEGER AS date_id,
    date_series AS full_date,
    EXTRACT(YEAR FROM date_series)::INTEGER AS year,
    EXTRACT(QUARTER FROM date_series)::INTEGER AS quarter,
    EXTRACT(MONTH FROM date_series)::INTEGER AS month,
    TO_CHAR(date_series, 'Month') AS month_name,
    EXTRACT(WEEK FROM date_series)::INTEGER AS week,
    EXTRACT(DAY FROM date_series)::INTEGER AS day_of_month,
    EXTRACT(DOW FROM date_series)::INTEGER AS day_of_week,
    TO_CHAR(date_series, 'Day') AS day_name,
    EXTRACT(DOW FROM date_series) IN (0, 6) AS is_weekend,
    CASE 
        WHEN EXTRACT(MONTH FROM date_series) >= 7 
        THEN EXTRACT(YEAR FROM date_series)::INTEGER
        ELSE EXTRACT(YEAR FROM date_series)::INTEGER - 1
    END AS financial_year,
    CASE 
        WHEN EXTRACT(MONTH FROM date_series) IN (7,8,9) THEN 1
        WHEN EXTRACT(MONTH FROM date_series) IN (10,11,12) THEN 2
        WHEN EXTRACT(MONTH FROM date_series) IN (1,2,3) THEN 3
        ELSE 4
    END AS financial_quarter
FROM generate_series('2015-01-01'::DATE, '2030-12-31'::DATE, '1 day'::INTERVAL) AS date_series;

-- ============================================================================
-- SECURITY & PERMISSIONS
-- ============================================================================

-- Create roles (adjust as needed)
-- CREATE ROLE compliance_admin;
-- CREATE ROLE compliance_analyst;
-- CREATE ROLE compliance_readonly;

-- Grant permissions
-- GRANT ALL PRIVILEGES ON SCHEMA compliance, reference, staging TO compliance_admin;
-- GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA compliance TO compliance_analyst;
-- GRANT SELECT ON ALL TABLES IN SCHEMA compliance, reference TO compliance_readonly;

-- ============================================================================
-- COMPLETION MESSAGE
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'AusNet Solar Compliance Database Schema Created Successfully';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'Database: ausnet_solar_compliance';
    RAISE NOTICE 'Schemas: compliance, reference, staging';
    RAISE NOTICE '';
    RAISE NOTICE 'Tables Created:';
    RAISE NOTICE '  - reference.dim_installer';
    RAISE NOTICE '  - reference.dim_tariff';
    RAISE NOTICE '  - reference.dim_postcode';
    RAISE NOTICE '  - reference.dim_date';
    RAISE NOTICE '  - compliance.fact_solar_installation';
    RAISE NOTICE '  - compliance.fact_solar_generation';
    RAISE NOTICE '  - compliance.fact_violation';
    RAISE NOTICE '  - compliance.fact_aemo_submission';
    RAISE NOTICE '  - staging.stg_solar_installation';
    RAISE NOTICE '';
    RAISE NOTICE 'Next Step: Run 02_load_data_to_postgres.py';
    RAISE NOTICE '============================================================';
END $$;