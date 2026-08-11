--!nonstrict
-- Minimal signal. Used instead of BindableEvent for module-to-module events so
-- we can pass tables and functions without serialization, and so firing costs a
-- plain loop rather than a cross-boundary hop.

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local connections = self._signal._connections
	local index = table.find(connections, self)
	if index then
		table.remove(connections, index)
	end
end

function Signal.new()
	return setmetatable({ _connections = {} }, Signal)
end

function Signal:Connect(fn: (...any) -> ())
	local connection = setmetatable({
		Connected = true,
		_signal = self,
		_fn = fn,
	}, Connection)
	table.insert(self._connections, connection)
	return connection
end

function Signal:Once(fn: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

-- Handlers run in their own thread so one erroring listener cannot stop the
-- others, and so a yielding listener cannot stall the firing code.
function Signal:Fire(...)
	-- Iterate a copy: a handler is allowed to disconnect itself or others.
	local snapshot = table.clone(self._connections)
	for _, connection in snapshot do
		if connection.Connected then
			task.spawn(connection._fn, ...)
		end
	end
end

function Signal:DisconnectAll()
	for _, connection in table.clone(self._connections) do
		connection:Disconnect()
	end
end

export type Connection = typeof(setmetatable({} :: { Connected: boolean, _signal: any, _fn: (...any) -> () }, Connection))
export type Signal = typeof(Signal.new())

return Signal
