// Original small wrapper to the documented libmpv client ABI; no player code copied.
#include "ProbeMPV.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
struct ProbeMPV {
  void *library, *context;
  void *(*create)(void);
  int (*option)(void *, const char *, const char *);
  int (*initialize)(void *);
  int (*command)(void *, const char *const *);
  char *(*property)(void *, const char *);
  void (*release)(void *);
  void (*destroy)(void *);
};
static char load_error[4096];
const char *probe_mpv_error(void) { return load_error; }
ProbeMPV *probe_mpv_create(const char *library) {
  ProbeMPV *p = calloc(1, sizeof(*p)); if (!p) return NULL;
  p->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
  if (!p->library) { snprintf(load_error,sizeof(load_error),"%s",dlerror()); free(p); return NULL; }
#define BIND(field, symbol) do { *(void **)(&p->field) = dlsym(p->library, symbol); if (!p->field) goto fail; } while(0)
  BIND(create,"mpv_create"); BIND(option,"mpv_set_option_string"); BIND(initialize,"mpv_initialize");
  BIND(command,"mpv_command"); BIND(property,"mpv_get_property_string"); BIND(release,"mpv_free"); BIND(destroy,"mpv_terminate_destroy");
  p->context = p->create(); if (!p->context) goto fail;
  return p;
fail:
  dlclose(p->library); free(p); return NULL;
}
int probe_mpv_option(ProbeMPV *p, const char *n, const char *v) { return p && p->context ? p->option(p->context,n,v) : -1; }
int probe_mpv_initialize(ProbeMPV *p) { return p && p->context ? p->initialize(p->context) : -1; }
int probe_mpv_command(ProbeMPV *p, const char *const *a) { return p && p->context ? p->command(p->context,a) : -1; }
int probe_mpv_property(ProbeMPV *p, const char *name, char *out, int capacity) {
  if (!p || !p->context || !out || capacity < 2) return -1;
  char *s = p->property(p->context,name); if (!s) return -1;
  snprintf(out,capacity,"%s",s); p->release(s); return 0;
}
void probe_mpv_destroy(ProbeMPV *p) {
  if (!p) return; if (p->context) p->destroy(p->context);
  // mpv's Cocoa classes outlive the player; keep the image loaded for process lifetime.
  free(p);
}
