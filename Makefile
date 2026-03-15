BEES_BIN = $(HOME)/.bees/bin

.PHONY: build install uninstall

build:
	zig build

install: build
	mkdir -p $(BEES_BIN)
	cp zig-out/bin/bees $(BEES_BIN)/bees
	chmod 755 $(BEES_BIN)/bees
	@if echo "$$PATH" | grep -q "$(BEES_BIN)"; then \
		echo "bees installed to $(BEES_BIN)/bees"; \
	else \
		echo "bees installed to $(BEES_BIN)/bees"; \
		echo "Add to your PATH by running:"; \
		echo "  echo 'export PATH=\"$(BEES_BIN):\$$PATH\"' >> ~/.bashrc && source ~/.bashrc"; \
	fi

uninstall:
	rm -f $(BEES_BIN)/bees
