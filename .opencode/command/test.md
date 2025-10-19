---
description: Run tests with coverage
sub-agent: general
model: opencode/grok-code

execution_policy:
  mode: safe
  requires:
    - must_follow_agents_md: true
    - must_use_native_test_tool: true
    - no_external_frameworks: true
  allowed_tools:
    - go test
    - phpunit
    - npm test
    - zig test
    - pytest
    - cargo test
  disallowed_tools:
    - jest
    - mocha
    - custom binaries

task:
  - step: Read AGENTS.md to confirm testing conventions.
  - step: Detect project language (Go, PHP, JS, Zig, etc.).
  - step: Execute only native test runner with coverage enabled.
  - step: Parse coverage output and summarize failing tests.
  - step: Suggest fixes for failed tests, following AGENTS.md policy.
  - step: Ensure no mutation of code or non-test directories.

on_failure:
  - explain: |
      If tests fail, summarize the cause and recommend minimal, safe code changes.
      Do not modify code automatically unless explicitly authorized by policy.
---

Run the project’s full test suite with coverage report, adhering to AGENTS.md rules.  
Use only the native test framework of the detected language.  
Show all failing tests with fix suggestions.  
After tests complete, directly report the results back to the agent (no separate report file).
