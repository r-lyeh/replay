// editor/sound.h - sounds for the game (the world VM): host_sound(pcm [, rate
// [, volume]]) plays a string of 16-bit little-endian mono PCM, mixed with
// what else plays (eight voices: SDL3 mixes the streams bound to one device;
// a ninth sound takes the voice that has the least left). -> true | nil, err.
// host_sound_stop() silences them all. runtime/sound.lua (w:sound) renders the
// game's .sfx files with runtime/sfxr.lua and calls this. Part of replay.c.
#define SND_VOICES 8
static SDL_AudioDeviceID snd_dev;
static SDL_AudioStream *snd_voice[SND_VOICES];
static int snd_rate;

static bool snd_open(int rate) {
  if (snd_dev && snd_rate == rate) return true;
  if (!SDL_WasInit(SDL_INIT_AUDIO) && !SDL_InitSubSystem(SDL_INIT_AUDIO)) return false;
  if (!snd_dev) {
    snd_dev = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, NULL);
    if (!snd_dev) return false;
  }
  SDL_AudioSpec spec = { SDL_AUDIO_S16LE, 1, rate };
  for (int i = 0; i < SND_VOICES; i++) {
    if (snd_voice[i]) SDL_DestroyAudioStream(snd_voice[i]);
    snd_voice[i] = SDL_CreateAudioStream(&spec, NULL);
    if (!snd_voice[i] || !SDL_BindAudioStream(snd_dev, snd_voice[i])) return false;
  }
  snd_rate = rate;
  return true;
}
static int l_sound(lua_State *L) {
  size_t n = 0;
  const char *pcm = luaL_checklstring(L, 1, &n);
  int rate = (int)luaL_optinteger(L, 2, 44100);
  float vol = (float)luaL_optnumber(L, 3, 1.0);
  if (!snd_open(rate)) { lua_pushnil(L); lua_pushstring(L, SDL_GetError()); return 2; }
  int best = 0, least = 0x7fffffff;                // (a free voice, else the one nearly done)
  for (int i = 0; i < SND_VOICES; i++) {
    int q = SDL_GetAudioStreamQueued(snd_voice[i]);
    if (q < least) { least = q; best = i; }
  }
  SDL_AudioStream *s = snd_voice[best];
  SDL_ClearAudioStream(s);
  SDL_SetAudioStreamGain(s, vol < 0 ? 0 : vol);
  if (n >= 2 && !SDL_PutAudioStreamData(s, pcm, (int)(n & ~(size_t)1))) { lua_pushnil(L); lua_pushstring(L, SDL_GetError()); return 2; }
  lua_pushboolean(L, 1);
  return 1;
}
static int l_sound_stop(lua_State *L) {
  (void)L;
  for (int i = 0; i < SND_VOICES; i++) if (snd_voice[i]) SDL_ClearAudioStream(snd_voice[i]);
  return 0;
}
static void sound_register(lua_State *L) {
  lua_register(L, "host_sound", l_sound);
  lua_register(L, "host_sound_stop", l_sound_stop);
}
