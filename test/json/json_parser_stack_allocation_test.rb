# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'tmpdir'

class JSONParserStackAllocationTest < Test::Unit::TestCase
  def test_stack_spill_allocation_failure
    omit 'Requires CRuby and a Unix toolchain' unless RUBY_ENGINE == 'ruby' && RUBY_PLATFORM !~ /mswin|mingw/

    root = File.expand_path('../..', __dir__)
    extconf = File.join(root, 'ext/json/ext/parser/extconf.rb')
    omit 'Requires the JSON extension sources' unless File.file?(extconf)

    # Build separately to fail only the allocation in each spill function.
    # Exhausting memory globally cannot reliably reach these failure paths.
    Dir.mktmpdir('json-stack-allocation') do |dir|
      File.write(File.join(dir, 'allocation_failure.h'), <<~C)
        #include "ruby.h"
        #include <stdlib.h>
        #include <string.h>

        static void *test_alloc(size_t count, size_t size, const char *function)
        {
            const char *target = getenv("JSON_FAIL_SPILL");
            if (target && strcmp(function, target) == 0) rb_memerror();
            return ruby_xmalloc2(count, size);
        }

        #undef ALLOC_N
        #define ALLOC_N(type, count) ((type *)test_alloc(count, sizeof(type), __func__))
      C

      commands = [
        [RbConfig.ruby, extconf, '--with-cppflags=-include allocation_failure.h'],
        [ENV.fetch('MAKE', 'make')],
      ]
      commands.each do |command|
        output, status = Open3.capture2e(*command, chdir: dir)
        assert_predicate status, :success?, output
      end

      program = <<~'RUBY'
        source = if ENV.fetch('JSON_FAIL_SPILL') == 'rvalue_stack_spill'
          '[' + (['"value"'] * 129).join(',') + ']'
        else
          '[' * 40 + '0' + ']' * 40
        end
        begin
          JSON::Ext::ParserConfig.new(max_nesting: 0).parse(source)
          abort 'expected NoMemoryError'
        rescue NoMemoryError
        end
        GC.start
        GC.compact if GC.respond_to?(:compact)
      RUBY

      %w[rvalue_stack_spill json_frame_stack_spill].each do |function|
        assert_ruby_status(
          [{ 'JSON_FAIL_SPILL' => function }, "-I#{root}/lib", "-r#{dir}/parser"],
          program, function, rlimit_core: 0,
        )
      end
    end
  end
end
