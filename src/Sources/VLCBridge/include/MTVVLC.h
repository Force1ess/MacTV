#ifndef MTV_VLC_BRIDGE_H
#define MTV_VLC_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct MTVVLC MTVVLC;
typedef struct {
  int state;
  int64_t time_ms;
  int64_t length_ms;
  int decoded_video;
  int decoded_audio;
  int displayed_pictures;
  unsigned width;
  unsigned height;
  int audio_count;
  int subtitle_count;
  int audio_id;
  int subtitle_id;
} MTVVLCStats;
typedef struct { int64_t pts_us; double frequency_hz; unsigned frames; double rms; } MTVVLCAudioBlock;
typedef struct { int id; char label[512]; } MTVVLCTrackOption;

MTVVLC *mtv_vlc_create(const char *root, int headless, char *error, size_t error_size);
int mtv_vlc_prefer_subtitles(MTVVLC *, const char *languages);
int mtv_vlc_play(MTVVLC *, const char *url, void *nsview, int muted, int64_t start_milliseconds, int avformat_demux);
int mtv_vlc_play_subtitle(MTVVLC *, const char *url, void *nsview, int muted, int64_t start_milliseconds, int avformat_demux, const char *subtitle_uri);
/* Optional audio URI requires the caller to have verified exactly one original
 * audio track. The external audio ordinal is then one; its ES ID is not fixed. */
int mtv_vlc_play_sources(MTVVLC *, const char *url, void *nsview, int muted, int64_t start_milliseconds, int avformat_demux, const char *subtitle_uri, const char *audio_uri);
int mtv_vlc_external_audio_selected(MTVVLC *);
void mtv_vlc_destroy(MTVVLC *);
void mtv_vlc_pause(MTVVLC *, int paused);
int mtv_vlc_set_rate(MTVVLC *, float rate);
float mtv_vlc_get_rate(MTVVLC *);
int mtv_vlc_set_volume(MTVVLC *, int volume);
void mtv_vlc_seek(MTVVLC *, int64_t milliseconds);
MTVVLCStats mtv_vlc_stats(MTVVLC *);
int mtv_vlc_cycle_track(MTVVLC *, int subtitles, char *label, size_t label_size);
unsigned mtv_vlc_copy_tracks(MTVVLC *, int subtitles, MTVVLCTrackOption *, unsigned capacity, int *selected, int *limited);
int mtv_vlc_select_track(MTVVLC *, int subtitles, int track_id);
int mtv_vlc_snapshot(MTVVLC *, const char *path);
const char *mtv_vlc_version(MTVVLC *);
int mtv_vlc_set_output(MTVVLC *, const char *device_id, int volume);
int mtv_vlc_output_status(MTVVLC *, char *device_id, unsigned capacity, int *muted, int *volume, int *played_buffers);
int mtv_vlc_signal_mode(int signal_number);
int mtv_vlc_audio_probe_enable(MTVVLC *);
unsigned mtv_vlc_audio_probe_read(MTVVLC *, MTVVLCAudioBlock *, unsigned capacity, int64_t *media_ms, int64_t *clock_us, int64_t *pause_pts);
#endif
