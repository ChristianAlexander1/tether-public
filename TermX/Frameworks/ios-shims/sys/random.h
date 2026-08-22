/* iOS shim: sys/random.h is not in the public iOS SDK. */
#pragma once
#include <stddef.h>
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
int getentropy(void *buf, size_t buflen);
ssize_t getrandom(void *buf, size_t buflen, unsigned int flags);
#ifdef __cplusplus
}
#endif
