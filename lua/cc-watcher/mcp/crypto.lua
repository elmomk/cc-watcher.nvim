-- crypto.lua — Pure Lua SHA-1 + base64 for WebSocket handshake (RFC 6455)
-- Uses LuaJIT bit module for performance.

local M = {}

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

--- Base64 encode a raw byte string
---@param data string raw bytes
---@return string base64-encoded string
function M.base64_encode(data)
	local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local out = {}
	local len = #data
	for i = 1, len, 3 do
		local a = data:byte(i)
		local b = i + 1 <= len and data:byte(i + 1) or 0
		local c = i + 2 <= len and data:byte(i + 2) or 0
		local n = lshift(a, 16) + lshift(b, 8) + c
		out[#out + 1] = b64:sub(rshift(n, 18) + 1, rshift(n, 18) + 1)
		out[#out + 1] = b64:sub(band(rshift(n, 12), 63) + 1, band(rshift(n, 12), 63) + 1)
		out[#out + 1] = i + 1 <= len and b64:sub(band(rshift(n, 6), 63) + 1, band(rshift(n, 6), 63) + 1) or "="
		out[#out + 1] = i + 2 <= len and b64:sub(band(n, 63) + 1, band(n, 63) + 1) or "="
	end
	return table.concat(out)
end

--- SHA-1 hash (RFC 3174)
---@param msg string raw bytes
---@return string 20-byte raw hash
function M.sha1(msg)
	local len = #msg
	local bit_len = len * 8

	-- Pre-processing: pad message
	local chunks = {}
	for i = 1, len do
		chunks[#chunks + 1] = msg:byte(i)
	end
	chunks[#chunks + 1] = 0x80

	-- Pad to 56 mod 64
	while (#chunks % 64) ~= 56 do
		chunks[#chunks + 1] = 0
	end

	-- Append original length as 64-bit big-endian
	for i = 56, 0, -8 do
		-- bit_len fits in 32 bits for our use case (< 512MB messages)
		if i >= 32 then
			chunks[#chunks + 1] = 0
		else
			chunks[#chunks + 1] = band(rshift(bit_len, i), 0xFF)
		end
	end

	-- Initialize hash values
	local h0 = 0x67452301
	local h1 = 0xEFCDAB89
	local h2 = 0x98BADCFE
	local h3 = 0x10325476
	local h4 = 0xC3D2E1F0

	-- Process each 512-bit (64-byte) chunk
	local w = {}
	for chunk_start = 1, #chunks, 64 do
		-- Break chunk into sixteen 32-bit big-endian words
		for i = 0, 15 do
			local base = chunk_start + i * 4
			w[i] = bor(
				lshift(chunks[base], 24),
				lshift(chunks[base + 1], 16),
				lshift(chunks[base + 2], 8),
				chunks[base + 3]
			)
		end

		-- Extend to 80 words
		for i = 16, 79 do
			w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
		end

		local a, b, c, d, e = h0, h1, h2, h3, h4

		for i = 0, 79 do
			local f, k
			if i <= 19 then
				f = bor(band(b, c), band(bnot(b), d))
				k = 0x5A827999
			elseif i <= 39 then
				f = bxor(b, c, d)
				k = 0x6ED9EBA1
			elseif i <= 59 then
				f = bor(band(b, c), band(b, d), band(c, d))
				k = 0x8F1BBCDC
			else
				f = bxor(b, c, d)
				k = 0xCA62C1D6
			end

			local temp = rol(a, 5) + f + e + k + w[i]
			e = d
			d = c
			c = rol(b, 30)
			b = a
			a = temp
		end

		h0 = h0 + a
		h1 = h1 + b
		h2 = h2 + c
		h3 = h3 + d
		h4 = h4 + e
	end

	-- Produce the 20-byte hash
	local function u32_to_bytes(n)
		return string.char(
			band(rshift(n, 24), 0xFF),
			band(rshift(n, 16), 0xFF),
			band(rshift(n, 8), 0xFF),
			band(n, 0xFF)
		)
	end

	return u32_to_bytes(h0) .. u32_to_bytes(h1) .. u32_to_bytes(h2)
		.. u32_to_bytes(h3) .. u32_to_bytes(h4)
end

--- Compute WebSocket accept key per RFC 6455
---@param client_key string the Sec-WebSocket-Key header value
---@return string base64-encoded accept key
function M.ws_accept_key(client_key)
	local magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	return M.base64_encode(M.sha1(client_key .. magic))
end

return M
