# Kernel profile `20261022T194321Z-h84b7f398c0dd`

seed=1792698201 harness=84b7f398c0dd0dda7fe72bb7f3de4555ffe079d5 rate=52200 reps=3
boot_id=2f8c9ae1-683c-4a61-9e99-21dfda106432 uptime_s=54581

- **state**: uptime 15.2–15.3 h; clean `A_iso` p99 10.06, 48.80, 84.54 ms (n = 3); carrier CPU 127.80 %, sys 89.27 %, wait 1.30 %
  - host counters at window start (median): conntrack_count 582, cgroup_dying_root 132, cgroup_dying_bench_slice 1, slab_kb 1297796, sunreclaim_kb 487748, tcp_sockets 577, tcp_timewait 161

## `A_iso`, profiled (n = 3): kernel 73.0 % of carrier-CPU samples

| symbol | kind | % of samples |
|:--|:--|--:|
| `entry_SYSRETQ_unsafe_stack` | kernel | 4.64 |
| `srso_alias_safe_ret` | kernel | 1.72 |
| `srso_alias_return_thunk` | kernel | 1.58 |
| `0x0000000000000a06` | user | 1.48 |
| `ipt_do_table` | kernel | 1.41 |
| `__tcp_transmit_skb` | kernel | 1.31 |
| `tcp_v4_rcv` | kernel | 1.07 |
| `tcp_sendmsg_locked` | kernel | 1.03 |
| `nf_hook_slow` | kernel | 1.02 |
| `tcp_ack` | kernel | 0.98 |
| `tcp_write_xmit` | kernel | 0.92 |
| `tcp_clean_rtx_queue` | kernel | 0.91 |
| `__mod_timer` | kernel | 0.91 |
| `tcp_rcv_established` | kernel | 0.90 |
| `native_write_msr` | kernel | 0.87 |
| `entry_SYSCALL_64` | kernel | 0.80 |
| `do_syscall_64` | kernel | 0.75 |
| `__pi__text` | kernel | 0.73 |
| `ep_poll_callback` | kernel | 0.71 |
| `do_epoll_ctl` | kernel | 0.66 |
| `process_backlog` | kernel | 0.65 |
| `net_rx_action` | kernel | 0.63 |
| `__ip_queue_xmit` | kernel | 0.62 |
| `read_tsc` | kernel | 0.61 |
| `native_queued_spin_lock_slowpath` | kernel | 0.59 |

## `D`, profiled (n = 3): kernel 75.6 % of carrier-CPU samples

| symbol | kind | % of samples |
|:--|:--|--:|
| `entry_SYSRETQ_unsafe_stack` | kernel | 4.57 |
| `srso_alias_safe_ret` | kernel | 1.74 |
| `0x0000000000000a06` | user | 1.66 |
| `srso_alias_return_thunk` | kernel | 1.58 |
| `ipt_do_table` | kernel | 1.40 |
| `__tcp_transmit_skb` | kernel | 1.31 |
| `tcp_sendmsg_locked` | kernel | 1.08 |
| `native_write_msr` | kernel | 1.06 |
| `tcp_v4_rcv` | kernel | 1.04 |
| `tcp_ack` | kernel | 1.03 |
| `nf_hook_slow` | kernel | 1.03 |
| `__mod_timer` | kernel | 0.94 |
| `tcp_rcv_established` | kernel | 0.94 |
| `tcp_clean_rtx_queue` | kernel | 0.93 |
| `tcp_write_xmit` | kernel | 0.90 |
| `entry_SYSCALL_64` | kernel | 0.77 |
| `__pi__text` | kernel | 0.74 |
| `do_syscall_64` | kernel | 0.73 |
| `do_epoll_ctl` | kernel | 0.67 |
| `ep_poll_callback` | kernel | 0.66 |
| `process_backlog` | kernel | 0.64 |
| `net_rx_action` | kernel | 0.63 |
| `__ip_queue_xmit` | kernel | 0.63 |
| `read_tsc` | kernel | 0.62 |
| `__pi_memset` | kernel | 0.59 |

