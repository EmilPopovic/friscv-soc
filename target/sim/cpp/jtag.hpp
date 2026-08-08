#pragma once

#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <vector>

#include "dut.hpp"
class SocTestbench;

class Jtag {
  public:
    explicit Jtag(SocTestbench& testbench);

    void initialize();
    void reset_soc();
    void halt();
    void resume();

    std::vector<uint8_t> read_memory(uint32_t address, size_t size);
    void write_memory(uint32_t address, const std::vector<uint8_t>& data);

  private:
    bool pulse(bool tms, bool tdi);
    void move_tap(std::initializer_list<bool> path);
    void idle(unsigned cycles);
    uint64_t shift_bits(uint64_t data, unsigned size);
    void shift_ir(uint8_t instruction);
    uint64_t shift_dr(uint64_t data, unsigned size);

    uint32_t dmi_access(uint8_t address, uint32_t data, uint8_t operation);
    uint32_t dmi_read(uint8_t address);
    void dmi_write(uint8_t address, uint32_t data);
    void reset_dmi();
    void wait_dmstatus(uint32_t mask);

    uint32_t sba_read(uint32_t address, uint8_t access);
    void sba_write(uint32_t address, uint32_t data, uint8_t access);
    void wait_sba();

    SocTestbench& testbench_;
    Dut& top_;
};
