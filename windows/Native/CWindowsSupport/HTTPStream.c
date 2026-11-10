#include "CWindowsSupport.h"
#if defined(_WIN32)
#include <windows.h>
#include <winhttp.h>
#include <limits.h>
#include <string.h>

/* One GET response read through WinHTTP's asynchronous API. Each step waits on
   an event, so a response that stays open without data uses no CPU. Only the
   thread that opens and reads a stream touches its WinHTTP handles: cancel
   just signals, and close runs after open and read have returned. */
typedef struct {
    HINTERNET session, connection, request, socket;
    HANDLE completed, cancelled, closing;
    volatile LONG error;
    volatile DWORD bytes, socket_type;
    DWORD status_code;
    int failed, observed, socket_observed;
    BYTE buffer[16384];
} PacerHTTPStream;

static void CALLBACK pacer_http_callback(HINTERNET handle, DWORD_PTR context, DWORD status, LPVOID information, DWORD length) {
    PacerHTTPStream *stream = (PacerHTTPStream *)context;
    if (stream == NULL) return;
    switch (status) {
    case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
    case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
    case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
        stream->error = 0; SetEvent(stream->completed); break;
    case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
        stream->bytes = information != NULL ? *(const DWORD *)information : 0; stream->error = 0; SetEvent(stream->completed); break;
    case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
        stream->error = 0;
        if (handle == stream->socket) {
            const WINHTTP_WEB_SOCKET_STATUS *received = information;
            if (received == NULL || length != sizeof(*received)) stream->error = 1;
            else { stream->bytes = received->dwBytesTransferred; stream->socket_type = received->eBufferType; }
        } else stream->bytes = length;
        SetEvent(stream->completed); break;
    case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
        stream->error = 1; SetEvent(stream->completed); break;
    case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
        // The last callback for the request; WinHTTP no longer uses the context.
        SetEvent(stream->closing); break;
    default: break;
    }
}

static int pacer_http_wait(PacerHTTPStream *stream, uint32_t timeout_ms) {
    HANDLE events[2] = {stream->completed, stream->cancelled};
    DWORD result = WaitForMultipleObjects(2, events, FALSE, timeout_ms);
    if (result == WAIT_OBJECT_0 && stream->error == 0) return 0;
    // An unfinished operation may still complete; only close may follow it.
    stream->failed = 1;
    if (result == WAIT_OBJECT_0 + 1) return -3;
    if (result == WAIT_TIMEOUT) return -2;
    return -1;
}

static int pacer_http_begin(PacerHTTPStream *stream) {
    if (stream->failed) return -1;
    if (WaitForSingleObject(stream->cancelled, 0) == WAIT_OBJECT_0) { stream->failed = 1; return -3; }
    return 0;
}

void *pacer_http_stream_create(void) {
    PacerHTTPStream *stream = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*stream));
    if (stream == NULL) return NULL;
    stream->completed = CreateEventW(NULL, FALSE, FALSE, NULL);
    stream->cancelled = CreateEventW(NULL, TRUE, FALSE, NULL);
    stream->closing = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (stream->completed == NULL || stream->cancelled == NULL || stream->closing == NULL) {
        if (stream->completed != NULL) CloseHandle(stream->completed);
        if (stream->cancelled != NULL) CloseHandle(stream->cancelled);
        if (stream->closing != NULL) CloseHandle(stream->closing);
        HeapFree(GetProcessHeap(), 0, stream); return NULL;
    }
    return stream;
}

