// editor/udp.h - UDP sockets for the world's Lua (runtime/net.lua: net.udp).
// Compiled in editor/editor.c's unit (it has <windows.h>; winsock2.h goes first,
// there); replay.c registers it in the world VM: editor_udp_register(L).
//
//   local s, err = udp.open(port)       -- bound to every interface (0: any free port); non-blocking
//   udp.open(port, "4")                  -- IPv4 only (multicast discovery: UPnP's SSDP; broadcast: the LAN lobby)
//   s:broadcast()                        -- may send to 255.255.255.255 / a subnet's .255 (SO_BROADCAST)
//   s:send(host, port, bytes)            -- -> true | nil, err (host: "1.2.3.4", "::1", "[::1]" or a name)
//   bytes, host, port = s:recv()         -- nil when nothing is waiting
//   s:port()                             -- the port it's bound to
//   s:close()
//   udp.resolve(name) -> "1.2.3.4" / "2001:db8::1" | nil, err;  udp.localip() ->
//   this computer's address on its network (nil: none);  udp.clock() ->
//   seconds (monotonic);  udp.sleep(seconds);  udp.gateway() -> the router's
//   IPv4 address (the default route's next hop; nil: unknown)
//
// TCP, IPv4, non-blocking (runtime/portmap.lua talks to routers with it: UPnP):
//   local c = tcp.connect(host, port)    -- -> a connection (connecting) | nil, err
//   c:status() -> "connecting" | "open" | "failed"
//   c:send(bytes) -> bytes taken (0: later) | nil, err
//   c:recv() -> bytes | nil, "wait" | nil, "closed"
//   c:close()
//   local l = tcp.listen(port)           -- (tests: a pretend router) l:accept() -> c | nil; l:port(); l:close()
// IPv4 and IPv6 alike: the socket is IPv6 with IPv4 mapped in (dual stack:
// one socket talks to both; IPv4 addresses show as "1.2.3.4"), or plain
// IPv4 where the system has no IPv6. Datagrams up to 64 KB (net.udp cuts
// messages smaller).
#ifdef _WIN32
#pragma comment(lib, "ws2_32.lib")
typedef SOCKET udp_sock;
#define UDP_BAD INVALID_SOCKET
#define udp_closesocket closesocket
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/select.h>
#include <stdio.h>
typedef int udp_sock;
#define UDP_BAD (-1)
#define udp_closesocket close
#endif

#define UDP_META "replay.udp"
typedef struct { udp_sock s; int family; } UdpBox;   // family: AF_INET6 (dual stack) or AF_INET

static bool udp_started(void) {
#ifdef _WIN32
  static bool ok = false;
  if (!ok) { WSADATA wd; ok = WSAStartup(MAKEWORD(2, 2), &wd) == 0; }
  return ok;
#else
  return true;
#endif
}

