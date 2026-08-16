# Contributing

## Style Guide

This project adheres to the [lowRISC Verilog Coding Style Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md), with the following exceptions:

- Non-ASCII characters may be used in the author list under the license banner.
- PULP-style module instantiation must be used instead of lowRISC-style:

    ```systemverilog
    example_module #(
        .SomeParam  ( '0         ),
        .OtherParam ( OtherParam )
    ) i_my_example (
        .clk_i,
        .rst_ni,
        .some_very_very_long_signal_name,
        .normal_signal_i ( some_normal_signal ),
        .short_o         ( short_name         )
    );
    ```

- Code indentation must use four spaces, instead of two. Tabs must not be used.
- Names of combinatorial signals may be prefixed with `w_`.
- Names of registered signals may be prefixed with `r_`.
- It is not recommended to indent the first level of code:

    ```systemverilog
    module example (
        input  logic clk_i,
        output logic result_o
    );

    // Code goes here
    logic some_signal;

        // Not here!
        logic not_here;
    ```
