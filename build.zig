const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create modules
    const types_mod = b.addModule("types", .{
        .root_source_file = b.path("src/types/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const crypto_mod = b.addModule("crypto", .{
        .root_source_file = b.path("src/crypto/crypto.zig"),
        .target = target,
        .optimize = optimize,
    });

    const rlp_mod = b.addModule("rlp", .{
        .root_source_file = b.path("src/rlp/rlp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const state_mod = b.addModule("state", .{
        .root_source_file = b.path("src/state/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_mod.addImport("types", types_mod);
    state_mod.addImport("crypto", crypto_mod);
    state_mod.addImport("rlp", rlp_mod);

    const evm_mod = b.addModule("evm", .{
        .root_source_file = b.path("src/evm/evm.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_mod.addImport("types", types_mod);
    evm_mod.addImport("crypto", crypto_mod);
    evm_mod.addImport("state", state_mod);

    const transaction_mod = b.addModule("transaction", .{
        .root_source_file = b.path("src/evm/transaction.zig"),
        .target = target,
        .optimize = optimize,
    });
    transaction_mod.addImport("types", types_mod);
    transaction_mod.addImport("crypto", crypto_mod);
    transaction_mod.addImport("state", state_mod);
    transaction_mod.addImport("evm", evm_mod);

    const sim_mod = b.addModule("sim", .{
        .root_source_file = b.path("src/sim.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_mod.addImport("evm", evm_mod);
    sim_mod.addImport("types", types_mod);
    sim_mod.addImport("state", state_mod);

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("types", types_mod);
    exe_mod.addImport("crypto", crypto_mod);
    exe_mod.addImport("rlp", rlp_mod);
    exe_mod.addImport("evm", evm_mod);
    exe_mod.addImport("state", state_mod);

    const exe = b.addExecutable(.{
        .name = "zeth",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the Ethereum node");
    run_step.dependOn(&run_cmd.step);

    // Examples
    const counter_mod = b.createModule(.{
        .root_source_file = b.path("examples/counter.zig"),
        .target = target,
        .optimize = optimize,
    });
    counter_mod.addImport("types", types_mod);
    counter_mod.addImport("crypto", crypto_mod);
    counter_mod.addImport("evm", evm_mod);

    const counter_exe = b.addExecutable(.{
        .name = "counter",
        .root_module = counter_mod,
    });
    b.installArtifact(counter_exe);

    const counter_run = b.addRunArtifact(counter_exe);
    const counter_step = b.step("run-counter", "Run the counter example");
    counter_step.dependOn(&counter_run.step);

    // Storage example
    const storage_mod = b.createModule(.{
        .root_source_file = b.path("examples/storage.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_mod.addImport("types", types_mod);
    storage_mod.addImport("crypto", crypto_mod);
    storage_mod.addImport("evm", evm_mod);

    const storage_exe = b.addExecutable(.{
        .name = "storage",
        .root_module = storage_mod,
    });
    b.installArtifact(storage_exe);

    const storage_run = b.addRunArtifact(storage_exe);
    const storage_step = b.step("run-storage", "Run the storage example");
    storage_step.dependOn(&storage_run.step);

    // Arithmetic example
    const arithmetic_mod = b.createModule(.{
        .root_source_file = b.path("examples/arithmetic.zig"),
        .target = target,
        .optimize = optimize,
    });
    arithmetic_mod.addImport("types", types_mod);
    arithmetic_mod.addImport("crypto", crypto_mod);
    arithmetic_mod.addImport("evm", evm_mod);

    const arithmetic_exe = b.addExecutable(.{
        .name = "arithmetic",
        .root_module = arithmetic_mod,
    });
    b.installArtifact(arithmetic_exe);

    const arithmetic_run = b.addRunArtifact(arithmetic_exe);
    const arithmetic_step = b.step("run-arithmetic", "Run the arithmetic example");
    arithmetic_step.dependOn(&arithmetic_run.step);

    // Events example
    const events_mod = b.createModule(.{
        .root_source_file = b.path("examples/events.zig"),
        .target = target,
        .optimize = optimize,
    });
    events_mod.addImport("types", types_mod);
    events_mod.addImport("crypto", crypto_mod);
    events_mod.addImport("evm", evm_mod);

    const events_exe = b.addExecutable(.{
        .name = "events",
        .root_module = events_mod,
    });
    b.installArtifact(events_exe);

    const events_run = b.addRunArtifact(events_exe);
    const events_step = b.step("run-events", "Run the events example");
    events_step.dependOn(&events_run.step);

    // Benchmarks
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/benchmarks.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Optimize benchmarks
    });
    bench_mod.addImport("types", types_mod);
    bench_mod.addImport("crypto", crypto_mod);
    bench_mod.addImport("evm", evm_mod);
    bench_mod.addImport("state", state_mod);

    const bench_exe = b.addExecutable(.{
        .name = "benchmarks",
        .root_module = bench_mod,
    });
    b.installArtifact(bench_exe);

    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_run.step);

    // Validation against Ethereum tests
    const rlp_validator_mod = b.createModule(.{
        .root_source_file = b.path("validation/rlp_validator.zig"),
        .target = target,
        .optimize = optimize,
    });
    rlp_validator_mod.addImport("rlp", rlp_mod);

    const rlp_validator_exe = b.addExecutable(.{
        .name = "rlp_validator",
        .root_module = rlp_validator_mod,
    });
    b.installArtifact(rlp_validator_exe);

    const rlp_validator_run = b.addRunArtifact(rlp_validator_exe);
    const validate_rlp_step = b.step("validate-rlp", "Validate RLP encoding against Ethereum");
    validate_rlp_step.dependOn(&rlp_validator_run.step);

    // RLP Decoding Validator
    const rlp_decode_validator_mod = b.createModule(.{
        .root_source_file = b.path("validation/rlp_decode_validator.zig"),
        .target = target,
        .optimize = optimize,
    });
    rlp_decode_validator_mod.addImport("rlp", rlp_mod);

    const rlp_decode_validator_exe = b.addExecutable(.{
        .name = "rlp_decode_validator",
        .root_module = rlp_decode_validator_mod,
    });
    b.installArtifact(rlp_decode_validator_exe);

    const rlp_decode_validator_run = b.addRunArtifact(rlp_decode_validator_exe);
    const validate_rlp_decode_step = b.step("validate-rlp-decode", "Validate RLP decoding against Ethereum");
    validate_rlp_decode_step.dependOn(&rlp_decode_validator_run.step);

    // Invalid RLP Validator
    const rlp_invalid_validator_mod = b.createModule(.{
        .root_source_file = b.path("validation/rlp_invalid_validator.zig"),
        .target = target,
        .optimize = optimize,
    });
    rlp_invalid_validator_mod.addImport("rlp", rlp_mod);

    const rlp_invalid_validator_exe = b.addExecutable(.{
        .name = "rlp_invalid_validator",
        .root_module = rlp_invalid_validator_mod,
    });
    b.installArtifact(rlp_invalid_validator_exe);

    const rlp_invalid_validator_run = b.addRunArtifact(rlp_invalid_validator_exe);
    const validate_rlp_invalid_step = b.step("validate-rlp-invalid", "Test invalid RLP rejection");
    validate_rlp_invalid_step.dependOn(&rlp_invalid_validator_run.step);

    // VMTests runner (ethereum consensus tests)
    const vm_test_runner_mod = b.createModule(.{
        .root_source_file = b.path("validation/vm_test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    vm_test_runner_mod.addImport("evm", evm_mod);
    vm_test_runner_mod.addImport("types", types_mod);
    vm_test_runner_mod.addImport("state", state_mod);

    const vm_test_runner_exe = b.addExecutable(.{
        .name = "vm_test_runner",
        .root_module = vm_test_runner_mod,
    });
    b.installArtifact(vm_test_runner_exe);

    const vm_test_runner_run = b.addRunArtifact(vm_test_runner_exe);
    if (b.args) |args| {
        vm_test_runner_run.addArgs(args);
    }
    const validate_vm_step = b.step("validate-vm", "Run Ethereum VMTests (requires ethereum-tests clone)");
    validate_vm_step.dependOn(&vm_test_runner_run.step);

    // Vector pipeline: convert VMTests to vectors, run regression
    const vector_runner_mod = b.createModule(.{
        .root_source_file = b.path("validation/vector_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    vector_runner_mod.addImport("evm", evm_mod);
    vector_runner_mod.addImport("types", types_mod);

    const vector_runner_exe = b.addExecutable(.{
        .name = "vector_runner",
        .root_module = vector_runner_mod,
    });
    b.installArtifact(vector_runner_exe);

    const vector_runner_run = b.addRunArtifact(vector_runner_exe);
    if (b.args) |args| vector_runner_run.addArgs(args);
    const vector_run_step = b.step("vector-run", "Run test vector regression (usage: zig build vector-run -- path/to/vectors.json)");
    vector_run_step.dependOn(&vector_runner_run.step);

    const regression_gate_mod = b.createModule(.{
        .root_source_file = b.path("validation/regression_gate.zig"),
        .target = target,
        .optimize = optimize,
    });
    const regression_gate_exe = b.addExecutable(.{
        .name = "regression_gate",
        .root_module = regression_gate_mod,
    });
    b.installArtifact(regression_gate_exe);
    const regression_gate_run = b.addRunArtifact(regression_gate_exe);
    if (b.args) |args| regression_gate_run.addArgs(args);
    const regression_gate_step = b.step("regression-gate", "Check discrepancy JSON against a baseline");
    regression_gate_step.dependOn(&regression_gate_run.step);

    // Opcode docs generator
    const opcode_docs_mod = b.createModule(.{
        .root_source_file = b.path("scripts/generate_opcode_docs.zig"),
        .target = target,
        .optimize = optimize,
    });
    opcode_docs_mod.addImport("evm", evm_mod);
    const opcode_docs_exe = b.addExecutable(.{
        .name = "opcode_docs",
        .root_module = opcode_docs_mod,
    });
    const opcode_docs_run = b.addRunArtifact(opcode_docs_exe);
    if (b.args) |args| opcode_docs_run.addArgs(args);
    const opcode_docs_step = b.step("opcode-docs", "Generate opcode reference (usage: zig build opcode-docs -- docs/opcodes.md)");
    opcode_docs_step.dependOn(&opcode_docs_run.step);

    // EVMC plugin (shared library for Geth/Reth/Besu)
    const evmc_mod = b.createModule(.{
        .root_source_file = b.path("src/evmc/zeth_evmc.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const evmc_lib = b.addSharedLibrary(.{
        .name = "zeth_evmc",
        .root_module = evmc_mod,
    });
    evmc_lib.rdynamic = true;
    b.installArtifact(evmc_lib);
    const evmc_step = b.step("evmc", "Build EVMC plugin (libzeth_evmc.so/.dylib)");
    evmc_step.dependOn(&b.addInstallArtifact(evmc_lib, .{}).step);

    // Differential fuzzing harness
    // Tests
    const test_step = b.step("test", "Run unit tests");

    // Main tests
    const main_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_test_mod.addImport("types", types_mod);
    main_test_mod.addImport("crypto", crypto_mod);
    main_test_mod.addImport("rlp", rlp_mod);
    main_test_mod.addImport("evm", evm_mod);
    main_test_mod.addImport("state", state_mod);

    const main_tests = b.addTest(.{
        .root_module = main_test_mod,
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Crypto tests
    const crypto_tests = b.addTest(.{
        .root_module = crypto_mod,
    });
    const run_crypto_tests = b.addRunArtifact(crypto_tests);
    test_step.dependOn(&run_crypto_tests.step);

    // RLP tests
    const rlp_tests = b.addTest(.{
        .root_module = rlp_mod,
    });
    const run_rlp_tests = b.addRunArtifact(rlp_tests);
    test_step.dependOn(&run_rlp_tests.step);

    // Types tests
    const types_tests = b.addTest(.{
        .root_module = types_mod,
    });
    const run_types_tests = b.addRunArtifact(types_tests);
    test_step.dependOn(&run_types_tests.step);

    // EVM tests
    const evm_tests = b.addTest(.{
        .root_module = evm_mod,
    });
    const run_evm_tests = b.addRunArtifact(evm_tests);
    test_step.dependOn(&run_evm_tests.step);

    // State tests
    const state_tests = b.addTest(.{
        .root_module = state_mod,
    });
    const run_state_tests = b.addRunArtifact(state_tests);
    test_step.dependOn(&run_state_tests.step);

    // Sim module tests
    const sim_tests = b.addTest(.{
        .root_module = sim_mod,
    });
    const run_sim_tests = b.addRunArtifact(sim_tests);
    test_step.dependOn(&run_sim_tests.step);

    // Comprehensive EVM tests
    const comprehensive_test_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    comprehensive_test_mod.addImport("evm", evm_mod);
    comprehensive_test_mod.addImport("types", types_mod);
    comprehensive_test_mod.addImport("crypto", crypto_mod);
    comprehensive_test_mod.addImport("state", state_mod);

    const comprehensive_tests = b.addTest(.{
        .root_module = comprehensive_test_mod,
    });
    const run_comprehensive_tests = b.addRunArtifact(comprehensive_tests);
    test_step.dependOn(&run_comprehensive_tests.step);

    // Journal integration tests (nested CALL/CREATE/SELFDESTRUCT state journaling)
    const journal_test_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/journal_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    journal_test_mod.addImport("evm", evm_mod);
    journal_test_mod.addImport("types", types_mod);
    journal_test_mod.addImport("crypto", crypto_mod);
    journal_test_mod.addImport("state", state_mod);

    const journal_tests = b.addTest(.{
        .root_module = journal_test_mod,
    });
    const run_journal_tests = b.addRunArtifact(journal_tests);
    test_step.dependOn(&run_journal_tests.step);

    // Edge case tests for U256
    const types_edge_test_mod = b.createModule(.{
        .root_source_file = b.path("src/types/edge_case_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    types_edge_test_mod.addImport("types", types_mod);

    const types_edge_tests = b.addTest(.{
        .root_module = types_edge_test_mod,
    });
    const run_types_edge_tests = b.addRunArtifact(types_edge_tests);
    test_step.dependOn(&run_types_edge_tests.step);

    // Edge case tests for EVM
    const evm_edge_test_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/edge_case_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_edge_test_mod.addImport("evm", evm_mod);
    evm_edge_test_mod.addImport("types", types_mod);
    evm_edge_test_mod.addImport("crypto", crypto_mod);
    evm_edge_test_mod.addImport("state", state_mod);

    const evm_edge_tests = b.addTest(.{
        .root_module = evm_edge_test_mod,
    });
    const run_evm_edge_tests = b.addRunArtifact(evm_edge_tests);
    test_step.dependOn(&run_evm_edge_tests.step);

    // Parity edge tests (signed arithmetic, bitwise shifts, env opcodes)
    const parity_edge_test_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/parity_edge_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    parity_edge_test_mod.addImport("evm", evm_mod);
    parity_edge_test_mod.addImport("types", types_mod);
    parity_edge_test_mod.addImport("state", state_mod);

    const parity_edge_tests = b.addTest(.{
        .root_module = parity_edge_test_mod,
    });
    const run_parity_edge_tests = b.addRunArtifact(parity_edge_tests);
    test_step.dependOn(&run_parity_edge_tests.step);

    // Manual opcode verification tests
    const manual_opcode_test_mod = b.createModule(.{
        .root_source_file = b.path("validation/manual_opcode_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    manual_opcode_test_mod.addImport("evm", evm_mod);
    manual_opcode_test_mod.addImport("types", types_mod);

    const manual_opcode_tests = b.addTest(.{
        .root_module = manual_opcode_test_mod,
    });
    const run_manual_opcode_tests = b.addRunArtifact(manual_opcode_tests);
    test_step.dependOn(&run_manual_opcode_tests.step);

    // Comparison tool tests
    const comparison_test_mod = b.createModule(.{
        .root_source_file = b.path("validation/comparison_tool.zig"),
        .target = target,
        .optimize = optimize,
    });
    comparison_test_mod.addImport("evm", evm_mod);
    comparison_test_mod.addImport("types", types_mod);
    comparison_test_mod.addImport("state", state_mod);

    const comparison_tests = b.addTest(.{
        .root_module = comparison_test_mod,
    });
    const run_comparison_tests = b.addRunArtifact(comparison_tests);
    test_step.dependOn(&run_comparison_tests.step);

    // Opcode verification tests
    const opcode_verification_mod = b.createModule(.{
        .root_source_file = b.path("validation/opcode_verification.zig"),
        .target = target,
        .optimize = optimize,
    });
    opcode_verification_mod.addImport("evm", evm_mod);
    opcode_verification_mod.addImport("types", types_mod);
    opcode_verification_mod.addImport("comparison_tool", comparison_test_mod);

    const opcode_verification_tests = b.addTest(.{
        .root_module = opcode_verification_mod,
    });
    const run_opcode_verification_tests = b.addRunArtifact(opcode_verification_tests);
    test_step.dependOn(&run_opcode_verification_tests.step);

    // Reference interfaces tests
    const reference_interfaces_mod = b.createModule(.{
        .root_source_file = b.path("validation/reference_interfaces.zig"),
        .target = target,
        .optimize = optimize,
    });
    reference_interfaces_mod.addImport("types", types_mod);
    reference_interfaces_mod.addImport("comparison_tool", comparison_test_mod);

    const reference_interfaces_tests = b.addTest(.{
        .root_module = reference_interfaces_mod,
    });
    const run_reference_interfaces_tests = b.addRunArtifact(reference_interfaces_tests);
    test_step.dependOn(&run_reference_interfaces_tests.step);

    // Discrepancy tracker tests
    const discrepancy_tracker_mod = b.createModule(.{
        .root_source_file = b.path("validation/discrepancy_tracker.zig"),
        .target = target,
        .optimize = optimize,
    });
    discrepancy_tracker_mod.addImport("types", types_mod);

    const discrepancy_tracker_tests = b.addTest(.{
        .root_module = discrepancy_tracker_mod,
    });
    const run_discrepancy_tracker_tests = b.addRunArtifact(discrepancy_tracker_tests);
    test_step.dependOn(&run_discrepancy_tracker_tests.step);

    // Reference test runner
    const reference_test_runner_mod = b.createModule(.{
        .root_source_file = b.path("validation/reference_test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    reference_test_runner_mod.addImport("evm", evm_mod);
    reference_test_runner_mod.addImport("types", types_mod);
    reference_test_runner_mod.addImport("comparison_tool", comparison_test_mod);
    reference_test_runner_mod.addImport("reference_interfaces", reference_interfaces_mod);
    reference_test_runner_mod.addImport("discrepancy_tracker", discrepancy_tracker_mod);

    const reference_test_runner_tests = b.addTest(.{
        .root_module = reference_test_runner_mod,
    });
    const run_reference_test_runner_tests = b.addRunArtifact(reference_test_runner_tests);
    test_step.dependOn(&run_reference_test_runner_tests.step);

    // Transaction execution tests
    const transaction_test_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/transaction.zig"),
        .target = target,
        .optimize = optimize,
    });
    transaction_test_mod.addImport("types", types_mod);
    transaction_test_mod.addImport("crypto", crypto_mod);
    transaction_test_mod.addImport("state", state_mod);
    transaction_test_mod.addImport("evm", evm_mod);

    const transaction_tests = b.addTest(.{
        .root_module = transaction_test_mod,
    });
    const run_transaction_tests = b.addRunArtifact(transaction_tests);
    test_step.dependOn(&run_transaction_tests.step);

    // Reference test runner executable
    const reference_test_exe_mod = b.createModule(.{
        .root_source_file = b.path("validation/run_reference_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    reference_test_exe_mod.addImport("evm", evm_mod);
    reference_test_exe_mod.addImport("types", types_mod);
    reference_test_exe_mod.addImport("comparison_tool", comparison_test_mod);
    reference_test_exe_mod.addImport("reference_interfaces", reference_interfaces_mod);
    reference_test_exe_mod.addImport("discrepancy_tracker", discrepancy_tracker_mod);
    reference_test_exe_mod.addImport("reference_test_runner", reference_test_runner_mod);

    const reference_test_exe = b.addExecutable(.{
        .name = "run_reference_tests",
        .root_module = reference_test_exe_mod,
    });
    b.installArtifact(reference_test_exe);

    // Machine-readable opcode/gas report generator
    const opcode_report_mod = b.createModule(.{
        .root_source_file = b.path("validation/opcode_report.zig"),
        .target = target,
        .optimize = optimize,
    });
    opcode_report_mod.addImport("types", types_mod);
    opcode_report_mod.addImport("comparison_tool", comparison_test_mod);
    opcode_report_mod.addImport("reference_interfaces", reference_interfaces_mod);

    const opcode_report_exe = b.addExecutable(.{
        .name = "opcode_report",
        .root_module = opcode_report_mod,
    });
    b.installArtifact(opcode_report_exe);

    const opcode_report_run = b.addRunArtifact(opcode_report_exe);
    if (b.args) |args| {
        opcode_report_run.addArgs(args);
    }
    const opcode_report_step = b.step("opcode-report", "Generate machine-readable opcode/gas report");
    opcode_report_step.dependOn(&opcode_report_run.step);

    // Differential fuzzing harness
    const differential_fuzz_mod = b.createModule(.{
        .root_source_file = b.path("validation/differential_fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    differential_fuzz_mod.addImport("evm", evm_mod);
    differential_fuzz_mod.addImport("types", types_mod);
    differential_fuzz_mod.addImport("comparison_tool", comparison_test_mod);
    differential_fuzz_mod.addImport("reference_interfaces", reference_interfaces_mod);

    const differential_fuzz_exe = b.addExecutable(.{
        .name = "differential_fuzz",
        .root_module = differential_fuzz_mod,
    });
    b.installArtifact(differential_fuzz_exe);

    const differential_fuzz_run = b.addRunArtifact(differential_fuzz_exe);
    if (b.args) |args| differential_fuzz_run.addArgs(args);
    const differential_fuzz_step = b.step("differential-fuzz", "Run differential fuzz (Zeth vs PyEVM)");
    differential_fuzz_step.dependOn(&differential_fuzz_run.step);

    // zeth-wasm: Browser/edge EVM target (wasm32-wasi)
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm/zeth_evm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
        .optimize = .ReleaseSmall,
    });
    wasm_mod.addImport("sim", sim_mod);

    const wasm_exe = b.addExecutable(.{
        .name = "zeth_evm",
        .root_module = wasm_mod,
    });
    wasm_exe.rdynamic = true;
    wasm_exe.entry = .disabled;
    const wasm_install = b.addInstallArtifact(wasm_exe, .{
        .dest_dir = .{ .override = .lib },
    });
    b.getInstallStep().dependOn(&wasm_install.step);

    const wasm_step = b.step("wasm", "Build zeth-wasm for browser/edge (wasm32-wasi)");
    wasm_step.dependOn(&wasm_install.step);

    // zeth-prove: RISC-V target for zkVM (SP1, RISC Zero)
    const riscv_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .linux,
        .abi = .gnu,
    });
    const riscv_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = riscv_target,
        .optimize = optimize,
    });
    riscv_exe_mod.addImport("types", types_mod);
    riscv_exe_mod.addImport("crypto", crypto_mod);
    riscv_exe_mod.addImport("rlp", rlp_mod);
    riscv_exe_mod.addImport("evm", evm_mod);
    riscv_exe_mod.addImport("state", state_mod);

    const riscv_exe = b.addExecutable(.{
        .name = "zeth-riscv64",
        .root_module = riscv_exe_mod,
    });
    b.installArtifact(riscv_exe);

    const riscv_step = b.step("riscv", "Build zeth for RISC-V (riscv64-linux)");
    riscv_step.dependOn(&b.addInstallArtifact(riscv_exe, .{}).step);

    // rv32im: zkVM target (SP1, RISC Zero, Jolt) — freestanding, no OS
    const riscv32_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
    });
    const riscv32_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = riscv32_target,
        .optimize = .ReleaseSmall,
    });
    riscv32_exe_mod.addImport("types", types_mod);
    riscv32_exe_mod.addImport("crypto", crypto_mod);
    riscv32_exe_mod.addImport("rlp", rlp_mod);
    riscv32_exe_mod.addImport("evm", evm_mod);
    riscv32_exe_mod.addImport("state", state_mod);

    const riscv32_exe = b.addExecutable(.{
        .name = "zeth-rv32",
        .root_module = riscv32_exe_mod,
    });
    riscv32_exe.entry = .disabled;
    b.installArtifact(riscv32_exe);

    const riscv32_step = b.step("riscv32", "Build zeth for RV32IM (zkVM: SP1, RISC Zero, Jolt)");
    riscv32_step.dependOn(&b.addInstallArtifact(riscv32_exe, .{}).step);
}
