#pragma once
typedef struct ProbeMPV ProbeMPV;
ProbeMPV *probe_mpv_create(const char *library);
const char *probe_mpv_error(void);
int probe_mpv_option(ProbeMPV *, const char *name, const char *value);
int probe_mpv_initialize(ProbeMPV *);
int probe_mpv_command(ProbeMPV *, const char *const *args);
int probe_mpv_property(ProbeMPV *, const char *name, char *result, int capacity);
void probe_mpv_destroy(ProbeMPV *);
