#!/usr/bin/env bats
#
# Tests for install.sh — consumed as a black box through its command line.

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PROJECT_ROOT
}

@test "parse --ip and --port" {
    run "$PROJECT_ROOT/install.sh" --ip 1.2.3.4 --port 8080
    [ "$status" -eq 0 ]
    [[ "$output" == *"IP: 1.2.3.4, PORT: 8080"* ]]
}

@test "default port is 443" {
    run "$PROJECT_ROOT/install.sh" --ip 1.2.3.4
    [ "$status" -eq 0 ]
    [[ "$output" == *"PORT: 443"* ]]
}

@test "unknown argument prints usage and exits non-zero" {
    run "$PROJECT_ROOT/install.sh" --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"未知参数"* ]]
}

@test "--help prints usage and exits zero" {
    run "$PROJECT_ROOT/install.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}
