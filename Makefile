BEES_BIN = $(HOME)/.bees/bin

.PHONY: build install uninstall

build:
	zig build

install: build
	mkdir -p $(BEES_BIN)
	cp zig-out/bin/bees $(BEES_BIN)/bees
	chmod 755 $(BEES_BIN)/bees
	@echo "bees installed to $(BEES_BIN)/bees"
	@echo "$$PATH" | grep -q "$(BEES_BIN)" || { \
		echo ""; \
		echo "Add bees to your PATH:"; \
		case $$(basename "$${SHELL:-/bin/sh}") in \
			bash) echo "  echo 'export PATH=\"$(BEES_BIN):\$$PATH\"' >> ~/.bashrc && source ~/.bashrc" ;; \
			zsh)  echo "  echo 'export PATH=\"$(BEES_BIN):\$$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;; \
			fish) echo "  fish_add_path $(BEES_BIN)" ;; \
			ksh)  echo "  echo 'export PATH=\"$(BEES_BIN):\$$PATH\"' >> ~/.kshrc && . ~/.kshrc" ;; \
			*)    echo "  export PATH=\"$(BEES_BIN):\$$PATH\"" ;; \
		esac; \
	}

uninstall:
	rm -f $(BEES_BIN)/bees
