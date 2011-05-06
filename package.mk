RELEASABLE:=true
DEPS:=rabbitmq-erlang-client webmachine-wrapper
WITH_BROKER_TEST_COMMANDS:=rabbit_shovel_test:test()

CONSTRUCT_APP_PREREQS:=$(shell find $(PACKAGE_DIR)/priv -type f)
define construct_app_commands
	cp -r $(PACKAGE_DIR)/priv $(APP_DIR)
endef
