PACKAGE         ?= partisan_amqp_peer_service_manager
VERSION         ?= $(shell git describe --tags)
BASE_DIR         = $(shell pwd)
ERLANG_BIN       = $(shell dirname $(shell which erl))
REBAR            = $(shell pwd)/rebar3
MAKE						 = make

.PHONY: rel deps test plots

all: compile

##
## Compilation targets
##

compile:
	$(REBAR) compile

clean: 
	$(REBAR) clean

##
## Test targets
##

kill: 
	pkill -9 beam.smp; pkill -9 epmd; exit 0

check: kill test xref dialyzer

test: ct eunit

lint:
	${REBAR} as lint lint

eunit:
	${REBAR} as test eunit

ct:
	${REBAR} ct
	${REBAR} cover

shell:
	${REBAR} shell --apps partisan

tail-logs:
	tail -F priv/lager/*/log/*.log

logs:
	cat priv/lager/*/log/*.log