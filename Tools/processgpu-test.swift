//
//  processgpu-test.swift
//
//  Exercises how the GPU popup's process list reads the IORegistry: who a
//  client belongs to, how much GPU time it reports, and the rate between two
//  samples.
//
//  Run:  cat Roost/Monitor/ProcessGPU.swift Tools/processgpu-test.swift | swift -
//
//  The keys are undocumented, so the failures worth catching are the quiet
//  ones: a pid of 0 offered to the quit menu, a driver that does not report
//  GPU time read as an idle GPU, and a counter that went backwards read as a
//  huge positive rate.
//
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "  ok   \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

// MARK: - Who a client belongs to

print("ProcessGPU.creator")

let window = ProcessGPU.creator("pid 421, WindowServer")
check("reads the pid", window?.pid == 421)
check("and the name", window?.name == "WindowServer")

// The kernel's short process name is cut at sixteen characters, and may hold
// commas of its own: only the first one separates.
let helper = ProcessGPU.creator("pid 19190, Orca Helper, GPU")
check("a name with a comma keeps the rest", helper?.name == "Orca Helper, GPU")

check("no name still gives the pid", ProcessGPU.creator("pid 7")?.pid == 7)
check("pid 0 is the kernel, not a process to quit",
      ProcessGPU.creator("pid 0, kernel_task") == nil)
check("a negative pid is refused", ProcessGPU.creator("pid -1, x") == nil)
check("text in another shape is refused", ProcessGPU.creator("WindowServer") == nil)
check("an empty string is refused", ProcessGPU.creator("") == nil)
check("a pid that is not a number is refused", ProcessGPU.creator("pid abc, x") == nil)

// MARK: - GPU time in a client

print("\nProcessGPU.gpuTime")

let queues: [[String: Any]] = [
    ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 8_352_019_036_750 as UInt64)],
    ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 8_249_541 as UInt64)],
    ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 0 as UInt64)]
]
check("sums every queue", ProcessGPU.gpuTime(queues) == 8_352_027_286_291)
check("a client with no queues has used no GPU", ProcessGPU.gpuTime([]) == 0)

// The case the dash exists for: a driver whose queues carry no time under
// any spelling known here. Zero would read as an idle GPU.
let unspelled: [[String: Any]] = [["API": "Metal", "somethingElse": NSNumber(value: 5)]]
check("queues without a known key are not a zero", ProcessGPU.gpuTime(unspelled) == nil)

let mixed: [[String: Any]] = [["API": "Metal"],
                              ["API": "Metal", "accumulatedGPUTime": NSNumber(value: 40)]]
check("a queue without the key is skipped, not fatal", ProcessGPU.gpuTime(mixed) == 40)

// MARK: - The rate

print("\nProcessGPU.percent")

check("a full second of GPU time in a second is 100%",
      ProcessGPU.percent(before: 0, after: 1_000_000_000, elapsed: 1) == 100)
check("a quarter of a second over two seconds is 12.5%",
      ProcessGPU.percent(before: 5_000_000_000, after: 5_250_000_000, elapsed: 2) == 12.5)
check("no change is 0%", ProcessGPU.percent(before: 7, after: 7, elapsed: 1) == 0)
check("no time passed gives no rate",
      ProcessGPU.percent(before: 0, after: 100, elapsed: 0) == nil)
check("a counter that went backwards is a different client, not a rate",
      ProcessGPU.percent(before: 900, after: 100, elapsed: 1) == nil)

// MARK: - This Mac

// Not an assertion about this Mac's GPU, which a CI runner may not have:
// only that reading the registry live returns rather than traps.
print("\nProcessGPU.census (live)")
let found = ProcessGPU.census()
check("timed clients are a subset of clients", found.timed <= found.clients)
print("  ·    \(found.clients) GPU clients, \(found.timed) reporting GPU time")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
