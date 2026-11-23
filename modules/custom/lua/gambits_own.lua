-- REVAMPED_STUB v1 gambits_own: an empty placeholder (the Gambits Revamped engine replaces this file).
-- GAMBITS_OWN is the answer to "does Gambits own this mate?" that the hooks in squad.lua ask. Here the answer is always no.
-- Nothing sets the GAMBITS_OWN_<slot> character variables, so every hook in squad.lua falls through to the dev team's code.
GAMBITS_OWN = GAMBITS_OWN or {}
GAMBITS_OWN.stub = true
if GAMBITS_OWN.owns == nil then
    GAMBITS_OWN.owns = function(_player, _trust)
        return false
    end
end
return GAMBITS_OWN
