// Copyright 2026 FER, HPC Architecture and Application Research Center
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Matej Jurasić <matej.jurasic@cappig.dev>
// Emil Popović <mail@emilpopovic.me>

#pragma once

#include <cstdint>

#include "dut.hpp"
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
    Dut& top_;
};
