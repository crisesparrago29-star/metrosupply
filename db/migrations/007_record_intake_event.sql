-- Save a customer message exactly once. Calling it again with the same
-- source + source_ref returns the existing event instead of a duplicate.

CREATE FUNCTION record_intake_event(p_source text, p_source_ref text, p_raw_text text)
RETURNS TABLE (event_id bigint, is_new boolean)
LANGUAGE plpgsql AS $$
BEGIN
  IF coalesce(trim(p_raw_text), '') = '' THEN
    RAISE EXCEPTION 'raw_text is empty';
  END IF;

  INSERT INTO intake_events (source, source_ref, raw_text)
  VALUES (p_source, p_source_ref, p_raw_text)
  ON CONFLICT (source, source_ref) DO NOTHING
  RETURNING id INTO event_id;

  IF event_id IS NOT NULL THEN
    is_new := true;            -- first time we've seen this message
  ELSE
    SELECT id INTO event_id    -- already saved before: return that one
    FROM intake_events
    WHERE source = p_source AND source_ref = p_source_ref;
    is_new := false;
  END IF;

  RETURN NEXT;
END $$;
