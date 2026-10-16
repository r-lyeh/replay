// editor/udp.h - UDP sockets for the world's Lua (runtime/net.lua: net.udp).
// Compiled in editor/editor.c's unit (it has <windows.h>; winsock2.h goes first,
// there); play.c registers it in the world VM: editor_udp_register(L).
//
//   local s, err = udp.open(port)       -- bound to every interface (0: any free port); non-blocking
//   s:send(host, port, bytes)            -- -> true | nil, err (host: "1.2.3.4", "::1", "[::1]" or a name)
//   bytes, host, port = s:recv()         -- nil when nothing is waiting
//   s:port()                             -- the port it's bound to
//   s:close()
//   udp.resolve(name) -> "1.2.3.4" / "2001:db8::1" | nil, err;  udp.localip() ->
//   this computer's address on its network (nil: none);  udp.clock() ->
//   seconds (monotonic);  udp.sleep(seconds)
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
  if (!udp_started()) { lua_pushnil(L); lua_pushstring(L, "no network (WSAStartup)"); return 2; }
  int family = AF_INET6;                           // dual stack first: IPv6, IPv4 mapped in
  udp_sock s = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
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
static int udp_clock(lua_State *L) { lua_pushnumber(L, (double)SDL_GetTicksNS() / 1e9); return 1; }
static int udp_sleep(lua_State *L) { double s = luaL_checknumber(L, 1); if (s > 0) SDL_DelayNS((Uint64)(s * 1e9)); return 0; }

void editor_udp_register(lua_State *L) {
  static const luaL_Reg methods[] = {
    { "send", udp_send }, { "recv", udp_recv }, { "port", udp_port }, { "close", udp_close }, { NULL, NULL }
  };
  luaL_newmetatable(L, UDP_META);
  lua_newtable(L);
  luaL_setfuncs(L, methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, udp_close);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  static const luaL_Reg fns[] = {
    { "open", udp_open }, { "resolve", udp_resolve }, { "localip", udp_localip }, { "clock", udp_clock }, { "sleep", udp_sleep }, { NULL, NULL }
  };
  lua_newtable(L);
  luaL_setfuncs(L, fns, 0);
  lua_setglobal(L, "udp");
}
