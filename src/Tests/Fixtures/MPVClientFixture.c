// Owned public-client-ABI fixture: no player, network or audio device access.
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
typedef struct { int event_id,error; uint64_t reply_userdata; void *data; } Event;
typedef struct { const char *name; int format; void *data; } Property;
typedef struct { const char *prefix,*level,*text; int loglevel; } Log;
typedef struct { Event event; Property property; const char *value; } Item;
typedef struct {
  pthread_mutex_t lock; pthread_cond_t condition;
  Item items[64]; int head,tail,waits,waiting,awakened,end_reason,end_error,async_gets;
  Event none; Log log;
} Context;
static atomic_int unsafe_destroys=0, wakeups=0;
static void push(Context *p,int event,uint64_t userdata,const char *name,const char *value) {
  Item *item=&p->items[p->tail++%64];
  item->value=value; item->property=(Property){name,1,&item->value};
  item->event=(Event){event,0,userdata,name ? &item->property:NULL};
  pthread_cond_signal(&p->condition);
}
void *mpv_create(void) {
  Context *p=calloc(1,sizeof(*p)); pthread_mutex_init(&p->lock,NULL); pthread_cond_init(&p->condition,NULL); return p;
}
int mpv_set_option_string(void *p,const char *name,const char *value) { return 0; }
int mpv_initialize(void *opaque) {
  Context *p=opaque; pthread_mutex_lock(&p->lock);
  push(p,6,0,NULL,NULL); push(p,8,0,NULL,NULL); push(p,17,0,NULL,NULL); push(p,18,0,NULL,NULL);
  pthread_mutex_unlock(&p->lock); return 0;
}
int mpv_command(void *opaque,const char *const *args) {
  Context *p=opaque; pthread_mutex_lock(&p->lock);
  if (args && args[0] && !strcmp(args[0],"fixture-eof")) {
    p->end_reason=0; push(p,7,0,NULL,NULL); p->items[(p->tail-1)%64].event.data=&p->end_reason;
    push(p,22,0,"time-pos",NULL); push(p,22,0,"duration",NULL);
    push(p,22,0,"pause","yes");
  } else if (args && args[0] && !strcmp(args[0],"fixture-seek")) { push(p,20,0,NULL,NULL); }
  else if (args && args[0] && !strcmp(args[0],"fixture-start")) { push(p,6,0,NULL,NULL); push(p,8,0,NULL,NULL); }
  else if (args && args[0] && !strcmp(args[0],"fixture-error")) {
    p->end_reason=4; p->end_error=-13; push(p,7,0,NULL,NULL); p->items[(p->tail-1)%64].event.data=&p->end_reason;
  }
  pthread_mutex_unlock(&p->lock); return 0;
}
char *mpv_get_property_string(void *opaque,const char *name) {
  Context *p=opaque; char value[64];
  pthread_mutex_lock(&p->lock); snprintf(value,sizeof(value),"%d",!strcmp(name,"fixture.async-gets") ? p->async_gets:p->waits); pthread_mutex_unlock(&p->lock);
  return strdup(!strcmp(name,"fixture.waits") || !strcmp(name,"fixture.async-gets") ? value:"999");
}
void mpv_free(void *p) { free(p); }
int mpv_observe_property(void *opaque,uint64_t id,const char *name,int format) {
  Context *p=opaque;
  const char *value="no";
  if (!strcmp(name,"time-pos")) value="1.25";
  else if (!strcmp(name,"duration")) value="10";
  else if (!strcmp(name,"current-vo")) value="gpu-next";
  else if (!strcmp(name,"video-params/w")) value="1920";
  else if (!strcmp(name,"video-params/h")) value="1080";
  else if (!strcmp(name,"video-out-params/colormatrix")) value="bt.709";
  else if (!strcmp(name,"demuxer")) value="mkv";
  pthread_mutex_lock(&p->lock); push(p,22,id,name,value); pthread_mutex_unlock(&p->lock); return 0;
}
int mpv_get_property_async(void *opaque,uint64_t id,const char *name,int format) {
  Context *p=opaque;
  pthread_mutex_lock(&p->lock); p->async_gets++; push(p,3,id,name,"42"); pthread_mutex_unlock(&p->lock); return 0;
}
int mpv_request_log_messages(void *opaque,const char *level) {
  Context *p=opaque;
  pthread_mutex_lock(&p->lock);
  p->log=(Log){"cplayer","debug","Opening https://owned.invalid/?key=fixture-secret\n",0};
  Item *item=&p->items[p->tail++%64]; item->event=(Event){2,0,0,&p->log};
  pthread_mutex_unlock(&p->lock); return 0;
}
const Event *mpv_wait_event(void *opaque,double timeout) {
  Context *p=opaque; pthread_mutex_lock(&p->lock); p->waits++; p->waiting++;
  if (p->head==p->tail && !p->awakened && timeout>0) {
    struct timespec end; clock_gettime(CLOCK_REALTIME,&end); end.tv_nsec+=100000000;
    if (end.tv_nsec>=1000000000) { end.tv_nsec-=1000000000; end.tv_sec++; }
    pthread_cond_timedwait(&p->condition,&p->lock,&end);
  }
  p->awakened=0; p->waiting--;
  const Event *event=p->head<p->tail ? &p->items[p->head++%64].event:&p->none;
  pthread_mutex_unlock(&p->lock); return event;
}
void mpv_wakeup(void *opaque) {
  Context *p=opaque; atomic_fetch_add(&wakeups,1);
  pthread_mutex_lock(&p->lock); p->awakened=1; pthread_cond_signal(&p->condition); pthread_mutex_unlock(&p->lock);
}
void mpv_terminate_destroy(void *opaque) {
  Context *p=opaque; if (p->waiting) atomic_fetch_add(&unsafe_destroys,1);
  pthread_mutex_destroy(&p->lock); pthread_cond_destroy(&p->condition); free(p);
}
int fixture_unsafe_destroys(void) { return atomic_load(&unsafe_destroys); }
int fixture_wakeups(void) { return atomic_load(&wakeups); }
