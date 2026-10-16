# lua-MessagePack 0.5.4 (vendored, unmodified)

The network's binary format (runtime/net.lua): MessagePack, by François
Perrad's pure Lua implementation (MIT/X11, see COPYRIGHT).

- Source: <https://framagit.org/fperrad/lua-MessagePack> release 0.5.4
  (2023-11-20), from luarocks `lua-messagepack-0.5.4-1.src.rock`; its
  tarball's md5 `49a8609804ef615a6445f60be553e1af` matches the rockspec.
- `MessagePack.lua` is upstream's `src/MessagePack.lua` (Lua 5.1, LuaJIT);
  `MessagePack53.lua` is upstream's `src5.3/MessagePack.lua` (Lua 5.3+,
  `string.pack`: the editor's Lua 5.5). Byte for byte; only the second
  file's name changed. net.lua picks the one for the running Lua.
- Upstream's own test suite (lua-TestAssertion 0.2.1 + lua-TestMore 0.3.7)
  passes on LuaJIT 2.1 (src), Lua 5.4 and Lua 5.5 (src5.3): the spec test
  (621 checks), exceptions, edges, coverage, fuzzing, multiples, closures,
  custom unpack (2026-10-15).

Don't edit these files: update them from a new upstream release instead,
and run its test suite again.
