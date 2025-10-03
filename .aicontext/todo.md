# TODO — Schema Guidance

- Track when join emitters diversify beyond our own experiments; that is the trigger to formalize schema descriptors and adapters.
- For now, keep guidance lightweight (docs, warnings, example wrappers) and avoid enforcing hard schemas.
- Plan next iteration to include helper wrappers (`wrapLuaEvent`, etc.) once uncontrolled or third-party sources start feeding the join.

Rationale: schema/version metadata is nice-to-have early, but it becomes essential only when we can no longer control or easily audit every emitter. We'll revisit once external mods pipe data through the join.
