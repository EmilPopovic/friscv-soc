#include "axi_mem.hpp"

#include <stdexcept>

AxiMem::AxiMem(Dut& top) : top_(top), memory_(0, MEMORY_SIZE) {
    drive();
}

void AxiMem::preload(uint32_t address, const std::vector<uint8_t>& data) {
    for (size_t offset = 0; offset < data.size(); ++offset) {
        uint32_t byte_address = address + uint32_t(offset);

        if (!memory_.in_range(byte_address)) {
            throw std::runtime_error("AXI memory preload is out of range");
        }

        memory_.write_byte(byte_address, data[offset]);
    }
}

uint32_t AxiMem::read_word(uint32_t address) {
    uint32_t base = (address & (MEMORY_SIZE - 1)) & ~uint32_t(3);
    uint32_t value = 0;

    for (unsigned i = 0; i < 4; ++i) {
        value |= uint32_t(memory_.read_byte(base + i)) << (8 * i);
    }

    return value;
}

void AxiMem::write_word(uint32_t address, uint32_t data, unsigned strb) {
    uint32_t base = (address & (MEMORY_SIZE - 1)) & ~uint32_t(3);

    for (unsigned i = 0; i < 4; ++i) {
        if (((strb >> i) & 1) != 0) {
            memory_.write_byte(base + i, uint8_t(data >> (8 * i)));
        }
    }
}

void AxiMem::capture() {
    sample_.aw_valid = top_.o_axi_aw_valid != 0;
    sample_.aw_addr  = top_.o_axi_aw_addr;
    sample_.aw_len   = top_.o_axi_aw_len;
    sample_.aw_size  = top_.o_axi_aw_size;
    sample_.aw_id    = top_.o_axi_aw_id != 0;

    sample_.w_valid = top_.o_axi_w_valid != 0;
    sample_.w_data  = top_.o_axi_w_data;
    sample_.w_strb  = top_.o_axi_w_strb;
    sample_.w_last  = top_.o_axi_w_last != 0;

    sample_.b_ready = top_.o_axi_b_ready != 0;

    sample_.ar_valid = top_.o_axi_ar_valid != 0;
    sample_.ar_addr  = top_.o_axi_ar_addr;
    sample_.ar_len   = top_.o_axi_ar_len;
    sample_.ar_size  = top_.o_axi_ar_size;
    sample_.ar_id    = top_.o_axi_ar_id != 0;

    sample_.r_ready = top_.o_axi_r_ready != 0;
}

void AxiMem::drive() {
    top_.i_axi_aw_ready = aw_ready_ ? 1 : 0;
    top_.i_axi_w_ready  = w_ready_ ? 1 : 0;

    top_.i_axi_b_valid = b_valid_ ? 1 : 0;
    top_.i_axi_b_resp  = 0;
    top_.i_axi_b_id    = b_id_ ? 1 : 0;

    top_.i_axi_ar_ready = ar_ready_ ? 1 : 0;

    top_.i_axi_r_valid = r_valid_ ? 1 : 0;
    top_.i_axi_r_data  = r_data_;
    top_.i_axi_r_resp  = 0;
    top_.i_axi_r_last  = r_last_ ? 1 : 0;
    top_.i_axi_r_id    = r_id_ ? 1 : 0;
}

void AxiMem::process() {
    const bool aw_ready = aw_ready_;
    const bool w_ready = w_ready_;
    const bool b_valid = b_valid_;
    const bool ar_ready = ar_ready_;
    const bool r_valid = r_valid_;
    const bool r_last = r_last_;

    if (b_valid && sample_.b_ready) {
        b_valid_ = false;
        aw_ready_ = true;
    }

    if (r_valid && sample_.r_ready) {
        if (r_last) {
            r_valid_ = false;
            r_last_ = false;
            ar_ready_ = true;
        } else {
            read_address_ += 1u << read_size_;
            --read_beats_;
            r_data_ = read_word(read_address_);
            r_last_ = read_beats_ == 1;
        }
    }

    if (w_ready && sample_.w_valid) {
        write_word(write_address_, sample_.w_data, sample_.w_strb);
        write_address_ += 1u << write_size_;

        if (sample_.w_last) {
            w_ready_ = false;
            b_valid_ = true;
        }
    }

    if (aw_ready && sample_.aw_valid) {
        write_address_ = sample_.aw_addr;
        write_size_ = sample_.aw_size;
        b_id_ = sample_.aw_id;
        aw_ready_ = false;
        w_ready_ = true;
    }

    if (ar_ready && sample_.ar_valid) {
        read_address_ = sample_.ar_addr;
        read_size_ = sample_.ar_size;
        read_beats_ = sample_.ar_len + 1;
        r_id_ = sample_.ar_id;
        r_data_ = read_word(read_address_);
        r_last_ = read_beats_ == 1;
        r_valid_ = true;
        ar_ready_ = false;
    }
}

void AxiMem::update() {
    bool clock = top_.i_clk != 0;

    if (clock == clock_) {
        return;
    }

    clock_ = clock;

    if (clock) {
        return;
    }

    capture();
    drive();
    process();
}
