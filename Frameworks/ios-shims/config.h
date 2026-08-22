/* Overlay on Blink's host config.h for iPhoneOS / Simulator builds. */
#include_next "config.h"

/* Prefer /dev/urandom path — sys/random.h is not in the public iOS SDK. */
#undef HAVE_SYS_GETENTROPY
#undef HAVE_GETRANDOM
#undef HAVE_SYS_GETRANDOM
#ifndef HAVE_DEV_URANDOM
#define HAVE_DEV_URANDOM
#endif
