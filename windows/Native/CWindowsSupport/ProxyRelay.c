#include "CWindowsSupport.h"
#if defined(_WIN32)
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <string.h>

/* A loopback HTTP proxy for one request target. WinHTTP cannot use SOCKS
   proxies or send proxy credentials it was not challenged for, so it connects
   here; each connection is tunnelled through the configured upstream proxy.
   Only the expected host and port are accepted. Every wait blocks on a
   socket, so an idle tunnel uses no CPU. */
enum { PACER_SOCKS4 = 1, PACER_SOCKS4A = 2, PACER_SOCKS5 = 3, PACER_SOCKS5H = 4, PACER_HTTP_PROXY = 5 };

typedef struct PacerRelay PacerRelay;
typedef struct PacerRelayLink {
    PacerRelay *relay;
    struct PacerRelayLink *next;
    SOCKET client, upstream;
    volatile LONG finished;
} PacerRelayLink;

struct PacerRelay {
    SRWLOCK lock;
    volatile LONG refs;
    int closing, kind, credentials;
    SOCKET listener;
    PacerRelayLink *links;
    char host[256], username[256], password[256], target[256];
    uint16_t port, target_port;
    DWORD timeout_ms;
};

static INIT_ONCE pacer_relay_winsock = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK pacer_relay_start_winsock(PINIT_ONCE once, void *parameter, void **context) {
    (void)once; (void)parameter; (void)context;
    WSADATA data;
    return WSAStartup(MAKEWORD(2, 2), &data) == 0;
}

static void pacer_relay_release(PacerRelay *relay) {
    if (InterlockedDecrement(&relay->refs) == 0) {
        SecureZeroMemory(relay->password, sizeof(relay->password));
        HeapFree(GetProcessHeap(), 0, relay);
    }
}

static int pacer_copy(char *destination, size_t capacity, const char *source) {
    if (source == NULL) { destination[0] = 0; return 1; }
    size_t length = strlen(source);
    if (length >= capacity) return 0;
    memcpy(destination, source, length + 1);
    return 1;
}

static int pacer_send_all(SOCKET socket, const char *bytes, int count) {
    while (count > 0) {
        int sent = send(socket, bytes, count, 0);
        if (sent <= 0) return 0;
        bytes += sent; count -= sent;
    }
    return 1;
}

static int pacer_recv_exact(SOCKET socket, unsigned char *bytes, int count) {
    while (count > 0) {
        int received = recv(socket, (char *)bytes, count, 0);
        if (received <= 0) return 0;
        bytes += received; count -= received;
    }
    return 1;
}

/* Reads one header block byte by byte, so no tunnel bytes are consumed. */
static int pacer_read_head(SOCKET socket, char *head, int capacity) {
    int length = 0;
    while (length < capacity - 1) {
        if (recv(socket, head + length, 1, 0) != 1) return -1;
        length++;
        if (length >= 4 && memcmp(head + length - 4, "\r\n\r\n", 4) == 0) { head[length] = 0; return length; }
    }
    return -1;
}

static void pacer_timeouts(SOCKET socket, DWORD milliseconds) {
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, (const char *)&milliseconds, sizeof(milliseconds));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, (const char *)&milliseconds, sizeof(milliseconds));
}

