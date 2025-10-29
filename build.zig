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
}
