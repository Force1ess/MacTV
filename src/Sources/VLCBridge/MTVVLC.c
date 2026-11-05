// Original dynamic C bridge to the documented libVLC 3 ABI. No decoder code is copied.
#include "MTVVLC.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <math.h>

typedef struct { int read_bytes; float input_bitrate; int demux_bytes; float demux_bitrate;
  int corrupted, discontinuities, decoded_video, decoded_audio, displayed, lost_pictures,
      played_audio, lost_audio, sent_packets, sent_bytes; float sent_bitrate; } VLCMediaStats;
typedef struct VLCTrack { int id; char *name; struct VLCTrack *next; } VLCTrack;
typedef struct {
  void *(*new_instance)(int, const char *const *);
  void (*release_instance)(void *);
  void *(*new_player)(void *);
  void (*release_player)(void *);
  void *(*new_location)(void *, const char *);
  void (*release_media)(void *);
  void (*set_media)(void *, void *);
  void (*set_nsobject)(void *, void *);
  int (*play)(void *);
  void (*stop)(void *);
  void (*set_pause)(void *, int);
  int (*set_rate)(void *, float);
  float (*get_rate)(void *);
  int64_t (*get_time)(void *), (*get_length)(void *);
  void (*set_time)(void *, int64_t);
  int (*get_state)(void *);
  void (*mute)(void *, int);
  int (*get_mute)(void *), (*get_volume)(void *), (*set_volume)(void *, int);
  void (*set_device)(void *, const char *, const char *);
  char *(*get_device)(void *);
  void (*free_string)(void *);
  void (*add_option)(void *, const char *);
  int (*get_stats)(void *, VLCMediaStats *);
  int (*get_size)(void *, unsigned, unsigned *, unsigned *);
  int (*audio_count)(void *), (*subtitle_count)(void *);
  int (*audio_id)(void *), (*subtitle_id)(void *);
  int (*set_audio)(void *, int), (*set_subtitle)(void *, int);
  VLCTrack *(*audio_tracks)(void *), *(*subtitle_tracks)(void *);
  void (*release_tracks)(VLCTrack *);
  int (*snapshot)(void *, unsigned, const char *, unsigned, unsigned);
  const char *(*version)(void);
  void (*audio_callbacks)(void *, void (*)(void *, const void *, unsigned, int64_t), void (*)(void *, int64_t), void (*)(void *, int64_t), void (*)(void *, int64_t), void (*)(void *), void *);
  void (*audio_format)(void *, const char *, unsigned, unsigned);
  int (*media_slave_add)(void *, int, unsigned, const char *);
  int64_t (*clock)(void);
} VLCAPI;

static pthread_mutex_t load_lock = PTHREAD_MUTEX_INITIALIZER;
static void *core_handle, *vlc_handle;
static VLCAPI api;
static int loaded;
typedef struct {
  pthread_mutex_t lock;
  MTVVLCAudioBlock blocks[256];
  unsigned count, next, samples, crossings;
  int previous, previous_valid;
  int64_t start_pts, pause_pts;
  double squares, first_cross, last_cross;
} AudioCapture;
struct MTVVLC { void *instance, *player, *media; int subtitles_initialized, system_audio, system_audio_ready, requested_mute; AudioCapture *audio; char subtitle_languages[128]; };

int mtv_vlc_prefer_subtitles(MTVVLC *value, const char *languages) {
  if (!value || value->media || !languages || !*languages || strlen(languages) >= sizeof(value->subtitle_languages)) return -1;
  for (const char *p = languages; *p; ++p) if (!((*p >= 'a' && *p <= 'z') || *p == ',' || *p == '-')) return -1;
  strcpy(value->subtitle_languages, languages);
  return 0;
}