int pacer_http_stream_open(void *value, const uint16_t *host, uint16_t port, int secure, const uint16_t *path,
                           const uint16_t *headers, const uint16_t *agent, const uint16_t *proxy,
                           uint32_t timeout_ms, uint32_t *status, int websocket) {
    PacerHTTPStream *stream = value;
    if (status != NULL) *status = 0;
    if (stream == NULL || host == NULL || path == NULL || agent == NULL || status == NULL || port == 0 ||
        timeout_ms == 0 || timeout_ms > INT_MAX || stream->session != NULL) return -1;
    int begun = pacer_http_begin(stream);
    if (begun != 0) return begun;
    stream->failed = 1;
    stream->session = WinHttpOpen((LPCWSTR)agent, proxy != NULL ? WINHTTP_ACCESS_TYPE_NAMED_PROXY : WINHTTP_ACCESS_TYPE_NO_PROXY,
        proxy != NULL ? (LPCWSTR)proxy : WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
    if (stream->session == NULL) return -1;
    if (!WinHttpSetTimeouts(stream->session, (int)timeout_ms, (int)timeout_ms, (int)timeout_ms, (int)timeout_ms)) return -1;
    stream->connection = WinHttpConnect(stream->session, (LPCWSTR)host, port, 0);
    if (stream->connection == NULL) return -1;
    stream->request = WinHttpOpenRequest(stream->connection, L"GET", (LPCWSTR)path, NULL, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0);
    if (stream->request == NULL) return -1;
    if (WinHttpSetStatusCallback(stream->request, pacer_http_callback,
            WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES, 0) == WINHTTP_INVALID_STATUS_CALLBACK) return -1;
    DWORD_PTR context = (DWORD_PTR)stream;
    if (!WinHttpSetOption(stream->request, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof(context))) return -1;
    stream->observed = 1;
    // Same request policy as the URLSession reads: no redirects, cookies, stored
    // or default credentials. Bodies may be compressed like curl's.
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    DWORD disabled = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_AUTHENTICATION;
    DWORD logon = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
    DWORD decompression = WINHTTP_DECOMPRESSION_FLAG_ALL;
    if (!WinHttpSetOption(stream->request, WINHTTP_OPTION_REDIRECT_POLICY, &redirects, sizeof(redirects)) ||
        !WinHttpSetOption(stream->request, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled)) ||
        !WinHttpSetOption(stream->request, WINHTTP_OPTION_AUTOLOGON_POLICY, &logon, sizeof(logon)) ||
        !WinHttpSetOption(stream->request, WINHTTP_OPTION_DECOMPRESSION, &decompression, sizeof(decompression)) ||
        (websocket && !WinHttpSetOption(stream->request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0))) return -1;
    stream->failed = 0;
    if (!WinHttpSendRequest(stream->request, headers != NULL ? (LPCWSTR)headers : WINHTTP_NO_ADDITIONAL_HEADERS,
            headers != NULL ? (DWORD)-1L : 0, WINHTTP_NO_REQUEST_DATA, 0, 0, context)) { stream->failed = 1; return -1; }
    int result = pacer_http_wait(stream, timeout_ms);
    if (result != 0) return result;
    if ((result = pacer_http_begin(stream)) != 0) return result;
    if (!WinHttpReceiveResponse(stream->request, NULL)) { stream->failed = 1; return -1; }
    if ((result = pacer_http_wait(stream, timeout_ms)) != 0) return result;
    DWORD code = 0, size = sizeof(code);
    if (!WinHttpQueryHeaders(stream->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            WINHTTP_HEADER_NAME_BY_INDEX, &code, &size, WINHTTP_NO_HEADER_INDEX)) { stream->failed = 1; return -1; }
    *status = code;
    stream->status_code = code;
    if (websocket) {
        stream->failed = 1;
        if (code != 101) return -1;
        stream->socket = WinHttpWebSocketCompleteUpgrade(stream->request, 0);
        if (stream->socket == NULL || WinHttpSetStatusCallback(stream->socket, pacer_http_callback,
                WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES, 0) == WINHTTP_INVALID_STATUS_CALLBACK ||
            !WinHttpSetOption(stream->socket, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof(context))) return -1;
        stream->socket_observed = 1;
        stream->failed = 0;
    }
    return 0;
}

