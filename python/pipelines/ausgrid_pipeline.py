"""
============================================================================
AUSGRID GENERATION DATA - ETL PIPELINE (FIXED)
============================================================================
Purpose: Process Ausgrid half-hourly solar generation data for operational monitoring
Input: Wide-format CSV (Customer, date, 0:30, 1:00, ..., 23:30, 0:00)
Output: Long-format time-series data in PostgreSQL fact_solar_generation
============================================================================
"""

import pandas as pd
import numpy as np
from pathlib import Path
from datetime import datetime, timedelta
from sqlalchemy import create_engine, text
import warnings
warnings.filterwarnings('ignore')

class AusgridGenerationPipeline:
    """
    Complete ETL pipeline for Ausgrid solar generation data
    """
    
    def __init__(self):
        self.data_dir = Path('data')
        self.raw_dir = self.data_dir / 'raw' / 'ausgrid'
        self.processed_dir = self.data_dir / 'processed'
        self.config_file = Path('config/database.ini')
        
        # Create directories
        for dir_path in [self.raw_dir, self.processed_dir]:
            dir_path.mkdir(parents=True, exist_ok=True)
        
        self.engine = None
        
        print("=" * 80)
        print("AUSGRID GENERATION DATA - ETL PIPELINE")
        print("=" * 80)
    
    # ========================================================================
    # STEP 1: PROCESS RAW AUSGRID FILES
    # ========================================================================
    
    def process_ausgrid_file(self, filepath):
        """
        Process single Ausgrid CSV file from wide to long format
        
        Input format:
        Customer,Generator Capacity,Postcode,Consumption Category,date,0:30,1:00,...,Row Quality
        1,3.78,2076,GG,1/07/2012,0,0,0,0.006,...
        
        Output format:
        customer_id, postcode, capacity_kw, reading_timestamp, 
        consumption_category, reading_kwh
        """
        print(f"\n📂 Processing: {filepath.name}")
        
        # FIX: Don't skip any rows - the header is already there!
        try:
            df = pd.read_csv(filepath)  # Removed skiprows=1
            print(f"   Loaded {len(df):,} rows, {len(df.columns)} columns")
            
            # Debug: Show first few column names
            print(f"   Column names: {list(df.columns[:8])}...")
            
        except Exception as e:
            print(f"   ⚠️  Warning: Could not read file: {e}")
            return None
        
        # Verify required columns exist
        required_cols = ['Customer', 'Generator Capacity', 'Postcode', 'Consumption Category', 'date']
        missing_cols = [col for col in required_cols if col not in df.columns]
        
        if missing_cols:
            print(f"   ❌ ERROR: Missing required columns: {missing_cols}")
            print(f"   Available columns: {list(df.columns)}")
            return None
        
        # Get time columns (all columns with : in the name)
        # Exclude 'Row Quality' if it exists
        time_cols = [col for col in df.columns 
                     if ':' in str(col) and col != 'Row Quality']
        
        print(f"   Found {len(time_cols)} half-hourly time slots")
        
        if len(time_cols) == 0:
            print(f"   ❌ ERROR: No time columns found!")
            return None
        
        # Process each consumption category
        all_readings = []
        
        print(f"   Processing rows...")
        
        for idx, row in df.iterrows():
            try:
                customer_id = row['Customer']
                capacity_kw = row['Generator Capacity']
                postcode = row['Postcode']
                category = row['Consumption Category']
                date_str = row['date']
                
                # Skip if any required field is missing
                if pd.isna(customer_id) or pd.isna(date_str):
                    continue
                
                # Parse date
                try:
                    date = pd.to_datetime(date_str, format='%d/%m/%Y')
                except:
                    try:
                        date = pd.to_datetime(date_str, dayfirst=True)
                    except:
                        continue
                
                # Process each time slot
                for time_col in time_cols:
                    reading_value = row[time_col]
                    
                    # Skip if no reading
                    if pd.isna(reading_value):
                        continue
                    
                    # Parse time (e.g., "0:30" -> hour=0, minute=30)
                    try:
                        time_parts = str(time_col).split(':')
                        hour = int(time_parts[0])
                        minute = int(time_parts[1])
                    except:
                        continue
                    
                    # Create timestamp
                    timestamp = date + timedelta(hours=hour, minutes=minute)
                    
                    all_readings.append({
                        'customer_id': int(customer_id),
                        'postcode': int(postcode),
                        'capacity_kw': float(capacity_kw),
                        'reading_timestamp': timestamp,
                        'consumption_category': category,
                        'reading_kwh': float(reading_value)
                    })
                
                if (idx + 1) % 1000 == 0:
                    print(f"   Processed {idx + 1:,} rows...", end='\r')
                    
            except Exception as e:
                # Skip problematic rows
                continue
        
        print(f"\n   ✅ Created {len(all_readings):,} reading records")
        
        if len(all_readings) == 0:
            print(f"   ❌ ERROR: No readings were extracted!")
            return None
        
        df_long = pd.DataFrame(all_readings)
        
        return df_long
    
    # ========================================================================
    # STEP 2: MAP CUSTOMERS TO NMIs
    # ========================================================================
    
    def map_customers_to_nmis(self, df_readings):
        """
        Map Ausgrid customers to NMIs in fact_solar_installation
        
        Strategy:
        1. Try to match by postcode and capacity
        2. Create synthetic NMIs for unmatched customers
        3. Create customer-NMI mapping table
        """
        print("\n" + "=" * 80)
        print("STEP 2: Mapping Customers to NMIs")
        print("=" * 80)
        
        # Get unique customers with their attributes
        customers = df_readings[['customer_id', 'postcode', 'capacity_kw']].drop_duplicates()
        
        print(f"\n📊 Found {len(customers):,} unique customers")
        
        # Load existing installations from database
        print("\n🔍 Loading installations from database...")
        
        try:
            with self.engine.connect() as conn:
                query = """
                    SELECT nmi, postcode, capacity_kw 
                    FROM compliance.fact_solar_installation
                """
                df_installations = pd.read_sql(query, conn)
            
            print(f"   ✅ Loaded {len(df_installations):,} installations")
        except Exception as e:
            print(f"   ⚠️  Could not load from database: {e}")
            df_installations = pd.DataFrame(columns=['nmi', 'postcode', 'capacity_kw'])
        
        # Create mapping
        customer_nmi_map = {}
        matched = 0
        unmatched = 0
        
        for idx, customer in customers.iterrows():
            customer_id = customer['customer_id']
            postcode = customer['postcode']
            capacity = customer['capacity_kw']
            
            # Try to find matching installation
            # Match criteria: same postcode and similar capacity (±0.5 kW)
            matches = df_installations[
                (df_installations['postcode'] == postcode) &
                (df_installations['capacity_kw'].between(capacity - 0.5, capacity + 0.5))
            ]
            
            if len(matches) > 0:
                # Use first match
                nmi = matches.iloc[0]['nmi']
                matched += 1
            else:
                # Create synthetic NMI for Ausgrid customer
                # Format: A[customer_id] (prefix A for Ausgrid)
                nmi = f"A{int(customer_id):010d}"
                unmatched += 1
            
            customer_nmi_map[customer_id] = nmi
        
        print(f"\n✅ Mapping complete:")
        print(f"   Matched to existing NMIs: {matched:,}")
        print(f"   Created synthetic NMIs: {unmatched:,}")
        
        # Add NMI to readings
        df_readings['nmi'] = df_readings['customer_id'].map(customer_nmi_map)
        
        # Save mapping
        mapping_df = pd.DataFrame([
            {'customer_id': k, 'nmi': v} 
            for k, v in customer_nmi_map.items()
        ])
        mapping_file = self.processed_dir / 'customer_nmi_mapping.csv'
        mapping_df.to_csv(mapping_file, index=False)
        print(f"\n💾 Saved mapping to: {mapping_file}")
        
        return df_readings
    
    # ========================================================================
    # STEP 3: PIVOT DATA BY CATEGORY
    # ========================================================================
    
    def pivot_by_category(self, df_readings):
        """
        Pivot data so each timestamp has GG, GC, CL in separate columns
        
        Input:
        nmi, timestamp, category, reading_kwh
        
        Output:
        nmi, timestamp, generation_kwh, consumption_kwh, controlled_load_kwh
        """
        print("\n" + "=" * 80)
        print("STEP 3: Pivoting Data by Category")
        print("=" * 80)
        
        print("\n🔄 Pivoting consumption categories...")
        
        # Pivot
        df_pivot = df_readings.pivot_table(
            index=['nmi', 'reading_timestamp', 'postcode', 'capacity_kw'],
            columns='consumption_category',
            values='reading_kwh',
            aggfunc='first'
        ).reset_index()
        
        # Rename columns
        df_pivot.columns.name = None
        
        # Map category codes to full names
        category_map = {
            'GG': 'generation_kwh',
            'GC': 'consumption_kwh',
            'CL': 'controlled_load_kwh'
        }
        
        df_pivot = df_pivot.rename(columns=category_map)
        
        # Ensure all columns exist
        for col in ['generation_kwh', 'consumption_kwh', 'controlled_load_kwh']:
            if col not in df_pivot.columns:
                df_pivot[col] = None
        
        # Calculate export (generation - consumption)
        # Export only when generation > consumption
        df_pivot['export_kwh'] = df_pivot.apply(
            lambda x: max(0, x['generation_kwh'] - x['consumption_kwh']) 
            if pd.notna(x['generation_kwh']) and pd.notna(x['consumption_kwh'])
            else None,
            axis=1
        )
        
        # Calculate import (consumption - generation when consumption > generation)
        df_pivot['import_kwh'] = df_pivot.apply(
            lambda x: max(0, x['consumption_kwh'] - x['generation_kwh'])
            if pd.notna(x['generation_kwh']) and pd.notna(x['consumption_kwh'])
            else x['consumption_kwh'] if pd.notna(x['consumption_kwh']) else None,
            axis=1
        )
        
        # Convert kWh (30-min reading) to kW (power)
        # Reading is kWh for 30 minutes, so kW = kWh / 0.5
        df_pivot['max_export_kw'] = df_pivot['export_kwh'] / 0.5
        df_pivot['max_generation_kw'] = df_pivot['generation_kwh'] / 0.5
        
        print(f"✅ Created {len(df_pivot):,} consolidated readings")
        print(f"   Columns: {list(df_pivot.columns)}")
        
        return df_pivot
    
    # ========================================================================
    # STEP 4: LOAD TO DATABASE
    # ========================================================================
    
    def connect_to_database(self):
        """Connect to PostgreSQL database"""
        print("\n" + "=" * 80)
        print("DATABASE CONNECTION")
        print("=" * 80)
        
        # Read config
        import configparser
        import getpass
        
        config = configparser.ConfigParser()
        

        db_config = {
            'host': 'localhost',
            'port': 5432,
            'database': 'ausnet_solar_compliance',
            'user': getpass.getuser(),
            'password': ''
        }
    
        print(f"🔌 Connecting to: {db_config['user']}@{db_config['host']}:{db_config['port']}/{db_config['database']}")
        
        try:
            if db_config['password']:
                connection_string = (
                    f"postgresql://{db_config['user']}:{db_config['password']}@"
                    f"{db_config['host']}:{db_config['port']}/{db_config['database']}"
                )
            else:
                connection_string = (
                    f"postgresql://{db_config['user']}@"
                    f"{db_config['host']}:{db_config['port']}/{db_config['database']}"
                )
            
            self.engine = create_engine(connection_string)
            
            # Test connection
            with self.engine.connect() as conn:
                result = conn.execute(text("SELECT version();"))
                version = result.fetchone()[0]
                print(f"✅ Connected successfully!")
                print(f"   PostgreSQL: {version.split(',')[0]}")
            
            return True
            
        except Exception as e:
            print(f"❌ Connection failed: {e}")
            return False
    
    def load_to_database(self, df_generation):
        """Load generation data to fact_solar_generation table"""
        print("\n" + "=" * 80)
        print("STEP 4: Loading to Database")
        print("=" * 80)
        
        print(f"\n📊 Preparing {len(df_generation):,} records for database load...")
        
        # Select only columns that exist in the database schema
        df_load = df_generation[[
            'nmi',
            'reading_timestamp',
            'generation_kwh',
            'consumption_kwh',
            'export_kwh',
            'import_kwh',
            'max_export_kw',
            'max_generation_kw'
        ]].copy()
        
        # Add metadata
        df_load['reading_quality'] = 'ACTUAL'
        df_load['data_source'] = 'AUSGRID_2012_2013'
        
        # Load in chunks
        chunk_size = 10000
        total_chunks = (len(df_load) // chunk_size) + 1
        
        print(f"\n🔄 Loading data in {total_chunks} chunks...")
        
        loaded = 0
        
        for i, chunk_start in enumerate(range(0, len(df_load), chunk_size)):
            chunk = df_load.iloc[chunk_start:chunk_start + chunk_size]
            
            try:
                chunk.to_sql(
                    'fact_solar_generation',
                    self.engine,
                    schema='compliance',
                    if_exists='append',
                    index=False,
                    method='multi'
                )
                
                loaded += len(chunk)
                progress = (loaded / len(df_load)) * 100
                
                print(f"   Progress: {progress:.1f}% ({loaded:,} / {len(df_load):,} records)", end='\r')
                
            except Exception as e:
                print(f"\n   ⚠️  Error loading chunk {i+1}: {e}")
                with open(self.processed_dir / 'db_load_error.txt', 'a') as f:
                    f.write(f"Chunk {i+1} error: {e}\n")
                break
        
        print(f"\n\n✅ Successfully loaded {loaded:,} generation records!")
        
        return loaded
    
    # ========================================================================
    # STEP 5: DATA QUALITY CHECKS
    # ========================================================================
    
    def run_data_quality_checks(self):
        """Run data quality checks on loaded data"""
        print("\n" + "=" * 80)
        print("DATA QUALITY CHECKS")
        print("=" * 80)
        
        with self.engine.connect() as conn:
            # Check 1: Total records
            print("\n📊 Check 1: Record Count")
            result = conn.execute(text("""
                SELECT COUNT(*) as total_records,
                       COUNT(DISTINCT nmi) as unique_nmis,
                       MIN(reading_timestamp) as earliest_reading,
                       MAX(reading_timestamp) as latest_reading
                FROM compliance.fact_solar_generation
            """))
            row = result.fetchone()
            
            print(f"   Total Records: {row[0]:,}")
            print(f"   Unique NMIs: {row[1]:,}")
            print(f"   Date Range: {row[2]} to {row[3]}")
            
            # Check 2: Data completeness
            print("\n📊 Check 2: Data Completeness")
            result = conn.execute(text("""
                SELECT 
                    COUNT(*) FILTER (WHERE generation_kwh IS NULL) as null_generation,
                    COUNT(*) FILTER (WHERE consumption_kwh IS NULL) as null_consumption,
                    COUNT(*) FILTER (WHERE export_kwh IS NULL) as null_export
                FROM compliance.fact_solar_generation
            """))
            row = result.fetchone()
            
            print(f"   Null Generation: {row[0]:,}")
            print(f"   Null Consumption: {row[1]:,}")
            print(f"   Null Export: {row[2]:,}")
            
            # Check 3: Peak export
            print("\n📊 Check 3: Peak Export Values")
            result = conn.execute(text("""
                SELECT 
                    MAX(max_export_kw) as peak_export,
                    AVG(max_export_kw) as avg_export,
                    MAX(max_generation_kw) as peak_generation,
                    AVG(max_generation_kw) as avg_generation
                FROM compliance.fact_solar_generation
                WHERE max_export_kw IS NOT NULL
            """))
            row = result.fetchone()
            
            print(f"   Peak Export: {row[0]:.2f} kW")
            print(f"   Average Export: {row[1]:.2f} kW")
            print(f"   Peak Generation: {row[2]:.2f} kW")
            print(f"   Average Generation: {row[3]:.2f} kW")
    
    # ========================================================================
    # MAIN EXECUTION
    # ========================================================================
    
    def run(self):
        """Execute complete Ausgrid ETL pipeline"""
        start_time = datetime.now()
        
        print("\n" + "=" * 80)
        print("AUSGRID GENERATION DATA - ETL PIPELINE")
        print("=" * 80)
        
        # Check for input files
        ausgrid_files = list(self.raw_dir.glob('*.csv'))
        
        if not ausgrid_files:
            print(f"\n❌ No Ausgrid CSV files found in: {self.raw_dir}")
            print("\nPlease download Ausgrid data from:")
            print("https://www.ausgrid.com.au/Industry/Our-Research/Data-to-share/Solar-home-electricity-data")
            print("\nOr:")
            print("https://data.nsw.gov.au/data/dataset/solar-home-electricity-data")
            print("\nExtract CSV files to: data/raw/ausgrid/")
            return False
        
        print(f"\n📂 Found {len(ausgrid_files)} Ausgrid CSV file(s)")
        for f in ausgrid_files:
            print(f"   - {f.name}")
        
        # Step 1: Process all files
        all_readings = []
        
        for filepath in ausgrid_files:
            df = self.process_ausgrid_file(filepath)
            if df is not None:
                all_readings.append(df)
        
        if not all_readings:
            print("\n❌ No data processed!")
            return False
        
        # Combine all data
        df_combined = pd.concat(all_readings, ignore_index=True)
        print(f"\n✅ Combined total: {len(df_combined):,} readings from all files")
        
        # Step 2: Connect to database
        if not self.connect_to_database():
            print("\n❌ Cannot proceed without database connection")
            return False
        
        # Step 3: Map to NMIs
        df_combined = self.map_customers_to_nmis(df_combined)
        
        # Step 4: Pivot by category
        df_pivoted = self.pivot_by_category(df_combined)
        
        # Save processed data
        output_file = self.processed_dir / 'ausgrid_generation_processed.csv'
        df_pivoted.to_csv(output_file, index=False)
        print(f"\n💾 Saved processed data to: {output_file}")
        
        try:            
            # Step 5: Load to database
            loaded = self.load_to_database(df_pivoted)
        except Exception as e:
            print(f"\n❌ Error during database load: {e}")
            if self.engine is not None:
                self.engine.dispose()

        # Step 6: Data quality checks
        if loaded > 0:
            self.run_data_quality_checks()
        
        # # Summary
        end_time = datetime.now()
        duration = (end_time - start_time).total_seconds()
        
        print("\n" + "=" * 80)
        print("✅ AUSGRID ETL PIPELINE COMPLETE!")
        print("=" * 80)
        print(f"Duration: {duration:.1f} seconds")
        print(f"Records Processed: {len(df_pivoted):,}")
        # print(f"Records Loaded: {loaded:,}")
        print(f"\nNext Steps:")
        print("1. Run over-export violation detection")
        print("2. Build operational monitoring dashboard")
        print("=" * 80)
        
        return True


# ============================================================================
# MAIN EXECUTION
# ============================================================================

if __name__ == "__main__":
    pipeline = AusgridGenerationPipeline()
    success = pipeline.run()
    
    if success:
        exit(0)
    else:
        exit(1)