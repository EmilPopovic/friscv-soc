// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>

#include "sd_card.hpp"

#include <algorithm>
#include <stdexcept>

namespace {

constexpr uint8_t CMD_GO_IDLE_STATE = 0;
constexpr uint8_t CMD_SEND_IF_COND = 8;
constexpr uint8_t CMD_SET_BLOCKLEN = 16;
constexpr uint8_t CMD_READ_SINGLE_BLOCK = 17;
constexpr uint8_t CMD_APP_CMD = 55;
constexpr uint8_t CMD_READ_OCR = 58;
constexpr uint8_t ACMD_SEND_OP_COND = 41;

constexpr uint8_t R1_READY = 0x00;
constexpr uint8_t R1_IDLE = 0x01;
constexpr uint8_t R1_ILLEGAL_COMMAND = 0x04;
constexpr uint8_t R1_CRC_ERROR = 0x08;

constexpr uint8_t DATA_TOKEN = 0xfe;

// Only CMD0 and CMD8 are sent before the host turns CRC checking off
constexpr uint8_t CMD0_CRC = 0x95;
constexpr uint8_t CMD8_CRC = 0x87;

uint16_t crc16_ccitt(const uint8_t* data, size_t length) {
    uint16_t crc = 0;

    for (size_t i = 0; i < length; ++i) {
        crc ^= uint16_t(data[i]) << 8;

        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x8000) ? uint16_t((crc << 1) ^ 0x1021) : uint16_t(crc << 1);
        }
    }

    return crc;
}

}  // namespace

SdCard::SdCard(Dut& top) : top_(top), memory_(0, MEMORY_SIZE) {}

uint8_t SdCard::pattern_byte(uint32_t block, unsigned offset) {
    return uint8_t(block * 31u + offset * 7u + 0x5au);
}

void SdCard::fill_test_pattern(unsigned blocks) {
    for (uint32_t block = 0; block < blocks; ++block) {
        for (unsigned offset = 0; offset < BLOCK_BYTES; ++offset) {
            memory_.write_byte(block * BLOCK_BYTES + offset, pattern_byte(block, offset));
        }
    }
}

void SdCard::preload(uint32_t block, const std::vector<uint8_t>& data) {
    for (size_t offset = 0; offset < data.size(); ++offset) {
        uint32_t byte_address = block * BLOCK_BYTES + uint32_t(offset);

        if (!memory_.in_range(byte_address)) {
            throw std::runtime_error("SD card preload is out of range");
        }

        memory_.write_byte(byte_address, data[offset]);
    }
}

void SdCard::set_miso_delay(unsigned cycles) {
    delay_ = std::min(cycles, MAX_DELAY);
    pipe_.assign(delay_, true);
}

bool SdCard::miso() const {
    return delay_ == 0 ? miso_raw_ : pipe_.front();
}

void SdCard::advance_delay() {
    if (delay_ == 0) {
        return;
    }

    pipe_.push_back(miso_raw_);
    pipe_.pop_front();
}

void SdCard::begin_transaction() {
    shift_in_ = 0;
    bit_in_ = 0;
    in_cmd_ = false;
    cmd_len_ = 0;

    // Mode 0 samples on the first rising edge, so present bit one now. A queued
    // response survives chip select dropping between segments.
    out_bit_ = 0;
    present_bit();
}

uint8_t SdCard::next_out_byte() {
    if (out_queue_.empty()) {
        return 0xff;
    }

    uint8_t byte = out_queue_.front();
    out_queue_.pop_front();
    return byte;
}

void SdCard::present_bit() {
    if (out_bit_ == 0) {
        out_byte_ = next_out_byte();
    }

    miso_raw_ = (out_byte_ & 0x80) != 0;
    out_byte_ = uint8_t(out_byte_ << 1);
    out_bit_ = (out_bit_ + 1) & 7;
}

void SdCard::sample_bit(bool mosi) {
    shift_in_ = uint8_t((shift_in_ << 1) | (mosi ? 1 : 0));

    if (++bit_in_ == 8) {
        bit_in_ = 0;
        finish_byte();
    }
}

void SdCard::finish_byte() {
    uint8_t byte = shift_in_;

    if (in_cmd_) {
        cmd_[cmd_len_++] = byte;

        if (cmd_len_ == 6) {
            in_cmd_ = false;
            process_command();
        }

        return;
    }

    // Command frames open with 01xxxxxx, and never while a response is going out
    if (out_queue_.empty() && (byte & 0xc0) == 0x40) {
        in_cmd_ = true;
        cmd_len_ = 0;
        cmd_[cmd_len_++] = byte;
    }
}

