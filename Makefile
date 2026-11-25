.PHONY: test install-venv uninstall purge

test:
	QT_QPA_PLATFORM=offscreen uv run --no-sync python -m unittest discover -s tests -v

run:
	uv run --locked tofu-eq

install-venv:
	bash install.sh --venv

uninstall:
	bash install.sh --uninstall

purge:
	bash install.sh --purge