// "1.2.3.4", "::1", "[::1]" or a name -> an address a socket of `family` can send to
// (IPv4 for an IPv6 socket: mapped, ::ffff:1.2.3.4)
static bool udp_addr(const char *host, int port, int family, struct sockaddr_storage *out, socklen_t *len) {
  char h[256];
  SDL_strlcpy(h, host, sizeof h);
  size_t n = strlen(h);
  if (n >= 2 && h[0] == '[' && h[n - 1] == ']') { memmove(h, h + 1, n - 2); h[n - 2] = 0; }
  struct addrinfo hints, *res = NULL;
  SDL_zero(hints);
  hints.ai_family = family == AF_INET ? AF_INET : AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  if (getaddrinfo(h, NULL, &hints, &res) != 0 || !res) return false;
  bool ok = false;
  SDL_zerop(out);
  for (struct addrinfo *r = res; r && !ok; r = r->ai_next) {
    if (family == AF_INET && r->ai_family == AF_INET) {
      struct sockaddr_in *a = (struct sockaddr_in *)out;
      *a = *(struct sockaddr_in *)r->ai_addr;
      a->sin_port = htons((unsigned short)port);
      *len = sizeof *a; ok = true;
    } else if (family == AF_INET6) {
      struct sockaddr_in6 *a = (struct sockaddr_in6 *)out;
      a->sin6_family = AF_INET6;
      a->sin6_port = htons((unsigned short)port);
      if (r->ai_family == AF_INET6) { a->sin6_addr = ((struct sockaddr_in6 *)r->ai_addr)->sin6_addr; a->sin6_scope_id = ((struct sockaddr_in6 *)r->ai_addr)->sin6_scope_id; ok = true; }
      else if (r->ai_family == AF_INET) {          // (IPv4 through the IPv6 socket: ::ffff:a.b.c.d)
        unsigned char *b = (unsigned char *)&a->sin6_addr;
        memset(b, 0, 10); b[10] = 0xff; b[11] = 0xff;
        memcpy(b + 12, &((struct sockaddr_in *)r->ai_addr)->sin_addr, 4);
        ok = true;
      }
      *len = sizeof *a;
    }
  }
  freeaddrinfo(res);
  return ok;
}
static void udp_name(const struct sockaddr_storage *a, char *ip, size_t n, int *port) {   // -> "1.2.3.4" (IPv4, mapped too) / "2001:db8::1"
  if (a->ss_family == AF_INET) {
    const struct sockaddr_in *v4 = (const struct sockaddr_in *)a;
    inet_ntop(AF_INET, &v4->sin_addr, ip, (socklen_t)n);
    if (port) *port = ntohs(v4->sin_port);
    return;
  }
  const struct sockaddr_in6 *v6 = (const struct sockaddr_in6 *)a;
  const unsigned char *b = (const unsigned char *)&v6->sin6_addr;
  static const unsigned char mapped[12] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
  if (!memcmp(b, mapped, 12)) inet_ntop(AF_INET, b + 12, ip, (socklen_t)n);
  else inet_ntop(AF_INET6, &v6->sin6_addr, ip, (socklen_t)n);
  if (port) *port = ntohs(v6->sin6_port);
}

static void udp_nonblock(udp_sock s) {
#ifdef _WIN32
  u_long nb = 1;
  ioctlsocket(s, FIONBIO, &nb);
  BOOL no = FALSE;                                 // (a port that went away doesn't break recv: WSAECONNRESET off)
  DWORD got = 0;
  WSAIoctl(s, _WSAIOW(IOC_VENDOR, 12), &no, sizeof no, NULL, 0, &got, NULL, NULL);
#else
  fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
}

static int udp_open(lua_State *L) {
  int port = (int)luaL_optinteger(L, 1, 0);
  bool v4 = lua_isstring(L, 2) && !strcmp(lua_tostring(L, 2), "4");
  if (!udp_started()) { lua_pushnil(L); lua_pushstring(L, "no network (WSAStartup)"); return 2; }
  int family = AF_INET6;                           // dual stack first: IPv6, IPv4 mapped in
  udp_sock s = v4 ? UDP_BAD : socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
  if (s != UDP_BAD) {
    int off = 0;
    setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, (const char *)&off, sizeof off);
    struct sockaddr_in6 a;
    SDL_zero(a);
    a.sin6_family = AF_INET6;
    a.sin6_addr = in6addr_any;
    a.sin6_port = htons((unsigned short)port);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0) { udp_closesocket(s); s = UDP_BAD; }
  }
  if (s == UDP_BAD) {                              // (no IPv6 here, or that port only free for IPv4: IPv4)
    family = AF_INET;
    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == UDP_BAD) { lua_pushnil(L); lua_pushstring(L, "can't make a socket"); return 2; }
    struct sockaddr_in a;
    SDL_zero(a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((unsigned short)port);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0) {
      udp_closesocket(s);
      lua_pushnil(L); lua_pushfstring(L, "port %d is taken (or not allowed)", port);
      return 2;
    }
  }
  udp_nonblock(s);
  UdpBox *b = lua_newuserdata(L, sizeof *b);
  b->s = s;
  b->family = family;
  luaL_setmetatable(L, UDP_META);
  return 1;
}

