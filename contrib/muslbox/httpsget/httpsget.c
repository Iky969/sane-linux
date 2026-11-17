/*
 * httpsget -- minimal HTTPS GET client for MUSLBOX, linked statically against
 * mbedTLS and musl.  No dynamic loader, no shared libraries.
 *
 * Usage: httpsget https://host[:port]/path [ca-bundle.crt]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

#define DEFAULT_CA "/etc/ssl/certs/ca-bundle.crt"
#define IO_BUF 4096

static void die(const char *msg, int code) {
	char buf[256];
	if (code)
		mbedtls_strerror(code, buf, sizeof(buf));
	fprintf(stderr, "httpsget: %s%s%s\n", msg, code ? ": " : "",
	        code ? buf : "");
	exit(1);
}

int main(int argc, char **argv) {
	const char *url = argc > 1 ? argv[1] : NULL;
	const char *ca_path = argc > 2 ? argv[2] : DEFAULT_CA;
	char host[256] = "", path[512] = "/";
	char port[16] = "443";

	if (!url || strncmp(url, "https://", 8) != 0) {
		fprintf(stderr, "usage: httpsget https://host[:port]/path [ca-bundle.crt]\n");
		return 2;
	}
	const char *start = url + 8;
	const char *slash = strchr(start, '/');
	const char *colon = strchr(start, ':');
	size_t hostlen = slash ? (size_t)(slash - start) : strlen(start);
	if (colon && (!slash || colon < slash)) {
		hostlen = (size_t)(colon - start);
		size_t portlen = slash ? (size_t)(slash - colon - 1) : strlen(colon + 1);
		if (portlen >= sizeof(port))
			portlen = sizeof(port) - 1;
		memcpy(port, colon + 1, portlen);
		port[portlen] = '\0';
	}
	if (hostlen == 0 || hostlen >= sizeof(host))
		die("invalid host", 0);
	memcpy(host, start, hostlen);
	host[hostlen] = '\0';
	if (slash && strlen(slash) < sizeof(path))
		strcpy(path, slash);

	mbedtls_net_context fd;
	mbedtls_entropy_context entropy;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_ssl_context ssl;
	mbedtls_ssl_config conf;
	mbedtls_x509_crt ca;

	mbedtls_net_init(&fd);
	mbedtls_entropy_init(&entropy);
	mbedtls_ctr_drbg_init(&drbg);
	mbedtls_ssl_init(&ssl);
	mbedtls_ssl_config_init(&conf);
	mbedtls_x509_crt_init(&ca);

	int ret;
	ret = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
	                            (const unsigned char *)"muslbox httpsget", 16);
	if (ret)
		die("ctr_drbg_seed", ret);

	ret = mbedtls_x509_crt_parse_file(&ca, ca_path);
	if (ret < 0)
		die("cannot parse CA bundle", ret);
	if (ret > 0)
		fprintf(stderr, "httpsget: warning: skipped %d invalid certs\n", ret);

	ret = mbedtls_net_connect(&fd, host, port, MBEDTLS_NET_PROTO_TCP);
	if (ret)
		die("net_connect", ret);

	ret = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT,
	                                  MBEDTLS_SSL_TRANSPORT_STREAM,
	                                  MBEDTLS_SSL_PRESET_DEFAULT);
	if (ret)
		die("ssl_config_defaults", ret);
	mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_REQUIRED);
	mbedtls_ssl_conf_ca_chain(&conf, &ca, NULL);
	mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);

	ret = mbedtls_ssl_setup(&ssl, &conf);
	if (ret)
		die("ssl_setup", ret);
	ret = mbedtls_ssl_set_hostname(&ssl, host);
	if (ret)
		die("ssl_set_hostname", ret);
	mbedtls_ssl_set_bio(&ssl, &fd, mbedtls_net_send, mbedtls_net_recv, NULL);

	while ((ret = mbedtls_ssl_handshake(&ssl)) != 0) {
		if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE)
			die("ssl_handshake", ret);
	}
	uint32_t flags = mbedtls_ssl_get_verify_result(&ssl);
	if (flags != 0) {
		char buf[512];
		mbedtls_x509_crt_verify_info(buf, sizeof(buf), "  ! ", flags);
		fprintf(stderr, "httpsget: certificate verification failed:\n%s\n", buf);
		return 1;
	}

	char req[1024];
	int n = snprintf(req, sizeof(req),
	                 "GET %s HTTP/1.1\r\nHost: %s\r\n"
	                 "User-Agent: muslbox/0.2\r\nConnection: close\r\n\r\n",
	                 path, host);
	if (n <= 0 || (size_t)n >= sizeof(req))
		die("request too large", 0);
	size_t sent = 0;
	while (sent < (size_t)n) {
		ret = mbedtls_ssl_write(&ssl, (const unsigned char *)req + sent,
		                        (size_t)n - sent);
		if (ret > 0)
			sent += (size_t)ret;
		else if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE)
			die("ssl_write", ret);
	}

	unsigned char buf[IO_BUF];
	for (;;) {
		ret = mbedtls_ssl_read(&ssl, buf, sizeof(buf));
		if (ret > 0) {
			fwrite(buf, 1, (size_t)ret, stdout);
			continue;
		}
		if (ret == 0 || ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY)
			break;
		if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE)
			continue;
		die("ssl_read", ret);
	}
	fflush(stdout);

	mbedtls_ssl_close_notify(&ssl);
	mbedtls_net_free(&fd);
	mbedtls_x509_crt_free(&ca);
	mbedtls_ssl_free(&ssl);
	mbedtls_ssl_config_free(&conf);
	mbedtls_ctr_drbg_free(&drbg);
	mbedtls_entropy_free(&entropy);
	return 0;
}
