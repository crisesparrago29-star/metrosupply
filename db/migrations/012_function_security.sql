-- Security: n8n may run ONLY the safe functions, never change tables directly.

-- 1. The six functions n8n calls run with their OWNER's permissions.
--    search_path is fixed so they only ever use our own tables.
ALTER FUNCTION record_intake_event(text, text, text)        SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION create_draft_order(bigint, text, text, jsonb) SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION approve_order(bigint, text)                   SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION reject_order(bigint, text, text)              SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION cancel_order(bigint, text, text)              SECURITY DEFINER SET search_path = public, pg_temp;
ALTER FUNCTION expire_reservations()                         SECURITY DEFINER SET search_path = public, pg_temp;

-- 2. Nobody may run our functions by default...
REVOKE EXECUTE ON FUNCTION
  get_setting(text),
  record_intake_event(text, text, text),
  find_product(text),
  to_base_qty(bigint, numeric, text),
  price_for(bigint, bigint, date),
  create_draft_order(bigint, text, text, jsonb),
  approve_order(bigint, text),
  require_approver(text),
  release_reservations(bigint, text),
  reject_order(bigint, text, text),
  cancel_order(bigint, text, text),
  expire_reservations(),
  block_ledger_change(),
  block_append_only_change()
FROM PUBLIC;

-- ...and functions created in the future start locked too.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- 3. n8n may run exactly these six. Helpers stay off-limits.
GRANT EXECUTE ON FUNCTION
  record_intake_event(text, text, text),
  create_draft_order(bigint, text, text, jsonb),
  approve_order(bigint, text),
  reject_order(bigint, text, text),
  cancel_order(bigint, text, text),
  expire_reservations()
TO app_n8n;
