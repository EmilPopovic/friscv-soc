#include "bus.hpp"

void BusRouter::map(uint32_t base, uint32_t size, BusDevice* dev) {
    address_map.push_back({base, size, dev});
}

void BusRouter::cycle(uint8_t size, uint32_t addr, uint32_t wdata,
                      bool w_en, bool r_en, bool burst_en) {
    if (owner && owner->wait) {
        // If the owner is still waiting, keep it as the owner
        owner->cycle(size, addr - owner_base, wdata, w_en, r_en, burst_en);
        rdata      = owner->rdata;
        wait       = owner->wait;
        beat_valid = owner->beat_valid;
        err        = owner->err;
        for (const auto& mapping : address_map) {
            if (mapping.dev != owner) {
                // Update not selected devices
                mapping.dev->cycle(size, addr - mapping.base, wdata, false, false, false);
            }
        }
        return;
    } else {
        // Clear the owner if it is not waiting anymore
        owner = nullptr;
    }
    
    for (const auto& mapping : address_map) {
        if (addr >= mapping.base && addr < mapping.base + mapping.size) {
            // Accept the transfer for the first maching device
            owner = mapping.dev;
            owner_base = mapping.base;
            mapping.dev->cycle(size, addr - mapping.base, wdata, w_en, r_en, burst_en);
            rdata      = mapping.dev->rdata;
            wait       = mapping.dev->wait;
            beat_valid = mapping.dev->beat_valid;
            err        = mapping.dev->err;
            return;
        } else {
            // Update not selected devices
            mapping.dev->cycle(size, addr - mapping.base, wdata, false, false, false);
        }
    }
    // If no device is mapped to the address, set error
    rdata      = 0;
    wait       = false;
    beat_valid = false;
    err        = true;
}
