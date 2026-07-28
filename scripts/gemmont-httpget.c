// SPDX-License-Identifier: MIT
/*
 * Minimal HTTP/1.x downloader for streaming a rootfs image on Gemmont.
 *
 * BusyBox wget has occasionally crashed on the experimental LA32R core during
 * long transfers.  This helper deliberately uses a fixed buffer and only the
 * socket/read/write path needed by the board flashing script.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define HEADER_CAPACITY 16384
#define IO_CAPACITY 32768

static int write_all(int fd, const void *buffer, size_t length)
{
	const unsigned char *cursor = buffer;

	while (length != 0) {
		ssize_t written = write(fd, cursor, length);

		if (written < 0 && errno == EINTR)
			continue;
		if (written <= 0)
			return -1;
		cursor += written;
		length -= (size_t)written;
	}
	return 0;
}

static const char *find_header(const char *headers, const char *name)
{
	size_t name_length = strlen(name);
	const char *line = headers;

	while (*line != '\0') {
		const char *next = strstr(line, "\r\n");

		if (next == NULL)
			break;
		if ((size_t)(next - line) > name_length &&
		    strncasecmp(line, name, name_length) == 0 &&
		    line[name_length] == ':') {
			line += name_length + 1;
			while (*line == ' ' || *line == '\t')
				line++;
			return line;
		}
		line = next + 2;
	}
	return NULL;
}

static int parse_size(const char *text, uint64_t *value)
{
	char *end;
	unsigned long long parsed;

	errno = 0;
	parsed = strtoull(text, &end, 10);
	if (errno != 0 || end == text || parsed == 0)
		return -1;
	*value = (uint64_t)parsed;
	return 0;
}

int main(int argc, char **argv)
{
	char host[64];
	char request[1024];
	char headers[HEADER_CAPACITY + 1];
	unsigned char buffer[IO_CAPACITY];
	struct sockaddr_in address;
	struct timeval timeout = { .tv_sec = 30, .tv_usec = 0 };
	const char *authority;
	const char *path;
	const char *colon;
	const char *length_header;
	char *end;
	uint64_t expected_size;
	uint64_t content_length;
	uint64_t received = 0;
	size_t authority_length;
	size_t header_length = 0;
	size_t body_offset;
	unsigned long port = 80;
	int socket_fd;
	int request_length;

	if (argc != 3) {
		fprintf(stderr, "Usage: %s HTTP_URL EXPECTED_SIZE\n", argv[0]);
		return 2;
	}
	if (parse_size(argv[2], &expected_size) != 0) {
		fprintf(stderr, "httpget: invalid expected size\n");
		return 2;
	}
	if (strncmp(argv[1], "http://", 7) != 0) {
		fprintf(stderr, "httpget: only http:// URLs are supported\n");
		return 2;
	}

	authority = argv[1] + 7;
	path = strchr(authority, '/');
	if (path == NULL) {
		fprintf(stderr, "httpget: URL has no path\n");
		return 2;
	}
	authority_length = (size_t)(path - authority);
	colon = memchr(authority, ':', authority_length);
	if (colon != NULL) {
		authority_length = (size_t)(colon - authority);
		errno = 0;
		port = strtoul(colon + 1, &end, 10);
		if (errno != 0 || end != path || port == 0 || port > 65535) {
			fprintf(stderr, "httpget: invalid port\n");
			return 2;
		}
	}
	if (authority_length == 0 || authority_length >= sizeof(host)) {
		fprintf(stderr, "httpget: invalid IPv4 address\n");
		return 2;
	}
	memcpy(host, authority, authority_length);
	host[authority_length] = '\0';

	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_port = htons((uint16_t)port);
	if (inet_pton(AF_INET, host, &address.sin_addr) != 1) {
		fprintf(stderr, "httpget: host must be a numeric IPv4 address\n");
		return 2;
	}

	socket_fd = socket(AF_INET, SOCK_STREAM, 0);
	if (socket_fd < 0) {
		perror("httpget: socket");
		return 1;
	}
	setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
		   sizeof(timeout));
	if (connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
		perror("httpget: connect");
		close(socket_fd);
		return 1;
	}

	request_length = snprintf(request, sizeof(request),
		"GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n",
		path, host);
	if (request_length < 0 || (size_t)request_length >= sizeof(request) ||
	    write_all(socket_fd, request, (size_t)request_length) != 0) {
		perror("httpget: request");
		close(socket_fd);
		return 1;
	}

	headers[0] = '\0';
	while (strstr(headers, "\r\n\r\n") == NULL) {
		ssize_t count;

		if (header_length == HEADER_CAPACITY) {
			fprintf(stderr, "httpget: HTTP headers are too large\n");
			close(socket_fd);
			return 1;
		}
		count = read(socket_fd, headers + header_length,
			     HEADER_CAPACITY - header_length);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			perror("httpget: read headers");
			close(socket_fd);
			return 1;
		}
		header_length += (size_t)count;
		headers[header_length] = '\0';
	}

	if (strncmp(headers, "HTTP/1.0 200 ", 13) != 0 &&
	    strncmp(headers, "HTTP/1.1 200 ", 13) != 0) {
		fprintf(stderr, "httpget: server did not return HTTP 200\n");
		close(socket_fd);
		return 1;
	}
	length_header = find_header(headers, "Content-Length");
	if (length_header == NULL ||
	    parse_size(length_header, &content_length) != 0 ||
	    content_length != expected_size) {
		fprintf(stderr, "httpget: unexpected Content-Length\n");
		close(socket_fd);
		return 1;
	}

	body_offset = (size_t)(strstr(headers, "\r\n\r\n") - headers) + 4;
	if (header_length > body_offset) {
		size_t initial = header_length - body_offset;

		if (initial > expected_size ||
		    write_all(STDOUT_FILENO, headers + body_offset, initial) != 0) {
			perror("httpget: write");
			close(socket_fd);
			return 1;
		}
		received = initial;
	}

	while (received < expected_size) {
		size_t wanted = sizeof(buffer);
		ssize_t count;

		if ((uint64_t)wanted > expected_size - received)
			wanted = (size_t)(expected_size - received);
		count = read(socket_fd, buffer, wanted);
		if (count < 0 && errno == EINTR)
			continue;
		if (count <= 0) {
			fprintf(stderr, "httpget: short response at %llu bytes\n",
				(unsigned long long)received);
			close(socket_fd);
			return 1;
		}
		if (write_all(STDOUT_FILENO, buffer, (size_t)count) != 0) {
			perror("httpget: write");
			close(socket_fd);
			return 1;
		}
		received += (uint64_t)count;
	}

	close(socket_fd);
	fprintf(stderr, "httpget: received %llu bytes\n",
		(unsigned long long)received);
	return 0;
}
