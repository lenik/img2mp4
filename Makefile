# Makefile for img2mp4

PREFIX ?= /usr
PROJECT_DIR := $(shell pwd)

.PHONY: install-debug uninstall-debug help

help:
	@echo "Available targets:"
	@echo "  install-debug  - Create symlinks for development (requires sudo)"
	@echo "  uninstall-debug - Remove development symlinks (requires sudo)"

install-debug:
	@echo "Setting up development symlinks..."
	@echo "PREFIX=$(PREFIX)"
	@echo "PROJECT_DIR=$(PROJECT_DIR)"
	@if [ ! -f "$(PROJECT_DIR)/img2mp4" ]; then \
		echo "Error: img2mp4 not found in $(PROJECT_DIR)" >&2; \
		exit 1; \
	fi
	@if [ ! -f "$(PROJECT_DIR)/img2mp4.bash-completion" ]; then \
		echo "Error: img2mp4.bash-completion not found in $(PROJECT_DIR)" >&2; \
		exit 1; \
	fi
	@echo "Creating symlink: /bin/img2mp4 -> $(PROJECT_DIR)/img2mp4"
	@sudo mkdir -p /bin
	@sudo ln -sf $(PROJECT_DIR)/img2mp4 /bin/img2mp4
	@echo "Creating symlink: /bin/img2mp4.sh -> $(PROJECT_DIR)/img2mp4.sh"
	@sudo mkdir -p /bin
	@sudo ln -sf $(PROJECT_DIR)/img2mp4.sh /bin/img2mp4.sh
	@echo "Creating symlink: $(PREFIX)/share/bash-completion/completions/img2mp4 -> $(PROJECT_DIR)/img2mp4.bash-completion"
	@sudo mkdir -p $(PREFIX)/share/bash-completion/completions
	@sudo ln -sf $(PROJECT_DIR)/img2mp4.bash-completion $(PREFIX)/share/bash-completion/completions/img2mp4
	@echo "Creating symlink: $(PREFIX)/share/bash-completion/completions/img2mp4.sh -> $(PROJECT_DIR)/img2mp4.bash-completion"
	@sudo ln -sf $(PROJECT_DIR)/img2mp4.bash-completion $(PREFIX)/share/bash-completion/completions/img2mp4.sh
	@echo "Creating symlink: $(PREFIX)/share/man/man1/img2mp4.1 -> $(PROJECT_DIR)/img2mp4.1"
	@sudo mkdir -p $(PREFIX)/share/man/man1
	@sudo ln -sf $(PROJECT_DIR)/img2mp4.1 $(PREFIX)/share/man/man1/img2mp4.1
	@echo "Development symlinks installed successfully!"
	@echo "Note: Changes to scripts in $(PROJECT_DIR) will be immediately available."

uninstall-debug:
	@echo "Removing development symlinks..."
	@sudo rm -f /bin/img2mp4
	@sudo rm -f /bin/img2mp4.sh
	@sudo rm -f $(PREFIX)/share/bash-completion/completions/img2mp4
	@sudo rm -f $(PREFIX)/share/bash-completion/completions/img2mp4.sh
	@sudo rm -f $(PREFIX)/share/man/man1/img2mp4.1
	@echo "Development symlinks removed."

