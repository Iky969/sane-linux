# S.A.N.E Linux Boot Verification Report

- **Timestamp**: 2026-11-14 14:44:26 UTC
- **Test Mode**: `all`
- **Overall Result**: **PASS** (Exit code: 0)
- **Disk Image**: `sane.img` (53M, 536870912 bytes)
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
- **switch_root to /dev/vda2**: 3462 ms
- **ninit PID 1 startup banner**: 3581 ms
- **ninit main loop ready**: 3702 ms
- **Service execution (sane-hello / console)**: 3588 ms
- **Kernel panic check**: Zero panics (OK)

### UEFI Boot Verification
- **Status**: `PASS`
- **switch_root to /dev/vda2**: 4618 ms
- **ninit PID 1 startup banner**: 4855 ms
- **ninit main loop ready**: 4975 ms
- **Service execution (sane-hello / console)**: 4861 ms
- **Kernel panic check**: Zero panics (OK)

## Console Logs
- BIOS Console Log: [`qemu-image-console-bios.log`](./qemu-image-console-bios.log)
- UEFI Console Log: [`qemu-image-console-uefi.log`](./qemu-image-console-uefi.log)
