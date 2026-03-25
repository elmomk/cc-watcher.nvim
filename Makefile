TESTS_DIR := tests
MINI_NVIM := deps/mini.nvim

.PHONY: deps test test-file clean

deps:
	@mkdir -p deps
	@[ -d $(MINI_NVIM) ] || git clone --depth 1 https://github.com/echasnovski/mini.nvim $(MINI_NVIM)

test: deps
	nvim --headless -u tests/minimal_init.lua \
		-c "lua MiniTest.run()"

test-file: deps
	nvim --headless -u tests/minimal_init.lua \
		-c "lua MiniTest.run_file('$(FILE)')"

clean:
	rm -rf deps
