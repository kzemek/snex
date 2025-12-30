CFLAGS ?= -g -O3 -std=c11 -Wall -Wpedantic -Wextra
CFLAGS += -Wall -Wno-format-truncation

CFLAGS += -I"$(ERTS_INCLUDE_DIR)"
CFLAGS += -Ic_src

PRIV_DIR = $(MIX_APP_PATH)/priv

ifneq ($(CROSSCOMPILE),)
    # crosscompiling
    CFLAGS += -fPIC
else
    # not crosscompiling
    ifneq ($(OS),Windows_NT)
        CFLAGS += -fPIC

        ifeq ($(shell uname),Darwin)
            LDFLAGS += -dynamiclib -undefined dynamic_lookup
        endif
    endif
endif

LIBS = $(PRIV_DIR)/env_reference_nif.so

.PHONY: calling_from_make
calling_from_make:
	mix compile

.PHONY: all
all: $(LIBS)

$(PRIV_DIR)/%.so: c_src/%.c | $(PRIV_DIR)
	$(CC) $(CFLAGS) -shared $(LDFLAGS) $^ -o "$@"

$(PRIV_DIR):
	@test -n "$(MIX_APP_PATH)" || (echo "This Makefile target cannot be called directly" ; exit 1)
	mkdir -p "$(PRIV_DIR)"

.PHONY: clean
clean:
	rm -f $(LIBS)