void SdCard::respond(const std::vector<uint8_t>& bytes) {
    for (unsigned i = 0; i < RESPONSE_DELAY_BYTES; ++i) {
        out_queue_.push_back(0xff);
    }

    for (uint8_t byte : bytes) {
        out_queue_.push_back(byte);
    }
}

void SdCard::process_command() {
    uint8_t  command = cmd_[0] & 0x3f;
    uint32_t argument = (uint32_t(cmd_[1]) << 24) | (uint32_t(cmd_[2]) << 16) |
                        (uint32_t(cmd_[3]) << 8) | uint32_t(cmd_[4]);
    uint8_t  crc = cmd_[5];

    bool app = app_cmd_;
    app_cmd_ = false;

    switch (command) {
        case CMD_GO_IDLE_STATE:
            if (idle_clocks_ < REQUIRED_INIT_CLOCKS) {
                return;
            }

            if (crc != CMD0_CRC) {
                respond({ R1_CRC_ERROR });
                return;
            }

            initialised_ = true;
            respond({ R1_IDLE });
            return;

        case CMD_SEND_IF_COND:
            if (!initialised_) {
                respond({ R1_ILLEGAL_COMMAND | R1_IDLE });
                return;
            }

            if (crc != CMD8_CRC) {
                respond({ R1_CRC_ERROR });
                return;
            }

            // R7 echoes the voltage range and the check pattern back
            respond({ R1_IDLE, 0x00, 0x00, 0x01, uint8_t(argument & 0xff) });
            return;

        case CMD_APP_CMD:
            app_cmd_ = true;
            respond({ initialised_ && ready_ ? R1_READY : R1_IDLE });
            return;

        case ACMD_SEND_OP_COND:
            if (!app) {
                respond({ R1_ILLEGAL_COMMAND });
                return;
            }

            // Real cards take a while to leave idle, so make the host loop
            if (acmd41_count_++ < 1) {
                respond({ R1_IDLE });
                return;
            }

            ready_ = true;
            respond({ R1_READY });
            return;

        case CMD_READ_OCR:
            // CCS set, this is a high capacity card and addresses are blocks
            respond({ ready_ ? R1_READY : R1_IDLE, 0xc0, 0xff, 0x80, 0x00 });
            return;

        case CMD_SET_BLOCKLEN:
            respond({ ready_ ? R1_READY : R1_IDLE });
            return;

        case CMD_READ_SINGLE_BLOCK: {
            if (!ready_) {
                respond({ R1_ILLEGAL_COMMAND | R1_IDLE });
                return;
            }

            uint64_t base = uint64_t(argument) * BLOCK_BYTES;

            if (base + BLOCK_BYTES > MEMORY_SIZE) {
                respond({ R1_READY, 0x08 });  // data error token, out of range
                return;
            }

            std::vector<uint8_t> block(BLOCK_BYTES);

            for (uint32_t i = 0; i < BLOCK_BYTES; ++i) {
                block[i] = memory_.read_byte(uint32_t(base) + i);
            }

            std::vector<uint8_t> reply;
            reply.push_back(R1_READY);

            for (unsigned i = 0; i < READ_ACCESS_BYTES; ++i) {
                reply.push_back(0xff);
            }

            reply.push_back(DATA_TOKEN);
            reply.insert(reply.end(), block.begin(), block.end());

            uint16_t crc16 = crc16_ccitt(block.data(), block.size());
            reply.push_back(uint8_t(crc16 >> 8));
            reply.push_back(uint8_t(crc16));

            respond(reply);
            return;
        }

        default:
            respond({ R1_ILLEGAL_COMMAND });
            return;
    }
}

void SdCard::update() {
    bool core_clock = top_.clk_i != 0;

    if (core_clock && !core_clock_) {
        advance_delay();
    }

    core_clock_ = core_clock;

    bool selected = dut::qspi_selected(top_, CS_INDEX);
    bool clock = dut::qspi_sck(top_);

    if (!selected) {
        selected_ = false;

        // Clocks on another chip select still reach the card, that is how init works
        if (clock != clock_ && clock) {
            ++idle_clocks_;
        }

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
        } else {
            present_bit();
        }
    }
}
