"""
============================================================================
AUSNET SOLAR COMPLIANCE - DATA LOADER (SYSTEM USER)
============================================================================
Defaults to current system user for PostgreSQL connection
============================================================================
"""

import pandas as pd
import numpy as np
from sqlalchemy import create_engine, text
import psycopg2
from psycopg2 import sql
from pathlib import Path
from datetime import datetime
import configparser
import os
import getpass
import warnings

# Suppress pandas/sqlalchemy warnings
warnings.filterwarnings('ignore')

class SimplePostgreSQLDataLoader:
    """
    Simplified data loader using system defaults
    """
    
    def __init__(self):
        self.data_dir = Path('data/simulated')
        
        # DEFAULT CONFIGURATION (Uses current system user)
        self.db_config = {
            'host': 'localhost',
            'port': 5432,
            'database': 'ausnet_solar_compliance',
            'user': getpass.getuser(),
            'password': ''
        }
        
        self.engine = None
        
        print("=" * 70)
        print("AUSNET SOLAR COMPLIANCE - DATA LOADER")
        print("=" * 70)
        print(f"👤 User: {self.db_config['user']}")
        print(f"🎯 Target Database: {self.db_config['database']}")
    
    def connect(self):
        """Connect to PostgreSQL"""
        print("\n" + "=" * 70)
        print("DATABASE CONNECTION")
        print("=" * 70)
        
        try:
            if self.db_config['password']:
                auth_str = f"{self.db_config['user']}:{self.db_config['password']}"
            else:
                auth_str = f"{self.db_config['user']}"

            connection_string = (
                f"postgresql://{auth_str}@"
                f"{self.db_config['host']}:{self.db_config['port']}/{self.db_config['database']}"
            )
            
            self.engine = create_engine(connection_string)
            
            with self.engine.connect() as conn:
                result = conn.execute(text("SELECT version();"))
                version = result.fetchone()[0]
                print(f"✅ Connected successfully!")
                print(f"   PostgreSQL version: {version.split(',')[0]}")
            
            return True
            
        except Exception as e:
            if 'does not exist' in str(e) and self.db_config['database'] in str(e):
                print(f"\n⚠️  Database '{self.db_config['database']}' does not exist")
                return self.create_database()
            
            print(f"❌ Connection failed: {e}")
            return False

    def create_database(self):
        """Create the database if it doesn't exist"""
        print(f"\n🔨 Creating database '{self.db_config['database']}'...")
        try:
            conn = psycopg2.connect(
                host=self.db_config['host'],
                port=self.db_config['port'],
                database='postgres', 
                user=self.db_config['user'],
                password=self.db_config['password']
            )
            conn.autocommit = True
            cursor = conn.cursor()
            cursor.execute(
                sql.SQL("CREATE DATABASE {}").format(
                    sql.Identifier(self.db_config['database'])
                )
            )
            cursor.close()
            conn.close()
            print(f"✅ Database created successfully!")
            return self.connect()
        except Exception as e:
            print(f"❌ Failed to create database: {e}")
            return False

    def clean_database(self):
        """
        Drops existing tables with CASCADE to prevent dependency errors
        """
        print("\n" + "=" * 70)
        print("CLEANING OLD DATA")
        print("=" * 70)
        
        try:
            with self.engine.connect() as conn:
                print("🧹 Dropping existing tables and views (CASCADE)...")
                
                # Drop tables with CASCADE to remove Foreign Keys and Views that depend on them
                conn.execute(text("DROP TABLE IF EXISTS compliance.fact_solar_installation CASCADE;"))
                conn.execute(text("DROP TABLE IF EXISTS reference.dim_installer CASCADE;"))
                conn.execute(text("DROP TABLE IF EXISTS reference.dim_tariff CASCADE;"))
                
                # Re-create schemas
                conn.execute(text("CREATE SCHEMA IF NOT EXISTS reference;"))
                conn.execute(text("CREATE SCHEMA IF NOT EXISTS compliance;"))
                
                conn.commit()
                print("✅ Database cleaned successfully")
        except Exception as e:
            print(f"⚠️ Warning during cleanup: {e}")

    def load_dimension_tables(self):
        """Load installer and tariff dimension tables"""
        print("\n" + "=" * 70)
        print("LOADING DIMENSION TABLES")
        print("=" * 70)
        
        # Load installers
        installer_file = self.data_dir / 'dim_installer.csv'
        if installer_file.exists():
            df_installer = pd.read_csv(installer_file)
            # CRITICAL FIX: Lowercase columns for PostgreSQL compatibility
            df_installer.columns = df_installer.columns.str.lower()
            
            df_installer.to_sql('dim_installer', self.engine, schema='reference', 
                              if_exists='replace', index=False)
            print(f"✅ Loaded {len(df_installer)} installers")
        
        # Load tariffs
        tariff_file = self.data_dir / 'dim_tariff.csv'
        if tariff_file.exists():
            df_tariff = pd.read_csv(tariff_file)
            # CRITICAL FIX: Lowercase columns
            df_tariff.columns = df_tariff.columns.str.lower()
            
            df_tariff.to_sql('dim_tariff', self.engine, schema='reference',
                           if_exists='replace', index=False)
            print(f"✅ Loaded {len(df_tariff)} tariffs")
    
    def load_fact_solar_installation(self):
        """Load main solar installation fact table"""
        print("\n" + "=" * 70)
        print("LOADING SOLAR INSTALLATIONS")
        print("=" * 70)
        
        master_file = self.data_dir / 'ausnet_solar_master.csv'
        
        if not master_file.exists():
            print(f"❌ Master file not found: {master_file}")
            return False
        
        print(f"📂 Reading file...")
        df = pd.read_csv(master_file)
        
        # CRITICAL FIX: Lowercase columns for PostgreSQL compatibility
        df.columns = df.columns.str.lower()
        
        date_columns = ['installation_date', 'application_date', 'approval_date', 'connection_date']
        for col in date_columns:
            if col in df.columns:
                df[col] = pd.to_datetime(df[col], errors='coerce')
        
        print(f"🔄 Loading {len(df):,} records...")
        
        chunk_size = 5000
        total_chunks = (len(df) // chunk_size) + 1
        
        for i, chunk in enumerate(range(0, len(df), chunk_size)):
            chunk_df = df.iloc[chunk:chunk + chunk_size]
            
            if i == 0:
                chunk_df.to_sql('fact_solar_installation', self.engine, 
                              schema='compliance', if_exists='replace', index=False)
            else:
                chunk_df.to_sql('fact_solar_installation', self.engine,
                              schema='compliance', if_exists='append', index=False)
            
            print(f"   Processed chunk {i+1}/{total_chunks}", end='\r')
        
        print(f"\n✅ Successfully loaded {len(df):,} records")
        return True
    
    def run_data_quality_checks(self):
        print("\n" + "=" * 70)
        print("DATA QUALITY CHECKS")
        print("=" * 70)
        
        with self.engine.connect() as conn:
            # Query uses lowercase 'nmi', which now matches the database table
            result = conn.execute(text("""
                SELECT COUNT(*) as total, COUNT(DISTINCT nmi) as unique_nmis
                FROM compliance.fact_solar_installation
            """))
            row = result.fetchone()
            
            if row[0] == row[1]:
                print("✅ Uniqueness Check: PASS (No duplicate NMIs)")
            else:
                print(f"⚠️  Uniqueness Check: FAIL ({row[0] - row[1]} duplicates found)")
            print(f"📊 Total Records in DB: {row[0]:,}")

    def run(self):
        start_time = datetime.now()
        
        if not self.connect():
            return False
        
        self.clean_database()
        self.load_dimension_tables()
        
        if not self.load_fact_solar_installation():
            return False
            
        self.run_data_quality_checks()
        
        duration = (datetime.now() - start_time).total_seconds()
        
        print("\n" + "=" * 70)
        print("✅ DATA LOAD COMPLETE!")
        print("=" * 70)
        print(f"Duration: {duration:.1f} seconds")
        return True

if __name__ == "__main__":
    loader = SimplePostgreSQLDataLoader()
    loader.run()