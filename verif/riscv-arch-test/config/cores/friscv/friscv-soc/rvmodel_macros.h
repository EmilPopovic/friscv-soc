#ifndef _RVMODEL_SOC_MACROS_H
#define _RVMODEL_SOC_MACROS_H

#include "../friscv-full/rvmodel_macros.h"

#undef RVMODEL_IO_INIT
#undef RVMODEL_IO_WRITE_STR

#define RVMODEL_IO_INIT(_R1, _R2, _R3)
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

#endif
