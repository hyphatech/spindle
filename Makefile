# The opam switch is local (./_opam), so OCaml commands go through opam exec.
OPAM = opam exec --switch=$(CURDIR) --

PG_TEST_PORT ?= 5438
PG_TEST_URL  ?= postgres://spindle:spindle@localhost:$(PG_TEST_PORT)/spindle
export PG_TEST_PORT

# The documentation site's builder, run through uvx so nothing is installed.
ZENSICAL  = 0.0.67
DOCS_PORT ?= 8000
# The reference is odoc's, for Spindle's own packages and nothing under them.
REFERENCE = spindle spindle_cli spindle_postgres odoc.support

.DEFAULT_GOAL := help
.PHONY: help setup pin build test lint fmt doc docs docs-serve reference db db-down

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

setup: ## create the local switch and install dependencies
	@docker compose version >/dev/null 2>&1 || echo "The Postgres suites need docker compose."
	@[ -d _opam ] || opam switch create . 5.5.1 --no-install -y
	$(MAKE) pin OPAM_SWITCH=--switch=$(CURDIR)
	opam install . --switch=$(CURDIR) --deps-only --with-test --with-dev-setup -y

# Hypha's own libraries, each at its release until opam-repository has it.
OPAM_SWITCH ?=
pin: ## pin Hypha's libraries Spindle is built on to their releases
	opam pin add $(OPAM_SWITCH) -n -y "git+https://github.com/hyphatech/postgres-eio.git#0.1.0"
	opam pin add $(OPAM_SWITCH) -n -y "git+https://github.com/hyphatech/rowtype.git#0.2.0"
	opam pin add $(OPAM_SWITCH) -n -y "git+https://github.com/hyphatech/wiretype.git#0.1.0"

build: ## build everything
	$(OPAM) dune build @all

test: db ## run the tests
	SPINDLE_TEST_PG=$(PG_TEST_URL) $(OPAM) dune test --force

# Release is the profile opam installs with.
lint: ## check formatting, docs and the release build
	$(OPAM) dune build @all @fmt @doc
	$(OPAM) dune build --profile release @all

fmt: ## format the code
	$(OPAM) dune fmt

doc: ## build the API docs into _build/default/_doc/_html
	$(OPAM) dune build @doc

docs: reference ## build the documentation site into site/
	uvx zensical@$(ZENSICAL) build --strict

docs-serve: reference ## serve the documentation site on DOCS_PORT, rebuilt as pages change
	uvx zensical@$(ZENSICAL) serve --open --dev-addr localhost:$(DOCS_PORT)

reference: doc
	rm -rf docs/reference
	mkdir -p docs/reference
	cd _build/default/_doc/_html && cp -R $(REFERENCE) $(CURDIR)/docs/reference/
	chmod -R u+w docs/reference

db: ## start the test database
	docker compose up -d --wait db

db-down: ## stop and delete the test database
	docker compose rm -sf db
