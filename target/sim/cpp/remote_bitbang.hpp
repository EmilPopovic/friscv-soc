#pragma once

#include <cstdint>

class Vfriscv_soc;

class RemoteBitbang {
  public:
    static constexpr uint16_t DEFAULT_PORT = 9824;

    explicit RemoteBitbang(Vfriscv_soc& top) : top_(top) {}

    void serve(uint16_t port);

  private:
    void set_pins(char command);
    void reset(char command);
    void run_cycles(uint64_t count);

    Vfriscv_soc& top_;
};
