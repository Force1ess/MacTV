#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
int main(int argc, char **argv) {
  if (argc != 4) return 2;
  errno = 0;
  int read_fd = open(argv[1], O_RDONLY | O_CLOEXEC);
  int read_error = errno;
  if (read_fd >= 0) close(read_fd);
  errno = 0;
  int write_fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  int write_error = errno;
  if (write_fd >= 0) { write(write_fd, "GENERATED_PROBE", 15); close(write_fd); }
  pid_t child = 0;
  char child_path[4096]; snprintf(child_path, sizeof(child_path), "%s-child", argv[2]);
  char *command[] = {"/usr/bin/touch", child_path, NULL};
  int spawned = posix_spawn(&child, command[0], NULL, NULL, command, environ);
  int status = -1;
  if (spawned == 0) waitpid(child, &status, 0);
  int connection = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address = {0}; address.sin_family = AF_INET; address.sin_port = htons(atoi(argv[3])); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  errno = 0;
  int connected = connection < 0 ? -1 : connect(connection, (struct sockaddr *)&address, sizeof(address));
  int network_error = errno;
  if (connection >= 0) close(connection);
  printf("{\"pid\":%d,\"readAllowed\":%s,\"readErrno\":%d,\"writeAllowed\":%s,\"writeErrno\":%d,\"spawnResult\":%d,\"spawnStatus\":%d,\"networkAllowed\":%s,\"networkErrno\":%d}\n",
    getpid(), read_fd >= 0 ? "true" : "false", read_error,
    write_fd >= 0 ? "true" : "false", write_error, spawned, status, connected == 0 ? "true" : "false", network_error);
  return 0;
}
