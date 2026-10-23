# makefile
.PHONY: all shards clean spec run layers bench

LAYERS = terminal render
SPECS  = spec/terminal spec/render
PRUNED = lib/bytewire lib/tty lib/termwidth
KEPT   = shard.yml src
PRUNE  = find $(PRUNED) -mindepth 1 -maxdepth 1 $(foreach name,$(KEPT),! -name $(name)) -exec rm -rf {} +

all: spec layers

shard.lock:
	shards install
	$(PRUNE)

shards: clean       ## Install shards
	shards install
	$(PRUNE)

clean:              ## Remove /lib and shard.lock
	rm -rf lib
	rm -f shard.lock

spec: shard.lock    ## Run the spec suite
	crystal spec $(SPECS)

layers: shard.lock  ## Type-check each layer on its own
	@$(foreach name,$(LAYERS),echo src/asekii-term/$(name).cr && crystal build --no-codegen src/asekii-term/$(name).cr &&) true

run: shard.lock     ## Run the terminal/render flakiness harness
	spec/terminal/run.sh

bench: shard.lock   ## Run the benchmark suite
	crystal run --release bench/run.cr

help:               ## Show this help text
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-18s %s\n", $$1, $$2}'
