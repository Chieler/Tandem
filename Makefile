JSONC := $(shell brew --prefix json-c 2>/dev/null || echo /usr/local)
CFLAGS ?= -std=c11 -O2 -Wall -Wextra
FLAGS = -pthread -I$(JSONC)/include -Ivendor/quickjs
LIBS = -L$(JSONC)/lib -ljson-c -lsqlite3 -lm

QJS_SRCS = vendor/quickjs/dtoa.c vendor/quickjs/libregexp.c vendor/quickjs/libunicode.c vendor/quickjs/quickjs.c
QJS_OBJS = $(patsubst vendor/quickjs/%.c,build/qjs/%.o,$(QJS_SRCS))
QJS_TEST_OBJS = $(patsubst vendor/quickjs/%.c,build/qjs-test/%.o,$(QJS_SRCS))

QJS_HDRS = $(wildcard vendor/quickjs/*.h)

build/qjs/%.o: vendor/quickjs/%.c $(QJS_HDRS)
	@mkdir -p $(dir $@)
	$(CC) -std=c11 -O2 -D_GNU_SOURCE -w -c $< -o $@

build/qjs-test/%.o: vendor/quickjs/%.c $(QJS_HDRS)
	@mkdir -p $(dir $@)
	$(CC) -std=c11 -g -O1 -D_GNU_SOURCE -w -fsanitize=address -c $< -o $@

cntctr: cntctr.c kb.c kb.h fleet.c fleet.h hooks.c hooks.h usage.c code_schema.c code_schema.h code_js.c code_js.h code_mcp.c code_mcp.h code_daemon.c code_daemon.h $(QJS_OBJS)
	$(CC) $(CFLAGS) $(FLAGS) -o $@ cntctr.c kb.c fleet.c hooks.c usage.c code_schema.c code_js.c code_mcp.c code_daemon.c $(QJS_OBJS) $(LIBS)

cntctr-test: cntctr.c kb.c kb.h fleet.c fleet.h hooks.c hooks.h usage.c code_schema.c code_schema.h code_js.c code_js.h code_mcp.c code_mcp.h code_daemon.c code_daemon.h $(QJS_TEST_OBJS)
	$(CC) -std=c11 -g -O1 -Wall -Wextra -Werror -DCNTCTR_TEST_HOOKS -fsanitize=address,undefined $(FLAGS) -o $@ cntctr.c kb.c fleet.c hooks.c usage.c code_schema.c code_js.c code_mcp.c code_daemon.c $(QJS_TEST_OBJS) $(LIBS)

test: cntctr-test
	BIN=./cntctr-test bash test.sh

clean:
	rm -rf cntctr cntctr-test build *.dSYM

.PHONY: test clean
