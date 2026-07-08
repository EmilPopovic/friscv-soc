TOP = friscv_cpu_verilator

all:
	verilator --cc --exe --build -j 0 --top-module $(TOP) \
		-F ../../friscv.f $(wildcard cpp/*.cpp) -o $(TOP)

clean:
	rm -rf obj_dir

.PHONY: all clean
