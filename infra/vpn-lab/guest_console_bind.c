// Loaded ONLY by our disposable guest-console executable. Never by Tart,
// Cisco, a shell, or a system process. Its sole effect is loopback-only bind
// inside that process; no route/firewall/socket of another process changes.
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <sys/socket.h>

static atomic_uint calls;
unsigned nosleep_loopback_bind_count(void) { return atomic_load(&calls); }
static int lab_bind(int fd, const struct sockaddr *address, socklen_t size) {
    if (!address) { errno = EINVAL; return -1; }
    if (address->sa_family == AF_INET) {
        if (size != sizeof(struct sockaddr_in)) { errno = EINVAL; return -1; }
        struct sockaddr_in local = *(const struct sockaddr_in *)address;
        local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        atomic_fetch_add(&calls, 1);
        // dyld exempts references from the replacement image itself from
        // interposition; this calls the original supported libc interface.
        return bind(fd, (const struct sockaddr *)&local, sizeof(local));
    }
    if (address->sa_family == AF_INET6) {
        if (size != sizeof(struct sockaddr_in6)) { errno = EINVAL; return -1; }
        struct sockaddr_in6 local = *(const struct sockaddr_in6 *)address;
        local.sin6_addr = in6addr_loopback;
        atomic_fetch_add(&calls, 1);
        return bind(fd, (const struct sockaddr *)&local, sizeof(local));
    }
    return bind(fd, address, size);
}
extern int __bind(int, const struct sockaddr *, socklen_t);
__attribute__((used)) static struct { const void *replacement; const void *replacee; }
interposition[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)lab_bind, (const void *)bind},
    {(const void *)lab_bind, (const void *)__bind}
};
