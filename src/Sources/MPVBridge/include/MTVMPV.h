#pragma once
typedef struct MTVMPV MTVMPV;
MTVMPV *mtv_mpv_create(const char *library);
const char *mtv_mpv_error(void);
int mtv_mpv_option(MTVMPV *, const char *, const char *);
int mtv_mpv_initialize(MTVMPV *);
int mtv_mpv_command(MTVMPV *, const char *const *);
int mtv_mpv_property(MTVMPV *, const char *, char *, int);
int mtv_mpv_cached_property(MTVMPV *, const char *, char *, int);
void mtv_mpv_enable_diagnostics(MTVMPV *);
void mtv_mpv_enable_stage_logs(MTVMPV *);
int mtv_mpv_startup_trace(MTVMPV *, char *, int);
int mtv_mpv_playback_error(MTVMPV *);
void mtv_mpv_destroy(MTVMPV *);
