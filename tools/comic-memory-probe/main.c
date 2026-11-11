#include <os/proc.h>
#include <mach/mach.h>
#include <TargetConditionals.h>
#include <stdio.h>
int main(void) {
    mach_port_t host = mach_host_self();
    vm_size_t page = 0;
    vm_statistics64_data_t stats = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&stats, &count);
    kern_return_t size_result = host_page_size(host, &page);
    // Purgeable/speculative pages can overlap these counts; do not add them.
    unsigned long long reclaimable = result == KERN_SUCCESS && size_result == KERN_SUCCESS
        ? ((unsigned long long)stats.free_count + stats.inactive_count) * page : 0;
    unsigned long long process_available = 0;
#if TARGET_OS_IOS
    process_available = (unsigned long long)os_proc_available_memory();
#endif
    printf("{\"simulator\":%d,\"proc_api_supported\":%d,\"proc_available_bytes\":%llu,\"host_free_and_inactive_bytes\":%llu,\"vm_status\":%d}\n",
        TARGET_OS_SIMULATOR, TARGET_OS_IOS, process_available, reclaimable, result);
    mach_port_deallocate(mach_task_self(), host);
    return 0;
}
