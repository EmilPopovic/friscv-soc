#include "clint_model.hpp"

namespace {
constexpr uint32_t MSIP        = 0x0000;
constexpr uint32_t MTIMECMP_LO = 0x4000;
constexpr uint32_t MTIMECMP_HI = 0x4004;
constexpr uint32_t MTIME_LO    = 0xBFF8;
constexpr uint32_t MTIME_HI    = 0xBFFC;
}

ClintModel::ClintModel() {
    reset();
}

void ClintModel::reset() {
    mtime         = 0;
    mtimecmp      = ~uint64_t{0};
    msip          = false;
    suppress_tick = false;
    prescaler     = 0;

    rdata      = 0;
    wait       = false;
    beat_valid = false;
    err        = false;
}

void ClintModel::tick() {
    if (suppress_tick) {
        suppress_tick = false;
        return;
    }

    prescaler++;
    if (prescaler == MTIME_DIV) {
        prescaler = 0;
        mtime++;
    }
}

uint32_t ClintModel::read_reg(uint32_t offset) const {
    switch (offset) {
    case MSIP:
        return msip;
    case MTIMECMP_LO:
        return static_cast<uint32_t>(mtimecmp);
    case MTIMECMP_HI:
        return static_cast<uint32_t>(mtimecmp >> 32);
    case MTIME_LO:
        return static_cast<uint32_t>(mtime);
    case MTIME_HI:
        return static_cast<uint32_t>(mtime >> 32);
    default:
        return 0;
    }
}

void ClintModel::write_reg(uint32_t offset, uint32_t data) {
    switch (offset) {
    case MSIP:
        msip = (data & 1) != 0;
        break;
    case MTIMECMP_LO:
        mtimecmp = (mtimecmp & 0xFFFFFFFF00000000ull) | data;
        break;
    case MTIMECMP_HI:
        mtimecmp = (mtimecmp & 0x00000000FFFFFFFFull) |
                    (static_cast<uint64_t>(data) << 32);
        break;
    case MTIME_LO:
        mtime = (mtime & 0xFFFFFFFF00000000ull) | data;
        prescaler     = 0;
        suppress_tick = true;
        break;
    case MTIME_HI:
        mtime = (mtime & 0x00000000FFFFFFFFull) |
                (static_cast<uint64_t>(data) << 32);
        prescaler     = 0;
        suppress_tick = true;
        break;
    default:
        break;
    }
}

void ClintModel::cycle(uint8_t size, uint32_t offset, uint32_t wdata,
                       bool w_en, bool r_en, bool burst_en) {
    (void)size;
    (void)burst_en;

    rdata      = 0;
    wait       = false;
    beat_valid = false;
    err        = false;

    if (r_en)
        rdata = read_reg(offset);

    if (w_en)
        write_reg(offset, wdata);

    tick();
}
