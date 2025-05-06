#Makefile for testing sparta under Xephyr

PREFIX		  ?= /usr/local
BINDIR		  ?= $(PREFIX)/bin
DISPLAY       ?= :1
XE_PHYR       ?= Xephyr
XE_FLAGS      ?= -screen 800x600
SXHKD_CMD     ?= sxhkd -c $(HOME)/.config/sxhkd/sxhkdrc
WM_CMD        ?= $(HOME)/src/sparta/main.lua
TEST_TERM_CMD ?= ghostty

.PHONY: all run stop xephyr sxhkd wm term
.PHONY: install uninstall

all: run

run: stop xephyr sxhkd wm term

stop:
	@pkill -f "Xephyr.*$(DISPLAY)"     || true
	@pkill -f "sxhkd.*sxhkdrc"         || true
	@pkill -f "$(WM_CMD)"              || true
	@pkill -f "$(TEST_TERM_CMD)"       || true


xephyr:
	@echo "[make] starting Xephyr on $(DISPLAY)"
	@$(XE_PHYR) $(XE_FLAGS) $(DISPLAY) & \
		sleep 1


sxhkd:
	@echo "[make] starting sxhkd"
	@DISPLAY=$(DISPLAY) $(SXHKD_CMD) & \
		sleep 1


wm:
	@echo "[make] starting sparta"
	@DISPLAY=$(DISPLAY) $(WM_CMD) & \
		sleep 1


term:
	@echo "[make] spawning test terminal"
	@DISPLAY=$(DISPLAY) $(TEST_TERM_CMD) & \
		sleep 1

install:
	@echo "[make] install sparta to $(BINDIR)"
	install -d $(BINDIR)
	install -m755 $(WM_CMD) $(BINDIR)/sparta

uninstall:
	@echo "[make] removing sparta from $(BINDIR)"
	rm -f $(BINDIR)/sparta