static int load_api(const char *root, char *error, size_t size) {
  pthread_mutex_lock(&load_lock);
  if (loaded) { pthread_mutex_unlock(&load_lock); return 0; }
  char path[4096];
  snprintf(path, sizeof(path), "%s/lib/libvlccore.dylib", root);
  core_handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (!core_handle) goto failure;
  snprintf(path, sizeof(path), "%s/lib/libvlc.dylib", root);
  vlc_handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (!vlc_handle) goto failure;
#define SYMBOL(field, name) do { *(void **)(&api.field) = dlsym(vlc_handle, name); if (!api.field) goto failure; } while(0)
  SYMBOL(new_instance, "libvlc_new"); SYMBOL(release_instance, "libvlc_release");
  SYMBOL(new_player, "libvlc_media_player_new"); SYMBOL(release_player, "libvlc_media_player_release");
  SYMBOL(new_location, "libvlc_media_new_location"); SYMBOL(release_media, "libvlc_media_release");
  SYMBOL(set_media, "libvlc_media_player_set_media"); SYMBOL(set_nsobject, "libvlc_media_player_set_nsobject");
  SYMBOL(play, "libvlc_media_player_play"); SYMBOL(stop, "libvlc_media_player_stop");
  SYMBOL(set_pause, "libvlc_media_player_set_pause"); SYMBOL(get_time, "libvlc_media_player_get_time");
  SYMBOL(set_rate, "libvlc_media_player_set_rate"); SYMBOL(get_rate, "libvlc_media_player_get_rate");
  SYMBOL(get_length, "libvlc_media_player_get_length"); SYMBOL(set_time, "libvlc_media_player_set_time");
  SYMBOL(get_state, "libvlc_media_player_get_state"); SYMBOL(mute, "libvlc_audio_set_mute");
  SYMBOL(get_mute, "libvlc_audio_get_mute"); SYMBOL(get_volume, "libvlc_audio_get_volume");
  SYMBOL(set_volume, "libvlc_audio_set_volume"); SYMBOL(set_device, "libvlc_audio_output_device_set");
  SYMBOL(get_device, "libvlc_audio_output_device_get"); SYMBOL(free_string, "libvlc_free");
  SYMBOL(add_option, "libvlc_media_add_option"); SYMBOL(get_stats, "libvlc_media_get_stats");
  SYMBOL(get_size, "libvlc_video_get_size"); SYMBOL(audio_count, "libvlc_audio_get_track_count");
  SYMBOL(subtitle_count, "libvlc_video_get_spu_count"); SYMBOL(audio_id, "libvlc_audio_get_track");
  SYMBOL(subtitle_id, "libvlc_video_get_spu"); SYMBOL(set_audio, "libvlc_audio_set_track");
  SYMBOL(set_subtitle, "libvlc_video_set_spu"); SYMBOL(audio_tracks, "libvlc_audio_get_track_description");
  SYMBOL(subtitle_tracks, "libvlc_video_get_spu_description"); SYMBOL(release_tracks, "libvlc_track_description_list_release");
  SYMBOL(snapshot, "libvlc_video_take_snapshot"); SYMBOL(version, "libvlc_get_version");
  SYMBOL(audio_callbacks, "libvlc_audio_set_callbacks"); SYMBOL(audio_format, "libvlc_audio_set_format"); SYMBOL(clock, "libvlc_clock");
  SYMBOL(media_slave_add, "libvlc_media_slaves_add");
#undef SYMBOL
  loaded = 1; pthread_mutex_unlock(&load_lock); return 0;
failure:
  { const char *message = dlerror(); snprintf(error, size, "%s", message ? message : "Cannot initialize libVLC ABI"); }
  pthread_mutex_unlock(&load_lock); return -1;
}

