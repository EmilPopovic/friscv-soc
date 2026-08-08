#include "qspi_flash.hpp"

#include <stdexcept>

#include "dut.hpp"

namespace {

constexpr uint8_t CMD_READ = 0x03;
constexpr uint8_t CMD_JEDEC_ID = 0x9f;

// Winbond W25Q128
constexpr uint8_t JEDEC_ID[3] = { 0xef, 0x40, 0x18 };

}  // namespace

QspiFlash::QspiFlash(Dut& top) : top_(top), memory_(0, MEMORY_SIZE) {
    dut::qspi_miso(top_, false);
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
    dut::qspi_miso(top_, (shift_out_ & 0x80) != 0);
    shift_out_ = uint8_t(shift_out_ << 1);
}

void QspiFlash::update() {
    bool selected = dut::qspi_selected(top_);
    bool clock = dut::qspi_sck(top_);

    if (!selected) {
        if (selected_) {
            dut::qspi_miso(top_, false);
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
            sample_bit(dut::qspi_mosi(top_));
        } else if (phase_ == Phase::Read || phase_ == Phase::Id) {
            drive_bit();
        }
    }
}
