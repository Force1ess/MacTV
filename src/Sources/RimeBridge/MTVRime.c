#include "MTVRime.h"
#include "upstream/rime_api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct MTVRime { void *library; RimeApi *api; RimeSessionId session; char *shared; char *user; };
struct MTVRimeResult { char *input; char *preedit; char *commit; char **candidates; int count; int page; int last; };
static int engine_active = 0;

MTVRime *mtv_rime_create(const char *root, const char *user, char *error, size_t size) {
  if (engine_active) { snprintf(error, size, "Rime engine already active"); return NULL; }
  MTVRime *engine = calloc(1, sizeof(*engine));
  if (!engine) return NULL;
  char path[4096];
  snprintf(path, sizeof(path), "%s/lib/librime.1.17.0.dylib", root);
  engine->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!engine->library) { snprintf(error, size, "%s", dlerror()); free(engine); return NULL; }
  RimeApi *(*get_api)(void) = dlsym(engine->library, "rime_get_api");
  engine->api = get_api ? get_api() : NULL;
  if (!RIME_PROVIDED(engine->api, select_candidate_on_current_page)) {
    snprintf(error, size, "Incompatible Rime API"); dlclose(engine->library); free(engine); return NULL;
  }
  snprintf(path, sizeof(path), "%s/share", root);
  engine->shared = strdup(path); engine->user = strdup(user);
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = engine->shared;
  traits.user_data_dir = engine->user;
  traits.distribution_name = "MTV";
  traits.distribution_code_name = "mtv";
  traits.distribution_version = "0.1";
  traits.app_name = "rime.mtv";
  traits.min_log_level = 2;
  traits.log_dir = engine->user;
  engine->api->setup(&traits);
  engine->api->initialize(&traits);
  engine_active = 1;
  if (engine->api->start_maintenance(1)) engine->api->join_maintenance_thread();
  engine->session = engine->api->create_session();
  if (!engine->session || !engine->api->select_schema(engine->session, "luna_pinyin_simp")) {
    snprintf(error, size, "Cannot deploy/select luna_pinyin_simp"); mtv_rime_destroy(engine); return NULL;
  }
  engine->api->set_option(engine->session, "ascii_mode", 0);
  engine->api->set_option(engine->session, "zh_hans", 1);
  return engine;
}

void mtv_rime_destroy(MTVRime *engine) {
  if (!engine) return;
  if (engine->session) engine->api->destroy_session(engine->session);
  engine->api->finalize();
  dlclose(engine->library);
  free(engine->shared); free(engine->user); free(engine);
  engine_active = 0;
}

MTVRimeResult *mtv_rime_apply(MTVRime *engine, int op, int argument) {
  if (!engine) return NULL;
  RimeApi *api = engine->api; RimeSessionId session = engine->session;
  if (op == 1) api->process_key(session, argument, 0);
  else if (op == 2 && argument >= 0) api->select_candidate_on_current_page(session, (size_t)argument);
  else if (op == 3) api->clear_composition(session);
  else if (op == 4) api->commit_composition(session);
  MTVRimeResult *result = calloc(1, sizeof(*result));
  if (!result) return NULL;
  const char *input = api->get_input(session);
  result->input = strdup(input ? input : "");
  RIME_STRUCT(RimeCommit, commit);
  if (api->get_commit(session, &commit)) {
    result->commit = strdup(commit.text ? commit.text : "");
    api->free_commit(&commit);
  } else result->commit = strdup("");
  RIME_STRUCT(RimeContext, context);
  if (api->get_context(session, &context)) {
    result->preedit = strdup(context.composition.preedit ? context.composition.preedit : "");
    result->count = context.menu.num_candidates;
    result->page = context.menu.page_no;
    result->last = context.menu.is_last_page;
    result->candidates = calloc((size_t)result->count, sizeof(char *));
    if (result->count && !result->candidates) { api->free_context(&context); mtv_rime_free_result(result); return NULL; }
    for (int index = 0; index < result->count; index++) result->candidates[index] = strdup(context.menu.candidates[index].text);
    api->free_context(&context);
  } else { result->preedit = strdup(""); result->last = 1; }
  return result;
}

const char *mtv_rime_input(MTVRimeResult *r) { return r && r->input ? r->input : ""; }
const char *mtv_rime_preedit(MTVRimeResult *r) { return r && r->preedit ? r->preedit : ""; }
const char *mtv_rime_commit(MTVRimeResult *r) { return r && r->commit ? r->commit : ""; }
int mtv_rime_count(MTVRimeResult *r) { return r ? r->count : 0; }
const char *mtv_rime_candidate(MTVRimeResult *r, int i) { return r && i >= 0 && i < r->count && r->candidates[i] ? r->candidates[i] : ""; }
int mtv_rime_page(MTVRimeResult *r) { return r ? r->page : 0; }
int mtv_rime_last_page(MTVRimeResult *r) { return r ? r->last : 1; }
const char *mtv_rime_version(MTVRime *r) { return r ? r->api->get_version() : ""; }
void mtv_rime_free_result(MTVRimeResult *r) {
  if (!r) return;
  free(r->input); free(r->preedit); free(r->commit);
  if (r->candidates) for (int i = 0; i < r->count; i++) free(r->candidates[i]);
  free(r->candidates); free(r);
}