static SOCKET pacer_connect(const char *host, uint16_t port, DWORD timeout_ms) {
    char service[8];
    snprintf(service, sizeof(service), "%u", (unsigned)port);
    ADDRINFOA hints = {0}, *found = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP;
    if (getaddrinfo(host, service, &hints, &found) != 0) return INVALID_SOCKET;
    SOCKET connected = INVALID_SOCKET;
    for (ADDRINFOA *item = found; item != NULL && connected == INVALID_SOCKET; item = item->ai_next) {
        SOCKET socket = WSASocketW(item->ai_family, item->ai_socktype, item->ai_protocol, NULL, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
        if (socket == INVALID_SOCKET) continue;
        u_long nonblocking = 1;
        ioctlsocket(socket, FIONBIO, &nonblocking);
        int result = connect(socket, item->ai_addr, (int)item->ai_addrlen);
        if (result != 0 && WSAGetLastError() == WSAEWOULDBLOCK) {
            fd_set writable, failed;
            FD_ZERO(&writable); FD_ZERO(&failed); FD_SET(socket, &writable); FD_SET(socket, &failed);
            struct timeval wait = { (long)(timeout_ms / 1000), (long)((timeout_ms % 1000) * 1000) };
            int error = 0, length = sizeof(error);
            result = select(0, NULL, &writable, &failed, &wait) == 1 && FD_ISSET(socket, &writable) &&
                     getsockopt(socket, SOL_SOCKET, SO_ERROR, (char *)&error, &length) == 0 && error == 0 ? 0 : -1;
        }
        nonblocking = 0;
        ioctlsocket(socket, FIONBIO, &nonblocking);
        if (result == 0) connected = socket; else closesocket(socket);
    }
    freeaddrinfo(found);
    return connected;
}

/* SOCKS4 and SOCKS5 resolve locally unless the 4a/5h variant asks the proxy to. */
static int pacer_resolve(const char *host, int family, ADDRINFOA **found) {
    ADDRINFOA hints = {0};
    hints.ai_family = family; hints.ai_socktype = SOCK_STREAM; hints.ai_protocol = IPPROTO_TCP;
    return getaddrinfo(host, NULL, &hints, found) == 0 && *found != NULL;
}

static int pacer_socks4(PacerRelay *relay, SOCKET socket) {
    unsigned char request[4 + 4 + 256 + 256 + 2], reply[8];
    size_t user = strlen(relay->username), host = strlen(relay->target), length = 0;
    request[length++] = 4; request[length++] = 1;
    request[length++] = (unsigned char)(relay->target_port >> 8); request[length++] = (unsigned char)relay->target_port;
    if (relay->kind == PACER_SOCKS4A) {
        request[length++] = 0; request[length++] = 0; request[length++] = 0; request[length++] = 1;
    } else {
        ADDRINFOA *found = NULL;
        if (!pacer_resolve(relay->target, AF_INET, &found)) return 0;
        memcpy(request + length, &((struct sockaddr_in *)found->ai_addr)->sin_addr, 4); length += 4;
        freeaddrinfo(found);
    }
    memcpy(request + length, relay->username, user + 1); length += user + 1;
    if (relay->kind == PACER_SOCKS4A) { memcpy(request + length, relay->target, host + 1); length += host + 1; }
    return pacer_send_all(socket, (const char *)request, (int)length) && pacer_recv_exact(socket, reply, 8) &&
           reply[0] == 0 && reply[1] == 0x5A;
}

static int pacer_socks5(PacerRelay *relay, SOCKET socket) {
    unsigned char message[4 + 1 + 255 + 1 + 255 + 2 + 16], reply[4];
    size_t length = 0;
    message[length++] = 5;
    if (relay->credentials) { message[length++] = 2; message[length++] = 0; message[length++] = 2; }
    else { message[length++] = 1; message[length++] = 0; }
    if (!pacer_send_all(socket, (const char *)message, (int)length) || !pacer_recv_exact(socket, reply, 2) || reply[0] != 5) return 0;
    if (reply[1] == 2 && relay->credentials) {
        size_t user = strlen(relay->username), password = strlen(relay->password);
        if (user > 255 || password > 255) return 0;
        length = 0;
        message[length++] = 1; message[length++] = (unsigned char)user;
        memcpy(message + length, relay->username, user); length += user;
        message[length++] = (unsigned char)password;
        memcpy(message + length, relay->password, password); length += password;
        int sent = pacer_send_all(socket, (const char *)message, (int)length);
        SecureZeroMemory(message, sizeof(message));
        if (!sent || !pacer_recv_exact(socket, reply, 2) || reply[1] != 0) return 0;
    } else if (reply[1] != 0) return 0;
    length = 0;
    message[length++] = 5; message[length++] = 1; message[length++] = 0;
    if (relay->kind == PACER_SOCKS5H) {
        size_t host = strlen(relay->target);
        if (host == 0 || host > 255) return 0;
        message[length++] = 3; message[length++] = (unsigned char)host;
        memcpy(message + length, relay->target, host); length += host;
    } else {
        ADDRINFOA *found = NULL;
        if (!pacer_resolve(relay->target, AF_UNSPEC, &found)) return 0;
        if (found->ai_family == AF_INET6) {
            message[length++] = 4;
            memcpy(message + length, &((struct sockaddr_in6 *)found->ai_addr)->sin6_addr, 16); length += 16;
        } else {
            message[length++] = 1;
            memcpy(message + length, &((struct sockaddr_in *)found->ai_addr)->sin_addr, 4); length += 4;
        }
        freeaddrinfo(found);
    }
    message[length++] = (unsigned char)(relay->target_port >> 8); message[length++] = (unsigned char)relay->target_port;
    if (!pacer_send_all(socket, (const char *)message, (int)length) || !pacer_recv_exact(socket, reply, 4) ||
        reply[0] != 5 || reply[1] != 0) return 0;
    unsigned char bound[2 + 255 + 2];
    int skip = reply[3] == 1 ? 4 : reply[3] == 4 ? 16 : 0;
    if (reply[3] == 3) { if (!pacer_recv_exact(socket, bound, 1)) return 0; skip = bound[0]; }
    else if (skip == 0) return 0;
    return pacer_recv_exact(socket, bound, skip + 2);
}

static void pacer_base64(const unsigned char *input, size_t count, char *output) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t o = 0;
    for (size_t i = 0; i < count; i += 3) {
        unsigned value = input[i] << 16 | (i + 1 < count ? input[i + 1] << 8 : 0) | (i + 2 < count ? input[i + 2] : 0);
        output[o++] = alphabet[value >> 18 & 63]; output[o++] = alphabet[value >> 12 & 63];
        output[o++] = i + 1 < count ? alphabet[value >> 6 & 63] : '=';
        output[o++] = i + 2 < count ? alphabet[value & 63] : '=';
    }
    output[o] = 0;
}

