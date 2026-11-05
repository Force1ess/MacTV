// Diagnostic only: captures our generated chirp, replacing hardware audio output.
// Output: repeated native-endian {int64_t PTS, uint32_t frames, int16_t PCM[frames]}.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>

static FILE *output;
static unsigned total;
static int64_t (*read_clock)(void *);
static void wait_player(void *player, unsigned milliseconds) {
  if (!getenv("MTV_OWNED_AUDIO_CLOCK_STREAM")) {
    struct timespec wait = {milliseconds / 1000, (long)(milliseconds % 1000) * 1000000}; nanosleep(&wait, NULL); return;
  }
  for (unsigned elapsed = 0; elapsed < milliseconds; elapsed += 100) {
    fprintf(stdout, "MTV_CLOCK %lld\n", (long long)read_clock(player)); fflush(stdout);
    struct timespec wait = {0, 100000000}; nanosleep(&wait, NULL);
  }
}
typedef struct track_description {
  int id;
  char *name;
  struct track_description *next;
} track_description;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static void flush(void *opaque, int64_t pts) {
  (void)opaque;
  pthread_mutex_lock(&lock);
  uint32_t marker = 0;
  fwrite(&pts, sizeof(pts), 1, output); fwrite(&marker, sizeof(marker), 1, output);
  pthread_mutex_unlock(&lock);
}
static void capture(void *opaque, const void *pcm, unsigned count, int64_t pts) {
  (void)opaque;
  pthread_mutex_lock(&lock);
  if (count <= 48000 && total + count <= 960000) {
    uint32_t frames = count;
    fwrite(&pts, sizeof(pts), 1, output); fwrite(&frames, sizeof(frames), 1, output);
    fwrite(pcm, sizeof(int16_t), count, output); total += count;
  }
  pthread_mutex_unlock(&lock);
}
int main(int argc, char **argv) {
  if (argc != 4 && argc != 5) return 2;
  const char *mode = argc == 5 ? argv[4] : "avformat";
  if (strcmp(mode, "native") && strcmp(mode, "avformat") && strcmp(mode, "avformat-no-stretch")) return 2;
  char expected[4096];
  snprintf(expected, sizeof(expected), "%s/Library/Application Support/MTV/Fixtures/AudioTimeline-v1/Edited-Audio-Timeline45.mp4", getenv("HOME"));
  if (strcmp(argv[1], expected) || (strcmp(argv[2], "0") && strcmp(argv[2], "11.5") && strcmp(argv[2], "23.5"))) return 2;
  output = fopen(argv[3], "wx"); if (!output) return 3;
  const char *root = "/Applications/MacTV.app/Contents/Resources/VLCEngine";
  const char *candidate = getenv("MTV_OWNED_AUDIO_PROBE_ENGINE");
  if (candidate) {
    snprintf(expected, sizeof(expected), "%s/Developer/MTV/.build/vlc-3.0.24-test/VLCEngine", getenv("HOME"));
    if (strcmp(candidate, expected)) return 2;
    root = candidate;
  }
  char path[4096]; snprintf(path, sizeof(path), "%s/lib/libvlccore.dylib", root);
  if (!dlopen(path, RTLD_NOW | RTLD_GLOBAL)) return 4;
  snprintf(path, sizeof(path), "%s/lib/libvlc.dylib", root);
  void *lib = dlopen(path, RTLD_NOW | RTLD_GLOBAL); if (!lib) return 4;
  snprintf(path, sizeof(path), "%s/plugins", root); setenv("VLC_PLUGIN_PATH", path, 1);
#define API(type, name, signature) type (*name) signature = dlsym(lib, "libvlc_" #name); if (!name) return 5
  API(void *, new, (int, const char *const *));
  API(void *, media_new_path, (void *, const char *));
  API(void *, media_player_new, (void *));
  API(void, media_add_option, (void *, const char *));
  API(int, media_slaves_add, (void *, int, unsigned, const char *));
  API(int, audio_get_track, (void *));
  API(int, audio_get_track_count, (void *));
  API(track_description *, audio_get_track_description, (void *));
  API(void, track_description_list_release, (track_description *));
  API(int, media_player_get_state, (void *));
  API(void, media_player_set_time, (void *, int64_t));
  API(int64_t, media_player_get_time, (void *));
  read_clock = media_player_get_time;
  API(void, media_player_set_media, (void *, void *));
  API(void, audio_set_callbacks, (void *, void (*)(void *, const void *, unsigned, int64_t), void *, void *, void (*)(void *, int64_t), void *, void *));
  API(void, audio_set_format, (void *, const char *, unsigned, unsigned));
  API(int, media_player_play, (void *));
  API(void, media_player_stop, (void *));
  API(void, media_player_release, (void *));
  API(void, media_release, (void *));
  API(void, release, (void *));
  const char *options[] = {"--ignore-config", "--quiet", "--vout=dummy", "--aout=dummy", "--no-audio-time-stretch"};
  void *instance = new(!strcmp(mode, "avformat-no-stretch") ? 5 : 4, options); if (!instance) return 6;
  void *player = media_player_new(instance), *media = media_new_path(instance, argv[1]);
  if (!player || !media) return 6;
  char start[64]; snprintf(start, sizeof(start), ":start-time=%s", argv[2]);
  media_add_option(media, start);
  if (strcmp(mode, "native")) media_add_option(media, ":demux=avformat");
  if (getenv("MTV_OWNED_AUDIO_COMPAT")) {
    char owned_audio[4096]; snprintf(owned_audio, sizeof(owned_audio), "file://%s/Developer/MTV/.build/boundary-system-audio.wav", getenv("HOME"));
    const char *origin = getenv("MTV_OWNED_AUDIO_ORIGIN");
    if (origin) {
      unsigned port; char nonce[37]; int consumed = 0;
      if (sscanf(origin, "http://127.0.0.1:%u/%36[0-9a-f-]/audio.wav%n", &port, nonce, &consumed) != 2 ||
          consumed <= 0 || origin[consumed] || !port || port > 65535 || strlen(nonce) != 36) return 2;
    }
    if (media_slaves_add(media, 1, 4, origin ? origin : owned_audio)) return 9;
    media_add_option(media, ":audio-track=1");
  }
  media_player_set_media(player, media);
  audio_set_callbacks(player, capture, NULL, NULL, flush, NULL, NULL);
  audio_set_format(player, "S16N", 48000, 1);
  if (media_player_play(player)) return 7;
  wait_player(player, !strcmp(argv[2], "0") ? 15000 : 4000);
  if (getenv("MTV_OWNED_AUDIO_SEEK_SEQUENCE")) {
    if (strcmp(argv[2], "11.5") || !getenv("MTV_OWNED_AUDIO_ORIGIN")) return 2;
    if (getenv("MTV_OWNED_AUDIO_CLOCK_STREAM")) { fprintf(stdout, "MTV_SEEK 23500\n"); fflush(stdout); }
    media_player_set_time(player, 23500); wait_player(player, 3000);
    if (getenv("MTV_OWNED_AUDIO_CLOCK_STREAM")) { fprintf(stdout, "MTV_SEEK 11500\n"); fflush(stdout); }
    media_player_set_time(player, 11500); wait_player(player, 3000);
  }
  fprintf(stderr, "Selected audio track %d of %d, state %d.\n", audio_get_track(player), audio_get_track_count(player), media_player_get_state(player));
  track_description *tracks = audio_get_track_description(player);
  for (track_description *track = tracks; track; track = track->next)
    fprintf(stderr, "Audio track %d: %s\n", track->id, track->name ? track->name : "(unnamed)");
  if (tracks) track_description_list_release(tracks);
  if (getenv("MTV_OWNED_AUDIO_CLOCK_STREAM")) { fprintf(stdout, "MTV_STOP\n"); fflush(stdout); }
  media_player_stop(player); media_player_release(player); media_release(media); release(instance);
  fclose(output); fprintf(stderr, "Captured %u owned-fixture samples; hardware output replaced.\n", total);
  return total > 48000 ? 0 : 8;
}
