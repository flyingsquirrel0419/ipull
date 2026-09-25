#include "include/cunicorn.h"
#include <stdlib.h>
#include <unicorn/unicorn.h>

int cu_open(cu_engine *out_engine) {
    uc_engine *uc = NULL;
    uc_err err = uc_open(UC_ARCH_X86, UC_MODE_64, &uc);
    if (err != UC_ERR_OK) return (int)err;
    *out_engine = (cu_engine)uc;
    return 0;
}

int cu_close(cu_engine engine) {
    return (int)uc_close((uc_engine *)engine);
}

int cu_mem_map(cu_engine engine, uint64_t address, uint64_t size) {
    return (int)uc_mem_map((uc_engine *)engine, address, size, UC_PROT_ALL);
}

int cu_mem_unmap(cu_engine engine, uint64_t address, uint64_t size) {
    return (int)uc_mem_unmap((uc_engine *)engine, address, size);
}

int cu_mem_write(cu_engine engine, uint64_t address, const void *bytes, size_t size) {
    return (int)uc_mem_write((uc_engine *)engine, address, bytes, size);
}

int cu_mem_read(cu_engine engine, uint64_t address, void *bytes, size_t size) {
    return (int)uc_mem_read((uc_engine *)engine, address, bytes, size);
}

int cu_reg_write(cu_engine engine, int reg, uint64_t value) {
    return (int)uc_reg_write((uc_engine *)engine, reg, &value);
}

int cu_reg_read(cu_engine engine, int reg, uint64_t *value) {
    return (int)uc_reg_read((uc_engine *)engine, reg, value);
}

int cu_emu_start(cu_engine engine, uint64_t begin, uint64_t until,
                 uint64_t timeout_us, size_t count) {
    return (int)uc_emu_start((uc_engine *)engine, begin, until, timeout_us, count);
}

int cu_emu_stop(cu_engine engine) {
    return (int)uc_emu_stop((uc_engine *)engine);
}

static void code_hook_trampoline(uc_engine *uc, uint64_t address, uint32_t size,
                                 void *user_data) {
    (void)uc;
    void **box = (void **)user_data;
    cu_code_hook_fn fn = (cu_code_hook_fn)box[0];
    void *real_user = box[1];
    fn(address, size, real_user);
}

int cu_hook_add_code(cu_engine engine, cu_code_hook_fn callback,
                     uint64_t begin, uint64_t end, void *user_data,
                     uint64_t *out_hook_id) {
    void **box = malloc(2 * sizeof(void *));
    box[0] = (void *)callback;
    box[1] = user_data;
    uc_hook hook;
    uc_err err = uc_hook_add((uc_engine *)engine, &hook, UC_HOOK_CODE,
                             (void *)code_hook_trampoline, box, begin, end);
    if (err != UC_ERR_OK) {
        free(box);
        return (int)err;
    }
    *out_hook_id = (uint64_t)(uintptr_t)hook;
    return 0;
}

int cu_hook_del(cu_engine engine, uint64_t hook_id) {
    return (int)uc_hook_del((uc_engine *)engine, (uc_hook)(uintptr_t)hook_id);
}

static int invalid_mem_trampoline(uc_engine *uc, uc_mem_type type, uint64_t address,
                                  int size, int64_t value, void *user_data) {
    (void)uc; (void)value;
    void **box = (void **)user_data;
    cu_invalid_mem_hook_fn fn = (cu_invalid_mem_hook_fn)box[0];
    void *real_user = box[1];
    return fn(address, (uint32_t)size, (int)type, real_user);
}

int cu_hook_add_invalid_mem(cu_engine engine, cu_invalid_mem_hook_fn callback,
                            void *user_data, uint64_t *out_hook_id) {
    void **box = malloc(2 * sizeof(void *));
    box[0] = (void *)callback;
    box[1] = user_data;
    uc_hook hook;
    uc_err err = uc_hook_add((uc_engine *)engine, &hook,
                             UC_HOOK_MEM_READ_UNMAPPED | UC_HOOK_MEM_WRITE_UNMAPPED
                             | UC_HOOK_MEM_FETCH_UNMAPPED,
                             (void *)invalid_mem_trampoline, box, 1, 0);
    if (err != UC_ERR_OK) {
        free(box);
        return (int)err;
    }
    *out_hook_id = (uint64_t)(uintptr_t)hook;
    return 0;
}

const char *cu_strerror(int code) {
    return uc_strerror((uc_err)code);
}

typedef struct {
    uint64_t tsc;
    uint64_t count;
} cu_tsc_state;

static int deterministic_tsc_hook(uc_engine *uc, void *user_data) {
    cu_tsc_state *state = (cu_tsc_state *)user_data;
    state->tsc += 1000;
    state->count += 1;
    uint64_t eax = (uint32_t)state->tsc;
    uint64_t edx = (uint32_t)(state->tsc >> 32);
    uc_reg_write(uc, UC_X86_REG_RAX, &eax);
    uc_reg_write(uc, UC_X86_REG_RDX, &edx);
    return 1;  /* skip the real RDTSC */
}

int cu_hook_add_deterministic_tsc(cu_engine engine, uint64_t **out_count) {
    cu_tsc_state *state = calloc(1, sizeof(cu_tsc_state));
    if (state == NULL) return (int)UC_ERR_NOMEM;
    uc_hook rdtsc, rdtscp;
    uc_err err = uc_hook_add((uc_engine *)engine, &rdtsc, UC_HOOK_INSN,
                             (void *)deterministic_tsc_hook, state, 1, 0, UC_X86_INS_RDTSC);
    if (err == UC_ERR_OK) {
        err = uc_hook_add((uc_engine *)engine, &rdtscp, UC_HOOK_INSN,
                          (void *)deterministic_tsc_hook, state, 1, 0, UC_X86_INS_RDTSCP);
    }
    if (err != UC_ERR_OK) {
        free(state);
        return (int)err;
    }
    *out_count = &state->count;
    return 0;
}