static void pacer_authority(const char *host, uint16_t port, char *output, size_t capacity) {
    snprintf(output, capacity, strchr(host, ':') != NULL ? "[%s]:%u" : "%s:%u", host, (unsigned)port);
}

static int pacer_http_connect(PacerRelay *relay, SOCKET socket) {
    char authority[300], request[2048], credentials[520], encoded[700], head[8192];
    pacer_authority(relay->target, relay->target_port, authority, sizeof(authority));
    int length;
    if (relay->credentials) {
        int count = snprintf(credentials, sizeof(credentials), "%s:%s", relay->username, relay->password);
        if (count < 0 || count >= (int)sizeof(credentials)) return 0;
        pacer_base64((const unsigned char *)credentials, (size_t)count, encoded);
        length = snprintf(request, sizeof(request), "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n\r\n",
                          authority, authority, encoded);
        SecureZeroMemory(credentials, sizeof(credentials)); SecureZeroMemory(encoded, sizeof(encoded));
    } else {
        length = snprintf(request, sizeof(request), "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", authority, authority);
    }
    int sent = length > 0 && length < (int)sizeof(request) && pacer_send_all(socket, request, length);
    SecureZeroMemory(request, sizeof(request));
    if (!sent || (length = pacer_read_head(socket, head, sizeof(head))) < 16 ||
        strncmp(head, "HTTP/1.", 7) != 0 || head[7] < '0' || head[7] > '9' || head[8] != ' ') return 0;
    // Every three-digit 2xx status establishes a CONNECT tunnel. Require the
    // status boundary as well, so a malformed value such as 2000 is rejected.
    return head[9] == '2' && head[10] >= '0' && head[10] <= '9' && head[11] >= '0' && head[11] <= '9' &&
           (head[12] == ' ' || (head[12] == '\r' && head[13] == '\n'));
}

/* host:port or [v6]:port; the default port is used when none is given. */
static int pacer_split_authority(const char *text, size_t length, uint16_t fallback, char *host, size_t capacity, uint16_t *port) {
    const char *end = text + length, *colon = NULL, *start = text, *stop;
    if (length > 0 && text[0] == '[') {
        const char *close = memchr(text, ']', length);
        if (close == NULL) return 0;
        start = text + 1; stop = close;
        if (close + 1 < end) { if (close[1] != ':') return 0; colon = close + 1; }
    } else {
        colon = memchr(text, ':', length);
        stop = colon != NULL ? colon : end;
    }
    size_t count = (size_t)(stop - start);
    if (count == 0 || count >= capacity) return 0;
    memcpy(host, start, count); host[count] = 0;
    if (colon == NULL) { *port = fallback; return 1; }
    unsigned value = 0;
    const char *digit = colon + 1;
    if (digit == end) return 0;
    for (; digit < end; digit++) {
        if (*digit < '0' || *digit > '9') return 0;
        value = value * 10 + (unsigned)(*digit - '0');
        if (value > 65535) return 0;
    }
    if (value == 0) return 0;
    *port = (uint16_t)value;
    return 1;
}

