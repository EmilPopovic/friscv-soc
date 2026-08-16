// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

#include "jtag.hpp"

#include <stdexcept>

#include "dut.hpp"
#include "soc_testbench.hpp"

namespace {

constexpr uint8_t IR_IDCODE = 0x01;
constexpr uint8_t IR_DTMCS = 0x10;
constexpr uint8_t IR_DMI = 0x11;
constexpr uint32_t IDCODE = 0x00000db3;

constexpr uint8_t DMCONTROL = 0x10;
constexpr uint8_t DMSTATUS = 0x11;
constexpr uint8_t SBCS = 0x38;
constexpr uint8_t SBADDRESS0 = 0x39;
constexpr uint8_t SBDATA0 = 0x3c;

constexpr uint8_t DMI_NOP = 0;
constexpr uint8_t DMI_READ = 1;
constexpr uint8_t DMI_WRITE = 2;
constexpr uint8_t DMI_SUCCESS = 0;
constexpr uint8_t DMI_BUSY = 3;

constexpr uint8_t SBA_BYTE = 0;
constexpr uint8_t SBA_WORD = 2;
constexpr uint32_t SBA_WORD_SUPPORTED = 1u << 2;
constexpr uint32_t SBA_ERROR = 7u << 12;
constexpr uint32_t SBA_READ_ON_ADDRESS = 1u << 20;
constexpr uint32_t SBA_BUSY = 1u << 21;
constexpr uint32_t SBA_BUSY_ERROR = 1u << 22;

constexpr uint32_t DM_ACTIVE = 1;
constexpr uint32_t DM_RESET = 3;
constexpr uint32_t DM_ANYHALTED = 1u << 8;
constexpr uint32_t DM_ANYRUNNING = 1u << 10;
constexpr uint32_t DM_ANYRESUMEACK = 1u << 16;
constexpr uint32_t DM_RESUMEREQ = 1u << 30;
constexpr uint32_t DM_HALTREQ = 1u << 31;

constexpr unsigned IR_SIZE = 5;
constexpr unsigned DMI_SIZE = 41;
constexpr unsigned DMI_IDLE_CYCLES = 8;
constexpr unsigned DMI_RETRIES = 8;

uint64_t encode_dmi(uint8_t address, uint32_t data, uint8_t operation) {
    return (uint64_t(address & 0x7f) << 34) |
           (uint64_t(data) << 2) |
           (operation & 3);
}

uint8_t dmi_status(uint64_t response) {
    return response & 3;
}

uint32_t dmi_data(uint64_t response) {
    return response >> 2;
}

uint32_t pack_word(const std::vector<uint8_t>& data, size_t offset) {
    return uint32_t(data[offset]) |
           (uint32_t(data[offset + 1]) << 8) |
           (uint32_t(data[offset + 2]) << 16) |
           (uint32_t(data[offset + 3]) << 24);
}

void append_word(std::vector<uint8_t>& data, uint32_t word) {
    data.push_back(uint8_t(word));
    data.push_back(uint8_t(word >> 8));
    data.push_back(uint8_t(word >> 16));
    data.push_back(uint8_t(word >> 24));
}

}  // namespace

Jtag::Jtag(SocTestbench& testbench)
    : testbench_(testbench), top_(testbench.top()) {}

bool Jtag::pulse(bool tms, bool tdi) {
    top_.jtag_tms_i = tms;
    top_.jtag_tdi_i = tdi;
    bool tdo = dut::jtag_tdo(top_);

    top_.jtag_tck_i = 1;
    testbench_.run_cycles(2);
    top_.jtag_tck_i = 0;
    testbench_.run_cycles(2);
    return tdo;
}

void Jtag::move_tap(std::initializer_list<bool> path) {
    for (bool tms : path) {
        pulse(tms, false);
    }
}

void Jtag::idle(unsigned cycles) {
    for (unsigned i = 0; i < cycles; ++i) {
        pulse(false, false);
    }
}

uint64_t Jtag::shift_bits(uint64_t data, unsigned size) {
    uint64_t result = 0;

    for (unsigned i = 0; i < size; ++i) {
        bool last = i + 1 == size;
        bool tdi = (data >> i) & 1;

        result |= uint64_t(pulse(last, tdi)) << i;
    }

    return result;
}

void Jtag::shift_ir(uint8_t instruction) {
    move_tap({true, true, false, false});
    shift_bits(instruction, IR_SIZE);
    move_tap({true, false});
}

uint64_t Jtag::shift_dr(uint64_t data, unsigned size) {
    move_tap({true, false, false});
    uint64_t result = shift_bits(data, size);
    move_tap({true, false});
    return result;
}