int pacer_http_stream_header(void *value, const uint16_t *name, uint16_t *output, size_t capacity) {
    PacerHTTPStream *stream = value;
    if (stream == NULL || stream->request == NULL || stream->failed || name == NULL || output == NULL ||
        capacity == 0 || capacity > 4096) return -1;
    DWORD size = (DWORD)(capacity * sizeof(WCHAR));
    if (!WinHttpQueryHeaders(stream->request, WINHTTP_QUERY_CUSTOM, (LPCWSTR)name, output, &size, WINHTTP_NO_HEADER_INDEX)) return -1;
    return (int)(size / sizeof(WCHAR));
}

int pacer_http_stream_raw_headers(void *value, uint16_t *output, size_t capacity) {
    PacerHTTPStream *stream = value;
    if (stream == NULL || stream->request == NULL || stream->failed || output == NULL || capacity == 0 || capacity > 65536) return -1;
    DWORD size = (DWORD)(capacity * sizeof(WCHAR));
    if (!WinHttpQueryHeaders(stream->request, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX,
            output, &size, WINHTTP_NO_HEADER_INDEX)) return -1;
    return (int)(size / sizeof(WCHAR));
}

static int pacer_http_stream_end(PacerHTTPStream *stream) {
    // These GET responses have no body, even with a representation's length.
    if (stream->status_code == 204 || stream->status_code == 304) return 0;
    DWORD size = 0;
    BOOL encoded = WinHttpQueryHeaders(stream->request, WINHTTP_QUERY_TRANSFER_ENCODING, WINHTTP_HEADER_NAME_BY_INDEX,
                                       NULL, &size, WINHTTP_NO_HEADER_INDEX);
    DWORD error = GetLastError();
    // Transfer-Encoding supplies its own framing and takes precedence.
    if (encoded || error == ERROR_INSUFFICIENT_BUFFER) return 0;
    if (error != ERROR_WINHTTP_HEADER_NOT_FOUND) { stream->failed = 1; return -1; }
    ULONGLONG expected = 0;
    size = sizeof(expected);
    if (!WinHttpQueryHeaders(stream->request, WINHTTP_QUERY_CONTENT_LENGTH | WINHTTP_QUERY_FLAG_NUMBER64,
            WINHTTP_HEADER_NAME_BY_INDEX, &expected, &size, WINHTTP_NO_HEADER_INDEX)) {
        if (GetLastError() == ERROR_WINHTTP_HEADER_NOT_FOUND) return 0;
        stream->failed = 1; return -1;
    }
    // A short fixed-length response can look like EOF to both read APIs.
    // Completed-request statistics count the encoded body, so gzip/deflate
    // lengths are never compared with the decompressed bytes we returned.
    WINHTTP_REQUEST_STATS stats = {0};
    stats.cStats = WinHttpRequestStatLast;
    size = sizeof(stats);
    if (!WinHttpQueryOption(stream->request, WINHTTP_OPTION_REQUEST_STATS, &stats, &size)) {
        stream->failed = 1; return -1;
    }
    ULONGLONG received = stats.rgullStats[WinHttpResponseBodyCompressedSize];
    if (received == 0) received = stats.rgullStats[WinHttpResponseBodySize];
    if (received != expected) { stream->failed = 1; return -1; }
    return 0;
}

