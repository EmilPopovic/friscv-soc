#pragma once

#include <cstdint>

#include "Vfriscv_soc.h"
#include "hyperram.hpp"

class SocTestbench {
  public:
    SocTestbench();
    ~SocTestbench();

    Vfriscv_soc& top() { return top_; }

    void reset();
    void run_cycles(uint64_t count);

  private:
    void eval();

    Vfriscv_soc top_;
    Hyperram hyperram_;
};
