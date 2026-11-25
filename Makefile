.PHONY: test build install-venv install-standalone uninstall purge

BUILD_DIR := build
STANDALONE_DIR := $(BUILD_DIR)/tofu-eq.dist

test:
	QT_QPA_PLATFORM=offscreen uv run --no-sync python -m unittest discover -s tests -v

run:
	uv run --locked tofu-eq

build:
	uv run --locked --group standalone python -m nuitka \
		--mode=standalone \
		--enable-plugin=pyside6 \
		--python-flag=package_mode \
		--python-flag=isolated \
		--output-dir=$(BUILD_DIR) \
		--output-folder-name=tofu-eq \
		--output-filename=tofu-eq \
		--include-data-dir=data=data \
		--include-data-files=LICENSE=LICENSE \
		tofu_eq

install-venv:
	bash install.sh --venv

install-standalone:
	bash install.sh --standalone "$(STANDALONE_DIR)"

uninstall:
	bash install.sh --uninstall

purge:
	bash install.sh --purge
