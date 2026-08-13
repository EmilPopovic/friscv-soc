# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Emil Popović <mail@emilpopovic.me>

def red(s) -> str:          return f"\033[91m{s}\033[00m"
def green(s) -> str:        return f"\033[92m{s}\033[00m"
def yellow(s) -> str:       return f"\033[93m{s}\033[00m"
def light_purple(s) -> str: return f"\033[94m{s}\033[00m"
def purple(s) -> str:       return f"\033[95m{s}\033[00m"
def cyan(s) -> str:         return f"\033[96m{s}\033[00m"
def light_gray(s) -> str:   return f"\033[97m{s}\033[00m"
def black(s) -> str:        return f"\033[90m{s}\033[00m"
