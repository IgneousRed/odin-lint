ifndef PROJECT_NIX_ENVIRONMENT
$(error Enter the locked Nix environment with ./scripts/dev make $(or $(MAKECMDGOALS),build); Nix is a one-time prerequisite)
endif

ODIN ?= odin
PYTHON ?= python3
CHECK_FLAGS = -vet -vet-tabs -vet-using-param -vet-nil-deref -vet-uninitialized -vet-atomic-access -strict-style -warnings-as-errors
PROJECT_PACKAGES = src,effects,functions,state,tests
PROJECT_CHECK_FLAGS = $(CHECK_FLAGS) -vet-packages:$(PROJECT_PACKAGES) -strict-style-packages:$(PROJECT_PACKAGES)
ODIN_FLAGS ?= -thread-count:2
REVISION ?= $(shell git rev-parse --verify HEAD 2>/dev/null)

.PHONY: build check lint test verify fuzz fuzz-prepare precommit check-deps

build:
	mkdir -p .work/build
	$(ODIN) build src -debug -o:speed $(ODIN_FLAGS) -define:ODIN_LINT_REVISION=$(or $(REVISION),unknown) -out:.work/build/odin-lint

check:
	$(ODIN) check src $(ODIN_FLAGS) $(PROJECT_CHECK_FLAGS)
	$(ODIN) check src $(ODIN_FLAGS) $(CHECK_FLAGS) -vet-unused-procedures -vet-packages:src,effects,state
	$(ODIN) check tests -no-entry-point $(ODIN_FLAGS) $(PROJECT_CHECK_FLAGS)

lint: build check
	.work/build/odin-lint --root . src tests

test: build
	$(ODIN) test tests -debug $(ODIN_FLAGS) $(PROJECT_CHECK_FLAGS) -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_RANDOM_SEED=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -out:.work/build/odin-lint-tests
	ODIN="$(ODIN)" ODIN_FLAGS="$(ODIN_FLAGS)" PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -p 'test_*.py'
	$(PYTHON) scripts/test-dev.py

verify: lint test

FUZZ_BUDGET ?= 60
FUZZ_SEED ?= 1

fuzz-prepare:
	ODIN="$(ODIN)" ODIN_FLAGS="$(ODIN_FLAGS)" $(PYTHON) scripts/fuzz.py --prepare-only

fuzz: lint
	./scripts/dev --profile fuzz env ODIN_FLAGS="$(ODIN_FLAGS)" $(PYTHON) scripts/fuzz.py --budget $(FUZZ_BUDGET) --seed $(FUZZ_SEED)

check-deps:
	./scripts/check-deps

precommit: check-deps
	$(MAKE) verify fuzz
