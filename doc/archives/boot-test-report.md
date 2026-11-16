# S.A.N.E Linux Boot Verification Report

- **Timestamp**: 2026-11-16 15:03:55 UTC
- **Test Mode**: `all`
- **Overall Result**: **PASS** (Exit code: 0)
- **Disk Image**: `sane.img` (80M, 536870912 bytes)
- **QEMU Acceleration**: `-cpu max`
- **UEFI Firmware**: `/usr/share/ovmf/OVMF.fd`

## Test Summary

| Test Mode | Status | Details |
| :--- | :--- | :--- |
| **BIOS Boot** | `PASS` | All boot pipeline markers verified |
| **UEFI Boot** | `PASS` | All boot pipeline markers verified |

## Milestone Check Timings

### BIOS Boot Verification
- **Status**: `PASS`
- **switch_root to /dev/vda2**: 3870 ms
- **ninit PID 1 startup banner**: 3988 ms
- **ninit main loop ready**: 4108 ms
- **Service execution (sane-hello / console)**: 4114 ms
- **Kernel panic check**: Zero panics (OK)

### UEFI Boot Verification
- **Status**: `PASS`
- **switch_root to /dev/vda2**: 5172 ms
- **ninit PID 1 startup banner**: 5405 ms
- **ninit main loop ready**: 5411 ms
- **Service execution (sane-hello / console)**: 5416 ms
- **Kernel panic check**: Zero panics (OK)

## Console Logs
- BIOS Console Log: [`qemu-image-console-bios.log`](./qemu-image-console-bios.log)
- UEFI Console Log: [`qemu-image-console-uefi.log`](./qemu-image-console-uefi.log)