void Jtag::initialize() {
    move_tap({true, true, true, true, true, true, false});

    shift_ir(IR_IDCODE);
    if (uint32_t(shift_dr(0, 32)) != IDCODE) {
        throw std::runtime_error("unexpected JTAG IDCODE");
    }

    shift_ir(IR_DTMCS);
    uint32_t dtmcs = uint32_t(shift_dr(0, 32));

    bool dtm_ok = (dtmcs & 0xf) == 1;
    bool abits_ok = ((dtmcs >> 4) & 0x3f) == 7;

    if (!dtm_ok || !abits_ok) {
        throw std::runtime_error("unsupported JTAG DTM");
    }

    dmi_write(DMCONTROL, DM_ACTIVE);
    uint32_t sbcs = dmi_read(SBCS);

    bool sba_ok = ((sbcs >> 29) & 7) == 1;
    bool size_ok = ((sbcs >> 5) & 0x7f) >= 32;
    bool word_ok = sbcs & SBA_WORD_SUPPORTED;

    if (!sba_ok || !size_ok || !word_ok) {
        throw std::runtime_error("unsupported system bus access");
    }
}

uint32_t Jtag::dmi_access(uint8_t address, uint32_t data,
                          uint8_t operation) {
    uint64_t request = encode_dmi(address, data, operation);

    for (unsigned retry = 0; retry < DMI_RETRIES; ++retry) {
        shift_ir(IR_DMI);
        shift_dr(request, DMI_SIZE);
        idle(DMI_IDLE_CYCLES);

        uint64_t response = shift_dr(encode_dmi(0, 0, DMI_NOP), DMI_SIZE);
        uint8_t status = dmi_status(response);

        if (status == DMI_SUCCESS) {
            return dmi_data(response);
        }

        if (status != DMI_BUSY) {
            throw std::runtime_error("DMI transaction failed");
        }

        reset_dmi();
    }

    throw std::runtime_error("DMI remained busy");
}

uint32_t Jtag::dmi_read(uint8_t address) {
    return dmi_access(address, 0, DMI_READ);
}

void Jtag::dmi_write(uint8_t address, uint32_t data) {
    dmi_access(address, data, DMI_WRITE);
}

void Jtag::reset_dmi() {
    shift_ir(IR_DTMCS);
    shift_dr(uint64_t(1) << 16, 32);
}

void Jtag::wait_dmstatus(uint32_t mask) {
    for (unsigned i = 0; i < 1000; ++i) {
        if (dmi_read(DMSTATUS) & mask) {
            return;
        }

        testbench_.run_cycles(8);
    }

    throw std::runtime_error("debug module operation timed out");
}

void Jtag::halt() {
    dmi_write(DMCONTROL, DM_ACTIVE | DM_HALTREQ);
    wait_dmstatus(DM_ANYHALTED);
    dmi_write(DMCONTROL, DM_ACTIVE);
}

void Jtag::resume() {
    dmi_write(DMCONTROL, DM_ACTIVE | DM_RESUMEREQ);
    wait_dmstatus(DM_ANYRESUMEACK);
    dmi_write(DMCONTROL, DM_ACTIVE);
    wait_dmstatus(DM_ANYRUNNING);
}

void Jtag::wait_sba() {
    for (unsigned i = 0; i < 1000; ++i) {
        uint32_t status = dmi_read(SBCS);

        if (status & SBA_BUSY) {
            continue;
        }

        if (status & SBA_BUSY_ERROR) {
            throw std::runtime_error("system bus busy error");
        }

        if (status & SBA_ERROR) {
            throw std::runtime_error("system bus transaction failed");
        }

        return;
    }

    throw std::runtime_error("system bus transaction timed out");
}

uint32_t Jtag::sba_read(uint32_t address, uint8_t access) {
    uint32_t control = (uint32_t(access) << 17) | SBA_READ_ON_ADDRESS;

    dmi_write(SBCS, control);
    dmi_write(SBADDRESS0, address);
    wait_sba();
    return dmi_read(SBDATA0);
}

void Jtag::sba_write(uint32_t address, uint32_t data, uint8_t access) {
    dmi_write(SBCS, uint32_t(access) << 17);
    dmi_write(SBADDRESS0, address);
    dmi_write(SBDATA0, data);
    wait_sba();
}

void Jtag::reset_soc() {
    dmi_write(DMCONTROL, DM_RESET);
    testbench_.run_cycles(16);
    dmi_write(DMCONTROL, DM_ACTIVE);
    testbench_.run_cycles(32);
}

std::vector<uint8_t> Jtag::read_memory(uint32_t address, size_t size) {
    std::vector<uint8_t> data;
    data.reserve(size);

    while (size != 0) {
        if ((address & 3) == 0 && size >= 4) {
            append_word(data, sba_read(address, SBA_WORD));
            address += 4;
            size -= 4;
        } else {
            data.push_back(uint8_t(sba_read(address, SBA_BYTE)));
            ++address;
            --size;
        }
    }

    return data;
}

void Jtag::write_memory(uint32_t address, const std::vector<uint8_t>& data) {
    size_t offset = 0;

    while (offset < data.size()) {
        if ((address & 3) == 0 && data.size() - offset >= 4) {
            sba_write(address, pack_word(data, offset), SBA_WORD);
            address += 4;
            offset += 4;
        } else {
            sba_write(address, data[offset], SBA_BYTE);
            ++address;
            ++offset;
        }
    }
}
