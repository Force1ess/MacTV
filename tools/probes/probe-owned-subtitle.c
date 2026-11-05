#include "MTVVLC.h"
#include <stdio.h>
#include <time.h>
int main(int argc, char **argv) {
  if (argc != 4) return 2;
  char error[2048];
  MTVVLC *player = mtv_vlc_create(argv[1], 1, error, sizeof(error));
  if (!player) { fprintf(stderr, "%s\n", error); return 3; }
  if (mtv_vlc_play_subtitle(player, argv[2], NULL, 1, 0, 0, argv[3])) { mtv_vlc_destroy(player); return 4; }
  struct timespec wait = {1, 0}; nanosleep(&wait, NULL);
  MTVVLCStats stats = mtv_vlc_stats(player);
  printf("{\"subtitleID\":%d,\"subtitleOptions\":%d,\"state\":%d}\n", stats.subtitle_id, stats.subtitle_count, stats.state);
  mtv_vlc_destroy(player);
  return stats.subtitle_id >= 0 && stats.subtitle_count >= 2 ? 0 : 5;
}
