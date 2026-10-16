// editor/hostfs.h - hostfs: directory functions for fs.lua, backed by SDL3.
// Part of replay.c: included once, in order, from there (one compilation unit).

// ---------------------------------------------------------------------------
// hostfs: directory functions for fs.lua, backed by SDL3
// ---------------------------------------------------------------------------

typedef struct { lua_State *L; int n; } ListCtx;

static SDL_EnumerationResult SDLCALL list_cb(void *ud, const char *dirname, const char *fname) {
  ListCtx *ctx = (ListCtx *)ud;
  char full[4096];
  SDL_PathInfo info;
  SDL_snprintf(full, sizeof full, "%s%s", dirname, fname);
  bool isdir = SDL_GetPathInfo(full, &info) && info.type == SDL_PATHTYPE_DIRECTORY;
  lua_newtable(ctx->L);
  lua_pushstring(ctx->L, fname);
  lua_setfield(ctx->L, -2, "name");
  lua_pushboolean(ctx->L, isdir);
  lua_setfield(ctx->L, -2, "dir");
  if (!isdir) {                                    // (a file: when it changed, how big: a reader can skip it if neither did)
    lua_pushinteger(ctx->L, (lua_Integer)info.modify_time);
    lua_setfield(ctx->L, -2, "mtime");
    lua_pushinteger(ctx->L, (lua_Integer)info.size);
    lua_setfield(ctx->L, -2, "size");
  }
  lua_rawseti(ctx->L, -2, ++ctx->n);
  return SDL_ENUM_CONTINUE;
}

static int hostfs_list(lua_State *L) {
  const char *dir = luaL_checkstring(L, 1);
  ListCtx ctx = { L, 0 };
  lua_newtable(L);
  SDL_PathInfo info;
  if (SDL_GetPathInfo(dir, &info) && info.type == SDL_PATHTYPE_DIRECTORY)
    SDL_EnumerateDirectory(dir, list_cb, &ctx);
  return 1;
}

static int hostfs_isdir(lua_State *L) {
  SDL_PathInfo info;
  lua_pushboolean(L, SDL_GetPathInfo(luaL_checkstring(L, 1), &info) &&
                     info.type == SDL_PATHTYPE_DIRECTORY);
  return 1;
}

static int hostfs_mkdir(lua_State *L) {
  lua_pushboolean(L, SDL_CreateDirectory(luaL_checkstring(L, 1)));   // creates parents
  return 1;
}

static int hostfs_remove(lua_State *L) {                            // file or empty dir
  lua_pushboolean(L, SDL_RemovePath(luaL_checkstring(L, 1)));
  return 1;
}

static int hostfs_rename(lua_State *L) {                            // a file or a folder: moved / renamed
  lua_pushboolean(L, SDL_RenamePath(luaL_checkstring(L, 1), luaL_checkstring(L, 2)));
  return 1;
}

static void register_hostfs(lua_State *L) {
  static const luaL_Reg fns[] = {
    { "list", hostfs_list }, { "isdir", hostfs_isdir },
    { "mkdir", hostfs_mkdir }, { "remove", hostfs_remove }, { "rename", hostfs_rename }, { NULL, NULL }
  };
  lua_newtable(L);
  for (const luaL_Reg *f = fns; f->name; f++) {
    lua_pushcfunction(L, f->func);
    lua_setfield(L, -2, f->name);
  }
  lua_setglobal(L, "hostfs");
}