/* Called with the relay lock held. Sockets are closed only after the link
   leaves the list, so close() never shuts down a released socket. */
static void pacer_relay_remove(PacerRelayLink *link) {
    PacerRelay *relay = link->relay;
    for (PacerRelayLink **item = &relay->links; *item != NULL; item = &(*item)->next) {
        if (*item == link) { *item = link->next; break; }
    }
}

static void pacer_relay_release_link(PacerRelayLink *link) {
    if (link->client != INVALID_SOCKET) closesocket(link->client);
    if (link->upstream != INVALID_SOCKET) closesocket(link->upstream);
    HeapFree(GetProcessHeap(), 0, link);
}

static void pacer_relay_unlink(PacerRelayLink *link) {
    AcquireSRWLockExclusive(&link->relay->lock);
    pacer_relay_remove(link);
    ReleaseSRWLockExclusive(&link->relay->lock);
    pacer_relay_release_link(link);
}

/* The first direction to end wakes the other; the second releases the link. */
static void pacer_relay_finish(PacerRelayLink *link) {
    PacerRelay *relay = link->relay;
    AcquireSRWLockExclusive(&relay->lock);
    if (++link->finished == 1) {
        shutdown(link->client, SD_BOTH); shutdown(link->upstream, SD_BOTH);
        ReleaseSRWLockExclusive(&relay->lock);
        return;
    }
    pacer_relay_remove(link);
    ReleaseSRWLockExclusive(&relay->lock);
    pacer_relay_release_link(link);
}

static void pacer_relay_copy(SOCKET from, SOCKET to) {
    char buffer[16384];
    for (;;) {
        int count = recv(from, buffer, sizeof(buffer), 0);
        if (count <= 0 || !pacer_send_all(to, buffer, count)) return;
    }
}

static DWORD WINAPI pacer_relay_upward(void *context) {
    PacerRelayLink *link = context;
    PacerRelay *relay = link->relay;
    pacer_relay_copy(link->client, link->upstream);
    pacer_relay_finish(link);
    pacer_relay_release(relay);
    return 0;
}

