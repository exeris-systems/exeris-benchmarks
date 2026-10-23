# Kernel profile `20261022T044235Z-h84b7f398c0dd`

seed=1792644155 harness=84b7f398c0dd0dda7fe72bb7f3de4555ffe079d5 rate=52200 reps=3
boot_id=2f8c9ae1-683c-4a61-9e99-21dfda106432 uptime_s=535

- **state**: uptime 0.2–0.3 h; clean `A_iso` p99 2.45, 2.46, 2.47 ms (n = 3); carrier CPU 119.90 %, sys 79.80 %, wait 0.10 %
  - host counters at window start (median): conntrack_count —, cgroup_dying_root 174, cgroup_dying_bench_slice 1, slab_kb 595772, sunreclaim_kb 224928, tcp_sockets 387, tcp_timewait 179

## `A_iso`, profiled (n = 3): kernel 71.1 % of carrier-CPU samples

| symbol | kind | % of samples |
|:--|:--|--:|
| `entry_SYSRETQ_unsafe_stack` | kernel | 5.00 |
| `srso_alias_safe_ret` | kernel | 1.72 |
| `srso_alias_return_thunk` | kernel | 1.67 |
| `0x0000000000000a06` | user | 1.50 |
| `__tcp_transmit_skb` | kernel | 1.36 |
| `tcp_v4_rcv` | kernel | 1.13 |
| `native_write_msr` | kernel | 1.11 |
| `tcp_ack` | kernel | 1.06 |
| `tcp_sendmsg_locked` | kernel | 1.04 |
| `entry_SYSCALL_64` | kernel | 0.97 |
| `__mod_timer` | kernel | 0.97 |
| `tcp_rcv_established` | kernel | 0.94 |
| `tcp_write_xmit` | kernel | 0.93 |
| `tcp_clean_rtx_queue` | kernel | 0.89 |
| `do_syscall_64` | kernel | 0.80 |
| `__pi__text` | kernel | 0.75 |
| `do_epoll_ctl` | kernel | 0.71 |
| `process_backlog` | kernel | 0.70 |
| `__ip_queue_xmit` | kernel | 0.69 |
| `net_rx_action` | kernel | 0.67 |
| `native_read_msr` | kernel | 0.63 |
| `read_tsc` | kernel | 0.62 |
| `ep_poll_callback` | kernel | 0.61 |
| `__pi_memset` | kernel | 0.60 |
| `__dev_queue_xmit` | kernel | 0.56 |

## `D`, profiled (n = 3): kernel 73.9 % of carrier-CPU samples

| symbol | kind | % of samples |
|:--|:--|--:|
| `entry_SYSRETQ_unsafe_stack` | kernel | 5.07 |
| `0x0000000000000a06` | user | 1.90 |
| `srso_alias_safe_ret` | kernel | 1.73 |
| `srso_alias_return_thunk` | kernel | 1.56 |
| `__tcp_transmit_skb` | kernel | 1.37 |
| `native_write_msr` | kernel | 1.32 |
| `tcp_sendmsg_locked` | kernel | 1.12 |
| `tcp_v4_rcv` | kernel | 1.09 |
| `tcp_ack` | kernel | 1.07 |
| `tcp_write_xmit` | kernel | 0.93 |
| `__mod_timer` | kernel | 0.92 |
| `tcp_rcv_established` | kernel | 0.92 |
| `tcp_clean_rtx_queue` | kernel | 0.90 |
| `entry_SYSCALL_64` | kernel | 0.86 |
| `do_syscall_64` | kernel | 0.77 |
| `__pi__text` | kernel | 0.76 |
| `process_backlog` | kernel | 0.72 |
| `do_epoll_ctl` | kernel | 0.72 |
| `net_rx_action` | kernel | 0.71 |
| `native_read_msr` | kernel | 0.70 |
| `__ip_queue_xmit` | kernel | 0.70 |
| `read_tsc` | kernel | 0.65 |
| `__pi_memset` | kernel | 0.63 |
| `native_queued_spin_lock_slowpath` | kernel | 0.59 |
| `ep_poll_callback` | kernel | 0.59 |

