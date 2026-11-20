ODIN ?= $(shell if command -v brew >/dev/null 2>&1 && test -x "$$(brew --prefix odin)/bin/odin"; then printf '%s/bin/odin' "$$(brew --prefix odin)"; else printf odin; fi)
PYTHON ?= python3
CHECK_FLAGS = -vet -vet-tabs -vet-using-param -vet-nil-deref -vet-uninitialized -vet-atomic-access -strict-style -warnings-as-errors
PROJECT_PACKAGES = src,effects,functions,state,tests
PROJECT_CHECK_FLAGS = $(CHECK_FLAGS) -vet-packages:$(PROJECT_PACKAGES) -strict-style-packages:$(PROJECT_PACKAGES)
ODIN_FLAGS ?= -thread-count:2
REVISION ?= $(shell git rev-parse --verify HEAD 2>/dev/null)

.PHONY: build check lint test verify

build:
	mkdir -p .work
	$(ODIN) build src -debug -o:speed $(ODIN_FLAGS) -define:ODIN_LINT_REVISION=$(or $(REVISION),unknown) -out:.work/odin-lint

check:
	$(ODIN) check src $(ODIN_FLAGS) $(PROJECT_CHECK_FLAGS)
	$(ODIN) check src $(ODIN_FLAGS) $(CHECK_FLAGS) -vet-unused-procedures -vet-packages:src,effects,state
	$(ODIN) check tests -no-entry-point $(ODIN_FLAGS) $(PROJECT_CHECK_FLAGS)

lint: build check
	.work/odin-lint --root . src tests

test: build
	$(ODIN) test tests -debug $(ODIN_FLAGS) $(PROJECT_CHECK_FLAGS) -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_RANDOM_SEED=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -out:.work/odin-lint-tests
	ODIN="$(ODIN)" PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -p 'test_*.py'

verify: lint test
