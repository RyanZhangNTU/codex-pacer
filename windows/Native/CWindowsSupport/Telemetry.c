#include "CWindowsSupport.h"
#ifdef _WIN32
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <limits.h>

typedef struct { SOCKET socket; WSAEVENT ready; HANDLE cancelled; } PacerTelemetrySocket;
typedef struct {
    SRWLOCK lock;
    SOCKET socket;
    WSAEVENT event;
    PTP_WAIT wait;
    PTP_WORK cleanup;
    void *context;
    void (*accepted)(void *, void *);
    void (*closed)(void *);
} PacerTelemetryListener;

static INIT_ONCE pacer_winsock_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK pacer_start_winsock(PINIT_ONCE once, void *parameter, void **context) {
    (void)once; (void)parameter; (void)context;
    WSADATA data;
    return WSAStartup(MAKEWORD(2, 2), &data) == 0;
}

static void CALLBACK pacer_telemetry_ready(PTP_CALLBACK_INSTANCE instance, void *context, PTP_WAIT wait, TP_WAIT_RESULT result) {
    (void)instance; (void)wait; (void)result;
    PacerTelemetryListener *listener = context;
    for (int i = 0; i < 32; i++) {
        AcquireSRWLockExclusive(&listener->lock);
        if (listener->socket == INVALID_SOCKET) { ReleaseSRWLockExclusive(&listener->lock); return; }
        WSANETWORKEVENTS events;
        (void)WSAEnumNetworkEvents(listener->socket, listener->event, &events);
        SOCKET socket = accept(listener->socket, NULL, NULL);
        if (socket == INVALID_SOCKET) {
            SetThreadpoolWait(listener->wait, listener->event, NULL);
            ReleaseSRWLockExclusive(&listener->lock); return;
        }
        ReleaseSRWLockExclusive(&listener->lock);
        (void)WSAEventSelect(socket, NULL, 0);
        if (!SetHandleInformation((HANDLE)socket, HANDLE_FLAG_INHERIT, 0)) { closesocket(socket); continue; }
        PacerTelemetrySocket *client = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*client));
        if (client == NULL) { closesocket(socket); continue; }
        client->socket = socket; client->ready = WSACreateEvent(); client->cancelled = CreateEventW(NULL, TRUE, FALSE, NULL);
        if (client->ready == WSA_INVALID_EVENT || client->cancelled == NULL || WSAEventSelect(socket, client->ready, FD_READ | FD_CLOSE) != 0) {
            if (client->ready != WSA_INVALID_EVENT) WSACloseEvent(client->ready);
            if (client->cancelled != NULL) CloseHandle(client->cancelled);
            closesocket(socket); HeapFree(GetProcessHeap(), 0, client); continue;
        }
        listener->accepted(listener->context, client);
    }
    AcquireSRWLockExclusive(&listener->lock);
    if (listener->socket != INVALID_SOCKET) SetThreadpoolWait(listener->wait, listener->event, NULL);
    ReleaseSRWLockExclusive(&listener->lock);
}

static void CALLBACK pacer_telemetry_release(PTP_CALLBACK_INSTANCE instance, void *context, PTP_WORK cleanup) {
    (void)instance;
    PacerTelemetryListener *listener = context;
    WaitForThreadpoolWaitCallbacks(listener->wait, TRUE);
    CloseThreadpoolWait(listener->wait); WSACloseEvent(listener->event);
    listener->closed(listener->context); HeapFree(GetProcessHeap(), 0, listener);
    CloseThreadpoolWork(cleanup);
}

void *pacer_telemetry_listen(uint16_t port, int backlog, uint16_t *bound_port, void *context,
                            void (*accepted)(void *, void *), void (*closed)(void *)) {
    if (bound_port == NULL || context == NULL || accepted == NULL || closed == NULL ||
        !InitOnceExecuteOnce(&pacer_winsock_once, pacer_start_winsock, NULL, NULL)) return NULL;
    SOCKET socket = WSASocketW(AF_INET, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_NO_HANDLE_INHERIT);
    if (socket == INVALID_SOCKET) return NULL;
    BOOL exclusive = TRUE;
    struct sockaddr_in address = {0}; address.sin_family = AF_INET;
    address.sin_port = htons(port); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int length = sizeof(address);
    if (setsockopt(socket, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&exclusive, sizeof(exclusive)) != 0 ||
        bind(socket, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(socket, backlog) != 0 ||
        getsockname(socket, (struct sockaddr *)&address, &length) != 0) { closesocket(socket); return NULL; }
    PacerTelemetryListener *listener = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*listener));
    if (listener == NULL) { closesocket(socket); return NULL; }
    InitializeSRWLock(&listener->lock);
    listener->socket = socket; listener->context = context; listener->accepted = accepted; listener->closed = closed;
    listener->event = WSACreateEvent();
    listener->cleanup = CreateThreadpoolWork(pacer_telemetry_release, listener, NULL);
    if (listener->event != WSA_INVALID_EVENT) listener->wait = CreateThreadpoolWait(pacer_telemetry_ready, listener, NULL);
    if (listener->wait == NULL || listener->cleanup == NULL || WSAEventSelect(socket, listener->event, FD_ACCEPT | FD_CLOSE) != 0) {
        if (listener->wait != NULL) CloseThreadpoolWait(listener->wait);
        if (listener->cleanup != NULL) CloseThreadpoolWork(listener->cleanup);
        if (listener->event != WSA_INVALID_EVENT) WSACloseEvent(listener->event);
        closesocket(socket); HeapFree(GetProcessHeap(), 0, listener); return NULL;
    }
    *bound_port = ntohs(address.sin_port);
    SetThreadpoolWait(listener->wait, listener->event, NULL);
    return listener;
}

