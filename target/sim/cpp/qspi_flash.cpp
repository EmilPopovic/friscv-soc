#include "qspi_flash.hpp"

#include <stdexcept>

#include "Vfriscv_soc.h"

namespace {

constexpr unsigned QSPI_SD_LSB  = 5;   // PA5..PA8 = IO0..IO3
constexpr unsigned QSPI_SCK_BIT = 9;
constexpr unsigned QSPI_CS0_BIT = 10;

constexpr uint8_t CMD_READ = 0x03;
constexpr uint8_t CMD_JEDEC_ID = 0x9f;

// Winbond W25Q128
constexpr uint8_t JEDEC_ID[3] = { 0xef, 0x40, 0x18 };

bool pad(const Vfriscv_soc& top, unsigned bit) {
    return ((top.pad_out_o >> bit) & 1) != 0;
}

void set_miso(Vfriscv_soc& top, bool value) {
    constexpr unsigned MISO_BIT = QSPI_SD_LSB + 1;  // IO1

    top.pad_in_i = (top.pad_in_i & ~(uint32_t(1) << MISO_BIT)) |
                   (uint32_t(value ? 1 : 0) << MISO_BIT);
}

}  // namespace

QspiFlash::QspiFlash(Vfriscv_soc& top) : top_(top), memory_(0, MEMORY_SIZE) {
    set_miso(top_, false);
}

void QspiFlash::preload(uint32_t address, const std::vector<uint8_t>& data) {
    for (size_t offset = 0; offset < data.size(); ++offset) {
        uint32_t byte_address = address + uint32_t(offset);

        if (!memory_.in_range(byte_address)) {
            throw std::runtime_error("QSPI flash preload is out of range");
        }

        memory_.write_byte(byte_address, data[offset]);
    }
}

void QspiFlash::begin_transaction() {
    phase_ = Phase::Command;
    shift_in_ = 0;
    bit_ = 0;
    address_bytes_ = 0;
    address_ = 0;
}

void QspiFlash::finish_byte() {
    switch (phase_) {
        case Phase::Command:
            command_ = shift_in_;

            if (command_ == CMD_READ) {
                phase_ = Phase::Address;
            } else if (command_ == CMD_JEDEC_ID) {
                phase_ = Phase::Id;
                address_ = 0;
                shift_out_ = JEDEC_ID[0];
            } else {
                throw std::runtime_error("QSPI flash saw an unsupported command");
            }
            break;

        case Phase::Address:
            address_ = (address_ << 8) | shift_in_;

            if (++address_bytes_ == 3) {
                phase_ = Phase::Read;
                shift_out_ = memory_.read_byte(address_);
            }
            break;

        case Phase::Read:
            // the host clocks a dummy byte per byte read
            shift_out_ = memory_.read_byte(++address_ & (MEMORY_SIZE - 1));
            break;

        case Phase::Id:
            address_ = (address_ + 1) % 3;
            shift_out_ = JEDEC_ID[address_];
            break;
    }
}

void QspiFlash::sample_bit(bool mosi) {
    shift_in_ = uint8_t((shift_in_ << 1) | (mosi ? 1 : 0));

    if (++bit_ == 8) {
        bit_ = 0;
        finish_byte();
    }
}

void QspiFlash::drive_bit() {
    // mode 0: shift out on the falling edge, MSB first
    set_miso(top_, (shift_out_ & 0x80) != 0);
    shift_out_ = uint8_t(shift_out_ << 1);
}

void QspiFlash::update() {
    bool selected = !pad(top_, QSPI_CS0_BIT);
    bool clock = pad(top_, QSPI_SCK_BIT);

    if (!selected) {
        if (selected_) {
            set_miso(top_, false);
        }

        selected_ = false;
        clock_ = clock;
        return;
    }

    if (!selected_) {
        begin_transaction();
        selected_ = true;
    }

    if (clock != clock_) {
        clock_ = clock;

        if (clock) {
            sample_bit(pad(top_, QSPI_SD_LSB));
        } else if (phase_ == Phase::Read || phase_ == Phase::Id) {
            drive_bit();
        }
    }
}
