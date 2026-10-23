SWITCH ?= hypha-spindle
OPAM = opam exec --switch=$(SWITCH) --

PG_TEST_PORT ?= 5438
PG_TEST_URL  ?= postgres://spindle:spindle@localhost:$(PG_TEST_PORT)/spindle
export PG_TEST_PORT

DOCS_PORT ?= 4321
# The reference is odoc's, for Spindle's own packages and nothing under them.
REFERENCE = spindle spindle-cli spindle-postgres spindle-sqlite odoc.support

.DEFAULT_GOAL := help
.PHONY: help setup build test lint fmt doc docs docs-serve reference db db-down

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

setup: ## create the switch and install dependencies
	@docker compose version >/dev/null 2>&1 || echo "The Postgres suites need docker compose."
	@command -v bun >/dev/null 2>&1 || echo "The documentation site needs Bun 1.3 or later."
	@opam switch list --short | grep -qx $(SWITCH) || opam switch create $(SWITCH) --empty -y
	opam repo add hypha https://github.com/hyphatech/opam-repository.git --switch=$(SWITCH) --rank=1
	opam install . --switch=$(SWITCH) --deps-only --with-test --with-dev-setup -y

build: ## build everything
	$(OPAM) dune build @all

test: db ## run the tests
	SPINDLE_TEST_PG=$(PG_TEST_URL) $(OPAM) dune test --force

# Release is the profile opam installs with. opam lint passes a warning
# unless told it is an error, and installing from source prints each one.
lint: ## check formatting, docs, the release build and the opam files
	$(OPAM) dune build @all @fmt @doc
	$(OPAM) dune build --profile release @all
	opam lint -W @1..99 *.opam

fmt: ## format the code
	$(OPAM) dune fmt

doc: ## build the API docs into _build/default/_doc/_html
	$(OPAM) dune build @doc

# The site is Astro's, on Starlight in Hypha's theme. Bun's dependencies are
# installed again whenever the lockfile or the manifest changes, so no build
# runs against what an older checkout installed.
docs/node_modules: docs/package.json docs/bun.lock
	cd docs && bun install --frozen-lockfile
	@touch docs/node_modules

docs: reference docs/node_modules ## build the documentation site into site/
	cd docs && bun --bun astro build

# The built site, as Pages serves it: Pagefind's index exists only in a
# build, and a page served as it changes loads its styles after its text.
docs-serve: docs ## serve the built documentation site on DOCS_PORT, search included
	cd docs && bun --bun astro preview --open --port $(DOCS_PORT)

reference: doc
	rm -rf docs/public/reference
	mkdir -p docs/public/reference
	cd _build/default/_doc/_html && cp -R $(REFERENCE) $(CURDIR)/docs/public/reference/
	chmod -R u+w docs/public/reference

db: ## start the test database
	docker compose up -d --wait db

db-down: ## stop and delete the test database
	docker compose rm -sf db
