# Agents Guide for llm-test

## Build/Test/Lint Commands

- **Test all**: `eldev test`
- **Lint**: `eldev lint`
- **Compile**: `eldev compile`

## Code Style Guidelines

- **File format**: Emacs Lisp with `lexical-binding: t` in first line
- **Headers**: Include standard copyright, GPL license, commentary section
- **Naming**: `llm-test-` prefix for public functions, `llm-test--` for private
- **Variables**: Use `defcustom` for user options with `:type` and `:group`
- **Tests**: Use ERT (`ert-deftest`), place in `test/` directory or `*-test.el` files
- **Formatting**: Standard Emacs Lisp indentation, max ~80 chars per line

## Project Structure

- `llm-test.el` — Main library (YAML parsing, subprocess control, agent loop, ERT registration)
- `testscripts/` — Sample YAML test specifications
- `Eldev` — Build configuration

## Dependencies

- `llm` — LLM provider interface
- `yaml` — YAML parsing
- `ert` — Emacs test framework (built-in)
- `cl-lib` — Common Lisp extensions (built-in)

## Architecture

1. **YAML Parser**: Reads `.yaml` test specs into `llm-test-group` / `llm-test-spec` structs
2. **Emacs Subprocess**: Launches `emacs -Q` and communicates via eval
3. **Agent Loop**: LLM agent with tools (eval-elisp, send-keys, etc.) interprets tests
4. **ERT Integration**: Each test spec becomes an ERT test via dynamic `ert-deftest`
