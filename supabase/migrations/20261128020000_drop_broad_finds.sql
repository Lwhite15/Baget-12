-- Finds a scout made only because the product shared its category ("Broad mission match only"), for scouts that
-- already know specific keywords, brands or styles: e.g. vinyl records labeled "collectibles" in a Funko scout. The
-- matcher no longer keeps these; this clears the ones still open. Watched finds stay.
delete from finds f
using agents a
where a.id = f.agent_id
  and f.status = 'open'
  and f.why[1] = 'Broad mission match only'
  and not coalesce(f.watching, false)
  and coalesce(array_length(a.keywords, 1), 0) + coalesce(array_length(a.makers, 1), 0) + coalesce(array_length(a.traits, 1), 0) >= 3;
