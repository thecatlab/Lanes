#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
swiftc -parse-as-library Sources/LanesCore/*.swift Tests/LanesCoreTests/TodoTests.swift -o .build/todo-tests
.build/todo-tests
