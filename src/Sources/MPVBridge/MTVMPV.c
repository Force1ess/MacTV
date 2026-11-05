// Original bridge to the public libmpv client ABI; no decoder or player code copied.
#include "MTVMPV.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <pthread.h>
#include <time.h>
// Layouts and event IDs from the stable public libmpv client ABI.
typedef struct { int event_id, error; uint64_t reply_userdata; void *data; } ClientEvent;
typedef struct { const char *name; int format; void *data; } PropertyEvent;
typedef struct { const char *prefix, *level, *text; int loglevel; } LogEvent;
static const char *observed_names[] = {"time-pos","duration","pause","eof-reached","estimated-frame-number",
  "current-vo","video-out-params/colormatrix","video-params/w","video-params/h","seeking","paused-for-cache","file-format"};
#define OBSERVED_COUNT (sizeof(observed_names)/sizeof(observed_names[0]))
struct MTVMPV {
  void *library, *context;
  void *(*create)(void);
  int (*option)(void *,const char *,const char *), (*initialize)(void *), (*command)(void *,const char *const *);
  char *(*property)(void *,const char *);
  void (*release)(void *), (*destroy)(void *);
  const ClientEvent *(*wait_event)(void *,double);
  void (*wakeup)(void *);
  int (*observe)(void *,uint64_t,const char *,int), (*request_logs)(void *,const char *);
  int (*get_async)(void *,uint64_t,const char *,int);
  pthread_t events;
  pthread_mutex_t lock;
  atomic_bool stopping;
  bool events_started, diagnostics, stage_logs, ended_eof;
  uint64_t frame_pending, frame_next;
  double began;
  char observed[OBSERVED_COUNT][256];
  struct { int event; double ms; } trace[64];
  int trace_count;
  int playback_error;
};
static double monotonic(void) { struct timespec value; clock_gettime(CLOCK_MONOTONIC,&value); return value.tv_sec+value.tv_nsec/1e9; }
static void record_event(MTVMPV *p,int event) {
  if (!p->diagnostics) return;
  pthread_mutex_lock(&p->lock);
  if (p->trace_count<64) { p->trace[p->trace_count].event=event; p->trace[p->trace_count++].ms=(monotonic()-p->began)*1000; }
  pthread_mutex_unlock(&p->lock);
}
static void request_frame_number(MTVMPV *p) {
  if (!p->frame_pending) {
    uint64_t id=++p->frame_next;
    if (p->get_async(p->context,id,"estimated-frame-number",1)>=0) p->frame_pending=id;
  }
}
static void *consume_events(void *opaque) {
  MTVMPV *p=opaque;
  while (!atomic_load(&p->stopping)) {
    const ClientEvent *event=p->wait_event(p->context,0.1);
    if (!event) continue;
    if (event->event_id==1) break; // MPV_EVENT_SHUTDOWN
    if (event->event_id==3) {
      if (!p->frame_pending || event->reply_userdata!=p->frame_pending) continue;
      p->frame_pending=0;
    }
    if ((event->event_id==22 || event->event_id==3) && event->data) {
      const PropertyEvent *property=event->data;
      if (!property->name) continue;
      for (size_t n=0;n<OBSERVED_COUNT;n++) if (!strcmp(property->name,observed_names[n])) {
        const char *value=property->format==1 && property->data ? *(char **)property->data:NULL;
        pthread_mutex_lock(&p->lock);
        bool final_clock=p->ended_eof && (!strcmp(property->name,"time-pos") || !strcmp(property->name,"duration"));
        if (!final_clock || (value && *value)) snprintf(p->observed[n],sizeof(p->observed[n]),"%s",value ? value:"");
        pthread_mutex_unlock(&p->lock);
        // This computed property has no periodic change notification in mpv.
        // Request its exact value asynchronously when the clock changes.
        if (value && *value && !strcmp(property->name,"time-pos")) request_frame_number(p);
        break;
      }
    } else if (event->event_id==2 && event->data && p->diagnostics) {
      const LogEvent *message=event->data;
      const char *text=message->text, *prefix=message->prefix;
      // Retain fixed stage numbers only, never log text, URLs or file names.
      if (!text || !prefix) continue;
      if (!strcmp(prefix,"mkv") && strstr(text,"All headers are parsed!")) record_event(p,101);
      else if (!strcmp(prefix,"demux") && strstr(text,"Detected file format:")) record_event(p,102);
      else if (strstr(prefix,"vd") && strstr(text,"Opening decoder")) record_event(p,103);
      else if (strstr(prefix,"ad") && strstr(text,"Opening decoder")) record_event(p,104);
      else if (!strncmp(text,"AO: ",4)) record_event(p,105);
      else if (!strncmp(text,"VO: ",4)) record_event(p,106);
    } else if (event->event_id==6 || event->event_id==7 || event->event_id==8 || event->event_id==17 ||
               event->event_id==18 || event->event_id==20 || event->event_id==21 || event->event_id==24) {
      record_event(p,event->event_id);
      if (event->event_id==6 || event->event_id==20 || (event->event_id==7 && event->data)) {
        pthread_mutex_lock(&p->lock);
        if (event->event_id==6 || event->event_id==20) {
          p->ended_eof=false; p->frame_pending=0;
          if (event->event_id==6) p->playback_error=0;
          for (size_t n=0;n<OBSERVED_COUNT;n++) {
            if (!strcmp(observed_names[n],"eof-reached")) snprintf(p->observed[n],sizeof(p->observed[n]),"no");
            if (!strcmp(observed_names[n],"estimated-frame-number")) p->observed[n][0]=0;
          }
        }
        else {
          const int *end=event->data;
          p->ended_eof=end[0]==0; // MPV_END_FILE_REASON_EOF
          if (end[0]==4) p->playback_error=end[1]<0 ? end[1]:-13;
        }
        pthread_mutex_unlock(&p->lock);
        if (event->event_id==7 && *(int *)event->data==4) record_event(p,107);
      }
      if (event->event_id==8 || event->event_id==17 || event->event_id==21) request_frame_number(p);
    }
  }
  return NULL;
}
static char load_error[4096];
const char *mtv_mpv_error(void) { return load_error; }
MTVMPV *mtv_mpv_create(const char *library) {
  MTVMPV *p = calloc(1,sizeof(*p)); if (!p) return NULL;
  if (pthread_mutex_init(&p->lock,NULL)) { free(p); return NULL; }
  atomic_init(&p->stopping,false); p->began=monotonic(); p->frame_next=1000;
  p->library = dlopen(library,RTLD_NOW | RTLD_LOCAL);
  if (!p->library) { snprintf(load_error,sizeof(load_error),"%s",dlerror()); pthread_mutex_destroy(&p->lock); free(p); return NULL; }
#define BIND(field,symbol) do { *(void **)(&p->field)=dlsym(p->library,symbol); if (!p->field) goto fail; } while(0)
  BIND(create,"mpv_create"); BIND(option,"mpv_set_option_string"); BIND(initialize,"mpv_initialize");
  BIND(command,"mpv_command"); BIND(property,"mpv_get_property_string"); BIND(release,"mpv_free"); BIND(destroy,"mpv_terminate_destroy");
  BIND(wait_event,"mpv_wait_event"); BIND(wakeup,"mpv_wakeup"); BIND(observe,"mpv_observe_property"); BIND(request_logs,"mpv_request_log_messages");
  BIND(get_async,"mpv_get_property_async");
  p->context = p->create(); if (!p->context) goto fail;
  return p;
fail: snprintf(load_error,sizeof(load_error),"libmpv client ABI unavailable"); pthread_mutex_destroy(&p->lock); free(p); return NULL;
}
int mtv_mpv_option(MTVMPV *p,const char *n,const char *v) { return p && p->context ? p->option(p->context,n,v) : -1; }
int mtv_mpv_initialize(MTVMPV *p) {
  if (!p || !p->context) return -1;
  int status=p->initialize(p->context); if (status<0) return status;
  for (size_t n=0;n<OBSERVED_COUNT;n++) {
    if (!strcmp(observed_names[n],"estimated-frame-number")) continue;
    status=p->observe(p->context,n+1,observed_names[n],1); // MPV_FORMAT_STRING
    if (status<0) return status;
  }
  if (p->stage_logs) p->request_logs(p->context,"debug");
  if (pthread_create(&p->events,NULL,consume_events,p)) return -1;
  p->events_started=true; record_event(p,100);
  return 0;
}
int mtv_mpv_command(MTVMPV *p,const char *const *a) { return p && p->context ? p->command(p->context,a) : -1; }
int mtv_mpv_property(MTVMPV *p,const char *n,char *out,int capacity) {
  if (!p || !p->context || !out || capacity < 2) return -1;
  char *s=p->property(p->context,n); if (!s) return -1;
  snprintf(out,capacity,"%s",s); p->release(s); return 0;
}
int mtv_mpv_cached_property(MTVMPV *p,const char *name,char *out,int capacity) {
  if (!p || !name || !out || capacity<2) return -1;
  for (size_t n=0;n<OBSERVED_COUNT;n++) if (!strcmp(name,observed_names[n])) {
    pthread_mutex_lock(&p->lock);
    snprintf(out,capacity,"%s",p->ended_eof && !strcmp(name,"eof-reached") ? "yes":p->observed[n]);
    pthread_mutex_unlock(&p->lock); return 0;
  }
  return -1;
}
void mtv_mpv_enable_diagnostics(MTVMPV *p) { if (p && !p->events_started) p->diagnostics=true; }
void mtv_mpv_enable_stage_logs(MTVMPV *p) { if (p && !p->events_started) { p->diagnostics=true; p->stage_logs=true; } }
int mtv_mpv_playback_error(MTVMPV *p) {
  if (!p) return -1;
  pthread_mutex_lock(&p->lock); int value=p->playback_error; pthread_mutex_unlock(&p->lock); return value;
}
int mtv_mpv_startup_trace(MTVMPV *p,char *out,int capacity) {
  if (!p || !out || capacity<3) return -1;
  pthread_mutex_lock(&p->lock);
  int used=snprintf(out,capacity,"[");
  for (int n=0;n<p->trace_count;n++) {
    int count=snprintf(out+used,capacity-used,"%s{\"event\":%d,\"ms\":%.3f}",n ? ",":"",p->trace[n].event,p->trace[n].ms);
    if (count<0 || count>=capacity-used) { pthread_mutex_unlock(&p->lock); return -1; }
    used += count;
  }
  int count=snprintf(out+used,capacity-used,"]");
  pthread_mutex_unlock(&p->lock);
  return count==1 && count<capacity-used ? 0:-1;
}
void mtv_mpv_destroy(MTVMPV *p) {
  if (!p) return;
  if (p->events_started) { atomic_store(&p->stopping,true); p->wakeup(p->context); pthread_join(p->events,NULL); }
  if (p->context) p->destroy(p->context);
  pthread_mutex_destroy(&p->lock); free(p);
}
