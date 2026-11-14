-- Runs once, the first time PostgreSQL starts with an empty data volume.
-- Database "n8n" (n8n's own data) is created from POSTGRES_DB.
-- This creates the separate business database.
CREATE DATABASE metrosupply;