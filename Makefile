DESTDIR ?=
PREFIX  ?= /usr/local
BINDIR  := $(DESTDIR)$(PREFIX)/bin

.PHONY: default test install uninstall lint clean

default: test

test:
	bats test/*.bats

install:
	@echo "Installing oh-cred to $(BINDIR)"
	install -d $(BINDIR)
	install -m 755 bin/oh-cred $(BINDIR)/oh-cred

uninstall:
	@echo "Removing oh-cred from $(BINDIR)"
	rm -f $(BINDIR)/oh-cred

lint:
	shellcheck bin/oh-cred scripts/*.sh

clean:
	@rm -rf tmp/ scratch/ coverage/ *.log
