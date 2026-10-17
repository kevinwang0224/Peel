.DEFAULT_GOAL := help

CONFIGURATION ?= release

.PHONY: help build run test runtime benchmark diagnose-editor

help:
	@printf '%s\n' \
	  'make build            Build build/Peel.app (CONFIGURATION=debug for a debug build)' \
	  'make run              Build and open Peel' \
	  'make test             Run native tests (TEST_ARGS="--filter ExtractionRunnerTests")' \
	  'make runtime          Install tools and regenerate the extraction runtime (requires Node.js)' \
	  'make benchmark        Build and measure Peel (BENCHMARK_ARGS="--records 100")' \
	  'make diagnose-editor  Run the isolated editor lifecycle diagnostic with AddressSanitizer'

build:
	bash scripts/build.sh "$(CONFIGURATION)"

run: build
	open build/Peel.app

test:
	bash scripts/test.sh $(TEST_ARGS)

runtime:
	npm --prefix tools/runtime ci --ignore-scripts
	npm --prefix tools/runtime run build

benchmark:
	bash scripts/build.sh release
	python3 tools/benchmarks/benchmark.py $(BENCHMARK_ARGS)

diagnose-editor:
	python3 tools/diagnostics/diagnose-editor.py