static UdpBox *udp_check(lua_State *L) {
  UdpBox *b = luaL_checkudata(L, 1, UDP_META);
  if (b->s == UDP_BAD) luaL_error(L, "udp: closed");
  return b;
}

static int udp_send(lua_State *L) {
  UdpBox *b = udp_check(L);
  const char *host = luaL_checkstring(L, 2);
  int port = (int)luaL_checkinteger(L, 3);
  size_t n = 0;
  const char *data = luaL_checklstring(L, 4, &n);
  struct sockaddr_storage a;
  socklen_t al = 0;
  if (!udp_addr(host, port, b->family, &a, &al)) { lua_pushnil(L); lua_pushfstring(L, "no such host: %s", host); return 2; }
  if (sendto(b->s, data, (int)n, 0, (struct sockaddr *)&a, al) < 0) { lua_pushnil(L); lua_pushstring(L, "send failed"); return 2; }
  lua_pushboolean(L, 1);
  return 1;
}

static int udp_recv(lua_State *L) {
  UdpBox *b = udp_check(L);
  static char buf[65536];
  struct sockaddr_storage a;
  socklen_t al = sizeof a;
  int n = (int)recvfrom(b->s, buf, sizeof buf, 0, (struct sockaddr *)&a, &al);
  if (n < 0) return 0;                             // (nothing waiting, or an error: nothing)
  char ip[64];
  int port = 0;
  udp_name(&a, ip, sizeof ip, &port);
  lua_pushlstring(L, buf, (size_t)n);
  lua_pushstring(L, ip);
  lua_pushinteger(L, port);
  return 3;
}

static int udp_broadcast(lua_State *L) {
  UdpBox *b = udp_check(L);
  int on = 1;
  lua_pushboolean(L, setsockopt(b->s, SOL_SOCKET, SO_BROADCAST, (const char *)&on, sizeof on) == 0);
  return 1;
}

static int udp_port(lua_State *L) {
  UdpBox *b = udp_check(L);
  struct sockaddr_storage a;
  socklen_t al = sizeof a;
  if (getsockname(b->s, (struct sockaddr *)&a, &al) != 0) return 0;
  int port = 0;
  char ip[64];
  udp_name(&a, ip, sizeof ip, &port);
  lua_pushinteger(L, port);
  return 1;
}

static int udp_close(lua_State *L) {
  UdpBox *b = luaL_checkudata(L, 1, UDP_META);
  if (b->s != UDP_BAD) { udp_closesocket(b->s); b->s = UDP_BAD; }
  return 0;
}

static int udp_resolve(lua_State *L) {
  struct sockaddr_storage a;
  socklen_t al = 0;
  if (!udp_started() || !udp_addr(luaL_checkstring(L, 1), 0, AF_INET6, &a, &al)) { lua_pushnil(L); lua_pushstring(L, "no such host"); return 2; }
  char ip[64];
  udp_name(&a, ip, sizeof ip, NULL);
  lua_pushstring(L, ip);
  return 1;
}

