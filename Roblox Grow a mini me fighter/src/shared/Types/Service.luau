--!strict
-- The contract every server service and client controller follows.
--
-- Two phases exist so that services can reference each other during Init without
-- caring about load order: by the time any Start runs, every service has been
-- required and initialised. A service may read another service's fields in
-- Start, but must not assume anything has *happened* yet during Init.

export type Registry = { [string]: any }

export type Service = {
	Name: string?,
	-- Wire up state and register handlers. Must not yield for long and must not
	-- assume other services have started.
	Init: ((registry: Registry) -> ())?,
	-- Begin doing work: connect to Heartbeat, start loops, spawn things.
	Start: ((registry: Registry) -> ())?,
}

return {}
