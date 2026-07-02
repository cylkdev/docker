PRIV = priv
NIF = $(PRIV)/docker_termios.so
ERTS_INCLUDE = $(shell erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
CFLAGS += -fPIC -O2 -I$(ERTS_INCLUDE)

ifeq ($(shell uname),Darwin)
LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
LDFLAGS += -shared
endif

all: $(NIF)

$(NIF): c_src/docker_termios.c
	mkdir -p $(PRIV)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ c_src/docker_termios.c

clean:
	rm -f $(NIF)

.PHONY: all clean