MTVVLC *mtv_vlc_create(const char *root, int headless, char *error, size_t error_size) {
  if (load_api(root, error, error_size)) return NULL;
  char plugin_path[4096]; snprintf(plugin_path, sizeof(plugin_path), "%s/plugins", root);
  setenv("VLC_PLUGIN_PATH", plugin_path, 1);
  const char *args[] = {"--ignore-config", "--quiet", "--no-video-title-show", headless ? "--vout=dummy" : "--vout=macosx", headless ? "--aout=dummy" : "--aout=auhal"};
  MTVVLC *value = calloc(1, sizeof(*value));
  if (!value) return NULL;
  value->instance = api.new_instance(5, args);
  if (value->instance) value->player = api.new_player(value->instance);
  if (!value->player) { snprintf(error, error_size, "libVLC instance/player initialization failed"); mtv_vlc_destroy(value); return NULL; }
  return value;
}
int mtv_vlc_play(MTVVLC *value, const char *url, void *nsview, int muted, int64_t start_ms, int avformat_demux) {
  return mtv_vlc_play_subtitle(value, url, nsview, muted, start_ms, avformat_demux, NULL);
}
int mtv_vlc_play_subtitle(MTVVLC *value, const char *url, void *nsview, int muted, int64_t start_ms, int avformat_demux, const char *subtitle_uri) {
  return mtv_vlc_play_sources(value, url, nsview, muted, start_ms, avformat_demux, subtitle_uri, NULL);
}
int mtv_vlc_play_sources(MTVVLC *value, const char *url, void *nsview, int muted, int64_t start_ms, int avformat_demux, const char *subtitle_uri, const char *audio_uri) {
  if (!value || !value->player || start_ms < 0 || (avformat_demux != 0 && avformat_demux != 1)) return -1;
  value->media = api.new_location(value->instance, url);
  if (!value->media) return -1;
  api.add_option(value->media, ":no-sub-autodetect-file");
  if (audio_uri) {
    unsigned port; char nonce[37]; int consumed = 0;
    if (sscanf(audio_uri, "http://127.0.0.1:%u/%36[0-9a-f-]/audio.wav%n", &port, nonce, &consumed) != 2 ||
        consumed <= 0 || audio_uri[consumed] || !port || port > 65535 || strlen(nonce) != 36 ||
        api.media_slave_add(value->media, 1, 4, audio_uri)) return -1;
    api.add_option(value->media, ":audio-track=1");
    value->system_audio = 1;
  }
  if (subtitle_uri) {
    if (strncmp(subtitle_uri, "file://", 7) || api.media_slave_add(value->media, 0, 4, subtitle_uri)) return -1;
    value->subtitles_initialized = 1;
  } else if (value->subtitle_languages[0]) {
    char option[160];
    snprintf(option, sizeof(option), ":sub-language=%s", value->subtitle_languages);
    api.add_option(value->media, option);
    value->subtitles_initialized = 1;
  } else {
    api.add_option(value->media, ":sub-track=-1");
    api.add_option(value->media, ":sub-language=none");
  }
  if (avformat_demux) api.add_option(value->media, ":demux=avformat");
  if (start_ms > 0) {
    char option[64];
    snprintf(option, sizeof(option), ":start-time=%lld.%03lld", (long long)(start_ms / 1000), (long long)(start_ms % 1000));
    api.add_option(value->media, option);
  }
  api.set_media(value->player, value->media);
  if (nsview) api.set_nsobject(value->player, nsview);
  value->requested_mute = value->audio ? 0 : muted;
  api.mute(value->player, value->system_audio && !value->audio ? 1 : value->requested_mute);
  return api.play(value->player);
}
int mtv_vlc_external_audio_selected(MTVVLC *value) {
  if (!value || !value->player || !value->system_audio) return 0;
  VLCTrack *tracks = api.audio_tracks(value->player); int count = 0, external = -1;
  for (VLCTrack *track = tracks; track; track = track->next) {
    if (track->id >= 0 && count++ == 1) external = track->id;
  }
  if (tracks) api.release_tracks(tracks);
  return count == 2 && external >= 0 && api.audio_id(value->player) == external;
}
void mtv_vlc_destroy(MTVVLC *value) {
  if (!value) return;
  // Must run off the UI thread: the macOS vout can synchronously finish UI work.
  if (value->player) { api.stop(value->player); api.release_player(value->player); }
  if (value->media) api.release_media(value->media);
  if (value->instance) api.release_instance(value->instance);
  if (value->audio) { pthread_mutex_destroy(&value->audio->lock); free(value->audio); }
  free(value);
}
static void capture_audio(void *opaque, const void *samples, unsigned count, int64_t pts) {
  AudioCapture *capture = opaque;
  if (!capture || !samples || count > 480000) return;
  const int16_t *pcm = samples;
  pthread_mutex_lock(&capture->lock);
  for (unsigned i = 0; i < count; ++i) {
    if (capture->samples == 0) capture->start_pts = pts + (int64_t)i * 1000000 / 48000;
    int current = pcm[i];
    if (capture->previous_valid && capture->previous <= 0 && current > 0) {
      double position = capture->samples - (double)current / (current - capture->previous);
      if (capture->crossings == 0) capture->first_cross = position;
      capture->last_cross = position; ++capture->crossings;
    }
    capture->previous = current; capture->previous_valid = 1;
    double normalized = current / 32768.0; capture->squares += normalized * normalized;
    if (++capture->samples == 4800) {
      double period = capture->last_cross - capture->first_cross;
      double frequency = capture->crossings > 1 && period > 0 ? (capture->crossings - 1) * 48000.0 / period : 0;
      int64_t midpoint = (int64_t)((capture->first_cross + capture->last_cross) * 0.5 * 1000000 / 48000);
      capture->blocks[capture->next] = (MTVVLCAudioBlock){capture->start_pts + midpoint, frequency, 4800, sqrt(capture->squares / 4800)};
      capture->next = (capture->next + 1) % 256; if (capture->count < 256) ++capture->count;
      capture->samples = capture->crossings = 0; capture->squares = 0;
    }
  }
  pthread_mutex_unlock(&capture->lock);
}
static void flush_audio(void *opaque, int64_t pts) {
  (void)pts; AudioCapture *capture = opaque; if (!capture) return;
  pthread_mutex_lock(&capture->lock);
  capture->count = capture->next = capture->samples = capture->crossings = 0;
  capture->squares = 0; capture->previous = 0; capture->previous_valid = 0;
  capture->pause_pts = 0;
  pthread_mutex_unlock(&capture->lock);
}
static void pause_audio(void *opaque, int64_t pts) {
  AudioCapture *capture = opaque; if (!capture) return;
  pthread_mutex_lock(&capture->lock); capture->pause_pts = pts; pthread_mutex_unlock(&capture->lock);
}
int mtv_vlc_audio_probe_enable(MTVVLC *value) {
  if (!value || !value->player || value->media || value->audio) return -1;
  AudioCapture *capture = calloc(1, sizeof(*capture)); if (!capture) return -1;
  if (pthread_mutex_init(&capture->lock, NULL) != 0) { free(capture); return -1; }
  value->audio = capture;
  // Diagnostic-only sink. libVLC callbacks replace hardware audio output.
  api.audio_callbacks(value->player, capture_audio, pause_audio, NULL, flush_audio, NULL, capture);
  api.audio_format(value->player, "S16N", 48000, 1);
  return 0;
}
unsigned mtv_vlc_audio_probe_read(MTVVLC *value, MTVVLCAudioBlock *out, unsigned capacity, int64_t *media_ms, int64_t *clock_us, int64_t *pause_pts) {
  if (!value || !value->audio || !out || capacity > 256 || !media_ms || !clock_us || !pause_pts) return 0;
  AudioCapture *capture = value->audio;
  pthread_mutex_lock(&capture->lock);
  unsigned count = capture->count < capacity ? capture->count : capacity;
  unsigned first = (capture->next + 256 - count) % 256;
  for (unsigned i = 0; i < count; ++i) out[i] = capture->blocks[(first + i) % 256];
  *pause_pts = capture->pause_pts;
  pthread_mutex_unlock(&capture->lock);
  int64_t before = api.clock(); *media_ms = api.get_time(value->player); int64_t after = api.clock();
  *clock_us = before + (after - before) / 2;
  return count;
}
void mtv_vlc_pause(MTVVLC *value, int paused) {
  if (!value || !value->player) return;
  int state = api.get_state(value->player);
  if (!paused && (state == 5 || state == 6)) { api.set_time(value->player, 0); api.play(value->player); }
  else api.set_pause(value->player, paused);
}
void mtv_vlc_seek(MTVVLC *value, int64_t ms) { if (value && value->player) api.set_time(value->player, ms); }
int mtv_vlc_set_rate(MTVVLC *value, float rate) {
  if (!value || !value->player || !isfinite(rate) || rate < 0.5f || rate > 2.f) return -1;
  if (api.set_rate(value->player, rate) != 0) return -1;
  return fabsf(api.get_rate(value->player) - rate) < 0.01f ? 0 : -1;
}
float mtv_vlc_get_rate(MTVVLC *value) { return value && value->player ? api.get_rate(value->player) : 0.f; }
MTVVLCStats mtv_vlc_stats(MTVVLC *value) {
  MTVVLCStats result = {0};
  if (!value || !value->player) return result;
  result.state = api.get_state(value->player);
  if (value->system_audio) {
    int ready = mtv_vlc_external_audio_selected(value);
    if (ready != value->system_audio_ready) {
      value->system_audio_ready = ready;
      api.mute(value->player, ready || value->audio ? value->requested_mute : 1);
    }
  }
  if (result.state == 3 && !value->subtitles_initialized) { api.set_subtitle(value->player, -1); value->subtitles_initialized = 1; }
  result.time_ms = api.get_time(value->player); result.length_ms = api.get_length(value->player);
  VLCMediaStats stats = {0};
  if (value->media && api.get_stats(value->media, &stats)) {
    result.decoded_video = stats.decoded_video; result.decoded_audio = stats.decoded_audio; result.displayed_pictures = stats.displayed;
  }
  api.get_size(value->player, 0, &result.width, &result.height);
  result.audio_count = api.audio_count(value->player); result.subtitle_count = api.subtitle_count(value->player);
  result.audio_id = api.audio_id(value->player); result.subtitle_id = api.subtitle_id(value->player);
  return result;
}
int mtv_vlc_set_output(MTVVLC *value, const char *device, int volume) {
  if (!value || !value->player || volume < 0 || volume > 100) return -1;
  if (device) {
    if (!*device || strlen(device) > 10 || strspn(device, "0123456789") != strlen(device)) return -1;
  }
  api.set_device(value->player, NULL, device);
  return api.set_volume(value->player, volume);
}
int mtv_vlc_output_status(MTVVLC *value, char *device, unsigned capacity, int *muted, int *volume, int *played) {
  if (!value || !value->player || !device || capacity < 2 || !muted || !volume || !played) return -1;
  char *selected = api.get_device(value->player);
  snprintf(device, capacity, "%s", selected ? selected : "");
  if (selected) api.free_string(selected);
  *muted = api.get_mute(value->player); *volume = api.get_volume(value->player);
  VLCMediaStats stats = {0}; *played = 0;
  if (value->media && api.get_stats(value->media, &stats)) *played = stats.played_audio;
  return 0;
}
int mtv_vlc_set_volume(MTVVLC *value, int volume) {
  if (!value || !value->player || volume < 0 || volume > 100) return -1;
  return api.set_volume(value->player, volume);
}
int mtv_vlc_cycle_track(MTVVLC *value, int subtitles, char *label, size_t size) {
  if (!value || !value->player) return -1;
  VLCTrack *head = subtitles ? api.subtitle_tracks(value->player) : api.audio_tracks(value->player);
  int current = subtitles ? api.subtitle_id(value->player) : api.audio_id(value->player);
  VLCTrack *selected = NULL;
  for (VLCTrack *track = head; track; track = track->next) {
    if (track->id == current) { selected = track->next; break; }
  }
  if (!selected) selected = head;
  if (!subtitles) while (selected && selected->id < 0) selected = selected->next;
  int result = -1;
  if (selected) {
    result = subtitles ? api.set_subtitle(value->player, selected->id) : api.set_audio(value->player, selected->id);
    snprintf(label, size, "%s", selected->name ? selected->name : (subtitles ? "Subtitle" : "Audio"));
  }
  if (head) api.release_tracks(head);
  return result;
}
unsigned mtv_vlc_copy_tracks(MTVVLC *value, int subtitles, MTVVLCTrackOption *out, unsigned capacity, int *selected, int *limited) {
  if (!value || !value->player || !out || capacity > 256 || !selected || !limited) return 0;
  *selected = subtitles ? api.subtitle_id(value->player) : api.audio_id(value->player); *limited = 0;
  VLCTrack *head = subtitles ? api.subtitle_tracks(value->player) : api.audio_tracks(value->player);
  unsigned count = 0;
  for (VLCTrack *track = head; track; track = track->next) {
    if (track->id < 0) continue;
    if (count == capacity) { *limited = 1; break; }
    out[count].id = track->id;
    snprintf(out[count].label, sizeof(out[count].label), "%s", track->name ? track->name : ""); ++count;
  }
  if (head) api.release_tracks(head);
  return count;
}
int mtv_vlc_select_track(MTVVLC *value, int subtitles, int id) {
  if (!value || !value->player) return -1;
  if (subtitles && id == -1) {
    int result = api.set_subtitle(value->player, -1);
    if (!result) value->subtitles_initialized = 1;
    return result;
  }
  if (id < 0) return -1;
  VLCTrack *head = subtitles ? api.subtitle_tracks(value->player) : api.audio_tracks(value->player);
  int found = 0;
  for (VLCTrack *track = head; track; track = track->next) if (track->id == id) { found = 1; break; }
  if (head) api.release_tracks(head);
  if (!found) return -1;
  int result = subtitles ? api.set_subtitle(value->player, id) : api.set_audio(value->player, id);
  if (!result && subtitles) value->subtitles_initialized = 1;
  return result;
}
int mtv_vlc_snapshot(MTVVLC *value, const char *path) { return value && value->player ? api.snapshot(value->player, 0, path, 0, 0) : -1; }
const char *mtv_vlc_version(MTVVLC *value) { return value ? api.version() : "unavailable"; }
int mtv_vlc_signal_mode(int number) {
  struct sigaction action;
  if (sigaction(number, NULL, &action)) return -1;
  if (action.sa_handler == SIG_DFL) return 0;
  if (action.sa_handler == SIG_IGN) return 1;
  return 2;
}
