#ifndef MTV_RIME_BRIDGE_H
#define MTV_RIME_BRIDGE_H
#include <stddef.h>
typedef struct MTVRime MTVRime;
typedef struct MTVRimeResult MTVRimeResult;
// Caller serializes all operations. The engine is process-global and app-private.
MTVRime *mtv_rime_create(const char *root, const char *user_data, char *error, size_t error_size);
void mtv_rime_destroy(MTVRime *engine);
// operation: 0=snapshot, 1=key, 2=select page candidate, 3=clear, 4=commit.
MTVRimeResult *mtv_rime_apply(MTVRime *engine, int operation, int argument);
const char *mtv_rime_input(MTVRimeResult *result);
const char *mtv_rime_preedit(MTVRimeResult *result);
const char *mtv_rime_commit(MTVRimeResult *result);
int mtv_rime_count(MTVRimeResult *result);
const char *mtv_rime_candidate(MTVRimeResult *result, int index);
int mtv_rime_page(MTVRimeResult *result);
int mtv_rime_last_page(MTVRimeResult *result);
const char *mtv_rime_version(MTVRime *engine);
void mtv_rime_free_result(MTVRimeResult *result);
#endif
