#include "include/cunicorn.h"
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

const char *cu_strerror(int code) {
    return uc_strerror((uc_err)code);
}
