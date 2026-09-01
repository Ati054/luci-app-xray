#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <inttypes.h>
#include <linux/tcp.h>
#include <netinet/in.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

#ifndef SYS_pidfd_getfd
#define SYS_pidfd_getfd 438
#endif

struct inode_set {
	ino_t *values;
	size_t length;
	size_t capacity;
};

struct socket_totals {
	uint64_t rx_bytes;
	uint64_t tx_bytes;
	uint64_t rtt_sum_us;
	unsigned int connections;
	unsigned int rtt_samples;
	int counters_available;
	int permission_denied;
};

static int inode_seen_or_add(struct inode_set *set, ino_t inode)
{
	size_t i;
	ino_t *grown;

	for (i = 0; i < set->length; i++) {
		if (set->values[i] == inode)
			return 1;
	}

	if (set->length == set->capacity) {
		size_t next_capacity = set->capacity ? set->capacity * 2 : 32;
		grown = realloc(set->values, next_capacity * sizeof(*grown));
		if (!grown)
			return -1;
		set->values = grown;
		set->capacity = next_capacity;
	}

	set->values[set->length++] = inode;
	return 0;
}

static int parse_pid(const char *text, pid_t *pid)
{
	char *end = NULL;
	long value;

	errno = 0;
	value = strtol(text, &end, 10);
	if (errno || !end || *end != '\0' || value <= 0 || value > 2147483647L)
		return -1;

	*pid = (pid_t)value;
	return 0;
}

static int inspect_pid(pid_t pid, struct socket_totals *totals)
{
	char fd_dir_path[64];
	struct inode_set inodes = { 0 };
	struct dirent *entry;
	DIR *fd_dir;
	int pidfd;

	pidfd = (int)syscall(SYS_pidfd_open, pid, 0);
	if (pidfd < 0)
		return -1;

	if (snprintf(fd_dir_path, sizeof(fd_dir_path), "/proc/%ld/fd", (long)pid) >=
	    (int)sizeof(fd_dir_path)) {
		close(pidfd);
		errno = ENAMETOOLONG;
		return -1;
	}

	fd_dir = opendir(fd_dir_path);
	if (!fd_dir) {
		close(pidfd);
		return -1;
	}

	while ((entry = readdir(fd_dir)) != NULL) {
		char *end = NULL;
		long remote_fd_long;
		struct sockaddr_storage peer;
		socklen_t peer_len = sizeof(peer);
		struct tcp_info info;
		socklen_t info_len = sizeof(info);
		struct stat socket_stat;
		int duplicate_fd;
		int socket_type;
		socklen_t socket_type_len = sizeof(socket_type);
		int seen;

		errno = 0;
		remote_fd_long = strtol(entry->d_name, &end, 10);
		if (errno || !end || *end != '\0' || remote_fd_long < 0 ||
		    remote_fd_long > 2147483647L)
			continue;

		duplicate_fd = (int)syscall(SYS_pidfd_getfd, pidfd,
					    (int)remote_fd_long, 0);
		if (duplicate_fd < 0) {
			if (errno == EPERM || errno == EACCES)
				totals->permission_denied = 1;
			continue;
		}

		if (fstat(duplicate_fd, &socket_stat) != 0 ||
		    getsockopt(duplicate_fd, SOL_SOCKET, SO_TYPE, &socket_type,
			       &socket_type_len) != 0 || socket_type != SOCK_STREAM ||
		    getpeername(duplicate_fd, (struct sockaddr *)&peer, &peer_len) != 0 ||
		    (peer.ss_family != AF_INET && peer.ss_family != AF_INET6)) {
			close(duplicate_fd);
			continue;
		}

		seen = inode_seen_or_add(&inodes, socket_stat.st_ino);
		if (seen != 0) {
			close(duplicate_fd);
			if (seen < 0) {
				closedir(fd_dir);
				close(pidfd);
				free(inodes.values);
				errno = ENOMEM;
				return -1;
			}
			continue;
		}

		memset(&info, 0, sizeof(info));
		if (getsockopt(duplicate_fd, IPPROTO_TCP, TCP_INFO, &info, &info_len) == 0) {
			totals->connections++;

			if (info_len >= offsetof(struct tcp_info, tcpi_bytes_sent) +
				       sizeof(info.tcpi_bytes_sent) &&
			    info_len >= offsetof(struct tcp_info, tcpi_bytes_received) +
				       sizeof(info.tcpi_bytes_received)) {
				totals->rx_bytes += info.tcpi_bytes_received;
				totals->tx_bytes += info.tcpi_bytes_sent;
				totals->counters_available = 1;
			}

			if (info_len >= offsetof(struct tcp_info, tcpi_rtt) +
				       sizeof(info.tcpi_rtt) && info.tcpi_rtt > 0) {
				totals->rtt_sum_us += info.tcpi_rtt;
				totals->rtt_samples++;
			}
		}

		close(duplicate_fd);
	}

	closedir(fd_dir);
	close(pidfd);
	free(inodes.values);
	return 0;
}

static void print_result(pid_t pid, const struct socket_totals *totals,
			 int inspect_rc, int first)
{
	printf("%s\"%ld\":{", first ? "" : ",", (long)pid);
	if (inspect_rc != 0) {
		printf("\"available\":false,\"reason\":\"%s\"}",
		       (errno == EPERM || errno == EACCES) ?
		       "pidfd_permission_denied" : "pidfd_unavailable");
		return;
	}

	if (totals->permission_denied && totals->connections == 0) {
		printf("\"available\":false,\"reason\":\"pidfd_permission_denied\"}");
		return;
	}

	printf("\"available\":true,\"reason\":null,");
	printf("\"connections\":%u,", totals->connections);
	printf("\"bytes_available\":%s,",
	       (totals->counters_available || totals->connections == 0) ? "true" : "false");
	printf("\"rx_bytes\":%" PRIu64 ",\"tx_bytes\":%" PRIu64 ",",
	       totals->rx_bytes, totals->tx_bytes);
	if (totals->rtt_samples > 0) {
		uint64_t average_us = totals->rtt_sum_us / totals->rtt_samples;
		uint64_t average_ms = (average_us + 500U) / 1000U;
		printf("\"rtt_available\":true,\"rtt_ms\":%" PRIu64 "}", average_ms);
	} else {
		printf("\"rtt_available\":false,\"rtt_ms\":null}");
	}
}

int main(int argc, char **argv)
{
	int i;

	if (argc < 2) {
		fprintf(stderr, "usage: xray-sockstats PID [PID ...]\n");
		return 2;
	}

	printf("{");
	for (i = 1; i < argc; i++) {
		struct socket_totals totals = { 0 };
		pid_t pid;
		int rc;

		if (parse_pid(argv[i], &pid) != 0) {
			fprintf(stderr, "invalid PID: %s\n", argv[i]);
			return 2;
		}

		errno = 0;
		rc = inspect_pid(pid, &totals);
		print_result(pid, &totals, rc, i == 1);
	}
	printf("}\n");
	return 0;
}
