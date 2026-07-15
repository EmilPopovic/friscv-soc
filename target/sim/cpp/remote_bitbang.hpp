#pragma once

#include <cstdint>

class Vfriscv_soc;
class SocTestbench;

class RemoteBitbang {
  public:
    static constexpr uint16_t DEFAULT_PORT = 9824;

    explicit RemoteBitbang(SocTestbench& testbench);

    void serve(uint16_t port);

  private:
    void set_pins(char command);
    void reset(char command);

    SocTestbench& testbench_;
    Vfriscv_soc& top_;
};