int64_t pacer_http_stream_read(void *value, uint8_t *bytes, size_t capacity, uint32_t timeout_ms) {
    PacerHTTPStream *stream = value;
    if (stream == NULL || stream->request == NULL || bytes == NULL || capacity == 0 || timeout_ms == 0) return -1;
    int result = pacer_http_begin(stream);
    if (result != 0) return result;
    // A read waits to fill its whole buffer, so first wait for any data and
    // then read only what has arrived: a partial line is delivered at once.
    stream->bytes = 0;
    if (!WinHttpQueryDataAvailable(stream->request, NULL)) { stream->failed = 1; return -1; }
    if ((result = pacer_http_wait(stream, timeout_ms)) != 0) return result;
    DWORD available = stream->bytes;
    if ((result = pacer_http_begin(stream)) != 0) return result;
    // WinHTTP fills the stream's own buffer, which outlives a cancelled read.
    // Even when no bytes are available, ReadData must confirm EOF: a closed
    // connection can otherwise hide an incomplete Content-Length response.
    DWORD chunk = capacity < sizeof(stream->buffer) ? (DWORD)capacity : (DWORD)sizeof(stream->buffer);
    if (available > 0 && available < chunk) chunk = available;
    stream->bytes = 0;
    if (!WinHttpReadData(stream->request, stream->buffer, chunk, NULL)) { stream->failed = 1; return -1; }
    if ((result = pacer_http_wait(stream, timeout_ms)) != 0) return result;
    DWORD count = stream->bytes;
    if (count > chunk) { stream->failed = 1; return -1; }
    if (count == 0) return pacer_http_stream_end(stream);
    memcpy(bytes, stream->buffer, count);
    return (int64_t)count;
}

int pacer_websocket_send(void *value, const uint8_t *bytes, size_t size, uint32_t timeout_ms) {
    PacerHTTPStream *stream = value;
    if (stream == NULL || stream->socket == NULL || bytes == NULL || size == 0 || size > sizeof(stream->buffer) || timeout_ms == 0) return -1;
    int result = pacer_http_begin(stream);
    if (result != 0) return result;
    // The buffer must stay alive even if cancellation wins the wait.
    memcpy(stream->buffer, bytes, size);
    if (WinHttpWebSocketSend(stream->socket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, stream->buffer, (DWORD)size) != NO_ERROR) {
        stream->failed = 1; return -1;
    }
    return pacer_http_wait(stream, timeout_ms);
}

int64_t pacer_websocket_read(void *value, uint8_t *bytes, size_t capacity, uint32_t timeout_ms, int *complete) {
    PacerHTTPStream *stream = value;
    if (stream == NULL || stream->socket == NULL || bytes == NULL || complete == NULL || capacity == 0 || timeout_ms == 0) return -1;
    int result = pacer_http_begin(stream);
    if (result != 0) return result;
    DWORD chunk = capacity < sizeof(stream->buffer) ? (DWORD)capacity : (DWORD)sizeof(stream->buffer);
    if (WinHttpWebSocketReceive(stream->socket, stream->buffer, chunk, NULL, NULL) != NO_ERROR) {
        stream->failed = 1; return -1;
    }
    if ((result = pacer_http_wait(stream, timeout_ms)) != 0) return result;
    DWORD count = stream->bytes, type = stream->socket_type;
    if (count > chunk || type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) { stream->failed = 1; return -1; }
    *complete = type == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE || type == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE;
    memcpy(bytes, stream->buffer, count);
    return count;
}

void pacer_http_stream_cancel(void *value) {
    PacerHTTPStream *stream = value;
    if (stream != NULL) SetEvent(stream->cancelled);
}

void pacer_http_stream_close(void *value) {
    PacerHTTPStream *stream = value;
    if (stream == NULL) return;
    int callbacks_drained = 1;
    HINTERNET handles[] = {stream->socket, stream->request};
    int observed[] = {stream->socket_observed, stream->observed};
    for (int i = 0; i < 2; ++i) if (handles[i] != NULL) {
        if (callbacks_drained) ResetEvent(stream->closing);
        WinHttpCloseHandle(handles[i]);
        // A pending operation ends before the closing callback. Never release
        // memory that a late callback could still reach.
        if (observed[i] && callbacks_drained && WaitForSingleObject(stream->closing, 30000) != WAIT_OBJECT_0) callbacks_drained = 0;
    }
    if (stream->connection != NULL) WinHttpCloseHandle(stream->connection);
    if (stream->session != NULL) WinHttpCloseHandle(stream->session);
    if (!callbacks_drained) return;
    CloseHandle(stream->completed); CloseHandle(stream->cancelled); CloseHandle(stream->closing);
    HeapFree(GetProcessHeap(), 0, stream);
}
#endif
