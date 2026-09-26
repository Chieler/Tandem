JSONC := $(shell brew --prefix json-c 2>/dev/null || echo /usr/local)
CFLAGS ?= -std=c11 -O2 -Wall -Wextra
FLAGS = -pthread -I$(JSONC)/include
LIBS = -L$(JSONC)/lib -ljson-c

cntctr: cntctr.c
	$(CC) $(CFLAGS) $(FLAGS) -o $@ cntctr.c $(LIBS)

cntctr-test: cntctr.c
	$(CC) -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined $(FLAGS) -o $@ cntctr.c $(LIBS)

test: cntctr-test
	BIN=./cntctr-test bash test.sh

clean:
	rm -rf cntctr cntctr-test *.dSYM

.PHONY: test clean
