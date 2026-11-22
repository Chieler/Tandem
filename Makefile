JSONC := $(shell brew --prefix json-c 2>/dev/null || echo /usr/local)
CFLAGS ?= -std=c11 -O2 -Wall -Wextra
FLAGS = -pthread -I$(JSONC)/include
LIBS = -L$(JSONC)/lib -ljson-c -lsqlite3

cntctr: cntctr.c kb.c kb.h fleet.c fleet.h hooks.c hooks.h
	$(CC) $(CFLAGS) $(FLAGS) -o $@ cntctr.c kb.c fleet.c hooks.c $(LIBS)

cntctr-test: cntctr.c kb.c kb.h fleet.c fleet.h hooks.c hooks.h
	$(CC) -std=c11 -g -O1 -Wall -Wextra -Werror -DCNTCTR_TEST_HOOKS -fsanitize=address,undefined $(FLAGS) -o $@ cntctr.c kb.c fleet.c hooks.c $(LIBS)

test: cntctr-test
	BIN=./cntctr-test bash test.sh

clean:
	rm -rf cntctr cntctr-test *.dSYM

.PHONY: test clean