static int udp_localip(lua_State *L) {             // this computer's address on its network (the way out; nothing is sent): IPv4, else IPv6
  if (!udp_started()) return 0;
  static const struct { int family; const char *to; } tries[] = { { AF_INET, "8.8.8.8" }, { AF_INET6, "2001:4860:4860::8888" } };
  for (int i = 0; i < 2; i++) {
    udp_sock s = socket(tries[i].family, SOCK_DGRAM, IPPROTO_UDP);
    if (s == UDP_BAD) continue;
    struct sockaddr_storage a, me;
    socklen_t al = 0, ml = sizeof me;
    int ok = udp_addr(tries[i].to, 53, tries[i].family, &a, &al) && connect(s, (struct sockaddr *)&a, al) == 0
             && getsockname(s, (struct sockaddr *)&me, &ml) == 0;
    udp_closesocket(s);
    if (!ok) continue;
    char ip[64];
    udp_name(&me, ip, sizeof ip, NULL);
    lua_pushstring(L, ip);
    return 1;
  }
  return 0;
}
// the router: the default route's next hop (IPv4)
static int udp_gateway(lua_State *L) {
#ifdef _WIN32
  typedef DWORD (WINAPI *best_fn)(DWORD, DWORD, PMIB_IPFORWARDROW);   // (iphlpapi.dll, loaded when asked: no link change)
  static best_fn best = NULL;
  static bool tried = false;
  if (!tried) { tried = true; HMODULE m = LoadLibraryA("iphlpapi.dll"); if (m) best = (best_fn)(void *)GetProcAddress(m, "GetBestRoute"); }
  if (!best) return 0;
  MIB_IPFORWARDROW row;
  SDL_zero(row);
  if (best(inet_addr("8.8.8.8"), 0, &row) != NO_ERROR || row.dwForwardNextHop == 0) return 0;
  struct in_addr a; a.s_addr = row.dwForwardNextHop;
  char ip[32]; inet_ntop(AF_INET, &a, ip, sizeof ip);
  lua_pushstring(L, ip);
  return 1;
#else
  FILE *f = fopen("/proc/net/route", "r");        // (Linux; elsewhere: nil, the caller guesses)
  if (!f) return 0;
  char line[256];
  unsigned dest, gw, flags;
  char ifn[64];
  bool found = false;
  struct in_addr a;
  while (fgets(line, sizeof line, f)) {
    if (sscanf(line, "%63s %x %x %x", ifn, &dest, &gw, &flags) == 4 && dest == 0 && gw != 0 && (flags & 2)) { a.s_addr = gw; found = true; break; }
  }
  fclose(f);
  if (!found) return 0;
  char ip[32]; inet_ntop(AF_INET, &a, ip, sizeof ip);
  lua_pushstring(L, ip);
  return 1;
#endif
}

// udp.random(n) -> n bytes from the system's secure source (a key's seed:
// runtime/players.lua): RtlGenRandom (advapi32's SystemFunction036) on
// Windows, getentropy / /dev/urandom elsewhere; nil when there's none
static int udp_random(lua_State *L) {
  int n = (int)luaL_checkinteger(L, 1);
  if (n < 1 || n > 256) return 0;
  unsigned char buf[256];
#ifdef _WIN32
  typedef BOOLEAN (WINAPI *gen_fn)(PVOID, ULONG);
  static gen_fn gen = NULL;
  static bool tried = false;
  if (!tried) { tried = true; HMODULE m = LoadLibraryA("advapi32.dll"); if (m) gen = (gen_fn)(void *)GetProcAddress(m, "SystemFunction036"); }
  if (!gen || !gen(buf, (ULONG)n)) return 0;
#else
  FILE *f = fopen("/dev/urandom", "rb");
  if (!f) return 0;
  size_t got = fread(buf, 1, (size_t)n, f);
  fclose(f);
  if ((int)got != n) return 0;
#endif
  lua_pushlstring(L, (const char *)buf, (size_t)n);
  return 1;
}

