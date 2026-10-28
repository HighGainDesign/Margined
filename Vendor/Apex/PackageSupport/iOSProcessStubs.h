// MDView integration shim: iOS cannot launch external programs. The pinned
// parser sources stay unchanged; unavailable optional CLI/plugin helpers fail
// closed instead of referencing process APIs. Never applied to macOS.
#pragma once
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static inline int mdview_ios_system(const char *command) { (void)command; errno = ENOTSUP; return -1; }
static inline FILE *mdview_ios_popen(const char *command, const char *mode) { (void)command; (void)mode; errno = ENOTSUP; return NULL; }
static inline pid_t mdview_ios_fork(void) { errno = ENOTSUP; return (pid_t)-1; }
static inline int mdview_ios_execl(const char *path, const char *arg, ...) { (void)path; (void)arg; errno = ENOTSUP; return -1; }
static inline int mdview_ios_execvp(const char *path, char *const argv[]) { (void)path; (void)argv; errno = ENOTSUP; return -1; }
#define system mdview_ios_system
#define popen mdview_ios_popen
#define fork mdview_ios_fork
#define execl mdview_ios_execl
#define execlp mdview_ios_execl
#define execvp mdview_ios_execvp
#endif
