--- Music Player Daemon (MPD) client library.
--
-- Alows basic manipulation of the MPD protocol. This provides the client part, you will need a MPD-compatible server running on
-- another machine.
--
-- Please see the MPD command reference on the [official documentation](http://www.musicpd.org/doc/protocol/command_reference.html).
--
-- You may want to generate a documentation for this file using LDoc: `ldoc .`. However, LDoc doesn't seem to
-- appreciate my coding style so it doesn't display everything, but the rendered documentation should be usable enough.
-- If you didn't understand something or think you missed something, please read the [source file](source/mpc.lua.html), which is
-- largely commented.
--
-- Variables prefixed with a `_` are private. Don't use them if you don't know what you're doing.
--
-- *Requires* `luasocket` or `ctr.socket` (ctrµLua).
--
-- When I started this project in october 2015, there weren't really any other decent MPD client library for Lua.
-- The ones available were either uncomplete or outdated, regarding either MPD or Lua. So I made this.
-- I didn't want to publish it until I used it in something, since it's a pretty small library (I didn't know things like left-pad existed and people were ok with it).
-- Well, too bad for me. As it turns out, today several new libraries have poped up and they look quite usable.
-- Well, it's too late. Now this is yet another MPD library, but this time I wrote it so it's the best.
--
-- @author Reuh
-- @release 0.2.0

-- Copyright (c) 2015-2018 Étienne "Reuh" Fildadut <fildadut@reuh.eu>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- 1. The above copyright notice and this permission notice shall be included in
--    all copies or substantial portions of the Software; and
-- 2. You must cause any modified source files to carry prominent notices stating
--    that you changed the files.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local socket
if package.loaded["ctr.socket"] then
	socket = require("ctr.socket")
else
	socket = require("socket")
end

-- Parsing commands response helpers.
local function cast(str)
	return tonumber(str, 10) or str
end
local function parseList(lines, starters)
	local list = {}
	if lines[1] ~= "OK" then
		if not starters then
			starters = { lines[1]:match("^[^:]+") } -- first tag for each song
		end
		local cursong -- currently parsing song
		for _, l in ipairs(lines) do
			if l == "OK" then
				break
			else
				for _, startType in ipairs(starters) do
					if l:match(startType..":") then -- next song
						cursong = {}
						table.insert(list, cursong)
						break
					end
				end
				cursong[l:match("^[^:]+")] = cast(l:match("^[^:]+%: (.*)$")) -- add tag
			end
		end
	end
	return list
end
local function parseSticker(dict)
	for k, v in pairs(dict) do
		if k == "sticker" and v:match(".+=.+") then
			dict[k] = { [v:match("(.+)=.+")] = cast(v:match(".+=(.+)")) }
		end
		if type(v) == "table" then
			parseSticker(v)
		end
	end
	return dict
end

--- Music Player Client object.
-- Used to manipulate a single MPD server.
-- @type mpc
local mpc = {
	---## PUBLIC METHODS ##---
	-- The functions you should use.

	--- Connect to a MPD server.
	-- @tparam string address server address
	-- @tparam number port server port
	-- @see mpcmodule
	init = function(self, address, port)
		self._address = address
		self._port = port

		self:_connect()
	end,

	--- Execute a command.
	-- A shortcut (and generally more useful version) is `mpc:commandName([arguments, ...])`, which will also try return a parsed version of the result
	-- in a nicer Lua representation as a second return value. See COMMANDS OVERWRITE.
	-- @tparam string command command name
	-- @tparam[opt] any ... command arguments
	-- @treturn[1] boolean true if it was a success, false otherwise
	-- @treturn[1] table List of the lines of the response (strings)
	-- @treturn[2] nil nil if nothing was received
	command = function(self, command, ...)
		self:_send({ command, ... })
		return self:_receive(true)
	end,

	--- Called each time something can be logged.
	-- You will want to and can overwrite this function.
	-- @tparam string message message string
	-- @tparam[opt] any ... arguments to pass to message:format(...)
	log = function(self, message, ...)
		print(("[mpc.lua@%s:%s] %s"):format(self._address, self._port, message:format(...)))
	end,

	---## COMMANDS OVERWRITE ##---
	-- Theses functions overwrite some MPD's command, to add somme pratical features.
	-- In particular, every MPD command which return something will be wrapped here so the second return value is either (the list of lines is still available as a third return value):
	-- * A list of dictionnaries, if the command can return a list of similar elements (playlistinfo, search, ...)
	-- * A dictionnary if the command return something which isn't a list (status, currentsong, ...)
	-- The key names are the same used by MPD in the responses. Numbers will be automatically casted to a Lua number, every other value will be a string.
	-- Commands which return nothing will return nil as a second return value.
	-- Most overwrites are generated at the end of the file using the overwrites lists defined below.
	-- Signature for every command called through `mpc:commandName`:
	-- @tparam[opt] any ... command arguments
	-- @treturn[1] boolean true if it was a success
	-- @treturn[1] table dictionnary or list of dictionnary containing the response data, or nil if there is no response data to be expected
	-- @treturn[1] table List of the lines of the response (strings)
	-- @treturn[2] boolean false if there was an error
	-- @treturn[2] string error message
	-- @treturn[3] nil nil if nothing was received

	--- Sends the close command and close the socket.
	-- This will log any uncomplete message received, if any. Returns nothing.
	-- Call this when you are done with the mpc object.
	-- Note however, that the client will automatically reconnect if you reuse it later.
	close = function(self)
		self:_send("close")
		self._socket:close()

		if #self._buffer > 0 then
			self:log("UNCOMPLETLY RECEIVED MESSAGE:\n\t%s", table.concat(self._buffer, "\n\t"))
		end
		self:log("CLOSED")
	end,

	--- Sends the password command.
	-- This will store the password in a variable so it can be resent in case of disconnection.
	-- @tparam string password the password
	password = function(self, password)
		self._password = password
		local success, lines = self:command("password", password)
		return success, not success and lines[1] or nil, lines
	end,

	--- Returns a chunk of albumart.
	-- See the MPD documentation. The raw bytes will be stored in the `chunk` field of the response dictionnary.
	albumart = function(self, ...)
		local success, lines = self:command("albumart", ...)
		return success, success and {
			size = lines[1]:match("size: (%d+)"),
			binary = lines[2]:match("binary: (%d+)"),
			chunk = table.concat(lines, "", 3, #lines-1)
		} or lines[1], lines
	end,

	--- Sticker commands.
	-- Will parse stickers values in dictionnary.sticker.name = value.
	sticker = function(self, action, ...)
		if action == "list" or action == "find" then
			local success, lines = self:command("sticker", action, ...)
			return success, success and parseSticker(parseList(lines)) or lines[1], lines
		elseif action == "get" then
			local success, lines = self:command("sticker", action, ...)
			return success, success and parseSticker(parseList(lines)[1]) or lines[1], lines
		else
			local success, lines = self:command("sticker", action, ...)
			return success, not success and lines[1] or nil, lines
		end
	end,

	--- Commands which will return a list of dictionnaries.
	_overwriteDictList = {
		"idle", -- Querying MPD's status
		"playlistfind", "playlistid", "playlistinfo", "playlistsearch", "plchanges", "plchangesposid", -- The current playlist
		"listplaylist", "listplaylistinfo", "listplaylists", -- The current playlist
		"count", "find", "list", "listall", "listallinfo", "search", listfiles = { "file", "directory" }, lsinfo = { "file", "directory" }, -- The music database
		"listmounts", "listneighbors", -- Mounts and neighbors
		"tagtypes", -- Connection settings
		"listpartitions", -- Partition commands
		"outputs", -- Audio output devices
		"commands", "notcommands", "urlhandlers", "decoders", -- Reflection
		"channels", "readmessages" -- Client to client
	},

	--- Commands which will return a dictionnary.
	_overwriteDict = {
		"currentsong", "status", "stats", -- Querying MPD's status
		"readcomments", "update", "rescan", -- The music database
		"config" -- Reflection
	},

	---## PRIVATE FUNCTIONS ##---
	-- Theses functions are intended to be used internally by mpc.lua.
	-- You can use them but they weren't meant to be used from the outside.

	_socket = nil, -- socket object

	_address = "", -- server address string
	_port = 0, -- server port integer

	_password = "",  -- server password string

	_buffer = {}, -- received message buffer table

	--- Connects to the server.
	-- The fuction will auto-login if a password was previously set.
	-- If the client was already connected, it will disconnect and then reconnect.
	_connect = function(self)
		if self._socket then self._socket:close() end

		self._socket = assert(socket.tcp())
		assert(self._socket:connect(self._address, self._port))
		if self._socket.settimeout then self._socket:settimeout(0.1) end

		assert(self:_receive(), "something went terribly wrong")
		self:log("CONNECTED")

		if self._password ~= "" then self:password(self._password) end
	end,

	--- Send a list of commands to the server.
	-- @tparam table commands List of commands (strings or tables). If table, the table represent the arguments list.
	-- ie, this `:_send({"play", 18})` is equivalent to `:_send("play 18")`.
	_send = function(self, ...)
		local commands = {...}
		for i, v in ipairs(commands) do
			if type(v) == "table" then
				local cmd = v[1]
				for j, k in ipairs(v) do
					if j > 1 then -- bweh
						if type(k) == "string" then
							cmd = cmd..(" %q"):format(k)
						elseif type(k) == "table" then
							cmd = cmd..(k[1] or "")..":"..(k[2] or "")
						else
							cmd = cmd.." "..tostring(k)
						end
					end
				end
				commands[i] = cmd
			end
		end

		local success, err = self._socket:send(table.concat(commands, "\n").."\n")
		if not success then
			if err == "closed" then
				self:log("CONNECTION CLOSED, RECONNECTING")
				self:_connect()
				self:_send(...)
			else
				error("error while sending data to MPD server: "..err)
			end
		end

		self:log("SENT:\n\t%s", table.concat(commands, "\n\t"))
	end,

	--- Receive a single server response.
	-- @tparam boolean block true to block until a message is received
	-- @treturn[1] boolean true if was a success, false otherwise
	-- @treturn[1] table List of the lines of the response (strings)
	-- @treturn[2] nil nil if nothing was received
	_receive = function(self, block)
		local success
		local received

		repeat
			local response, err = self._socket:receive()

			if response and response ~= "" then
				table.insert(self._buffer, response)

				if response:sub(1, 2) == "OK" or response:sub(1, 3) == "ACK" then
					success = response:sub(1, 2) == "OK"

					received = self._buffer
					self._buffer = {}

					break
				end

			elseif err == "closed" then
				self:log("CONNECTION CLOSED, RECONNECTING")
				self:_connect()
				return self:_receive()
			elseif err ~= "timeout" then
				error("error while receiving data from MPD server: "..err)
			end
		until not block and (not response or response == "")

		if not received then return nil end

		self:log("RECEIVED:\n\t%s", table.concat(received, "\n\t"))
		return success, received
	end
}

-- Overwrites for commands which return lists of dictionnaries
for k, v in pairs(mpc._overwriteDictList) do
	local command, starters
	if type(k) == "number" then command = v
	else command, starters = k, v end
	mpc[command] = function(self, ...)
		local success, lines = self:command(command, ...)
		return success, success and parseList(lines, starters) or lines[1], lines
	end
end
-- Overwrites for commands which return a single dictionnary
for k, v in pairs(mpc._overwriteDict) do
	local command, starters
	if type(k) == "number" then command = v
	else command, starters = k, v end
	mpc[command] = function(self, ...)
		local success, lines = self:command(command, ...)
		return success, success and parseList(lines, starters)[1] or lines[1], lines
	end
end

--- The module returns a constructor function.
-- Calling this function will create a new MPC object.
-- The arguments will be passed to the object's `:init` method.
-- @within Module
-- @function mpcmodule
-- @usage local mpc = require("mpc")("localhost", 6600) -- where "localhost", 6600 are :init's arguments
return setmetatable(mpc, {
	__call = function(t, ...)
		local object = setmetatable({}, {
			__index = function(t, k)
				if mpc[k] then
					return mpc[k]
				elseif k:sub(1, 1) ~= "_" then
					return function(self, ...)
						local success, lines = mpc.command(self, k, ...)
						return success, not success and lines[1] or nil, lines
					end
				end
			end
		})
		object:init(...)
		return object
	end
})