static void pacer_relay_refuse(SOCKET socket, const char *status) {
    char reply[128];
    int length = snprintf(reply, sizeof(reply), "HTTP/1.1 %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status);
    pacer_send_all(socket, reply, length);
}

static int pacer_relay_closing(PacerRelay *relay) {
    AcquireSRWLockShared(&relay->lock);
    int closing = relay->closing;
    ReleaseSRWLockShared(&relay->lock);
    return closing;
}

static DWORD WINAPI pacer_relay_serve(void *context) {
    PacerRelayLink *link = context;
    PacerRelay *relay = link->relay;
    char head[8192], host[256], forwarded[8192];
    int forward = 0;
    uint16_t port = 0;
    pacer_timeouts(link->client, relay->timeout_ms);
    int length = pacer_read_head(link->client, head, sizeof(head));
    char *line_end = length > 0 ? strstr(head, "\r\n") : NULL;
    char *space = line_end != NULL ? memchr(head, ' ', (size_t)(line_end - head)) : NULL;
    char *second = space != NULL ? memchr(space + 1, ' ', (size_t)(line_end - space - 1)) : NULL;
    if (second == NULL) { pacer_relay_refuse(link->client, "400 Bad Request"); goto failed; }
    char *target = space + 1;
    size_t target_length = (size_t)(second - target);
    if ((size_t)(space - head) == 7 && strncmp(head, "CONNECT", 7) == 0) {
        if (!pacer_split_authority(target, target_length, 443, host, sizeof(host), &port)) {
            pacer_relay_refuse(link->client, "400 Bad Request"); goto failed;
        }
    } else if (target_length > 7 && _strnicmp(target, "http://", 7) == 0) {
        /* An absolute http:// request: forward it in origin form. */
        char *authority = target + 7, *path = memchr(authority, '/', target_length - 7);
        size_t authority_length = path != NULL ? (size_t)(path - authority) : target_length - 7;
        if (!pacer_split_authority(authority, authority_length, 80, host, sizeof(host), &port)) {
            pacer_relay_refuse(link->client, "400 Bad Request"); goto failed;
        }
        /* "GET /path HTTP/1.1": `second` starts at the space before the version. */
        const char *origin = path != NULL ? path : "/";
        size_t origin_length = path != NULL ? (size_t)(second - path) : 1;
        forward = snprintf(forwarded, sizeof(forwarded), "%.*s %.*s%.*s\r\n", (int)(space - head), head,
                           (int)origin_length, origin, (int)(line_end - second), second);
        if (forward <= 0 || forward >= (int)sizeof(forwarded)) { pacer_relay_refuse(link->client, "400 Bad Request"); goto failed; }
        for (char *field = line_end + 2; field < head + length - 2;) {
            char *next = strstr(field, "\r\n");
            if (next == NULL) break;
            size_t field_length = (size_t)(next - field) + 2;
            if (_strnicmp(field, "Proxy-", 6) != 0) {
                if ((size_t)forward + field_length >= sizeof(forwarded)) { pacer_relay_refuse(link->client, "400 Bad Request"); goto failed; }
                memcpy(forwarded + forward, field, field_length); forward += (int)field_length;
            }
            field = next + 2;
        }
        if ((size_t)forward + 2 >= sizeof(forwarded)) { pacer_relay_refuse(link->client, "400 Bad Request"); goto failed; }
        memcpy(forwarded + forward, "\r\n", 2); forward += 2;
    } else { pacer_relay_refuse(link->client, "405 Method Not Allowed"); goto failed; }
    if (port != relay->target_port || _stricmp(host, relay->target) != 0) { pacer_relay_refuse(link->client, "403 Forbidden"); goto failed; }
    SOCKET upstream = pacer_connect(relay->host, relay->port, relay->timeout_ms);
    AcquireSRWLockExclusive(&relay->lock);
    link->upstream = upstream;
    int closing = relay->closing;
    ReleaseSRWLockExclusive(&relay->lock);
    /* A proxy that cannot be reached or refuses the tunnel ends the connection
       without a reply, so WinHTTP reports a connection failure as libcurl did,
       never a response from the server. */
    if (upstream == INVALID_SOCKET || closing) goto failed;
    pacer_timeouts(upstream, relay->timeout_ms);
    int tunnel = relay->kind == PACER_HTTP_PROXY ? pacer_http_connect(relay, upstream)
               : relay->kind == PACER_SOCKS5 || relay->kind == PACER_SOCKS5H ? pacer_socks5(relay, upstream)
               : pacer_socks4(relay, upstream);
    if (!tunnel || pacer_relay_closing(relay)) goto failed;
    static const char established[] = "HTTP/1.1 200 Connection established\r\n\r\n";
    if (forward > 0 ? !pacer_send_all(upstream, forwarded, forward)
                    : !pacer_send_all(link->client, established, (int)sizeof(established) - 1)) goto failed;
    /* Open tunnels wait for data without a deadline; WinHTTP keeps its own. */
    pacer_timeouts(link->client, 0); pacer_timeouts(upstream, 0);
    InterlockedIncrement(&relay->refs);
    HANDLE thread = CreateThread(NULL, 0, pacer_relay_upward, link, 0, NULL);
    if (thread == NULL) { pacer_relay_release(relay); goto failed; }
    CloseHandle(thread);
    pacer_relay_copy(upstream, link->client);
    pacer_relay_finish(link);
    pacer_relay_release(relay);
    return 0;
failed:
    pacer_relay_unlink(link);
    pacer_relay_release(relay);
    return 0;
}

static DWORD WINAPI pacer_relay_accept(void *context) {
    PacerRelay *relay = context;
    AcquireSRWLockShared(&relay->lock);
    SOCKET listener = relay->listener;
    ReleaseSRWLockShared(&relay->lock);
    while (listener != INVALID_SOCKET && !pacer_relay_closing(relay)) {
        SOCKET client = accept(listener, NULL, NULL);
        if (client == INVALID_SOCKET) break;
        SetHandleInformation((HANDLE)client, HANDLE_FLAG_INHERIT, 0);
        PacerRelayLink *link = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*link));
        if (link == NULL) { closesocket(client); continue; }
        link->relay = relay; link->client = client; link->upstream = INVALID_SOCKET;
        AcquireSRWLockExclusive(&relay->lock);
        int closing = relay->closing;
        if (!closing) { link->next = relay->links; relay->links = link; }
        ReleaseSRWLockExclusive(&relay->lock);
        if (closing) { closesocket(client); HeapFree(GetProcessHeap(), 0, link); break; }
        InterlockedIncrement(&relay->refs);
        HANDLE thread = CreateThread(NULL, 0, pacer_relay_serve, link, 0, NULL);
        if (thread == NULL) { pacer_relay_unlink(link); pacer_relay_release(relay); continue; }
        CloseHandle(thread);
    }
    pacer_relay_release(relay);
    return 0;
}

