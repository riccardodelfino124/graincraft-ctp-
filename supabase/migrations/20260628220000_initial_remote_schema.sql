


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."contracts" (
    "contract_id" character varying(20) NOT NULL,
    "vendor_code" character varying(10),
    "material" character varying(20),
    "unit_price_standard" numeric(12,4),
    "unit_price_expedite" numeric(12,4),
    "lead_time_standard_wd" integer,
    "lead_time_expedite_wd" numeric(5,1),
    "expedite_freight_cost" numeric(12,4),
    "is_primary" boolean,
    "validity_start" "date",
    "validity_end" "date"
);


ALTER TABLE "public"."contracts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."items" (
    "material" character varying(20) NOT NULL,
    "product_group" character varying(20),
    "description" character varying(160),
    "uom" character varying(8),
    "current_stock" numeric(12,2),
    "avg_daily_demand" numeric(12,3)
);


ALTER TABLE "public"."items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."open_pos" (
    "po_id" character varying(20) NOT NULL,
    "vendor_code" character varying(10),
    "material" character varying(20),
    "quantity_ordered" numeric(12,2),
    "quantity_received" numeric(12,2),
    "expected_delivery_date" "date",
    "is_expedite" boolean
);


ALTER TABLE "public"."open_pos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."orders_history" (
    "order_id" character varying(20) NOT NULL,
    "customer_id" character varying(20),
    "customer_tier" character varying(2),
    "material" character varying(20),
    "quantity" numeric(12,2),
    "order_date" "date",
    "promised_date" "date",
    "actual_delivery_date" "date",
    "unit_price_charged" numeric(12,4),
    "unit_cost" numeric(12,4),
    "expedite_used" boolean
);


ALTER TABLE "public"."orders_history" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendors" (
    "vendor_code" character varying(10) NOT NULL,
    "vendor_name" character varying(120) NOT NULL,
    "payment_terms_days" integer,
    "product_group" character varying(20)
);


ALTER TABLE "public"."vendors" OWNER TO "postgres";


ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_pkey" PRIMARY KEY ("contract_id");



ALTER TABLE ONLY "public"."items"
    ADD CONSTRAINT "items_pkey" PRIMARY KEY ("material");



ALTER TABLE ONLY "public"."open_pos"
    ADD CONSTRAINT "open_pos_pkey" PRIMARY KEY ("po_id");



ALTER TABLE ONLY "public"."orders_history"
    ADD CONSTRAINT "orders_history_pkey" PRIMARY KEY ("order_id");



ALTER TABLE ONLY "public"."vendors"
    ADD CONSTRAINT "vendors_pkey" PRIMARY KEY ("vendor_code");



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_material_fkey" FOREIGN KEY ("material") REFERENCES "public"."items"("material");



ALTER TABLE ONLY "public"."contracts"
    ADD CONSTRAINT "contracts_vendor_code_fkey" FOREIGN KEY ("vendor_code") REFERENCES "public"."vendors"("vendor_code");



ALTER TABLE ONLY "public"."open_pos"
    ADD CONSTRAINT "open_pos_material_fkey" FOREIGN KEY ("material") REFERENCES "public"."items"("material");



ALTER TABLE ONLY "public"."open_pos"
    ADD CONSTRAINT "open_pos_vendor_code_fkey" FOREIGN KEY ("vendor_code") REFERENCES "public"."vendors"("vendor_code");



ALTER TABLE ONLY "public"."orders_history"
    ADD CONSTRAINT "orders_history_material_fkey" FOREIGN KEY ("material") REFERENCES "public"."items"("material");



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON TABLE "public"."contracts" TO "anon";
GRANT ALL ON TABLE "public"."contracts" TO "authenticated";
GRANT ALL ON TABLE "public"."contracts" TO "service_role";



GRANT ALL ON TABLE "public"."items" TO "anon";
GRANT ALL ON TABLE "public"."items" TO "authenticated";
GRANT ALL ON TABLE "public"."items" TO "service_role";



GRANT ALL ON TABLE "public"."open_pos" TO "anon";
GRANT ALL ON TABLE "public"."open_pos" TO "authenticated";
GRANT ALL ON TABLE "public"."open_pos" TO "service_role";



GRANT ALL ON TABLE "public"."orders_history" TO "anon";
GRANT ALL ON TABLE "public"."orders_history" TO "authenticated";
GRANT ALL ON TABLE "public"."orders_history" TO "service_role";



GRANT ALL ON TABLE "public"."vendors" TO "anon";
GRANT ALL ON TABLE "public"."vendors" TO "authenticated";
GRANT ALL ON TABLE "public"."vendors" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







