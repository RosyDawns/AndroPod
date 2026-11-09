"""AndroPod engine — VM orchestration layer.

This package owns the lifecycle of guest VMs. It never links against QEMU;
it spawns `qemu-system-aarch64` as a child process and drives it over QMP.
That process boundary is the GPLv2 boundary described in docs/01-license-boundary.md.
"""

__version__ = "0.1.0"