void *pacer_proxy_relay_start(int kind, const char *host, uint16_t port, const char *username, const char *password,
                              int credentials, const char *target_host, uint16_t target_port, uint32_t timeout_ms,
                              uint16_t *bound_port) {
    if (bound_port == NULL || kind < PACER_SOCKS4 || kind > PACER_HTTP_PROXY || host == NULL || port == 0 ||
        target_host == NULL || target_port == 0 || timeout_ms == 0 ||
        !InitOnceExecuteOnce(&pacer_relay_winsock, pacer_relay_start_winsock, NULL, NULL)) return NULL;
    PacerRelay *relay = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*relay));
    if (relay == NULL) return NULL;
    InitializeSRWLock(&relay->lock);
    relay->refs = 1; relay->kind = kind; relay->port = port; relay->target_port = target_port;
    relay->timeout_ms = timeout_ms; relay->credentials = credentials != 0; relay->listener = INVALID_SOCKET;
    if (!pacer_copy(relay->host, sizeof(relay->host), host) || !pacer_copy(relay->target, sizeof(relay->target), target_host) ||
        !pacer_copy(relay->username, sizeof(relay->username), credentials ? username : NULL) ||
        !pacer_copy(relay->password, sizeof(relay->password), credentials ? password : NULL) ||
        relay->host[0] == 0 || relay->target[0] == 0) { pacer_relay_release(relay); return NULL; }
    SOCKET listener = WSASocketW(AF_INET, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
    if (listener == INVALID_SOCKET) { pacer_relay_release(relay); return NULL; }
    BOOL exclusive = TRUE;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int length = sizeof(address);
    if (setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&exclusive, sizeof(exclusive)) != 0 ||
        bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 4) != 0 ||
        getsockname(listener, (struct sockaddr *)&address, &length) != 0) {
        closesocket(listener); pacer_relay_release(relay); return NULL;
    }
    relay->listener = listener;
    InterlockedIncrement(&relay->refs);
    HANDLE thread = CreateThread(NULL, 0, pacer_relay_accept, relay, 0, NULL);
    if (thread == NULL) {
        relay->listener = INVALID_SOCKET; closesocket(listener);
        pacer_relay_release(relay); pacer_relay_release(relay); return NULL;
    }
    CloseHandle(thread);
    *bound_port = ntohs(address.sin_port);
    return relay;
}

/* Stops accepting and ends open tunnels; threads release the relay as they exit. */
void pacer_proxy_relay_close(void *value) {
    PacerRelay *relay = value;
    if (relay == NULL) return;
    AcquireSRWLockExclusive(&relay->lock);
    relay->closing = 1;
    SOCKET listener = relay->listener;
    relay->listener = INVALID_SOCKET;
    for (PacerRelayLink *link = relay->links; link != NULL; link = link->next) {
        shutdown(link->client, SD_BOTH);
        if (link->upstream != INVALID_SOCKET) shutdown(link->upstream, SD_BOTH);
    }
    ReleaseSRWLockExclusive(&relay->lock);
    if (listener != INVALID_SOCKET) closesocket(listener);
    pacer_relay_release(relay);
}
#endif
