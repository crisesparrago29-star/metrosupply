-- 013: Telegram identity.
-- n8n may ask "who is this Telegram user?" but may never read app_users itself.
-- Returns one row (username, role) for an ACTIVE user linked to that Telegram ID,
-- or no rows if the ID is unknown or the user is inactive.

CREATE FUNCTION user_for_telegram(p_telegram_user_id bigint)
RETURNS TABLE(username text, role text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT u.username::text, u.role::text
  FROM app_users u
  WHERE u.telegram_user_id = p_telegram_user_id
    AND u.is_active;
$$;

-- Nobody may run it by default; only n8n may.
REVOKE EXECUTE ON FUNCTION user_for_telegram(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION user_for_telegram(bigint) TO app_n8n;