// TCP (IPv4, non-blocking)
#define TCP_META "replay.tcp"
#define TCP_LMETA "replay.tcp.listen"
typedef struct { udp_sock s; int state; } TcpBox;   // state: 0 connecting, 1 open, 2 failed, 3 closed (by the other side)
static bool tcp_would_block(void) {
#ifdef _WIN32
  int e = WSAGetLastError(); return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS || e == WSAEALREADY;
#else
  return errno == EWOULDBLOCK || errno == EAGAIN || errno == EINPROGRESS;
#endif
}
static void tcp_nonblock(udp_sock s) {
#ifdef _WIN32
  u_long nb = 1; ioctlsocket(s, FIONBIO, &nb);
#else
  fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
}
static TcpBox *tcp_push(lua_State *L, udp_sock s, int state) {
  TcpBox *b = lua_newuserdata(L, sizeof *b);
  b->s = s; b->state = state;
  luaL_setmetatable(L, TCP_META);
  return b;
}
static int tcp_connect(lua_State *L) {
  const char *host = luaL_checkstring(L, 1);
  int port = (int)luaL_checkinteger(L, 2);
  struct sockaddr_storage a;
  socklen_t al = 0;
  if (!udp_started() || !udp_addr(host, port, AF_INET, &a, &al)) { lua_pushnil(L); lua_pushfstring(L, "no such host: %s", host); return 2; }
  udp_sock s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == UDP_BAD) { lua_pushnil(L); lua_pushstring(L, "can't make a socket"); return 2; }
  tcp_nonblock(s);
  int r = connect(s, (struct sockaddr *)&a, al);
  if (r != 0 && !tcp_would_block()) { udp_closesocket(s); lua_pushnil(L); lua_pushstring(L, "can't connect"); return 2; }
  tcp_push(L, s, r == 0 ? 1 : 0);
  return 1;
}
static TcpBox *tcp_check(lua_State *L) { return luaL_checkudata(L, 1, TCP_META); }
static void tcp_poll_connect(TcpBox *b) {
  if (b->state != 0 || b->s == UDP_BAD) return;
  fd_set w, x;
  FD_ZERO(&w); FD_ZERO(&x);
  FD_SET(b->s, &w); FD_SET(b->s, &x);
  struct timeval tv = { 0, 0 };
  if (select((int)b->s + 1, NULL, &w, &x, &tv) <= 0) return;
  int err = 0;
  socklen_t el = sizeof err;
  getsockopt(b->s, SOL_SOCKET, SO_ERROR, (char *)&err, &el);
  b->state = (FD_ISSET(b->s, &x) || err != 0) ? 2 : 1;
}
static int tcp_status(lua_State *L) {
  TcpBox *b = tcp_check(L);
  tcp_poll_connect(b);
  static const char *names[] = { "connecting", "open", "failed", "open" };
  lua_pushstring(L, b->s == UDP_BAD ? "failed" : names[b->state]);
  return 1;
}
static int tcp_send(lua_State *L) {
  TcpBox *b = tcp_check(L);
  size_t n = 0;
  const char *data = luaL_checklstring(L, 2, &n);
  tcp_poll_connect(b);
  if (b->s == UDP_BAD || b->state == 2) { lua_pushnil(L); lua_pushstring(L, "not connected"); return 2; }
  if (b->state == 0 || n == 0) { lua_pushinteger(L, 0); return 1; }
  int r = (int)send(b->s, data, (int)n, 0);
  if (r < 0) { if (tcp_would_block()) { lua_pushinteger(L, 0); return 1; } lua_pushnil(L); lua_pushstring(L, "send failed"); return 2; }
  lua_pushinteger(L, r);
  return 1;
}
static int tcp_recv(lua_State *L) {
  TcpBox *b = tcp_check(L);
  tcp_poll_connect(b);
  if (b->s == UDP_BAD || b->state == 2 || b->state == 3) { lua_pushnil(L); lua_pushstring(L, "closed"); return 2; }
  if (b->state == 0) { lua_pushnil(L); lua_pushstring(L, "wait"); return 2; }
  static char buf[16384];
  int r = (int)recv(b->s, buf, sizeof buf, 0);
  if (r > 0) { lua_pushlstring(L, buf, (size_t)r); return 1; }
  if (r < 0 && tcp_would_block()) { lua_pushnil(L); lua_pushstring(L, "wait"); return 2; }
  b->state = 3;
  lua_pushnil(L); lua_pushstring(L, "closed");
  return 2;
}
static int tcp_close(lua_State *L) {
  TcpBox *b = tcp_check(L);
  if (b->s != UDP_BAD) { udp_closesocket(b->s); b->s = UDP_BAD; }
  return 0;
}
static int tcp_listen(lua_State *L) {
  int port = (int)luaL_optinteger(L, 1, 0);
  if (!udp_started()) { lua_pushnil(L); lua_pushstring(L, "no network"); return 2; }
  udp_sock s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == UDP_BAD) { lua_pushnil(L); lua_pushstring(L, "can't make a socket"); return 2; }
  int on = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&on, sizeof on);
  struct sockaddr_in a;
  SDL_zero(a);
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  a.sin_port = htons((unsigned short)port);
  if (bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 8) != 0) {
    udp_closesocket(s); lua_pushnil(L); lua_pushfstring(L, "port %d is taken (or not allowed)", port); return 2;
  }
  tcp_nonblock(s);
  UdpBox *b = lua_newuserdata(L, sizeof *b);
  b->s = s; b->family = AF_INET;
  luaL_setmetatable(L, TCP_LMETA);
  return 1;
}
static int tcp_accept(lua_State *L) {
  UdpBox *l = luaL_checkudata(L, 1, TCP_LMETA);
  if (l->s == UDP_BAD) return 0;
  udp_sock c = accept(l->s, NULL, NULL);
  if (c == UDP_BAD) return 0;
  tcp_nonblock(c);
  tcp_push(L, c, 1);
  return 1;
}
static int tcp_lport(lua_State *L) {
  UdpBox *l = luaL_checkudata(L, 1, TCP_LMETA);
  struct sockaddr_storage a;
  socklen_t al = sizeof a;
  if (l->s == UDP_BAD || getsockname(l->s, (struct sockaddr *)&a, &al) != 0) return 0;
  int port = 0; char ip[64];
  udp_name(&a, ip, sizeof ip, &port);
  lua_pushinteger(L, port);
  return 1;
}
static int tcp_lclose(lua_State *L) {
  UdpBox *l = luaL_checkudata(L, 1, TCP_LMETA);
  if (l->s != UDP_BAD) { udp_closesocket(l->s); l->s = UDP_BAD; }
  return 0;
}

