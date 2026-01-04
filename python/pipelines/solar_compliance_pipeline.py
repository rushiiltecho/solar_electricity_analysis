"""
============================================================================
AUSNET SOLAR COMPLIANCE - DATA PIPELINE (CORRECTED FOR ACTUAL DATA)
============================================================================
Purpose: Process real CER and Ausgrid data into compliance database
Author: Data Analytics Team
Date: 2026-01-04
============================================================================
"""

import pandas as pd
import numpy as np
from pathlib import Path
from datetime import datetime, timedelta
import random
import warnings
warnings.filterwarnings('ignore')

class SolarComplianceDataPipeline:
    """
    Process actual CER postcode-level data and Ausgrid half-hourly data
    into individual installation records with compliance fields
    """
    
    def __init__(self):
        self.data_dir = Path('data')
        self.raw_dir = self.data_dir / 'raw'
        self.processed_dir = self.data_dir / 'processed'
        self.simulated_dir = self.data_dir / 'simulated'
        
        # Create directories
        for dir_path in [self.raw_dir, self.processed_dir, self.simulated_dir]:
            dir_path.mkdir(parents=True, exist_ok=True)
        
        print("=" * 80)
        print("AUSNET SOLAR COMPLIANCE DATA PIPELINE - CORRECTED VERSION")
        print("=" * 80)
        print(f"Working with ACTUAL CER and Ausgrid data structures")
        print("=" * 80)
    
    # ========================================================================
    # STEP 1: PROCESS CER DATA (Wide Format → Individual Installations)
    # ========================================================================
    
    def process_cer_data(self):
        """
        Process CER postcode-level data into individual installations
        
        Input: Wide format (postcode, month columns)
        Output: Long format (postcode, installation_date, individual records)
        """
        print("\n" + "="*80)
        print("STEP 1: Processing CER Solar Installation Data")
        print("="*80)
        
        cer_file = self.raw_dir / 'SGU-Solar-Installations-2011-present.csv'
        
        if not cer_file.exists():
            print(f"❌ CER file not found: {cer_file}")
            print("\nPlease download from:")
            print("https://cer.gov.au/markets/reports-and-data/small-scale-installation-postcode-data")
            return None
        
        print(f"📂 Loading: {cer_file}")
        
        # Read CER data
        df_cer = pd.read_csv(cer_file)
        
        print(f"   Loaded {len(df_cer):,} postcodes")
        print(f"   Columns: {len(df_cer.columns)}")
        
        # Filter for Victorian postcodes
        # Victoria: 3000-3999, 8000-8999
        vic_postcodes = df_cer[
            ((df_cer['Small Unit Installation Postcode'] >= 3000) & 
             (df_cer['Small Unit Installation Postcode'] <= 3999)) |
            ((df_cer['Small Unit Installation Postcode'] >= 8000) & 
             (df_cer['Small Unit Installation Postcode'] <= 8999))
        ].copy()
        
        print(f"\n✅ Filtered to Victoria: {len(vic_postcodes):,} postcodes")
        
        # Convert wide format to long format
        print("\n🔄 Converting wide format to individual installation records...")
        
        installations = []
        
        # Get month columns (exclude postcode and totals)
        month_columns = [col for col in vic_postcodes.columns 
                        if 'Installation Quantity' in col 
                        and col != 'Total Installation Quantity'
                        and 'Historic' not in col]
        
        print(f"   Processing {len(month_columns)} months...")
        
        for idx, row in vic_postcodes.iterrows():
            postcode = int(row['Small Unit Installation Postcode'])
            
            # Process each month
            for month_col in month_columns:
                count = row[month_col]
                
                if pd.isna(count) or count == 0:
                    continue
                
                count = int(count)
                
                # Parse month from column name
                # Format: "Jan 2011 - Installation Quantity"
                month_str = month_col.replace(' - Installation Quantity', '')
                
                try:
                    install_date = pd.to_datetime(month_str, format='%b %Y')
                except:
                    continue
                
                # Create individual installation records
                for i in range(count):
                    # Random day within the month
                    max_day = (install_date + pd.DateOffset(months=1) - timedelta(days=1)).day
                    random_day = random.randint(1, max_day)
                    
                    installation_date = install_date.replace(day=random_day)
                    
                    installations.append({
                        'Postcode': postcode,
                        'Installation_Date': installation_date,
                        'Installation_Month': install_date
                    })
            
            if (idx + 1) % 100 == 0:
                print(f"   Processed {idx + 1:,} postcodes... ({len(installations):,} installations)", end='\r')
        
        print(f"\n   ✅ Created {len(installations):,} installation records")
        
        # Convert to DataFrame
        df_installations = pd.DataFrame(installations)
        
        # Filter for AusNet territory (eastern Victoria)
        # AusNet postcodes: roughly 3000-3999 in eastern/rural Victoria
        ausnet_postcodes = [
            # Melbourne eastern suburbs
            3000, 3002, 3003, 3004, 3005, 3006, 3008, 3010, 3011, 3012, 3013,
            3015, 3016, 3018, 3019, 3020, 3021, 3022, 3023, 3024, 3025, 3026,
            3027, 3028, 3029, 3030, 3031, 3032, 3033, 3034, 3036, 3037, 3038,
            3039, 3040, 3041, 3042, 3043, 3044, 3045, 3046, 3047, 3048, 3049,
            3050, 3051, 3052, 3053, 3054, 3055, 3056, 3057, 3058, 3059, 3060,
            3061, 3062, 3063, 3064, 3065, 3066, 3067, 3068, 3070, 3071, 3072,
            3073, 3074, 3075, 3076, 3078, 3079, 3081, 3082, 3083, 3084, 3085,
            # Eastern Victoria / Gippsland
            3840, 3850, 3860, 3870, 3880, 3890, 3900, 3910, 3920, 3930, 3940,
            3950, 3960, 3970, 3980, 3990
        ]
        
        # Keep broader set for demo
        df_ausnet = df_installations[
            df_installations['Postcode'].isin(ausnet_postcodes)
        ].copy()
        
        print(f"\n✅ AusNet territory: {len(df_ausnet):,} installations")
        print(f"   Date range: {df_ausnet['Installation_Date'].min()} to {df_ausnet['Installation_Date'].max()}")
        
        # Save processed data
        output_file = self.processed_dir / 'cer_victoria_solar.csv'
        df_ausnet.to_csv(output_file, index=False)
        print(f"\n💾 Saved to: {output_file}")
        
        return df_ausnet
    
    # ========================================================================
    # STEP 2: ENRICH WITH COMPLIANCE FIELDS
    # ========================================================================
    
    def enrich_with_compliance_fields(self, df_installations):
        """
        Add simulated compliance fields to installation records
        """
        print("\n" + "="*80)
        print("STEP 2: Enriching with Compliance Fields")
        print("="*80)
        
        df = df_installations.copy()
        
        # Generate NMIs
        print("\n🔢 Generating NMIs...")
        df['NMI'] = df.apply(lambda x: self.generate_nmi(x['Postcode']), axis=1)
        
        # Assign capacity (realistic distribution)
        print("⚡ Assigning system capacities...")
        df['Capacity_kW'] = self.assign_capacity(len(df))
        
        # Simulate application status
        print("📋 Simulating application status...")
        df['Application_Status'] = df.apply(
            lambda x: self.simulate_application_status(x['Installation_Date'], x['Capacity_kW']),
            axis=1
        )
        
        # Assign export limits
        print("📊 Calculating export limits...")
        df['Approved_Export_Limit_kW'] = df.apply(
            lambda x: self.assign_export_limit(x['Postcode'], x['Capacity_kW'], x['Application_Status']),
            axis=1
        )
        
        # Assign installer
        print("👷 Assigning installers...")
        installer_ids = self.assign_installer_weighted(df['Capacity_kW'].values, len(df))
        df['Installer_ID'] = installer_ids
        
        # Assign tariff
        print("💳 Assigning tariffs...")
        df['Tariff_Code'] = df.apply(
            lambda x: self.assign_tariff(x['Installation_Date'], x['Application_Status']),
            axis=1
        )
        
        # Application dates
        print("📅 Generating application dates...")
        df = self.generate_application_dates(df)
        
        # Meter configuration
        print("🔌 Configuring meter setup...")
        df = self.assign_meter_configuration(df)
        
        # Battery storage
        print("🔋 Simulating battery installations...")
        df = self.simulate_battery_storage(df)
        
        print(f"\n✅ Enriched {len(df):,} installations with compliance fields")
        
        return df
    
    # ========================================================================
    # HELPER FUNCTIONS
    # ========================================================================
    
    def generate_nmi(self, postcode):
        """Generate valid NMI for Victorian postcode"""
        # Victorian NMI format: [Checksum][62/63][03][Random]
        jurisdiction = '62' if postcode < 3800 else '63'  # Metro vs Rural
        participant = '03'  # AusNet Services
        meter_id = str(random.randint(100000, 999999))
        
        # Base NMI (10 digits)
        nmi_base = jurisdiction + participant + meter_id
        
        # Calculate checksum (simplified Luhn algorithm)
        total = 0
        for i, digit in enumerate(nmi_base):
            weight = 2 if i % 2 == 0 else 1
            total += int(digit) * weight
        
        checksum = (10 - (total % 10)) % 10
        
        return str(checksum) + nmi_base
    
    def assign_capacity(self, n_installations):
        """Assign realistic system capacities"""
        # Australian residential solar distribution (kW)
        # Mode around 6.6 kW (most common)
        capacities = np.random.choice(
            [1.5, 2.0, 3.0, 3.3, 4.0, 5.0, 6.6, 10.0, 13.0],
            size=n_installations,
            p=[0.05, 0.08, 0.10, 0.12, 0.15, 0.20, 0.25, 0.03, 0.02]
        )
        return capacities
    
    def simulate_application_status(self, install_date, capacity_kw):
        """Simulate application status based on date and capacity"""
        year = install_date.year
        
        # Time-based probabilities
        if year < 2015:
            probs = {'APPROVED': 0.95, 'NO_APPLICATION': 0.03, 'PENDING': 0.02}
        elif year < 2020:
            probs = {'APPROVED': 0.85, 'NO_APPLICATION': 0.10, 'PENDING': 0.05}
        elif year < 2023:
            probs = {'APPROVED': 0.75, 'NO_APPLICATION': 0.20, 'PENDING': 0.05}
        else:
            probs = {'APPROVED': 0.88, 'NO_APPLICATION': 0.07, 'PENDING': 0.05}
        
        # Adjust for system size
        if capacity_kw > 10:
            probs['APPROVED'] += 0.10
            probs['NO_APPLICATION'] = max(0, probs['NO_APPLICATION'] - 0.10)
        elif capacity_kw < 3:
            probs['NO_APPLICATION'] += 0.08
            probs['APPROVED'] = max(0, probs['APPROVED'] - 0.08)
        
        # Normalize
        total = sum(probs.values())
        probs = {k: v/total for k, v in probs.items()}
        
        return np.random.choice(list(probs.keys()), p=list(probs.values()))
    
    def assign_export_limit(self, postcode, capacity_kw, status):
        """Assign export limit based on Victorian rules"""
        if status == 'NO_APPLICATION':
            return None
        
        # Constrained areas (Westernport region)
        constrained_postcodes = [3978, 3979, 3980, 3981, 3984]
        
        if postcode in constrained_postcodes:
            return 3.0
        elif capacity_kw < 1.5:
            return 1.0  # Micro System Limit
        elif capacity_kw > 10:
            return min(10.0, capacity_kw * 0.8)  # Network study approval
        else:
            return 5.0  # Standard limit
    
    def assign_installer_weighted(self, capacities, n_installations):
        """Assign installer based on system size and market share"""
        installers = {
            1: {'name': 'SolarMax Victoria', 'share': 0.15, 'speciality': 'residential'},
            2: {'name': 'GreenTech Energy', 'share': 0.12, 'speciality': 'all'},
            3: {'name': 'EcoSolar Solutions', 'share': 0.10, 'speciality': 'residential'},
            4: {'name': 'PowerPlus Solar', 'share': 0.10, 'speciality': 'commercial'},
            5: {'name': 'SunnyDay Installations', 'share': 0.09, 'speciality': 'residential'},
            6: {'name': 'VIC Solar Experts', 'share': 0.08, 'speciality': 'all'},
            7: {'name': 'QuickSolar Install', 'share': 0.08, 'speciality': 'residential'},
            8: {'name': 'Budget Solar Co', 'share': 0.08, 'speciality': 'residential'}
        }
        
        # Remaining 20% distributed to "others"
        shares = [inst['share'] for inst in installers.values()]
        shares.append(0.20)  # Others
        
        installer_ids = np.random.choice(
            list(installers.keys()) + [99],  # 99 = Other
            size=n_installations,
            p=shares
        )
        
        # Adjust for system size
        for i, cap in enumerate(capacities):
            if cap > 10 and installer_ids[i] not in [2, 4, 6]:
                # Large systems go to commercial specialists
                installer_ids[i] = np.random.choice([2, 4, 6])
        
        return installer_ids
    
    def assign_tariff(self, install_date, status):
        """Assign tariff based on installation era and status"""
        year = install_date.year
        
        # Solar tariffs by era
        if year < 2012:
            solar_tariffs = ['FIT60']
        elif year < 2017:
            solar_tariffs = ['FIT25', 'FIT20']
        elif year < 2020:
            solar_tariffs = ['FIT10', 'FIT12']
        else:
            solar_tariffs = ['SOLARFLAT', 'SOLARTOU', 'FIT10']
        
        non_solar_tariffs = ['RESIDENTIAL', 'RESTOU', 'CONTROLLED']
        
        # Approved installations mostly get solar tariffs
        if status == 'APPROVED':
            if random.random() < 0.95:
                return random.choice(solar_tariffs)
            else:
                return random.choice(non_solar_tariffs)  # Compliance issue!
        else:
            # Unauthorized mostly on wrong tariffs
            if random.random() < 0.80:
                return random.choice(non_solar_tariffs)  # Compliance issue!
            else:
                return random.choice(solar_tariffs)
    
    def generate_application_dates(self, df):
        """Generate realistic application, approval, connection dates"""
        df = df.copy()
        
        df['Application_Date'] = None
        df['Approval_Date'] = None
        df['Connection_Date'] = None
        
        for idx, row in df.iterrows():
            install_date = row['Installation_Date']
            status = row['Application_Status']
            
            if status == 'APPROVED':
                # Application 1-2 months before install
                app_date = install_date - timedelta(days=random.randint(30, 60))
                # Approval 14-45 days after application
                approval_date = app_date + timedelta(days=random.randint(14, 45))
                # Connection 0-14 days after install
                conn_date = install_date + timedelta(days=random.randint(0, 14))
                
                df.at[idx, 'Application_Date'] = app_date
                df.at[idx, 'Approval_Date'] = approval_date
                df.at[idx, 'Connection_Date'] = conn_date
                
            elif status == 'PENDING':
                # Application recent, no approval yet
                app_date = install_date - timedelta(days=random.randint(7, 30))
                df.at[idx, 'Application_Date'] = app_date
                df.at[idx, 'Connection_Date'] = install_date
                
            else:  # NO_APPLICATION
                # Direct connection
                df.at[idx, 'Connection_Date'] = install_date
        
        return df
    
    def assign_meter_configuration(self, df):
        """Assign meter configuration"""
        df = df.copy()
        
        # 85% single, 12% dual, 3% multi
        df['Is_Multi_Meter'] = np.random.choice(
            [False, True],
            size=len(df),
            p=[0.85, 0.15]
        )
        
        # Multi-meter sites: only 60% properly consolidated
        df['Is_Meter_Consolidated'] = df['Is_Multi_Meter'].apply(
            lambda x: random.random() < 0.60 if x else True
        )
        
        return df
    
    def simulate_battery_storage(self, df):
        """Simulate battery installations"""
        df = df.copy()
        
        # Battery adoption rates by year
        battery_rates = {
            2015: 0.01, 2016: 0.015, 2017: 0.02, 2018: 0.03, 2019: 0.04,
            2020: 0.05, 2021: 0.07, 2022: 0.10, 2023: 0.12, 2024: 0.15, 2025: 0.18
        }
        
        df['Has_Battery'] = False
        df['Battery_Capacity_kWh'] = None
        df['Battery_Type'] = None
        
        for idx, row in df.iterrows():
            year = row['Installation_Date'].year
            capacity = row['Capacity_kW']
            
            # Get battery rate for year
            rate = battery_rates.get(year, 0.01)
            
            # Larger systems more likely to have battery
            if capacity > 10:
                rate *= 1.5
            
            if random.random() < rate:
                df.at[idx, 'Has_Battery'] = True
                df.at[idx, 'Battery_Capacity_kWh'] = random.choice([10, 13.5, 15])
                df.at[idx, 'Battery_Type'] = random.choice(['LITHIUM_ION', 'SOLAR_BATTERY'])
        
        return df
    
    # ========================================================================
    # STEP 3: CREATE DIMENSION TABLES
    # ========================================================================
    
    def create_dimension_tables(self):
        """Create installer and tariff dimension tables"""
        print("\n" + "="*80)
        print("STEP 3: Creating Dimension Tables")
        print("="*80)
        
        # Installer dimension
        installers = [
            {'Installer_ID': 1, 'Installer_Name': 'SolarMax Victoria', 'ABN': '12345678901', 'Quality_Score': 9.2, 'CEC_Accredited': True},
            {'Installer_ID': 2, 'Installer_Name': 'GreenTech Energy', 'ABN': '23456789012', 'Quality_Score': 8.8, 'CEC_Accredited': True},
            {'Installer_ID': 3, 'Installer_Name': 'EcoSolar Solutions', 'ABN': '34567890123', 'Quality_Score': 8.5, 'CEC_Accredited': True},
            {'Installer_ID': 4, 'Installer_Name': 'PowerPlus Solar', 'ABN': '45678901234', 'Quality_Score': 9.0, 'CEC_Accredited': True},
            {'Installer_ID': 5, 'Installer_Name': 'SunnyDay Installations', 'ABN': '56789012345', 'Quality_Score': 7.8, 'CEC_Accredited': True},
            {'Installer_ID': 6, 'Installer_Name': 'VIC Solar Experts', 'ABN': '67890123456', 'Quality_Score': 8.3, 'CEC_Accredited': True},
            {'Installer_ID': 7, 'Installer_Name': 'QuickSolar Install', 'ABN': '78901234567', 'Quality_Score': 7.2, 'CEC_Accredited': True},
            {'Installer_ID': 8, 'Installer_Name': 'Budget Solar Co', 'ABN': '89012345678', 'Quality_Score': 6.5, 'CEC_Accredited': True},
        ]
        
        df_installer = pd.DataFrame(installers)
        installer_file = self.simulated_dir / 'dim_installer.csv'
        df_installer.to_csv(installer_file, index=False)
        print(f"✅ Created installer dimension: {len(df_installer)} installers")
        
        # Tariff dimension
        tariffs = [
            {'Tariff_Code': 'FIT60', 'Tariff_Type': 'SOLAR', 'FIT_Rate_c_kWh': 60.0, 'Is_Active': False},
            {'Tariff_Code': 'FIT25', 'Tariff_Type': 'SOLAR', 'FIT_Rate_c_kWh': 25.0, 'Is_Active': False},
            {'Tariff_Code': 'FIT20', 'Tariff_Type': 'SOLAR', 'FIT_Rate_c_kWh': 20.0, 'Is_Active': False},
            {'Tariff_Code': 'FIT12', 'Tariff_Type': 'SOLAR', 'FIT_Rate_c_kWh': 12.0, 'Is_Active': False},
            {'Tariff_Code': 'FIT10', 'Tariff_Type': 'SOLAR', 'FIT_Rate_c_kWh': 10.0, 'Is_Active': True},
            {'Tariff_Code': 'SOLARFLAT', 'Tariff_Type': 'SOLAR', 'FIT_Rate_c_kWh': 10.2, 'Is_Active': True},
            {'Tariff_Code': 'SOLARTOU', 'Tariff_Type': 'SOLAR', 'FIT_Rate_c_kWh': 12.0, 'Is_Active': True},
            {'Tariff_Code': 'RESIDENTIAL', 'Tariff_Type': 'NON_SOLAR', 'FIT_Rate_c_kWh': 0.0, 'Is_Active': True},
            {'Tariff_Code': 'RESTOU', 'Tariff_Type': 'NON_SOLAR', 'FIT_Rate_c_kWh': 0.0, 'Is_Active': True},
            {'Tariff_Code': 'CONTROLLED', 'Tariff_Type': 'NON_SOLAR', 'FIT_Rate_c_kWh': 0.0, 'Is_Active': True},
        ]
        
        df_tariff = pd.DataFrame(tariffs)
        tariff_file = self.simulated_dir / 'dim_tariff.csv'
        df_tariff.to_csv(tariff_file, index=False)
        print(f"✅ Created tariff dimension: {len(df_tariff)} tariffs")
        
        return df_installer, df_tariff
    
    # ========================================================================
    # MAIN EXECUTION
    # ========================================================================
    
    def run(self):
        """Execute complete pipeline"""
        start_time = datetime.now()
        
        # Step 1: Process CER data
        df_installations = self.process_cer_data()
        
        if df_installations is None:
            print("\n❌ Cannot proceed without CER data")
            return False
        
        # Step 2: Enrich with compliance fields
        df_enriched = self.enrich_with_compliance_fields(df_installations)
        
        # Step 3: Create dimension tables
        self.create_dimension_tables()
        
        # Save final master file
        print("\n" + "="*80)
        print("SAVING FINAL OUTPUTS")
        print("="*80)
        
        output_file = self.simulated_dir / 'ausnet_solar_master.csv'
        df_enriched.to_csv(output_file, index=False)
        print(f"💾 Master file: {output_file}")
        print(f"   Records: {len(df_enriched):,}")
        
        # Summary statistics
        print("\n" + "="*80)
        print("SUMMARY STATISTICS")
        print("="*80)
        
        print(f"\nTotal Installations: {len(df_enriched):,}")
        print(f"Date Range: {df_enriched['Installation_Date'].min()} to {df_enriched['Installation_Date'].max()}")
        print(f"\nApplication Status:")
        print(df_enriched['Application_Status'].value_counts())
        print(f"\nTotal Capacity: {df_enriched['Capacity_kW'].sum():,.1f} kW")
        print(f"Average Capacity: {df_enriched['Capacity_kW'].mean():.2f} kW")
        print(f"Battery Installations: {df_enriched['Has_Battery'].sum():,} ({df_enriched['Has_Battery'].sum()/len(df_enriched)*100:.1f}%)")
        
        # Compliance issues preview
        tariff_issues = (df_enriched['Application_Status'] == 'APPROVED') & (df_enriched['Tariff_Code'].str.contains('RESIDENTIAL|CONTROLLED|RESTOU', na=False))
        print(f"\nPotential Compliance Issues:")
        print(f"  Unauthorized: {(df_enriched['Application_Status'] == 'NO_APPLICATION').sum():,}")
        print(f"  Tariff Mismatches: {tariff_issues.sum():,}")
        print(f"  Multi-meter not consolidated: {((df_enriched['Is_Multi_Meter'] == True) & (df_enriched['Is_Meter_Consolidated'] == False)).sum():,}")
        
        end_time = datetime.now()
        duration = (end_time - start_time).total_seconds()
        
        print("\n" + "="*80)
        print("✅ PIPELINE COMPLETE!")
        print("="*80)
        print(f"Duration: {duration:.1f} seconds")
        print(f"\nNext Steps:")
        print("1. Run: python 02_load_data_to_postgres.py")
        print("2. Build Power BI dashboard")
        print("="*80)
        
        return True


# ============================================================================
# MAIN EXECUTION
# ============================================================================

if __name__ == "__main__":
    pipeline = SolarComplianceDataPipeline()
    success = pipeline.run()
    
    if success:
        exit(0)
    else:
        exit(1)