void pacer_telemetry_stop(void *value) {
    if (value == NULL) return;
    PacerTelemetryListener *listener = value;
    AcquireSRWLockExclusive(&listener->lock);
    SetThreadpoolWait(listener->wait, NULL, NULL);
    SOCKET socket = listener->socket; listener->socket = INVALID_SOCKET;
    if (socket != INVALID_SOCKET) { shutdown(socket, SD_BOTH); closesocket(socket); }
    ReleaseSRWLockExclusive(&listener->lock);
    SubmitThreadpoolWork(listener->cleanup);
}

int pacer_telemetry_read(void *value, uint8_t *bytes, size_t capacity, uint32_t timeout_ms) {
    if (value == NULL || bytes == NULL || capacity == 0 || capacity > INT_MAX) return -1;
    PacerTelemetrySocket *client = value;
    SOCKET socket = client->socket;
    ULONGLONG deadline = GetTickCount64() + timeout_ms;
    HANDLE events[2] = {client->cancelled, client->ready};
    while (1) {
        if (WaitForSingleObject(client->cancelled, 0) == WAIT_OBJECT_0) return -1;
        WSANETWORKEVENTS network;
        if (WSAEnumNetworkEvents(socket, client->ready, &network) != 0) return -1;
        int count = recv(socket, (char *)bytes, (int)capacity, 0);
        if (count >= 0) return count;
        int error = WSAGetLastError();
        if (error == WSAEINTR) continue;
        if (error != WSAEWOULDBLOCK) return -1;
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return -2;
        DWORD result = WaitForMultipleObjects(2, events, FALSE, (DWORD)(deadline - now));
        if (result == WAIT_TIMEOUT) return -2;
        if (result != WAIT_OBJECT_0 + 1) return -1;
    }
}
int pacer_telemetry_write(void *value, const uint8_t *bytes, size_t count) {
    if (value == NULL || bytes == NULL || count > INT_MAX) return 0;
    PacerTelemetrySocket *client = value;
    SOCKET socket = client->socket;
    if (WSAEventSelect(socket, client->ready, FD_WRITE | FD_CLOSE) != 0) return 0;
    size_t offset = 0; ULONGLONG deadline = GetTickCount64() + 1000;
    HANDLE events[2] = {client->cancelled, client->ready};
    while (offset < count && GetTickCount64() < deadline) {
        if (WaitForSingleObject(client->cancelled, 0) == WAIT_OBJECT_0) return 0;
        WSANETWORKEVENTS network;
        if (WSAEnumNetworkEvents(socket, client->ready, &network) != 0) return 0;
        int sent = send(socket, (const char *)bytes + offset, (int)(count - offset), 0);
        if (sent > 0) offset += sent;
        else if (sent < 0 && WSAGetLastError() == WSAEINTR) continue;
        else if (sent < 0 && WSAGetLastError() == WSAEWOULDBLOCK) {
            ULONGLONG now = GetTickCount64();
            if (now >= deadline || WaitForMultipleObjects(2, events, FALSE, (DWORD)(deadline - now)) != WAIT_OBJECT_0 + 1) return 0;
        } else return 0;
    }
    return offset == count;
}
void pacer_telemetry_interrupt(void *value) {
    if (value == NULL) return;
    PacerTelemetrySocket *client = value;
    // Cancellation never takes a socket lock or waits for its reader.
    SetEvent(client->cancelled);
}
void pacer_telemetry_close(void *value) {
    if (value == NULL) return;
    PacerTelemetrySocket *client = value;
    if (client->socket != INVALID_SOCKET) closesocket(client->socket);
    WSACloseEvent(client->ready); CloseHandle(client->cancelled);
    HeapFree(GetProcessHeap(), 0, client);
}
#endif
