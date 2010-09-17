PACKAGE:=rabbitmq-shovel
APPNAME:=rabbit_shovel
DEPS:=rabbitmq-erlang-client
DEPS_FILE:=deps.mk
TEST_COMMANDS=rabbit_shovel_test:test()

include ../include.mk

$(DEPS_FILE): $(SOURCES) $(INCLUDES)
	escript generate_deps $(INCLUDE_DIR) $(SOURCE_DIR) \$$\(EBIN_DIR\) $@

clean::
	rm -f $(DEPS_FILE)

-include $(DEPS_FILE)
