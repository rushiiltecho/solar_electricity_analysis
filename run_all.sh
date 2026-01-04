#!/bin/bash
set -e
echo "========================================="
echo "AUSNET SOLAR COMPLIANCE - FULL PIPELINE"
echo "========================================="
echo ""
echo "Step 1: Setting up virtual environment..."
source venv/bin/activate
echo "Step 2: Running data pipeline..."
python python/pipelines/solar_compliance_pipeline.py
echo "Step 3: Creating database..."
psql -U postgres -f sql/01_create_database_schema.sql
echo "Step 4: Loading data..."
python python/02_load_data_to_postgres.py
echo "Step 5: Running compliance detection..."
psql -U postgres -d ausnet_solar_compliance -f sql/03_compliance_detection_queries.sql
echo ""
echo "✓ PIPELINE COMPLETE!"
