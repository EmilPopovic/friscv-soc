# Core-level Simulation

This document describes the contents of `target/sim/cpp/` and `tb_core_main.cpp`.
The purpose of the core-level simulation is to test the functionality of the
core without relying on any particular system, such as running `riscv-arch-test`.

The C++ testbench instantiates a bare FRISC-V CPU Subsystem (in a wrapper -
`traget/sim/rtl/friscv_cpu_verilator.sv`) and drives the system side from C++.

The harness consists of an RTL core, and a virtual bus router and peripherals,
where each device attached to the bus is a `BusDevice` which drives an output
interface every cycle (from a `void cycle (...)` method).

```cpp
class BusDevice {
  public:
    uint32_t rdata      = 0;
    bool     wait       = false;
    bool     beat_valid = false;
    bool     err        = false;
    virtual ~BusDevice() = default;
    virtual void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
                       bool w_en, bool r_en, bool burst_en) = 0;
};
```

A `BusRouter` is a special device that delegates transfers to child devices.
It grants the bus to a requested device (owner) for the duration of the
transfer, and does not allow switching until the responder deasserts `wait`.

```cpp
class BusRouter : public BusDevice {
  public:
    void map(uint32_t base, uint32_t size, BusDevice* dev);
    void cycle(uint8_t size, uint32_t offset, uint32_t wdata,
               bool w_en, bool r_en, bool burst_en) override;
  private:
    struct Mapping {
        uint32_t base;
        uint32_t size;
        BusDevice* dev;
    };
    std::vector<Mapping> address_map;
    BusDevice* owner = nullptr;
    uint32_t owner_base = 0;
};
```

It can be configured with any number of responders:

```cpp
MemModel       dram(&mem_pool, MEM_WAIT_CYCLES);
Uart16550Model uart;
SinkDevice     gpio, halt_sink;
// ...
BusRouter      bus;

bus.map(MEM_BASE_ADDR,  MEM_SIZE, &dram);
bus.map(UART_BASE_ADDR, 0x20,     &uart);
bus.map(GPIO_BASE_ADDR, 4,        &gpio);
bus.map(HALT_BASE_ADDR, 4,        &halt_sink);
// ...
```
