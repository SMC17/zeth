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

    const evm_mod = b.addModule("evm", .{
        .root_source_file = b.path("src/evm/evm.zig"),
        .target = target,
        .optimize = optimize,
    });
    evm_mod.addImport("types", types_mod);
    evm_mod.addImport("crypto", crypto_mod);

    const state_mod = b.addModule("state", .{
        .root_source_file = b.path("src/state/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    state_mod.addImport("types", types_mod);
    state_mod.addImport("crypto", crypto_mod);

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
    
    // Comprehensive EVM tests
    const comprehensive_test_mod = b.createModule(.{
        .root_source_file = b.path("src/evm/comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    comprehensive_test_mod.addImport("evm", evm_mod);
    comprehensive_test_mod.addImport("types", types_mod);
    comprehensive_test_mod.addImport("crypto", crypto_mod);
    
    const comprehensive_tests = b.addTest(.{
        .root_module = comprehensive_test_mod,
    });
    const run_comprehensive_tests = b.addRunArtifact(comprehensive_tests);
    test_step.dependOn(&run_comprehensive_tests.step);
    
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
    
    const evm_edge_tests = b.addTest(.{
        .root_module = evm_edge_test_mod,
    });
    const run_evm_edge_tests = b.addRunArtifact(evm_edge_tests);
    test_step.dependOn(&run_evm_edge_tests.step);
}
