PG_TEST_PORT ?= 5438
PG_TEST_URL  ?= postgres://spindle:spindle@localhost:$(PG_TEST_PORT)/spindle
export PG_TEST_PORT

# The documentation site's builder, run through uvx so nothing is installed.
ZENSICAL  = 0.0.67
DOCS_PORT ?= 8000
# The reference is odoc's, for Spindle's own packages and nothing under them.
REFERENCE = spindle spindle-cli spindle-postgres odoc.support

.DEFAULT_GOAL := help
.PHONY: help setup build test lint fmt doc docs docs-serve reference db db-down

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

# dune builds the dependencies as it needs them (dune-workspace); setup
# brings dune's tools.
setup: ## install the formatter, odoc, the language server and Merlin
	@docker compose version >/dev/null 2>&1 || echo "The Postgres suites need docker compose."
	dune tools install ocamlformat
	dune tools install odoc
	dune tools install ocamllsp
	dune tools install ocamlmerlin

build: ## build everything
	dune build @all

test: db ## run the tests
	SPINDLE_TEST_PG=$(PG_TEST_URL) dune test --force

# Release is the profile opam installs with. The opam files are linted
# where opam is, in CI's job for the oldest versions.
lint: ## check formatting, docs and the release build
	dune build @all @fmt @doc
	dune build --profile release @all

fmt: ## format the code
	dune fmt

doc: ## build the API docs into _build/default/_doc/_html
	dune build @doc

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
