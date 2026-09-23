#ifndef CUNICORN_H
#define CUNICORN_H

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

/// Thin, stable C ABI over libunicorn 2.x covering exactly what the SAP
/// runtime needs. Keeps the unicorn headers out of Swift.

#ifdef __cplusplus
extern "C" {
#endif

typedef void *cu_engine;

/// x86-64 register selectors (subset of uc_x86_reg).
typedef enum {
    CU_REG_RAX = 35,
    CU_REG_RBX = 36,
    CU_REG_RCX = 38,
    CU_REG_RDI = 39,
    CU_REG_RDX = 40,
    CU_REG_RIP = 41,
    CU_REG_RSI = 43,
    CU_REG_RSP = 44,
    CU_REG_R8  = 106,
    CU_REG_R9  = 107,
} cu_register;

int  cu_open(cu_engine *out_engine);
int  cu_close(cu_engine engine);

int  cu_mem_map(cu_engine engine, uint64_t address, uint64_t size);
int  cu_mem_unmap(cu_engine engine, uint64_t address, uint64_t size);
int  cu_mem_write(cu_engine engine, uint64_t address, const void *bytes, size_t size);
int  cu_mem_read(cu_engine engine, uint64_t address, void *bytes, size_t size);

int  cu_reg_write(cu_engine engine, int reg, uint64_t value);
int  cu_reg_read(cu_engine engine, int reg, uint64_t *value);

/// Run from begin until until is reached, timeout_us elapses, or count
/// instructions execute (0 = unlimited).
int  cu_emu_start(cu_engine engine, uint64_t begin, uint64_t until,
                  uint64_t timeout_us, size_t count);
int  cu_emu_stop(cu_engine engine);

/// Code hook: invoked for every instruction in [begin, end].
typedef void (*cu_code_hook_fn)(uint64_t address, uint32_t size, void *user_data);
int  cu_hook_add_code(cu_engine engine, cu_code_hook_fn callback,
                      uint64_t begin, uint64_t end, void *user_data,
                      uint64_t *out_hook_id);
int  cu_hook_del(cu_engine engine, uint64_t hook_id);

const char *cu_strerror(int code);

#ifdef __cplusplus
}
#endif

#endif