static int udp_clock(lua_State *L) { lua_pushnumber(L, (double)SDL_GetTicksNS() / 1e9); return 1; }
static int udp_sleep(lua_State *L) { double s = luaL_checknumber(L, 1); if (s > 0) SDL_DelayNS((Uint64)(s * 1e9)); return 0; }

void editor_udp_register(lua_State *L) {
  static const luaL_Reg methods[] = {
    { "send", udp_send }, { "recv", udp_recv }, { "port", udp_port }, { "close", udp_close }, { "broadcast", udp_broadcast }, { NULL, NULL }
  };
  luaL_newmetatable(L, UDP_META);
  lua_newtable(L);
  luaL_setfuncs(L, methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, udp_close);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  static const luaL_Reg fns[] = {
    { "open", udp_open }, { "resolve", udp_resolve }, { "localip", udp_localip }, { "clock", udp_clock }, { "sleep", udp_sleep },
    { "gateway", udp_gateway }, { "random", udp_random }, { NULL, NULL }
  };
  lua_newtable(L);
  luaL_setfuncs(L, fns, 0);
  lua_setglobal(L, "udp");
  static const luaL_Reg tmethods[] = {
    { "status", tcp_status }, { "send", tcp_send }, { "recv", tcp_recv }, { "close", tcp_close }, { NULL, NULL }
  };
  luaL_newmetatable(L, TCP_META);
  lua_newtable(L);
  luaL_setfuncs(L, tmethods, 0);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, tcp_close);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  static const luaL_Reg lmethods[] = { { "accept", tcp_accept }, { "port", tcp_lport }, { "close", tcp_lclose }, { NULL, NULL } };
  luaL_newmetatable(L, TCP_LMETA);
  lua_newtable(L);
  luaL_setfuncs(L, lmethods, 0);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, tcp_lclose);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  static const luaL_Reg tfns[] = { { "connect", tcp_connect }, { "listen", tcp_listen }, { NULL, NULL } };
  lua_newtable(L);
  luaL_setfuncs(L, tfns, 0);
  lua_setglobal(L, "tcp");
}
